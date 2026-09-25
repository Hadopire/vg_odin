#+build windows
#+private
package font

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"

foreign import dwrite_lib "system:Dwrite.lib"
foreign import gdi32 "system:Gdi32.lib"

_init :: proc() {
    factory: rawptr
    dw_check(DWriteCreateFactory(.SHARED, IFactory2_UUID, &factory), "DWriteCreateFactory(IDWriteFactory2)")
    dwrite.factory = (^IFactory2)(factory)

    gamma    :: 1.8
    contrast :: 0.5

    for rendering in RENDERING_MODE {
        if rendering == .DEFAULT || rendering == .OUTLINE {
            continue
        }
        for grid_fit in GRID_FIT_MODE {
            contrast : f32 = contrast
            if (rendering == .NATURAL || rendering == .NATURAL_SYMMETRIC) && grid_fit == .DISABLED {
                contrast = 0
            }
            dw_check(dwrite.factory->CreateCustomRenderingParams2(
                gamma,
                contrast,
                contrast,
                0,
                .FLAT,
                rendering,
                grid_fit,
                &dwrite.params[rendering][grid_fit],
            ), "CreateCustomRenderingParams2")
        }
    }

    dw_check(dwrite.factory->GetGdiInterop(&dwrite.gdi_interop), "GetGdiInterop")
}

_shutdown :: proc() {
    if dwrite.target != nil {
        dwrite.target->Release()
    }

    for rendering in RENDERING_MODE {
        for grid_fit in GRID_FIT_MODE {
            if dwrite.params[rendering][grid_fit] != nil {
                dwrite.params[rendering][grid_fit]->Release()
            }
        }
    }

    dwrite.gdi_interop->Release()
    dwrite.factory->Release()
}

_open :: proc(path: string) -> (face: Face, metrics: FaceMetrics) {
    candidates := make([dynamic]string, 0, 4, context.temp_allocator)
    append(&candidates, path)

    data_dir, _ := filepath.join({filepath.dir(os.args[0]), "..", "data", path}, context.temp_allocator)
    append(&candidates, data_dir)

    buffer: [win32.MAX_PATH]u16
    if length := win32.GetWindowsDirectoryW(&buffer[0], len(buffer)); length > 0 {
        windows_dir, _ := win32.wstring_to_utf8(win32.wstring(&buffer[0]), int(length), context.temp_allocator)
        system_font, _ := filepath.join({windows_dir, "Fonts", path}, context.temp_allocator)
        append(&candidates, system_font)
    }

    if local_dir := os.get_env("LOCALAPPDATA", context.temp_allocator); local_dir != "" {
        user_font, _ := filepath.join({local_dir, "Microsoft", "Windows", "Fonts", path}, context.temp_allocator)
        append(&candidates, user_font)
    }

    for candidate in candidates {
        font_file: ^IFontFile
        if dwrite.factory->CreateFontFileReference(win32.utf8_to_wstring(candidate, context.temp_allocator), nil, &font_file) != win32.S_OK {
            continue
        }

        files := [1]^IFontFile{ font_file }
        font_face: ^IFontFace
        result := dwrite.factory->CreateFontFace(.TRUETYPE, 1, raw_data(files[:]), 0, .NONE, &font_face)
        font_file->Release()
        if result != win32.S_OK {
            continue
        }

        font_face2: ^IFontFace2
        dw_check(font_face->QueryInterface(IFontFace2_UUID, (^rawptr)(&font_face2)), "QueryInterface(IDWriteFontFace2)")
        font_face->Release()

        design: FONT_METRICS
        font_face2->GetMetrics(&design)
        metrics = {
            units_per_em = f32(design.designUnitsPerEm),
            ascent       = f32(design.ascent),
            descent      = f32(design.descent),
            line_gap     = f32(design.lineGap),
            cap_height   = f32(design.capHeight),
            x_height     = f32(design.xHeight),
        }
        return Face(font_face2), metrics
    }

    return nil, {}
}

_close :: proc(face: Face) {
    if face != nil {
        (^IFontFace)(face)->Release()
    }
}

_rasterize :: proc(face: Face, size_in_pixel: i32, code: rune, allocator: mem.Allocator) -> Raster {
    if face == nil {
        return {}
    }
    font_face := (^IFontFace2)(face)
    em_size := f32(size_in_pixel)

    rendering: RENDERING_MODE
    grid_fit: GRID_FIT_MODE
    dw_check(font_face->GetRecommendedRenderingMode2(em_size, 96, 96, nil, false, .ANTIALIASED, .NATURAL, nil, &rendering, &grid_fit), "GetRecommendedRenderingMode")
    if rendering == .DEFAULT || rendering == .OUTLINE {
        rendering = .NATURAL_SYMMETRIC
    }
    measuring := rendering_measuring[rendering]

    face_metrics: FONT_METRICS
    font_face->GetMetrics(&face_metrics)
    scale := em_size / f32(face_metrics.designUnitsPerEm)

    code_point := u32(code)
    glyph_index: u16
    glyph_metrics: GLYPH_METRICS
    dw_check(font_face->GetGlyphIndices(&code_point, 1, &glyph_index), "GetGlyphIndices")
    if measuring == .NATURAL {
        dw_check(font_face->GetDesignGlyphMetrics(&glyph_index, 1, &glyph_metrics, false), "GetDesignGlyphMetrics")
    } else {
        dw_check(font_face->GetGdiCompatibleGlyphMetrics(em_size, 1, nil, measuring == .GDI_NATURAL, &glyph_index, 1, &glyph_metrics, false), "GetGdiCompatibleGlyphMetrics")
    }

    margin :: 3
    pen_x  := margin - i32(math.floor(f32(glyph_metrics.leftSideBearing) * scale))
    pen_y  := margin + i32(math.ceil(f32(face_metrics.ascent) * scale))
    width  := margin + pen_x + i32(math.ceil(f32(i32(glyph_metrics.advanceWidth) - glyph_metrics.rightSideBearing) * scale))
    height := margin + pen_y + i32(math.ceil(f32(face_metrics.descent) * scale))

    if width > dwrite.target_width || height > dwrite.target_height {
        if dwrite.target != nil {
            dwrite.target->Release()
        }
        dwrite.target_width = max(dwrite.target_width, width)
        dwrite.target_height = max(dwrite.target_height, height)
        dw_check(dwrite.gdi_interop->CreateBitmapRenderTarget(nil, u32(dwrite.target_width), u32(dwrite.target_height), &dwrite.target), "CreateBitmapRenderTarget")
        dw_check(dwrite.target->SetPixelsPerDip(1), "SetPixelsPerDip")

        bitmap: win32.BITMAP
        win32.GetObjectW(win32.HANDLE(GetCurrentObject(dwrite.target->GetMemoryDC(), 7)), size_of(bitmap), &bitmap)
        dwrite.target_bits = ([^]byte)(bitmap.bmBits)
        dwrite.target_pitch = i32(bitmap.bmWidthBytes)
    }

    for row in 0 ..< height {
        mem.zero(&dwrite.target_bits[row * dwrite.target_pitch], int(width) * 4)
    }

    run := GLYPH_RUN{
        fontFace     = font_face,
        fontEmSize   = em_size,
        glyphCount   = 1,
        glyphIndices = &glyph_index,
    }

    bounds: win32.RECT
    dwrite.target->DrawGlyphRun(f32(pen_x), f32(pen_y), measuring, &run, dwrite.params[rendering][grid_fit], 0x00ffffff, &bounds)

    bounds_width := bounds.right - bounds.left
    bounds_height := bounds.bottom - bounds.top
    pixels := make([]byte, int(bounds_width * bounds_height), allocator)
    for row in 0 ..< bounds_height {
        source := (bounds.top + row) * dwrite.target_pitch + bounds.left * 4
        for column in 0 ..< bounds_width {
            pixels[row * bounds_width + column] = dwrite.target_bits[source + column * 4]
        }
    }

    return {
        pixels  = pixels,
        advance = f32(glyph_metrics.advanceWidth) * scale,
        left    = bounds.left - pen_x,
        top     = bounds.top - pen_y,
        width   = bounds_width,
        height  = bounds_height,
    }
}

Dwrite :: struct {
    factory:       ^IFactory2,
    gdi_interop:   ^IGdiInterop,
    target:        ^IBitmapRenderTarget,
    target_bits:   [^]byte,
    target_pitch:  i32,
    target_width:  i32,
    target_height: i32,
    params:        [RENDERING_MODE][GRID_FIT_MODE]^IRenderingParams,
}

dwrite: Dwrite

dw_check :: proc(hr: HRESULT, msg: string, loc := #caller_location) {
    if hr != win32.S_OK {
        fmt.panicf("dwrite: %s failed (hr = 0x%x)", msg, u32(hr), loc = loc)
    }
}

@(default_calling_convention = "system")
foreign gdi32 {
    GetCurrentObject :: proc(hdc: win32.HDC, type: win32.UINT) -> win32.HGDIOBJ ---
}

HRESULT         :: win32.HRESULT
IUnknown        :: win32.IUnknown
IUnknown_VTable :: win32.IUnknown_VTable
BOOL            :: win32.BOOL
RECT            :: win32.RECT
FILETIME        :: win32.FILETIME
IID             :: win32.IID
HDC             :: win32.HDC
wstring         :: win32.wstring
COLORREF        :: u32

FACTORY_TYPE :: enum i32 {
    SHARED,
    ISOLATED,
}

FONT_FACE_TYPE :: enum i32 {
    CFF,
    TRUETYPE,
    OPENTYPE_COLLECTION,
    TYPE1,
    VECTOR,
    BITMAP,
    UNKNOWN,
    RAW_CFF,
}

FONT_SIMULATIONS :: enum i32 {
    NONE    = 0,
    BOLD    = 1,
    OBLIQUE = 2,
}

RENDERING_MODE :: enum i32 {
    DEFAULT,
    ALIASED,
    GDI_CLASSIC,
    GDI_NATURAL,
    NATURAL,
    NATURAL_SYMMETRIC,
    OUTLINE,
}

MEASURING_MODE :: enum i32 {
    NATURAL,
    GDI_CLASSIC,
    GDI_NATURAL,
}

GRID_FIT_MODE :: enum i32 {
    DEFAULT,
    DISABLED,
    ENABLED,
}

OUTLINE_THRESHOLD :: enum i32 {
    ANTIALIASED,
    ALIASED,
}

PIXEL_GEOMETRY :: enum i32 {
    FLAT,
    RGB,
    BGR,
}

FONT_METRICS :: struct {
    designUnitsPerEm:       u16,
    ascent:                 u16,
    descent:                u16,
    lineGap:                i16,
    capHeight:              u16,
    xHeight:                u16,
    underlinePosition:      i16,
    underlineThickness:     u16,
    strikethroughPosition:  i16,
    strikethroughThickness: u16,
}

GLYPH_METRICS :: struct {
    leftSideBearing:   i32,
    advanceWidth:      u32,
    rightSideBearing:  i32,
    topSideBearing:    i32,
    advanceHeight:     u32,
    bottomSideBearing: i32,
    verticalOriginY:   i32,
}

GLYPH_OFFSET :: struct {
    advanceOffset:  f32,
    ascenderOffset: f32,
}

MATRIX :: struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx:  f32,
    dy:  f32,
}

GLYPH_RUN :: struct {
    fontFace:      ^IFontFace,
    fontEmSize:    f32,
    glyphCount:    u32,
    glyphIndices:  [^]u16,
    glyphAdvances: [^]f32,
    glyphOffsets:  [^]GLYPH_OFFSET,
    isSideways:    BOOL,
    bidiLevel:     u32,
}

IFontFile :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IFontFile_VTable,
}

IFontFile_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
}

IRenderingParams :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IRenderingParams_VTable,
}

IRenderingParams_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
}

IFontFace :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IFontFace_VTable,
}

IFontFace_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
    GetType:                      rawptr,
    GetFiles:                     rawptr,
    GetIndex:                     rawptr,
    GetSimulations:               rawptr,
    IsSymbolFont:                 rawptr,
    GetMetrics:                   proc "system" (this: ^IFontFace, fontFaceMetrics: ^FONT_METRICS),
    GetGlyphCount:                rawptr,
    GetDesignGlyphMetrics:        proc "system" (this: ^IFontFace, glyphIndices: [^]u16, glyphCount: u32, glyphMetrics: [^]GLYPH_METRICS, isSideways: BOOL) -> HRESULT,
    GetGlyphIndices:              proc "system" (this: ^IFontFace, codePoints: [^]u32, codePointCount: u32, glyphIndices: [^]u16) -> HRESULT,
    TryGetFontTable:              rawptr,
    ReleaseFontTable:             rawptr,
    GetGlyphRunOutline:           rawptr,
    GetRecommendedRenderingMode:  rawptr,
    GetGdiCompatibleMetrics:      rawptr,
    GetGdiCompatibleGlyphMetrics: proc "system" (this: ^IFontFace, emSize: f32, pixelsPerDip: f32, transform: ^MATRIX, useGdiNatural: BOOL, glyphIndices: [^]u16, glyphCount: u32, glyphMetrics: [^]GLYPH_METRICS, isSideways: BOOL) -> HRESULT,
}

IFontFace1 :: struct #raw_union {
    #subtype idwritefontface: IFontFace,
    using vtable: ^IFontFace1_VTable,
}

IFontFace1_VTable :: struct {
    using idwritefontface_vtable: IFontFace_VTable,
    GetMetrics1:                   rawptr,
    GetGdiCompatibleMetrics1:      rawptr,
    GetCaretMetrics:               rawptr,
    GetUnicodeRanges:              rawptr,
    IsMonospacedFont:              rawptr,
    GetDesignGlyphAdvances:        rawptr,
    GetGdiCompatibleGlyphAdvances: rawptr,
    GetKerningPairAdjustments:     rawptr,
    HasKerningPairs:               rawptr,
    GetRecommendedRenderingMode1:  rawptr,
    GetVerticalGlyphVariants:      rawptr,
    HasVerticalGlyphVariants:      rawptr,
}

IFontFace2 :: struct #raw_union {
    #subtype idwritefontface1: IFontFace1,
    using vtable: ^IFontFace2_VTable,
}

IFontFace2_VTable :: struct {
    using idwritefontface1_vtable: IFontFace1_VTable,
    IsColorFont:                  rawptr,
    GetColorPaletteCount:         rawptr,
    GetPaletteEntryCount:         rawptr,
    GetPaletteEntries:            rawptr,
    GetRecommendedRenderingMode2: proc "system" (this: ^IFontFace2, fontEmSize: f32, dpiX: f32, dpiY: f32, transform: ^MATRIX, isSideways: BOOL, outlineThreshold: OUTLINE_THRESHOLD, measuringMode: MEASURING_MODE, renderingParams: ^IRenderingParams, renderingMode: ^RENDERING_MODE, gridFitMode: ^GRID_FIT_MODE) -> HRESULT,
}

IFontFace2_UUID := &IID{0xd8b768ff, 0x64bc, 0x4e66, {0x98, 0x2b, 0xec, 0x8e, 0x87, 0xf6, 0x93, 0xf7}}

IBitmapRenderTarget :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IBitmapRenderTarget_VTable,
}

IBitmapRenderTarget_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
    DrawGlyphRun:        proc "system" (this: ^IBitmapRenderTarget, baselineOriginX: f32, baselineOriginY: f32, measuringMode: MEASURING_MODE, glyphRun: ^GLYPH_RUN, renderingParams: ^IRenderingParams, textColor: COLORREF, blackBoxRect: ^RECT) -> HRESULT,
    GetMemoryDC:         proc "system" (this: ^IBitmapRenderTarget) -> HDC,
    GetPixelsPerDip:     rawptr,
    SetPixelsPerDip:     proc "system" (this: ^IBitmapRenderTarget, pixelsPerDip: f32) -> HRESULT,
    GetCurrentTransform: rawptr,
    SetCurrentTransform: rawptr,
    GetSize:             rawptr,
    Resize:              rawptr,
}

IGdiInterop :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IGdiInterop_VTable,
}

IGdiInterop_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
    CreateFontFromLOGFONT:    rawptr,
    ConvertFontToLOGFONT:     rawptr,
    ConvertFontFaceToLOGFONT: rawptr,
    CreateFontFaceFromHdc:    rawptr,
    CreateBitmapRenderTarget: proc "system" (this: ^IGdiInterop, hdc: HDC, width: u32, height: u32, renderTarget: ^^IBitmapRenderTarget) -> HRESULT,
}

IFactory :: struct #raw_union {
    #subtype iunknown: IUnknown,
    using vtable: ^IFactory_VTable,
}

IFactory_VTable :: struct {
    using iunknown_vtable: IUnknown_VTable,
    GetSystemFontCollection:        rawptr,
    CreateCustomFontCollection:     rawptr,
    RegisterFontCollectionLoader:   rawptr,
    UnregisterFontCollectionLoader: rawptr,
    CreateFontFileReference:        proc "system" (this: ^IFactory, filePath: wstring, lastWriteTime: ^FILETIME, fontFile: ^^IFontFile) -> HRESULT,
    CreateCustomFontFileReference:  rawptr,
    CreateFontFace:                 proc "system" (this: ^IFactory, fontFaceType: FONT_FACE_TYPE, numberOfFiles: u32, fontFiles: [^]^IFontFile, faceIndex: u32, fontFaceSimulationFlags: FONT_SIMULATIONS, fontFace: ^^IFontFace) -> HRESULT,
    CreateRenderingParams:          rawptr,
    CreateMonitorRenderingParams:   rawptr,
    CreateCustomRenderingParams:    rawptr,
    RegisterFontFileLoader:         rawptr,
    UnregisterFontFileLoader:       rawptr,
    CreateTextFormat:               rawptr,
    CreateTypography:               rawptr,
    GetGdiInterop:                  proc "system" (this: ^IFactory, gdiInterop: ^^IGdiInterop) -> HRESULT,
    CreateTextLayout:               rawptr,
    CreateGdiCompatibleTextLayout:  rawptr,
    CreateEllipsisTrimmingSign:     rawptr,
    CreateTextAnalyzer:             rawptr,
    CreateNumberSubstitution:       rawptr,
    CreateGlyphRunAnalysis:         rawptr,
}

IFactory1 :: struct #raw_union {
    #subtype idwritefactory: IFactory,
    using vtable: ^IFactory1_VTable,
}

IFactory1_VTable :: struct {
    using idwritefactory_vtable: IFactory_VTable,
    GetEudcFontCollection:        rawptr,
    CreateCustomRenderingParams1: rawptr,
}

IFactory2 :: struct #raw_union {
    #subtype idwritefactory1: IFactory1,
    using vtable: ^IFactory2_VTable,
}

IFactory2_VTable :: struct {
    using idwritefactory1_vtable: IFactory1_VTable,
    GetSystemFontFallback:        rawptr,
    CreateFontFallbackBuilder:    rawptr,
    TranslateColorGlyphRun:       rawptr,
    CreateCustomRenderingParams2: proc "system" (this: ^IFactory2, gamma: f32, enhancedContrast: f32, grayscaleEnhancedContrast: f32, clearTypeLevel: f32, pixelGeometry: PIXEL_GEOMETRY, renderingMode: RENDERING_MODE, gridFitMode: GRID_FIT_MODE, renderingParams: ^^IRenderingParams) -> HRESULT,
    CreateGlyphRunAnalysis2:      rawptr,
}

IFactory2_UUID := &IID{0x0439fc60, 0xca44, 0x4994, {0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec}}

@(default_calling_convention = "system")
foreign dwrite_lib {
    DWriteCreateFactory :: proc(factoryType: FACTORY_TYPE, iid: ^IID, factory: ^rawptr) -> HRESULT ---
}

rendering_measuring := [RENDERING_MODE]MEASURING_MODE {
    .DEFAULT           = .NATURAL,
    .ALIASED           = .GDI_CLASSIC,
    .GDI_CLASSIC       = .GDI_CLASSIC,
    .GDI_NATURAL       = .GDI_NATURAL,
    .NATURAL           = .NATURAL,
    .NATURAL_SYMMETRIC = .NATURAL,
    .OUTLINE           = .NATURAL,
}

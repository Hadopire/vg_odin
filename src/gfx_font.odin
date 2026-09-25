package vg

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import rect_pack "vendor:stb/rect_pack"

import "font"

GfxFontFace :: distinct rawptr

GfxFontMetrics :: struct {
    ascent:      f32,
    descent:     f32,
    line_gap:    f32,
    line_height: f32,
    cap_height:  f32,
    x_height:    f32,
}

GfxFontGlyph :: struct {
    advance: f32,
    bearing: [2]f32,
    subrect: RectF32,
    page:    i32,
}

GfxFontRun :: struct {
    glyphs:  []GfxFontGlyph,
    advance: f32,
}

GfxFontText :: struct {
    face:          GfxFontFace,
    size_in_point: f32,
    origin:        [2]f32,
    color:         [4]f32,
    text:          string,
}

gfx_font_atlas_size :: 1024

gfx_font_init :: proc() {
    if err := virtual.arena_init_growing(&gfx_font.arena); err != nil {
        panic("gfx_font_init: failed to init the gfx_font arena")
    }
    if err := virtual.arena_init_growing(&gfx_font.cache_arena); err != nil {
        panic("gfx_font_init: failed to init the gfx_font cache arena")
    }
    gfx_font.allocator = virtual.arena_allocator(&gfx_font.arena)
    gfx_font.cache_allocator = virtual.arena_allocator(&gfx_font.cache_arena)
    gfx_font.styles = make(map[GfxFontStyleKey]^GfxFontStyle, gfx_font.allocator)

    gfx_font.texture = gpu_create_texture({
        width         = gfx_font_atlas_size,
        height        = gfx_font_atlas_size,
        array_size    = gfx_font_atlas_count,
        format        = .R8_Unorm,
        usage         = {.Srv_Pixel, .Copy_Dest},
        initial_usage = {.Srv_Pixel},
    })
    gfx_font.view = gpu_create_texture_view(gfx_font.texture, { kind = .Srv })
    gfx_font_atlas_push()

    font.init()
}

gfx_font_shutdown :: proc() {
    for node := gfx_font.first_face; node != nil; node = node.next {
        font.close(node.face)
    }
    font.shutdown()

    for &atlas in gfx_font.atlases {
        if atlas.buffer != nil {
            gpu_destroy_buffer(atlas.buffer)
        }
    }
    gpu_destroy_view(gfx_font.view)
    gpu_destroy_texture(gfx_font.texture)
    virtual.arena_destroy(&gfx_font.cache_arena)
    virtual.arena_destroy(&gfx_font.arena)
}

gfx_font_open :: proc(path: string) -> GfxFontFace {
    for node := gfx_font.first_face; node != nil; node = node.next {
        if node.path == path {
            return GfxFontFace(node)
        }
    }

    face, metrics := font.open(path)
    if face == nil {
        return nil
    }

    node := new(GfxFontFaceNode, gfx_font.allocator)
    node.path = strings.clone(path, gfx_font.allocator)
    node.face = face
    node.metrics = metrics
    sll_stack_push(&gfx_font.first_face, node)

    return GfxFontFace(node)
}

gfx_font_metrics :: proc(face: GfxFontFace, size_in_point: f32) -> GfxFontMetrics {
    design := gfx_font_face_node(face).metrics
    scale := f32(gfx_font_size_in_pixel(size_in_point)) / design.units_per_em
    return {
        ascent      = math.round(design.ascent * scale),
        descent     = math.round(design.descent * scale),
        line_gap    = math.round(design.line_gap * scale),
        line_height = math.round((design.ascent + design.descent + design.line_gap) * scale),
        cap_height  = math.round(design.cap_height * scale),
        x_height    = math.round(design.x_height * scale),
    }
}

gfx_font_run :: proc(face: GfxFontFace, size_in_point: f32, str: string, allocator := context.temp_allocator) -> GfxFontRun {
    key := GfxFontStyleKey{ face = gfx_font_face_node(face), size_in_pixel = gfx_font_size_in_pixel(size_in_point) }
    style := gfx_font.styles[key]
    if style == nil {
        style = new(GfxFontStyle, gfx_font.cache_allocator)
        style.face = key.face
        style.size_in_pixel = key.size_in_pixel
        style.glyphs = make(map[rune]GfxFontGlyph, gfx_font.cache_allocator)
        gfx_font.styles[key] = style
    }

    run: GfxFontRun
    run.glyphs = make([]GfxFontGlyph, len(str), allocator)
    glyph_count := 0
    for code in str {
        glyph := &run.glyphs[glyph_count]
        glyph_count += 1

        is_ascii := code < 128
        if is_ascii && int(code) in style.ascii_cached {
            glyph^ = style.ascii[code]
        } else if cached, found := style.glyphs[code]; found {
            glyph^ = cached
        } else {
            raster := font.rasterize(style.face.face, style.size_in_pixel, code, context.temp_allocator)
            glyph.advance = math.round(raster.advance)

            if raster.width > 0 && raster.height > 0 {
                padding :: 1
                rect : rect_pack.Rect
                rect.w = rect_pack.Coord(raster.width + padding)
                rect.h = rect_pack.Coord(raster.height + padding)

                rect_pack.pack_rects(&gfx_font.atlases[gfx_font.atlas_count - 1].pack, &rect, 1)
                if rect.was_packed == false && gfx_font.atlas_count < gfx_font_atlas_count {
                    gfx_font_atlas_push()
                    rect_pack.pack_rects(&gfx_font.atlases[gfx_font.atlas_count - 1].pack, &rect, 1)
                }

                if rect.was_packed {
                    page := gfx_font.atlas_count - 1
                    atlas := &gfx_font.atlases[page]
                    atlas_x := i32(rect.x)
                    atlas_y := i32(rect.y)
                    for row in 0 ..< raster.height {
                        destination := (atlas_y + row) * gfx_font_atlas_size + atlas_x
                        source := row * raster.width
                        copy(atlas.pixels[destination:][:raster.width], raster.pixels[source:][:raster.width])
                    }

                    subrect := RectI32{ min = { atlas_x, atlas_y }, max = { atlas_x + raster.width, atlas_y + raster.height } }
                    glyph.bearing = { f32(raster.left), f32(raster.top) }
                    glyph.subrect = { min = linalg.array_cast(subrect.min, f32), max = linalg.array_cast(subrect.max, f32) }
                    glyph.page = page
                    if atlas.dirty.max.x > atlas.dirty.min.x {
                        atlas.dirty = { min = linalg.min(atlas.dirty.min, subrect.min), max = linalg.max(atlas.dirty.max, subrect.max) }
                    } else {
                        atlas.dirty = subrect
                    }
                } else {
                    if gfx_font.atlas_full == true {
                        fmt.printfln("gfx_font: atlas full (%v pages) - resetting at the end of the frame", gfx_font.atlas_count)
                    }
                    gfx_font.atlas_full = true
                }
            }

            if is_ascii {
                style.ascii[code] = glyph^
                style.ascii_cached += { int(code) }
            } else {
                style.glyphs[code] = glyph^
            }
        }

        run.advance += glyph.advance
    }

    run.glyphs = run.glyphs[:glyph_count]
    return run
}

gfx_font_flush :: proc(cmd: GpuCommandList) {
    gpu_barrier(cmd, GpuTextureBarrier{ texture = gfx_font.texture, before = {.Srv_Pixel}, after = {.Copy_Dest} })
    for &atlas, page in gfx_font.atlases {
        size := atlas.dirty.max - atlas.dirty.min
        if size.x > 0 && size.y > 0 {
            gpu_copy_buffer_to_texture(cmd, gfx_font.texture, 0, i32(page), atlas.dirty.min.x, atlas.dirty.min.y, size.x, size.y, atlas.buffer, 0, gfx_font_atlas_size)
        }
        atlas.dirty = {}
    }
    gpu_barrier(cmd, GpuTextureBarrier{ texture = gfx_font.texture, before = {.Copy_Dest}, after = {.Srv_Pixel} })

    if gfx_font.atlas_full {
        free_all(gfx_font.cache_allocator)
        clear(&gfx_font.styles)
        gfx_font.atlas_count = 0
        gfx_font.atlas_full = false
        gfx_font_atlas_push()
    }
}

gfx_font_atlas_view :: proc() -> GpuView {
    return gfx_font.view
}

gfx_font_atlas_count :: proc() -> i32 {
    return gfx_font.atlas_count
}

@(private="file")
gfx_font: GfxFont
@(private="file")
gfx_font_atlas_count :: 4

@(private="file")
GfxFontFaceNode :: struct {
    next:    ^GfxFontFaceNode,
    path:    string,
    face:    font.Face,
    metrics: font.FaceMetrics,
}

@(private="file")
GfxFontStyleKey :: struct {
    face:          ^GfxFontFaceNode,
    size_in_pixel: i32,
}

@(private="file")
GfxFontStyle :: struct {
    face:          ^GfxFontFaceNode,
    size_in_pixel: i32,
    ascii_cached:  bit_set[0 ..< 128],
    ascii:         [128]GfxFontGlyph,
    glyphs:        map[rune]GfxFontGlyph,
}

@(private="file")
GfxFontAtlas :: struct {
    buffer: GpuBuffer,
    pixels: []byte,
    pack:   rect_pack.Context,
    nodes:  []rect_pack.Node,
    dirty:  RectI32,
}

@(private="file")
GfxFont :: struct {
    arena:           virtual.Arena,
    allocator:       mem.Allocator,
    cache_arena:     virtual.Arena,
    cache_allocator: mem.Allocator,
    first_face:      ^GfxFontFaceNode,
    styles:          map[GfxFontStyleKey]^GfxFontStyle,
    atlases:         [gfx_font_atlas_count]GfxFontAtlas,
    atlas_count:     i32,
    atlas_full:      bool,
    texture:         GpuTexture,
    view:            GpuView,
}

@(private="file", rodata)
gfx_font_face_nil := GfxFontFaceNode{ metrics = { units_per_em = 1 } }

@(private="file")
gfx_font_face_node :: proc(face: GfxFontFace) -> ^GfxFontFaceNode {
    node := (^GfxFontFaceNode)(face)
    if node == nil {
        node = &gfx_font_face_nil
    }
    return node
}

@(private="file")
gfx_font_size_in_pixel :: proc(size_in_point: f32) -> i32 {
    pixels_per_point :: 96.0 / 72.0
    return i32(math.round(size_in_point * pixels_per_point))
}

@(private="file")
gfx_font_atlas_push :: proc() {
    atlas := &gfx_font.atlases[gfx_font.atlas_count]
    if atlas.buffer == nil {
        atlas.buffer = gpu_create_buffer({
            size   = gfx_font_atlas_size * gfx_font_atlas_size,
            usage  = {.Copy_Source},
            memory = .Upload,
        })
        atlas.pixels = gpu_map(atlas.buffer)
        mem.zero_slice(atlas.pixels)
        atlas.nodes = make([]rect_pack.Node, gfx_font_atlas_size, gfx_font.allocator)
        atlas.dirty = { max = { gfx_font_atlas_size, gfx_font_atlas_size } }
    }
    rect_pack.init_target(&atlas.pack, gfx_font_atlas_size, gfx_font_atlas_size, raw_data(atlas.nodes), i32(len(atlas.nodes)))
    gfx_font.atlas_count += 1
}

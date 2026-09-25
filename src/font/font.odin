package font

import "core:mem"

Face :: distinct rawptr

FaceMetrics :: struct {
    units_per_em: f32,
    ascent:       f32,
    descent:      f32,
    line_gap:     f32,
    cap_height:   f32,
    x_height:     f32,
}

Raster :: struct {
    pixels:  []byte,
    advance: f32,
    left:    i32,
    top:     i32,
    width:   i32,
    height:  i32,
}

init :: proc() {
    _init()
}

shutdown :: proc() {
    _shutdown()
}

open :: proc(path: string) -> (face: Face, metrics: FaceMetrics) {
    return _open(path)
}

close :: proc(face: Face) {
    _close(face)
}

rasterize :: proc(face: Face, size_in_pixel: i32, code: rune, allocator: mem.Allocator) -> Raster {
    return _rasterize(face, size_in_pixel, code, allocator)
}

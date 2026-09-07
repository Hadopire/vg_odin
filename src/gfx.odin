package vg

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:time"

GfxVertex :: struct {
    position: [3]f32,
    normal:   [3]f32,
    uv:       [2]f32,
}

GfxCamera :: struct {
    view_projection: matrix[4, 4]f32,
}

GfxTransform :: struct #packed {
    model: matrix[4, 4]f32,
    color: [4]f32,
}

#assert(size_of(GfxVertex) == 32)
#assert(size_of(GfxCamera) == 64)
#assert(size_of(GfxTransform) == 80)

GfxMesh :: struct {
    vertices:    GpuBuffer,
    vertex_view: GpuView,
    indices:     GpuBuffer,
    index_count: i32,
}

GfxTexture :: struct {
    data: GpuTexture,
    view: GpuView,
}

GFX_CHECKER_SIZE        :: 64
GFX_DEPTH_FORMAT        :: GpuFormat.D32_Float
GFX_COLOR_FORMAT        :: GpuFormat.RGBA8_Unorm
GFX_MESH_CONSTANT_COUNT :: 11

Gfx :: struct {
    arena:        virtual.Arena,
    allocator:    mem.Allocator,

    gpu_arena:       ^GpuArena,
    gpu_arena_fence: GpuFence,

    depth:        GpuTexture,
    depth_view:   GpuView,
    depth_width:  i32,
    depth_height: i32,

    layout:   GpuPipelineLayout,
    pipeline: GpuPipeline,
    sampler:  GpuSampler,

    mesh:    GfxMesh,
    texture: GfxTexture,
}

gfx: Gfx

gfx_init :: proc() {
    if err := virtual.arena_init_growing(&gfx.arena); err != nil {
        panic("gfx_init: failed to init the gfx arena")
    }
    gfx.allocator = virtual.arena_allocator(&gfx.arena)
    gfx.gpu_arena = gpu_arena_alloc(&gfx.arena, mem.Megabyte * 32)
    gfx.gpu_arena_fence = gpu_create_fence()

    gfx.sampler = gpu_create_sampler({
        min       = .Linear,
        mag       = .Linear,
        mip       = .Linear,
        address_u = .Repeat,
        address_v = .Repeat,
        address_w = .Repeat,
    })

    gfx.layout = gpu_create_pipeline_layout({ constant_count = GFX_MESH_CONSTANT_COUNT })

    when ODIN_DEBUG {
        shader_watch_init()
    }
    gfx.pipeline = gfx_create_pipeline()

    vertices: [24]GfxVertex
    indices:  [36]i32
    corners := [4][2]f32{ {-1, -1}, {1, -1}, {1, 1}, {-1, 1} }
    for face, face_index in cube_faces {
        base := face_index * 4
        for corner, corner_index in corners {
            vertices[base + corner_index] = {
                position = face.normal * 0.5 + face.u * (corner.x * 0.5) + face.v * (corner.y * 0.5),
                normal   = face.normal,
                uv       = { corner.x * 0.5 + 0.5, corner.y * 0.5 + 0.5 },
            }
        }
        indices[face_index * 6 + 0] = i32(base + 0)
        indices[face_index * 6 + 1] = i32(base + 1)
        indices[face_index * 6 + 2] = i32(base + 2)
        indices[face_index * 6 + 3] = i32(base + 0)
        indices[face_index * 6 + 4] = i32(base + 2)
        indices[face_index * 6 + 5] = i32(base + 3)
    }

    pixels: [GFX_CHECKER_SIZE * GFX_CHECKER_SIZE * 4]byte
    for y in 0 ..< GFX_CHECKER_SIZE {
        for x in 0 ..< GFX_CHECKER_SIZE {
            value: byte = ((x / 8) + (y / 8)) % 2 == 0 ? 255 : 0
            index := (y * GFX_CHECKER_SIZE + x) * 4
            pixels[index + 0] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
    }

    gfx.mesh.vertices = gpu_create_buffer({
        size   = size_of(vertices),
        usage  = GPU_BUFFER_USAGE_SRV + {.Copy_Dest},
        memory = .Device,
    })
    gfx.mesh.indices = gpu_create_buffer({
        size   = size_of(indices),
        usage  = {.Vertex_Or_Index, .Copy_Dest},
        memory = .Device,
    })
    gfx.mesh.index_count = len(indices)

    gfx.texture.data = gpu_create_texture({
        width         = GFX_CHECKER_SIZE,
        height        = GFX_CHECKER_SIZE,
        format        = .RGBA8_Unorm,
        usage         = {.Srv_Pixel, .Copy_Dest},
        initial_usage = {.Copy_Dest},
    })

    texture_bytes := gpu_texture_upload_size(gfx.texture.data, 0, 0)
    vertex_offset := 0
    index_offset := vertex_offset + size_of(vertices)
    pixel_offset := mem.align_forward_int(index_offset + size_of(indices), 512)

    staging := gpu_create_buffer({
        size   = i64(pixel_offset) + texture_bytes,
        usage  = {.Copy_Source},
        memory = .Upload,
    })
    mapped := gpu_map(staging)
    copy(mapped[vertex_offset:], (([^]byte)(&vertices[0]))[:size_of(vertices)])
    copy(mapped[index_offset:], (([^]byte)(&indices[0]))[:size_of(indices)])

    cmd := gpu_command_list_begin(.Direct)
    gpu_copy_buffer(cmd, gfx.mesh.vertices, 0, staging, i64(vertex_offset), size_of(vertices))
    gpu_copy_buffer(cmd, gfx.mesh.indices, 0, staging, i64(index_offset), size_of(indices))
    gpu_set_texture_data(cmd, gfx.texture.data, 0, 0, pixels[:], staging, i64(pixel_offset))

    buffer_barriers := [2]GpuBufferBarrier{
        { buffer = gfx.mesh.vertices, before = {.Copy_Dest}, after = GPU_BUFFER_USAGE_SRV },
        { buffer = gfx.mesh.indices, before = {.Copy_Dest}, after = {.Vertex_Or_Index} },
    }
    texture_barriers := [1]GpuTextureBarrier{
        { texture = gfx.texture.data, before = {.Copy_Dest}, after = {.Srv_Pixel} },
    }
    gpu_barrier(cmd, texture_barriers[:], buffer_barriers[:])
    gpu_command_list_end(cmd)

    submits := [1]GpuCommandList{ cmd }
    gpu_submit(submits[:])
    gpu_destroy_buffer(staging)

    gfx.mesh.vertex_view = gpu_create_buffer_view(gfx.mesh.vertices, {
        kind   = .Srv,
        count  = len(vertices),
        stride = size_of(GfxVertex),
    })
    gfx.texture.view = gpu_create_texture_view(gfx.texture.data, { kind = .Srv })
}

gfx_shutdown :: proc() {
    if gfx.depth != nil {
        gpu_destroy_view(gfx.depth_view)
        gpu_destroy_texture(gfx.depth)
    }
    gpu_destroy_view(gfx.texture.view)
    gpu_destroy_texture(gfx.texture.data)
    gpu_destroy_view(gfx.mesh.vertex_view)
    gpu_destroy_buffer(gfx.mesh.indices)
    gpu_destroy_buffer(gfx.mesh.vertices)
    gpu_destroy_pipeline(gfx.pipeline)
    gpu_destroy_pipeline_layout(gfx.layout)
    gpu_destroy_sampler(gfx.sampler)
    gpu_destroy_fence(gfx.gpu_arena_fence)

    gpu_arena_release(gfx.gpu_arena)
    virtual.arena_destroy(&gfx.arena)
}

gfx_render :: proc(frame: ^FrameContext) {
    when ODIN_DEBUG {
        shader_watch_poll()
    }

    swapchain_width, swapchain_height := gpu_swapchain_size(frame.swapchain)
    width, height := i32(frame.resolution.x), i32(frame.resolution.y)
    if min(width, height) > 0 && (swapchain_width != width || swapchain_height != height) {
        gpu_swapchain_resize(frame.swapchain, width, height)
    }
    gpu_swapchain_acquire(frame.swapchain)

    if gfx.depth == nil || gfx.depth_width != width || gfx.depth_height != height {
        if gfx.depth != nil {
            gpu_destroy_view(gfx.depth_view)
            gpu_destroy_texture(gfx.depth)
        }
        gfx.depth = gpu_create_texture({
            width         = width,
            height        = height,
            format        = GFX_DEPTH_FORMAT,
            usage         = {.Dsv_Write, .Dsv_Read},
            initial_usage = {.Dsv_Write},
        })
        gfx.depth_view = gpu_create_texture_view(gfx.depth, { kind = .Dsv, format = GFX_DEPTH_FORMAT })
        gfx.depth_width = width
        gfx.depth_height = height
    }

    camera, camera_buffer, _, camera_index := gpu_arena_push(gfx.gpu_arena, GfxCamera)
    camera.view_projection = frame.view_projection
    camera_view := gpu_create_temp_buffer_view(camera_buffer, {
        kind   = .Srv,
        first  = camera_index,
        count  = 1,
        stride = size_of(GfxCamera),
    })

    transform, transform_buffer, _, transform_index := gpu_arena_push(gfx.gpu_arena, GfxTransform)
    transform.model = frame.cube_transform
    transform.color = frame.cube_color

    transform_view := gpu_create_temp_buffer_view(transform_buffer, {
        kind   = .Srv,
        first  = transform_index,
        count  = 1,
        stride = size_of(GfxTransform),
    })

    cmd := gpu_command_list_begin(.Direct)

    back_buffer := gpu_back_buffer(frame.swapchain)
    back_buffer_view := gpu_back_buffer_view(frame.swapchain)
    gpu_barrier(cmd, GpuTextureBarrier{ texture = back_buffer, before = {.Present}, after = {.Rtv} })

    gpu_set_render_target(cmd, back_buffer_view, gfx.depth_view)
    gpu_clear_render_target(cmd, back_buffer_view, {0.05, 0.06, 0.09, 1.0})
    gpu_clear_depth_stencil(cmd, gfx.depth_view)
    gpu_set_viewport(cmd, 0, 0, width, height)
    gpu_set_scissor(cmd, 0, 0, width, height)

    gpu_set_pipeline(cmd, gfx.pipeline)
    gpu_set_index_buffer(cmd, gfx.mesh.indices, 0, .Index32)
    c_idx : i32 = 0
    c_idx = gpu_push_constant(cmd, c_idx, gfx.mesh.vertex_view)
    c_idx = gpu_push_constant(cmd, c_idx, camera_view)
    c_idx = gpu_push_constant(cmd, c_idx, transform_view)
    c_idx = gpu_push_constant(cmd, c_idx, gfx.texture.view)
    c_idx = gpu_push_constant(cmd, c_idx, gfx.sampler)
    gpu_push_constant(cmd, c_idx, i32(0))
    gpu_draw_indexed(cmd, gfx.mesh.index_count)

    gpu_barrier(cmd, GpuTextureBarrier{ texture = back_buffer, before = {.Rtv}, after = {.Present} })
    gpu_command_list_end(cmd)
    gpu_submit(cmd)

    fence_value := frame.index + 1
    gpu_fence_signal(gfx.gpu_arena_fence, .Direct, fence_value)
    gpu_arena_reset(gfx.gpu_arena, fence_value, gpu_fence_value(gfx.gpu_arena_fence))

    gpu_swapchain_present(frame.swapchain)
    gpu_collect()
}

gfx_create_pipeline :: proc() -> GpuPipeline {
    vertex_shader := shader_load("mesh.vs.dxil")
    pixel_shader := shader_load("mesh.fs.dxil")
    defer delete(vertex_shader)
    defer delete(pixel_shader)

    color_formats := [1]GpuFormat{ GFX_COLOR_FORMAT }
    return gpu_create_pipeline({
        layout        = gfx.layout,
        vertex_shader = vertex_shader,
        pixel_shader  = pixel_shader,
        color_formats = color_formats[:],
        depth_format  = GFX_DEPTH_FORMAT,
        topology      = .Triangle_List,
        raster        = { cull = .Front },
        depth         = { test = true, write = true, compare = .Less },
    })
}

shader_load :: proc(name: string) -> []byte {
    path, _ := filepath.join({filepath.dir(os.args[0]), "shaders", name}, context.temp_allocator)
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil {
        fmt.panicf("failed to read shader %s (%v)", path, err)
    }
    return data
}

when ODIN_DEBUG {

shader_source: string
shader_output: string
slangc:        string
shader_time:   time.Time

shader_watch_init :: proc() {
    exe_dir := filepath.dir(os.args[0])
    root := filepath.dir(filepath.dir(exe_dir))
    shader_source, _ = filepath.join({root, "src", "shaders", "mesh.slang"})
    shader_output, _ = filepath.join({exe_dir, "shaders"})
    slangc, _ = filepath.join({root, "vendor", "slang", "slangc.exe"})
    if info, stat_err := os.stat(shader_source, context.temp_allocator); stat_err == nil {
        shader_time = info.modification_time
    }
}

shader_watch_poll :: proc() {
    info, stat_err := os.stat(shader_source, context.temp_allocator)
    if stat_err != nil || info.modification_time == shader_time {
        return
    }
    shader_time = info.modification_time

    if !shader_compile("vs_main", "vertex", "mesh.vs.dxil") {
        return
    }
    if !shader_compile("fs_main", "fragment", "mesh.fs.dxil") {
        return
    }

    gpu_destroy_pipeline(gfx.pipeline)
    gfx.pipeline = gfx_create_pipeline()
    fmt.println("shaders reloaded")
}

shader_compile :: proc(entry: string, stage: string, output: string) -> bool {
    output_path, _ := filepath.join({shader_output, output}, context.temp_allocator)
    desc := os.Process_Desc{
        command = {slangc, shader_source, "-target", "dxil", "-profile", "sm_6_6", "-entry", entry, "-stage", stage, "-O0", "-g", "-o", output_path},
    }

    state, stdout, stderr, exec_err := os.process_exec(desc, context.temp_allocator)
    if exec_err != nil {
        fmt.println("shader reload: could not run slangc:", exec_err)
        return false
    }
    if state.exit_code != 0 {
        fmt.println("shader reload failed:")
        fmt.print(string(stdout), string(stderr))
        return false
    }
    return true
}

}

cube_faces := [6]struct{ normal, u, v: [3]f32 } {
    { {  0,  0,  1 }, {  1,  0,  0 }, {  0, -1,  0 } },
    { {  0,  0, -1 }, { -1,  0,  0 }, {  0, -1,  0 } },
    { {  1,  0,  0 }, {  0,  0, -1 }, {  0, -1,  0 } },
    { { -1,  0,  0 }, {  0,  0,  1 }, {  0, -1,  0 } },
    { {  0,  1,  0 }, {  1,  0,  0 }, {  0,  0,  1 } },
    { {  0, -1,  0 }, {  1,  0,  0 }, {  0,  0, -1 } },
}

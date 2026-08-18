package vg

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

Vertex :: struct {
    pos:   [2]f32,
    color: [3]f32,
}

Triangle :: struct {
    layout:       GpuPipelineLayout,
    pipeline:     GpuPipeline,
    buffer:       GpuBuffer,
    view:         GpuView,
    texture:      GpuTexture,
    texture_view: GpuView,
}

entry :: proc(window: WindowHandle) {
    job_init()
    defer job_shutdown()

    gpu_init()
    defer gpu_shutdown()

    swapchain := gpu_equip_window(window)
    defer gpu_unequip_window(swapchain)

    triangle: Triangle
    triangle_init(&triangle)
    defer triangle_destroy(&triangle)

    shader_watch_init()

    last_tick := time.tick_now()
    loop: for {
        events := os_poll_events()
        for event := events.first; event != nil; event = event.next {
            if event.kind == .Window_Close {
                break loop
            } else if event.kind == .Window_Resize {
                gpu_swapchain_resize(swapchain, event.width, event.height)
            } else if event.kind == .Press || event.kind == .Release {
                //fmt.println(event.kind, event.key, os_key_name(event.key), event.modifiers, event.pos_x, event.pos_y)
            } else if event.kind == .Mouse_Move || event.kind == .Scroll {
                //fmt.println(event.kind, "pos", event.pos_x, event.pos_y, "delta", event.delta_x, event.delta_y)
            }
        }

        now := time.tick_now()
        dt := time.duration_seconds(time.tick_diff(last_tick, now))
        last_tick = now

        shader_watch_poll(&triangle)

        if gpu_swapchain_acquire(swapchain) {
            cmd := gpu_command_list_begin(.Direct)
            triangle_draw(&triangle, cmd, swapchain)
            gpu_command_list_end(cmd)

            submits := [1]GpuCommandList{ cmd }
            gpu_submit(submits[:])

            gpu_swapchain_present(swapchain)
        }
        gpu_collect()
        free_all(context.temp_allocator)
    }
}

triangle_init :: proc(triangle: ^Triangle) {
    vertices := [3]Vertex{
        { pos = { 0.0,  0.6}, color = {1, 0, 0} },
        { pos = { 0.6, -0.6}, color = {0, 1, 0} },
        { pos = {-0.6, -0.6}, color = {0, 0, 1} },
    }

    triangle.buffer = gpu_create_buffer({
        size   = size_of(vertices),
        usage  = GPU_BUFFER_USAGE_SRV + {.Copy_Dest},
        memory = .Device,
    })

    staging := gpu_create_buffer({
        size   = size_of(vertices),
        usage  = {.Copy_Source},
        memory = .Upload,
    })
    mapped := gpu_map(staging)
    copy(mapped, ([^]byte)(&vertices[0])[:size_of(vertices)])

    triangle.texture = gpu_create_texture({
        width         = 64,
        height        = 64,
        format        = .RGBA8_Unorm,
        usage         = {.Srv_Pixel, .Copy_Dest},
        initial_usage = {.Copy_Dest},
    })

    pixels := make([]byte, 64 * 64 * 4, context.temp_allocator)
    for y in 0 ..< 64 {
        for x in 0 ..< 64 {
            value: byte = ((x / 8) + (y / 8)) % 2 == 0 ? 255 : 0
            index := (y * 64 + x) * 4
            pixels[index + 0] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
    }

    texture_staging := gpu_create_buffer({ size = gpu_texture_upload_size(triangle.texture, 0, 0), usage = {.Copy_Source}, memory = .Upload })

    cmd := gpu_command_list_begin(.Direct)
    gpu_copy_buffer(cmd, triangle.buffer, 0, staging, 0, size_of(vertices))
    gpu_set_texture_data(cmd, triangle.texture, 0, 0, pixels, texture_staging, 0)

    to_srv := [1]GpuBufferBarrier{{ buffer = triangle.buffer, before = {.Copy_Dest}, after = GPU_BUFFER_USAGE_SRV }}
    texture_to_srv := [1]GpuTextureBarrier{{ texture = triangle.texture, before = {.Copy_Dest}, after = {.Srv_Pixel} }}
    gpu_barrier(cmd, texture_to_srv[:], to_srv[:])
    gpu_command_list_end(cmd)

    submits := [1]GpuCommandList{ cmd }
    gpu_submit(submits[:])
    gpu_destroy_buffer(staging)
    gpu_destroy_buffer(texture_staging)

    triangle.view = gpu_create_buffer_view(triangle.buffer, { kind = .Srv, count = len(vertices), stride = size_of(Vertex) })
    triangle.texture_view = gpu_create_texture_view(triangle.texture, { kind = .Srv })

    triangle.layout = gpu_create_pipeline_layout({ constant_count = 2 })
    triangle.pipeline = triangle_create_pipeline(triangle.layout)
}

triangle_destroy :: proc(triangle: ^Triangle) {
    gpu_destroy_pipeline(triangle.pipeline)
    gpu_destroy_pipeline_layout(triangle.layout)
    gpu_destroy_view(triangle.texture_view)
    gpu_destroy_texture(triangle.texture)
    gpu_destroy_view(triangle.view)
    gpu_destroy_buffer(triangle.buffer)
}

triangle_create_pipeline :: proc(layout: GpuPipelineLayout) -> GpuPipeline {
    vertex_shader := shader_load("triangle.vs.dxil")
    pixel_shader := shader_load("triangle.fs.dxil")
    defer delete(vertex_shader)
    defer delete(pixel_shader)

    color_formats := [1]GpuFormat{ .RGBA8_Unorm }
    return gpu_create_pipeline({
        layout        = layout,
        vertex_shader = vertex_shader,
        pixel_shader  = pixel_shader,
        color_formats = color_formats[:],
    })
}

triangle_draw :: proc(triangle: ^Triangle, cmd: GpuCommandList, swapchain: GpuSwapchain) {
    back_buffer := gpu_back_buffer(swapchain)
    back_buffer_view := gpu_back_buffer_view(swapchain)
    width, height := gpu_swapchain_size(swapchain)

    to_render_target := [1]GpuTextureBarrier{{ texture = back_buffer, before = {.Present}, after = {.Rtv} }}
    gpu_barrier(cmd, to_render_target[:], nil)

    targets := [1]GpuView{ back_buffer_view }
    gpu_set_render_targets(cmd, targets[:])
    gpu_clear_render_target(cmd, back_buffer_view, {0.05, 0.06, 0.09, 1.0})
    gpu_set_viewport(cmd, 0, 0, width, height)
    gpu_set_scissor(cmd, 0, 0, width, height)

    gpu_set_pipeline(cmd, triangle.pipeline)
    constants := [2]i32{ gpu_view_index(triangle.view), gpu_view_index(triangle.texture_view) }
    gpu_set_constants(cmd, constants[:])
    gpu_draw(cmd, 3)

    to_present := [1]GpuTextureBarrier{{ texture = back_buffer, before = {.Rtv}, after = {.Present} }}
    gpu_barrier(cmd, to_present[:], nil)
}

shader_load :: proc(name: string) -> []byte {
    path, _ := filepath.join({filepath.dir(os.args[0]), "shaders", name}, context.temp_allocator)
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil {
        fmt.panicf("failed to read shader %s (%v)", path, err)
    }
    return data
}

shader_source: string
shader_output: string
slangc:        string
shader_time:   time.Time

shader_watch_init :: proc() {
    exe_dir := filepath.dir(os.args[0])
    root := filepath.dir(filepath.dir(exe_dir))
    shader_source, _ = filepath.join({root, "src", "shaders", "triangle.slang"})
    shader_output, _ = filepath.join({exe_dir, "shaders"})
    slangc, _ = filepath.join({root, "third_party", "slang", "slangc.exe"})
    if info, stat_err := os.stat(shader_source, context.temp_allocator); stat_err == nil {
        shader_time = info.modification_time
    }
}

shader_watch_poll :: proc(triangle: ^Triangle) {
    info, stat_err := os.stat(shader_source, context.temp_allocator)
    if stat_err != nil || info.modification_time == shader_time {
        return
    }
    shader_time = info.modification_time

    if !shader_compile("vs_main", "vertex", "triangle.vs.dxil") {
        return
    }
    if !shader_compile("fs_main", "fragment", "triangle.fs.dxil") {
        return
    }

    gpu_destroy_pipeline(triangle.pipeline)
    triangle.pipeline = triangle_create_pipeline(triangle.layout)
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

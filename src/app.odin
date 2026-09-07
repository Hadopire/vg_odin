package vg

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:time"

FrameContext :: struct {
    index:           i64,
    arena:           virtual.Arena,
    allocator:       mem.Allocator,
    dt:              f32,
    time:            f32,
    resolution:      [2]f32,
    swapchain:       GpuSwapchain,
    view_projection: matrix[4, 4]f32,
    cube_transform:  matrix[4, 4]f32,
    cube_color:      [4]f32,
    os_events:       OsEventList,
}

AppContext :: struct {
    render_counter:  ^JobCounter,
    cursor:          [2]f32,
    async_rendering: bool,
    done:            bool,
}

@(private="file")
first_tick: time.Tick
@(private="file")
prev_tick: time.Tick

update :: proc(app: ^AppContext, frame: ^FrameContext) {
    for event := frame.os_events.first; event != nil; event = event.next {
        #partial switch event.kind {
        case .Window_Close:
            app.done = true
            return
        case .Mouse_Move:
            app.cursor.x = f32(event.pos_x)
            app.cursor.y = f32(event.pos_y)
        case .Window_Drag_Begin:
            app.async_rendering = false
        case .Window_Drag_End:
            app.async_rendering = true
        }
    }

    z    :: 5
    fov  :: 90
    near :: 0.1
    far  :: 100

    aspect := frame.resolution.x / frame.resolution.y
    tan_half := math.tan_f32(math.to_radians_f32(fov) * 0.5)
    half_height := tan_half * z
    half_width := half_height * aspect
    cube_position := [3]f32{
        (2 * app.cursor.x / frame.resolution.x - 1) * half_width,
        (1 - 2 * app.cursor.y / frame.resolution.y) * half_height,
        z,
    }

    eye := [3]f32{ 0, 0, 0 }
    target := [3]f32{ 0, 0, 1 }
    world_up := [3]f32{ 0, 1, 0 }
    forward := linalg.normalize(target - eye)
    right := linalg.normalize(linalg.cross(world_up, forward))
    up := linalg.cross(forward, right)

    view := matrix[4, 4]f32{
        right.x,   right.y,   right.z,   -linalg.dot(right, eye),
        up.x,      up.y,      up.z,      -linalg.dot(up, eye),
        forward.x, forward.y, forward.z, -linalg.dot(forward, eye),
        0,         0,         0,         1,
    }

    focal := 1 / tan_half
    depth_scale: f32 = far / (far - near)
    projection := matrix[4, 4]f32{
        focal / aspect, 0,     0,           0,
        0,              focal, 0,           0,
        0,              0,     depth_scale, -depth_scale * near,
        0,              0,     1,           0,
    }

    rotation := linalg.matrix4_rotate_f32(frame.time * 0.8, linalg.normalize([3]f32{ 0.4, 1, 0.2 }))
    frame.view_projection = projection * view
    frame.cube_transform = linalg.matrix4_translate_f32(cube_position) * rotation
}

render_job :: proc(data: rawptr, index: i32) {
    frame := (^FrameContext)(data)
    gfx_render(frame)
    free_all(frame.allocator)
}

entry :: proc(window: WindowHandle) {
    job_init()
    defer job_shutdown()

    gpu_init()
    defer gpu_shutdown()

    swapchain := gpu_equip_window(window)
    defer gpu_unequip_window(swapchain)

    gfx_init()
    defer gfx_shutdown()

    frame_contexts: [2]FrameContext
    for &frame in frame_contexts {
        if err := virtual.arena_init_growing(&frame.arena); err != nil {
            panic("failed to init the frame arena")
        }
        frame.allocator = virtual.arena_allocator(&frame.arena)
        frame.swapchain = swapchain
        frame.cube_color = { 1.0, 0.35, 0.2, 1 }
    }

    start_tick := time.tick_now()
    last_tick := start_tick
    initial_x, initial_y := os_mouse_position(window)

    app: AppContext
    app.cursor.x, app.cursor.y = f32(initial_x), f32(initial_y)

    loop: for frame_index : i64 = 0;; frame_index += 1 {
        frame := &frame_contexts[frame_index % len(frame_contexts)]
        free_all(frame.allocator)
        frame.index = frame_index

        if app.async_rendering {
            gpu_swapchain_wait(frame.swapchain)
        }

        frame.os_events = os_poll_events()
        now := time.tick_now()
        frame.dt = f32(time.duration_seconds(time.tick_diff(last_tick, now)))
        frame.time = f32(time.duration_seconds(time.tick_diff(start_tick, now)))
        last_tick = now
        window_width, window_height := os_window_size(window)
        frame.resolution.x, frame.resolution.y = f32(max(1, window_width)), f32(max(1, window_height))

        update(&app, frame)
        if app.done do break

        if app.render_counter != nil {
            wait_and_release_counter(app.render_counter)
            app.render_counter = nil
        }

        if app.async_rendering {
            app.render_counter = job_schedule(.High, render_job, frame)
        } else {
            render_job(frame, 0)
        }

        free_all(context.temp_allocator)
    }

    if app.render_counter != nil {
        wait_and_release_counter(app.render_counter)
    }
}

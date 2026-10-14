package vg

import "core:fmt"
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
    cursor:           [2]f32,
    swapchain:       GpuSwapchain,
    view_projection: matrix[4, 4]f32,
    cube_transform:  matrix[4, 4]f32,
    cube_color:      [4]f32,
    ui:              []^UiBox,
    os_events:       OsEventList,
    window:          WindowHandle,
}

AppContext :: struct {
    render_counter:  ^JobCounter,
    face:            GfxFontFace,
    ui_cache:        UiCache,
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

    frame.cursor = app.cursor
    ui_begin(frame^, &app.ui_cache)
    ui_push_font_face(app.face)

    ui_push_pref_width({ kind = .Percent_Of_Parent, value = 1, strictness = 1 })
    ui_push_pref_height({ kind = .Children_Sum, strictness = 1 })
    ui_row_begin({.Draw_Background}, "menu_bar")
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_push_background_color({ 0.22, 0.24, 0.3, 1 })
    ui_push_corner_radius(4)
    ui_push_text_padding(8)
    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
    for name in ([]string{ "File", "Edit", "View", "Window", "Help" }) {
        if .Clicked in ui_button(name).flags {
            fmt.println("clicked", name)
        }
    }
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_pop_text_padding()
    ui_pop_corner_radius()
    ui_pop_background_color()
    ui_row_end()

    ui_spacer({ kind = .Pixels, value = 24 })

    ui_push_pref_width({ kind = .Children_Sum })
    ui_push_pref_height({ kind = .Children_Sum, strictness = 0 })
    ui_push_corner_radius(8)
    ui_column_begin({.Draw_Drop_Shadow, .Draw_Background, .Draw_Border, .Clip})
    ui_pop_corner_radius()
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_push_text_padding(8)
    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
    for size_in_point in ([]f32{ 9, 11, 14, 20 }) {
        ui_push_font_size(size_in_point)
        ui_label(fmt.tprintf("A %vpt label in a Children_Sum panel", size_in_point))
        ui_pop_font_size()
    }
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_pop_text_padding()
    ui_column_end()

    ui_spacer({ kind = .Pixels, value = 100, strictness = 0 })

    ui_push_pref_width({ kind = .Pixels, value = 500, strictness = 1 })
    ui_push_pref_height({ kind = .Pixels, value = 100, strictness = 1 })
    ui_push_background_color([4]f32{1,1,1,1})
    ui_push_text_color([4]f32{0,0,0,1})
    ui_row_begin({.Draw_Background}, "panel")

    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
    ui_push_background_color({ 0.85, 0.3, 0.3, 1 })
    ui_push_text_padding(8)
    floating := ui_box_make({.Floating_X, .Floating_Y, .Draw_Background, .Draw_Text}, "Floating")
    floating.rel_position = { 300, 30 }
    ui_pop_text_padding()
    ui_pop_background_color()
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_spacer({ kind = .Percent_Of_Parent, value = 1 })

    ui_push_pref_width({ kind = .Children_Sum, strictness = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, value = 1, strictness = 0 })
    ui_column_begin()
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_spacer({ kind = .Percent_Of_Parent, value = 1 })

    ui_push_pref_height({ kind = .Text_Content, strictness = 1})
    ui_push_pref_width({ kind = .Text_Content, strictness = 1})
    ui_label("->HELLO CENTER<-")
    ui_pop_pref_width()
    ui_pop_pref_height()

    ui_spacer({ kind = .Percent_Of_Parent, value = 1 })
    ui_column_end()

    ui_spacer({ kind = .Percent_Of_Parent, value = 1 })
    ui_row_end()

    ui_pop_text_color()
    ui_pop_background_color()
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })

    ui_push_pref_width({ kind = .Pixels, value = 200, strictness = 1 })
    ui_push_pref_height({ kind = .Pixels, value = 40, strictness = 1 })
    ui_row_begin({.Clip, .Draw_Background, .Draw_Border}, "clip_demo")
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, value = 1, strictness = 1 })
    ui_push_text_padding(8)
    ui_label("Clip:")
    if .Clicked in ui_button("JSUIS COUPE DU CUL").flags {
        fmt.println("clip click")
    }
    ui_pop_text_padding()
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_row_end()

    ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })

    ui_push_pref_width({ kind = .Children_Sum, strictness = 1 })
    ui_push_pref_height({ kind = .Children_Sum, strictness = 1 })
    ui_row_begin()
    ui_pop_pref_height()
    ui_pop_pref_width()
    for name in ([]string{ "scroll_pixels", "scroll_percent" }) {
        flags := UiBoxFlags{.Clip, .View_Scroll_Y, .Draw_Background, .Draw_Border}
        if name == "scroll_percent" {
            flags += {.View_Scroll_Percent}
        }
        ui_push_pref_width({ kind = .Pixels, value = 200, strictness = 1 })
        ui_push_pref_height({ kind = .Pixels, value = 120, strictness = 1 })
        region := ui_column_begin(flags, name)
        ui_pop_pref_height()
        ui_pop_pref_width()

        ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
        ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
        ui_push_text_padding(8)
        for line in ([]string{ "Sloubi 1", "Sloubi 2", "Sloubi 3", "Sloubi 4", "Sloubi 5", "Sloubi 6", "ABOBA", "lbp", "fddr", "cclpo", "asdasdasd", "asdasdasd", "asdasdasd", "asdasdasd", "asdasdasd", "Asdasdasd", "asdasdasd"}) {
            ui_label(line)
        }
        ui_pop_text_padding()
        ui_pop_pref_height()
        ui_pop_pref_width()
        ui_column_end()
        ui_signal(region)

        ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })
    }
    ui_row_end()

    ui_pop_font_face()
    ui_end()
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

    app: AppContext
    app.face = gfx_font_open("Quicksand-Regular.ttf")

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
        frame.window = window

        update(&app, frame)
        if app.done do break

        if app.render_counter != nil {
            wait_and_release_counter(app.render_counter)
            app.render_counter = nil
        }

        frame.ui = ui_layout()

        if app.async_rendering {
            app.render_counter = job_schedule(.High, render_job, frame)
        } else {
            render_job(frame, 0)
            gpu_queue_wait(.Direct)
        }

        free_all(context.temp_allocator)
    }

    if app.render_counter != nil {
        wait_and_release_counter(app.render_counter)
    }
}

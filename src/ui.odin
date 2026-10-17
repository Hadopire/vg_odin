package vg

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"

UiAxis :: enum i32 {
    X,
    Y,
}

UiSizeKind :: enum i32 {
    Pixels,
    Text_Content,
    Percent_Of_Parent,
    Children_Sum,
}

UiSize :: struct {
    kind:       UiSizeKind,
    value:      f32,
    strictness: f32,
}

UiBoxFlag :: enum {
    Clickable,
    Clip,
    Floating_X,
    Floating_Y,
    View_Scroll_X,
    View_Scroll_Y,
    View_Scroll_Percent,
    Draw_Drop_Shadow,
    Draw_Background,
    Draw_Border,
    Draw_Text,
    Draw_Hot_Effects,
    Draw_Active_Effects,
}
UiBoxFlags :: bit_set[UiBoxFlag]

UiKey :: struct {
    value: u64
}

UiScroll :: struct {
    offset:       [2]f32,
    target:       [2]f32,
    percent:      [2]f32,
    content_size: [2]f32,
}

UiBox :: struct {
    first_child:  ^UiBox,
    last_child:   ^UiBox,
    next:         ^UiBox,
    prev:         ^UiBox,
    parent:       ^UiBox,

    // builder settings
    flags:             UiBoxFlags,
    text:              string,
    pref_size:         [2]UiSize,
    child_layout_axis: UiAxis,
    background_color:  [4]f32,
    text_color:        [4]f32,
    border_color:      [4]f32,
    corner_radius:     f32,
    border_thickness:  f32,
    text_padding:      f32,
    font_face:         GfxFontFace,
    font_size:         f32,

    // layout data
    hash_key:     UiKey,
    run:          GfxFontRun,
    rel_position: [2]f32,
    fixed_size:   [2]f32,
    rect:         RectF32,
    clip:         RectF32,
    hot_t:        f32,
    active_t:     f32,

    // cached data from last frame
    scroll: UiScroll,
}

UiCacheNode :: struct {
    rect:               RectF32,
    clip_rect:          RectF32,
    last_touched_index: i64,
    hot_t:              f32,
    active_t:           f32,
    scroll:             UiScroll,
}

UiCache :: struct {
    nodes:            map[UiKey]UiCacheNode,
    hot_key:          UiKey,
    active_key:       UiKey,
    drag_start_mouse: [2]f32,
    drag_data:        [64]byte,
}

UiSignalFlag :: enum {
    Pressed,
    Released,
    Clicked,
    Dragging,
    Hovering,
    Mouse_Over,
    Scrolled,
}

UiSignalFlags :: bit_set[UiSignalFlag]

UiSignal :: struct {
    box:        ^UiBox,
    flags:      UiSignalFlags,
    cursor:     [2]f32,
    drag_delta: [2]f32,
    clip_rect:  RectF32
}

UiWindowSignalFlag :: enum {
    Close,
    Raise,
}

UiWindowSignal :: bit_set[UiWindowSignalFlag]

UiWindow :: struct {
    rect: RectF32
}


ui_begin :: proc(frame: FrameContext, cache: ^UiCache) {
    root := new(UiBox, frame.allocator)
    root.flags = {.Clip}
    root.pref_size = { { kind = .Pixels, value = frame.resolution.x, strictness = 1 }, { kind = .Pixels, value = frame.resolution.y, strictness = 1 } }
    root.child_layout_axis = .Y

    ui_state = {
        allocator   = frame.allocator,
        frame_index = frame.index,
        dt          = frame.dt,
        cache       = cache,
        events      = frame.os_events,
        cursor      = frame.cursor,
        root        = root,
        box_count   = 1,
        stacks      = ui_stacks_default,
    }
    ui_state.stacks.parent.items[0] = root

    if cache.active_key not_in cache.nodes {
        cache.active_key = ui_nil_key
    }
    if cache.active_key == ui_nil_key {
        cache.hot_key = ui_nil_key
    }
}

ui_end :: proc() {
    assert(ui_state.stacks.parent.count == 1, "ui_end: parent stack not popped")
    assert(ui_state.stacks.child_layout_axis.count == 1, "ui_end: child_layout_axis stack not popped")
    assert(ui_state.stacks.pref_width.count == 1, "ui_end: pref_width stack not popped")
    assert(ui_state.stacks.pref_height.count == 1, "ui_end: pref_height stack not popped")
    assert(ui_state.stacks.background_color.count == 1, "ui_end: background_color stack not popped")
    assert(ui_state.stacks.text_color.count == 1, "ui_end: text_color stack not popped")
    assert(ui_state.stacks.font_face.count == 1, "ui_end: font_face stack not popped")
    assert(ui_state.stacks.font_size.count == 1, "ui_end: font_size stack not popped")
    assert(ui_state.stacks.border_color.count == 1, "ui_end: border_color stack not popped")
    assert(ui_state.stacks.corner_radius.count == 1, "ui_end: corner_radius stack not popped")
    assert(ui_state.stacks.border_thickness.count == 1, "ui_end: border_thickness stack not popped")
    assert(ui_state.stacks.text_padding.count == 1, "ui_end: text_padding stack not popped")
}

ui_box_make :: proc(flags := UiBoxFlags{}, text := "") -> ^UiBox {
    display_text := text
    hashed_text := text
    if index := strings.index(text, "##"); index >= 0 {
        display_text = text[:index]
        hashed_text = text[index + 2:]
    }
    return ui_box_make_keyed(flags, display_text, hashed_text)
}

ui_signal :: proc(box: ^UiBox) -> UiSignal {
    cache := ui_state.cache
    signal := UiSignal{ box = box, cursor = ui_state.cursor }
    if box.hash_key == ui_nil_key {
        return signal
    }
    rect := cache.nodes[box.hash_key].clip_rect
    is_clickable := .Clickable in box.flags
    scrolls_x := .View_Scroll_X in box.flags
    scrolls_y := .View_Scroll_Y in box.flags

    for event := ui_state.events.first; event != nil; event = event.next {
        if event.consumed {
            continue
        }
        position := [2]f32{ f32(event.pos_x), f32(event.pos_y) }
        is_left_mouse := event.key == .Mouse_Left

        if is_clickable && is_left_mouse && event.kind == .Press && rect_contains(rect, position) {
            cache.hot_key = box.hash_key
            cache.active_key = box.hash_key
            cache.drag_start_mouse = position
            signal.flags += {.Pressed}
            event.consumed = true
        }

        if is_clickable && is_left_mouse && event.kind == .Release && cache.active_key == box.hash_key {
            cache.active_key = ui_nil_key
            signal.flags += {.Released}
            if rect_contains(rect, position) {
                signal.flags += {.Clicked}
            } else {
                cache.hot_key = ui_nil_key
            }
            event.consumed = true
        }

        if (scrolls_x || scrolls_y) && event.kind == .Scroll && rect_contains(rect, position) {
            speed : f32 = 0.75
            delta := [2]f32{ f32(event.delta_x) * speed, -f32(event.delta_y) * speed }
            if .Shift in event.modifiers {
                delta = { delta.y, delta.x }
            }
            if !scrolls_x {
                delta = { 0, delta.x + delta.y }
            }
            if !scrolls_y {
                delta = { delta.x + delta.y, 0 }
            }
            box.scroll.target += delta
            signal.flags += {.Scrolled}
            event.consumed = true
        }
    }

    mouse_over := rect_contains(rect, ui_state.cursor)
    if mouse_over {
        signal.flags += {.Mouse_Over}
    }
    if cache.active_key == box.hash_key {
        signal.flags += {.Dragging}
        signal.drag_delta = ui_state.cursor - cache.drag_start_mouse
    }
    nobody_hot := cache.hot_key == ui_nil_key || cache.hot_key == box.hash_key
    nobody_active := cache.active_key == ui_nil_key || cache.active_key == box.hash_key
    if is_clickable && mouse_over && nobody_hot && nobody_active {
        cache.hot_key = box.hash_key
        signal.flags += {.Hovering}
    }
    signal.clip_rect = rect
    return signal
}

ui_spacer :: proc(size: UiSize) {
    parent := ui_stack_top(&ui_state.stacks.parent)
    box := ui_box_make()
    layout_axis := int(parent.child_layout_axis)
    box.pref_size[layout_axis] = size
    box.pref_size[1 - layout_axis] = { kind = .Pixels, value = 0, strictness = 1 }
}

ui_row_begin :: proc(flags := UiBoxFlags{}, key := "", padding := UiSize{}) -> ^UiBox {
    return ui_layout_box_begin(.X, flags, key, padding)
}

ui_row_end :: proc(loc := #caller_location) {
    ui_layout_box_end(loc)
}

ui_column_begin :: proc(flags := UiBoxFlags{}, key := "", padding := UiSize{}) -> ^UiBox {
    return ui_layout_box_begin(.Y, flags, key, padding)
}

ui_column_end :: proc(loc := #caller_location) {
    ui_layout_box_end(loc)
}

ui_label :: proc(text: string) {
    ui_box_make_keyed({.Draw_Text}, text, "")
}

ui_button :: proc(text: string) -> UiSignal {
    box := ui_box_make({.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, text)
    return ui_signal(box)
}

ui_line_height :: proc(box: ^UiBox = nil) -> f32 {
    if box != nil {
        return gfx_font_metrics(box.font_face, box.font_size).line_height
    }
    return gfx_font_metrics(ui_stack_top(&ui_state.stacks.font_face), ui_stack_top(&ui_state.stacks.font_size)).line_height
}

ui_cache_node :: proc(box: ^UiBox) -> UiCacheNode {
    node: UiCacheNode
    if box.hash_key != ui_nil_key {
        node = ui_state.cache.nodes[box.hash_key]
    }
    return node
}

ui_drag_store :: proc(value: $T) where size_of(T) <= size_of(UiCache{}.drag_data) {
    value := value
    mem.copy(&ui_state.cache.drag_data, &value, size_of(T))
}

ui_drag_load :: proc($T: typeid) -> (value: T) where size_of(T) <= size_of(UiCache{}.drag_data) {
    mem.copy(&value, &ui_state.cache.drag_data, size_of(T))
    return value
}

ui_scroll_bar :: proc(box: ^UiBox) {
    parent      := ui_stack_top(&ui_state.stacks.parent)
    cross_index := int(parent.child_layout_axis)
    axis_index  := 1 - cross_index
    axis        := UiAxis(axis_index)
    cross       := UiAxis(cross_index)

    box_rect     := ui_cache_node(box).rect
    view_size    := box_rect.max[axis_index] - box_rect.min[axis_index]
    content_size := box.scroll.content_size[axis_index]
    max_scroll   := max(content_size - view_size, 0)

    show_scroll_bar := max_scroll > 0
    if show_scroll_bar {
        padding_px :: 1
        thumb_size_pct: f32 = max(view_size / content_size, 0.05)
        thumb_pos_pct: f32 = box.scroll.offset[axis_index] / max_scroll * (1 - thumb_size_pct)
        key := fmt.tprintf("scroll_bar_%v_%v", box.hash_key.value, axis)

        scroll_bar := ui_layout_box_begin(cross, {.Clickable, .Draw_Background}, key, padding = { kind = .Pixels, value = padding_px, strictness = 1 })
            scroll_bar.pref_size[axis_index] = { kind = .Percent_Of_Parent, value = 1 }
            scroll_bar.pref_size[cross_index] = { kind = .Children_Sum, strictness = 1 }
            scroll_bar.corner_radius = 4
            track := ui_layout_box_begin(axis, {}, "track", padding = { kind = .Pixels, value = padding_px, strictness = 1 })
                track.pref_size[axis_index] = { kind = .Percent_Of_Parent, value = 1 }
                track.pref_size[cross_index] = { kind = .Children_Sum, strictness = 1 }
                ui_spacer({ kind = .Percent_Of_Parent, value = thumb_pos_pct })
                thumb := ui_box_make_keyed({.Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, "", "thumb")
                thumb.pref_size[axis_index] = { kind = .Percent_Of_Parent, value = thumb_size_pct }
                thumb.pref_size[cross_index] = { kind = .Pixels, value = 4, strictness = 1 }
                thumb.background_color = thumb.text_color
                thumb.corner_radius = 2
                ui_spacer({ kind = .Percent_Of_Parent, value = 1 - thumb_pos_pct - thumb_size_pct })
            ui_layout_box_end()
        ui_layout_box_end()

        track_rect    := ui_cache_node(track).rect
        track_size_px := track_rect.max[axis_index] - track_rect.min[axis_index] - padding_px * 2
        thumb_size_px := track_size_px * thumb_size_pct
        track_start   := track_rect.min[axis_index] + thumb_size_px * 0.5 + padding_px
        track_length  := track_size_px - thumb_size_px

        thumb_signal := ui_signal(thumb)
        bar_signal   := ui_signal(scroll_bar)
        if .Pressed in thumb_signal.flags {
            // store the current offset as the initial offset when dragging the thumb
            ui_drag_store(box.scroll.target[axis_index])
        }
        if .Pressed in bar_signal.flags {
            // scroll to the click position and store that as the initial offset when dragging the track
            offset := (bar_signal.cursor[axis_index] - track_start) / track_length * max_scroll
            ui_drag_store(clamp(offset, 0, max_scroll))
        }

        #unroll for signal in ([2]UiSignal{ thumb_signal, bar_signal }) {
            if .Dragging in signal.flags {
                offset := clamp(ui_drag_load(f32) + signal.drag_delta[axis_index] / track_length * max_scroll, 0, max_scroll)
                box.scroll.offset[axis_index] = offset
                box.scroll.target[axis_index] = offset
            }
        }
    }
}

ui_window_begin :: proc(text: string, window: ^UiWindow) -> UiWindowSignal {
    outer_px  :: 2
    corner_px :: 16
    flags       := UiBoxFlags{.Draw_Background, .Clip}
    border_px   := ui_stack_top(&ui_state.stacks.border_thickness)
    handle_px   := border_px + outer_px * 2
    min_size_px := [2]f32{ 50, ui_line_height() }
    if border_px > 0 {
        flags += {.Draw_Border}
    }
    window.rect.max = linalg.max(window.rect.max, window.rect.min + min_size_px)

    ui_push_pref_width({ kind = .Percent_Of_Parent, value = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, value = 1 })
    defer ui_pop_pref_height()
    defer ui_pop_pref_width()
    win_box := ui_box_make({.Clickable, .Floating_X, .Floating_Y}, text)
    ui_push_parent(win_box)

    // the window should be raised to the front when clicked
    result: UiWindowSignal
    win_rect := ui_cache_node(win_box).clip_rect
    for event := ui_state.events.first; event != nil; event = event.next {
        position := [2]f32{ f32(event.pos_x), f32(event.pos_y) }
        if event.kind == .Press && event.key == .Mouse_Left && !event.consumed && rect_contains(win_rect, position) {
            result += {.Raise}
        }
    }

    // resize handles
    handles: [4]^UiBox
    ui_row_begin({.Floating_X, .Floating_Y})
        handles[0] = ui_box_make_keyed({.Clickable}, "", "handle_left")
        ui_column_begin()
            handles[3] = ui_box_make_keyed({.Clickable}, "", "handle_top")
            ui_spacer({ kind = .Percent_Of_Parent, value = 1 })
            handles[1] = ui_box_make_keyed({.Clickable}, "", "handle_bot")
        ui_column_end()
        handles[2] = ui_box_make_keyed({.Clickable}, "", "handle_right")
    ui_row_end()

    for handle in handles {
        axis_index := int(handle.parent.child_layout_axis)
        handle.pref_size[axis_index] = { kind = .Pixels, value = handle_px, strictness = 1 }
        handle.pref_size[1 - axis_index] = { kind = .Percent_Of_Parent, value = 1 }
    }

    // content
    content: ^UiBox
    title:   ^UiBox
    ui_row_begin(padding = { kind = .Pixels, value = outer_px, strictness = 1 })
        ui_column_begin(padding = { kind = .Pixels, value = outer_px, strictness = 1 })
            ui_row_begin(flags, padding = { kind = .Pixels, value = border_px, strictness = 1 })
                ui_column_begin(padding = { kind = .Pixels, value = border_px, strictness = 1 })
                    title = ui_row_begin({.Clickable}, "title_bar")
                        title.pref_size[1] = { kind = .Children_Sum, strictness = 1 }
                        ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
                        ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
                        ui_label(win_box.text)
                        ui_spacer({ kind = .Percent_Of_Parent, value = 1 })
                        if .Clicked in ui_button("X").flags {
                            result += {.Close}
                        }
                        ui_pop_pref_height()
                        ui_pop_pref_width()
                    ui_row_end()
                    content = ui_box_make({.Clip})
                    content.child_layout_axis = .Y
                ui_column_end()
            ui_row_end()
        ui_column_end()
    ui_row_end()

    // drag
    signals: [5]UiSignal
    for handle, index in handles {
        signals[index] = ui_signal(handle)
        if .Pressed in signals[index].flags {
            cursor := signals[index].cursor
            drag := UiWindowDrag{ rect = window.rect }
            if cursor.x < window.rect.min.x + corner_px do drag.mask.min.x = 1
            if cursor.y < window.rect.min.y + corner_px do drag.mask.min.y = 1
            if cursor.x > window.rect.max.x - corner_px do drag.mask.max.x = 1
            if cursor.y > window.rect.max.y - corner_px do drag.mask.max.y = 1
            ui_drag_store(drag)
        }
    }

    signals[4] = ui_signal(title)
    if .Pressed in signals[4].flags {
        drag := UiWindowDrag{ rect = window.rect }
        drag.mask.min = {1, 1}
        drag.mask.max = {1, 1}
        ui_drag_store(drag)
    }

    for signal in signals {
        if .Dragging in signal.flags {
            drag := ui_drag_load(UiWindowDrag)
            rect := RectF32{
                min = drag.rect.min + signal.drag_delta * drag.mask.min,
                max = drag.rect.max + signal.drag_delta * drag.mask.max,
            }
            #unroll for axis in 0 ..< 2 {
                if drag.mask.min[axis] > drag.mask.max[axis] {
                    rect.min[axis] = min(rect.min[axis], rect.max[axis] - min_size_px[axis])
                } else if drag.mask.min[axis] < drag.mask.max[axis] {
                    rect.max[axis] = max(rect.max[axis], rect.min[axis] + min_size_px[axis])
                }
            }
            window.rect = rect
        }
    }

    size_px := window.rect.max - window.rect.min + outer_px * 2
    win_box.rel_position = window.rect.min - outer_px
    win_box.pref_size[0] = { kind = .Pixels, value = size_px.x, strictness = 1 }
    win_box.pref_size[1] = { kind = .Pixels, value = size_px.y, strictness = 1 }

    ui_push_parent(content)
    return result
}

ui_window_end :: proc() {
    ui_pop_parent()
    win_box := ui_stack_top(&ui_state.stacks.parent)
    ui_signal(win_box) // eat inputs over this window
    ui_pop_parent()
}

ui_push_parent :: proc(box: ^UiBox) {
    ui_stack_push(&ui_state.stacks.parent, box)
}

ui_pop_parent :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.parent, loc)
}

ui_push_child_layout_axis :: proc(axis: UiAxis) {
    ui_stack_push(&ui_state.stacks.child_layout_axis, axis)
}

ui_pop_child_layout_axis :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.child_layout_axis, loc)
}

ui_push_pref_width :: proc(size: UiSize) {
    ui_stack_push(&ui_state.stacks.pref_width, size)
}

ui_pop_pref_width :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.pref_width, loc)
}

ui_push_pref_height :: proc(size: UiSize) {
    ui_stack_push(&ui_state.stacks.pref_height, size)
}

ui_pop_pref_height :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.pref_height, loc)
}

ui_push_background_color :: proc(color: [4]f32) {
    ui_stack_push(&ui_state.stacks.background_color, color)
}

ui_pop_background_color :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.background_color, loc)
}

ui_push_text_color :: proc(color: [4]f32) {
    ui_stack_push(&ui_state.stacks.text_color, color)
}

ui_pop_text_color :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.text_color, loc)
}

ui_push_font_face :: proc(face: GfxFontFace) {
    ui_stack_push(&ui_state.stacks.font_face, face)
}

ui_pop_font_face :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.font_face, loc)
}

ui_push_font_size :: proc(size_in_point: f32) {
    ui_stack_push(&ui_state.stacks.font_size, size_in_point)
}

ui_pop_font_size :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.font_size, loc)
}

ui_push_border_color :: proc(color: [4]f32) {
    ui_stack_push(&ui_state.stacks.border_color, color)
}

ui_pop_border_color :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.border_color, loc)
}

ui_push_corner_radius :: proc(radius: f32) {
    ui_stack_push(&ui_state.stacks.corner_radius, radius)
}

ui_pop_corner_radius :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.corner_radius, loc)
}

ui_push_border_thickness :: proc(thickness: f32) {
    ui_stack_push(&ui_state.stacks.border_thickness, thickness)
}

ui_pop_border_thickness :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.border_thickness, loc)
}

ui_push_text_padding :: proc(padding: f32) {
    ui_stack_push(&ui_state.stacks.text_padding, padding)
}

ui_pop_text_padding :: proc(loc := #caller_location) {
    ui_stack_pop(&ui_state.stacks.text_padding, loc)
}

ui_layout :: proc() -> (draw_list: []^UiBox) {
    boxes := make([]^UiBox, ui_state.box_count, ui_state.allocator)
    box_index := 0
    for box := ui_state.root; box != nil; {
        boxes[box_index] = box
        box_index += 1

        if .Draw_Text in box.flags {
            box.run = gfx_font_run(box.font_face, box.font_size, box.text, ui_state.allocator)
        }

        if box.last_child != nil {
            box = box.last_child
        } else {
            for box != nil && box.prev == nil {
                box = box.parent
            }
            if box != nil {
                box = box.prev
            }
        }
    }

    // size
    for axis in 0 ..< 2 {
        floating_flag := ui_floating_flag(axis)

        // two passes, so that floating childen with Percent_Of_Parent sizes can be resolved with Children_Sum parent
        for _ in 0 ..< 2 {
            // downwards pass
            for box in boxes {
                size := box.pref_size[axis]
                #partial switch size.kind {
                case .Pixels:
                    box.fixed_size[axis] = size.value
                case .Text_Content:
                    content := axis == 0 ? box.run.advance + box.text_padding * 2 : gfx_font_metrics(box.font_face, box.font_size).line_height
                    box.fixed_size[axis] = content + size.value
                case .Percent_Of_Parent:
                    ancestor := box.parent
                    for (ancestor.pref_size[axis].kind == .Children_Sum && floating_flag not_in box.flags) {
                        ancestor = ancestor.parent
                    }
                    box.fixed_size[axis] = ancestor.fixed_size[axis] * size.value
                }
            }

            // upwards pass
            #reverse for box in boxes {
                if box.pref_size[axis].kind == .Children_Sum {
                    sum: f32
                    for child := box.first_child; child != nil; child = child.next {
                        if floating_flag in child.flags {
                            continue
                        }
                        if int(box.child_layout_axis) == axis {
                            sum += child.fixed_size[axis]
                        } else {
                            sum = max(sum, child.fixed_size[axis])
                        }
                    }
                    box.fixed_size[axis] = sum
                }
            }
        }

        // constraints
        for box in boxes {
            allowed_size := box.fixed_size[axis]

            if axis == int(box.child_layout_axis) {
                // solve constraint along the layout axis
                children_sum:   f32
                removeable_sum: f32
                for child := box.first_child; child != nil; child = child.next {
                    if floating_flag in child.flags {
                        continue
                    }
                    child_size := child.fixed_size[axis]
                    children_sum += child_size
                    removeable_sum += child_size * (1-child.pref_size[axis].strictness)
                }

                overflow := children_sum - allowed_size
                if overflow > 0 && removeable_sum > 0 {
                    rm_pct := min(overflow / removeable_sum, 1)
                    for child := box.first_child; child != nil; child = child.next {
                        if floating_flag in child.flags {
                            continue
                        }
                        removeable := child.fixed_size[axis] * (1-child.pref_size[axis].strictness)
                        child.fixed_size[axis] -= removeable * rm_pct
                        children_sum -= removeable * rm_pct
                    }
                }
                box.scroll.content_size[axis] = children_sum

            } else {
                // solve constraint along the *non*-layout axis
                children_max: f32
                for child := box.first_child; child != nil; child = child.next {
                    if floating_flag in child.flags {
                        continue
                    }
                    overflow := child.fixed_size[axis] - allowed_size
                    if overflow > 0 {
                        removeable := child.fixed_size[axis] * (1 - child.pref_size[axis].strictness)
                        child.fixed_size[axis] -= min(overflow, removeable)
                    }
                    children_max = max(children_max, child.fixed_size[axis])
                }
                box.scroll.content_size[axis] = children_max
            }
        }
    }

    // scroll
    for box in boxes {
        if box.hash_key == ui_nil_key {
            continue
        }
        node := &ui_state.cache.nodes[box.hash_key]
        scroll := &box.scroll
        for axis in 0 ..< 2 {
            max_scroll := max(scroll.content_size[axis] - box.fixed_size[axis], 0)

            target_untouched := scroll.target[axis] == node.scroll.target[axis]
            if .View_Scroll_Percent in box.flags && target_untouched {
                target := scroll.percent[axis] * max_scroll
                scroll.offset[axis] += target - scroll.target[axis]
                scroll.target[axis] = target
            }
            scroll.target[axis] = clamp(scroll.target[axis], 0, max_scroll)
            scroll.offset[axis] = ui_ease(scroll.offset[axis], scroll.target[axis], 15)
            scroll.offset[axis] = clamp(scroll.offset[axis], 0, max_scroll)
            scroll.percent[axis] = max_scroll > 0 ? scroll.target[axis] / max_scroll : 0
        }
        node.scroll = box.scroll
    }

    // position
    ui_state.root.rect = { {}, ui_state.root.fixed_size }
    ui_state.root.clip = ui_state.root.rect
    for box in boxes {
        layout_axis := int(box.child_layout_axis)
        cross_axis := 1 - layout_axis
        children_clip := .Clip in box.flags ? rect_intersect(box.clip, box.rect) : box.clip
        offset: f32
        for child := box.first_child; child != nil; child = child.next {
            if ui_floating_flag(layout_axis) not_in child.flags {
                child.rel_position[layout_axis] = offset
                offset += child.fixed_size[layout_axis]
            }
            if ui_floating_flag(cross_axis) not_in child.flags {
                child.rel_position[cross_axis] = 0
            }
            child.rect.min = linalg.floor(box.rect.min + child.rel_position - box.scroll.offset)
            child.rect.max = linalg.floor(child.rect.min + child.fixed_size)
            child.clip = children_clip
        }
    }

    // update cache
    for box in boxes {
        is_cached := box.hash_key != ui_nil_key
        if is_cached {
            node := &ui_state.cache.nodes[box.hash_key]
            node.rect = box.rect
            node.clip_rect = rect_intersect(box.rect, box.clip)
            is_hot: f32 = box.hash_key == ui_state.cache.hot_key ? 1 : 0
            is_active: f32 = box.hash_key == ui_state.cache.active_key ? 1 : 0
            node.hot_t = ui_ease(node.hot_t, is_hot, 20)
            node.active_t = ui_ease(node.active_t, is_active, 40)
            box.hot_t = node.hot_t
            box.active_t = node.active_t
        }
    }

    for key, node in ui_state.cache.nodes {
        if node.last_touched_index != ui_state.frame_index {
            delete_key(&ui_state.cache.nodes, key)
        }
    }

    return boxes
}

@(private="file")
UiStack :: struct($T: typeid) {
    items: [64]T,
    count: i32,
}

@(private="file")
UiStacks :: struct {
    parent:            UiStack(^UiBox),
    child_layout_axis: UiStack(UiAxis),
    pref_width:        UiStack(UiSize),
    pref_height:       UiStack(UiSize),
    background_color:  UiStack([4]f32),
    text_color:        UiStack([4]f32),
    font_face:         UiStack(GfxFontFace),
    font_size:         UiStack(f32),
    border_color:      UiStack([4]f32),
    corner_radius:     UiStack(f32),
    border_thickness:  UiStack(f32),
    text_padding:      UiStack(f32),
}

@(private="file")
UiState :: struct {
    allocator:   mem.Allocator,
    frame_index: i64,
    dt:          f32,
    cache:       ^UiCache,
    stacks:      UiStacks,
    events:      OsEventList,
    cursor:       [2]f32,
    root:        ^UiBox,
    box_count:   i32,
}

@(private="file")
ui_state: UiState

@(private="file")
UiWindowDrag :: struct {
    rect: RectF32,
    mask: RectF32,
}

@(private="file")
ui_box_make_keyed :: proc(flags: UiBoxFlags, display_text: string, key: string) -> ^UiBox {
    parent := ui_stack_top(&ui_state.stacks.parent)

    hash_key: UiKey
    if len(key) > 0 {
        seed := u64(0xcbf29ce484222325)
        for ancestor := parent; ancestor != nil; ancestor = ancestor.parent {
            if ancestor.hash_key != ui_nil_key {
                seed = ancestor.hash_key.value
                break
            }
        }
        hash_key.value = hash.fnv64a(transmute([]byte)key, seed)
    }

    cached: UiCacheNode
    is_cached := hash_key != ui_nil_key
    if is_cached {
        _, node, just_inserted, _ := map_entry(&ui_state.cache.nodes, hash_key)
        if !just_inserted && node.last_touched_index == ui_state.frame_index {
            hash_key = ui_nil_key
        } else {
            node.last_touched_index = ui_state.frame_index
            cached = node^
        }
    }

    box := new(UiBox, ui_state.allocator)
    dll_push_back(&parent.first_child, &parent.last_child, box)
    box.parent = parent
    box.flags = flags
    box.text = strings.clone(display_text, ui_state.allocator)
    box.hash_key = hash_key
    box.pref_size = { ui_stack_top(&ui_state.stacks.pref_width), ui_stack_top(&ui_state.stacks.pref_height) }
    box.child_layout_axis = ui_stack_top(&ui_state.stacks.child_layout_axis)
    box.background_color = ui_stack_top(&ui_state.stacks.background_color)
    box.text_color = ui_stack_top(&ui_state.stacks.text_color)
    box.font_face = ui_stack_top(&ui_state.stacks.font_face)
    box.font_size = ui_stack_top(&ui_state.stacks.font_size)
    box.border_color = ui_stack_top(&ui_state.stacks.border_color)
    box.corner_radius = ui_stack_top(&ui_state.stacks.corner_radius)
    box.border_thickness = ui_stack_top(&ui_state.stacks.border_thickness)
    box.text_padding = ui_stack_top(&ui_state.stacks.text_padding)
    box.scroll = cached.scroll

    ui_state.box_count += 1
    return box
}

@(private="file")
ui_layout_box_begin :: proc(axis: UiAxis, flags: UiBoxFlags, key: string, padding: UiSize) -> ^UiBox {
    box := ui_box_make_keyed(flags, "", key)
    box.child_layout_axis = axis
    ui_push_parent(box)
    ui_spacer(padding)
    return box
}

@(private="file")
ui_layout_box_end :: proc(loc := #caller_location) {
    box := ui_stack_top(&ui_state.stacks.parent)
    padding := box.first_child.pref_size[int(box.child_layout_axis)]
    if padding.value == 0 {
        dll_remove(&box.first_child, &box.last_child, box.first_child)
        ui_state.box_count -= 1
    } else {
        ui_spacer(padding)
    }
    ui_pop_parent(loc)
}

@(private="file")
ui_floating_flag :: proc(axis: int) -> UiBoxFlag {
    return UiBoxFlag(int(UiBoxFlag.Floating_X) + axis)
}

@(private="file")
ui_ease :: proc(current: f32, target: f32, decay: f32) -> f32 {
    return target + (current - target) * math.exp(-decay * ui_state.dt)
}

@(private="file")
ui_stack_push :: proc(stack: ^UiStack($T), value: T) {
    stack.items[stack.count] = value
    stack.count += 1
}

@(private="file")
ui_stack_pop :: proc(stack: ^UiStack($T), loc: runtime.Source_Code_Location) {
    assert(stack.count > 1, "ui_pop: popping the stack's default value", loc)
    stack.count -= 1
}

@(private="file")
ui_stack_top :: proc(stack: ^UiStack($T)) -> T {
    return stack.items[stack.count - 1]
}

@(private="file")
ui_stacks_default := UiStacks{
    parent            = { count = 1 },
    child_layout_axis = { items = { 0 = .Y }, count = 1 },
    pref_width        = { count = 1 },
    pref_height       = { count = 1 },
    background_color  = { items = { 0 = { 0.14, 0.15, 0.19, 1 } }, count = 1 },
    text_color        = { items = { 0 = { 0.9, 0.9, 0.92, 1 } }, count = 1 },
    font_face         = { count = 1 },
    font_size         = { items = { 0 = 14 }, count = 1 },
    border_color      = { items = { 0 = { 0.32, 0.35, 0.44, 1 } }, count = 1 },
    corner_radius     = { count = 1 },
    border_thickness  = { items = { 0 = 1 }, count = 1 },
    text_padding      = { count = 1 },
}

@(private="file")
ui_nil_key :: UiKey{}
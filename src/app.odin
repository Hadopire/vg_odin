package vg

import "core:time"
import "core:fmt"

entry :: proc(window: WindowHandle) {
    job_init()
    defer job_shutdown()

    last_tick := time.tick_now()
    loop: for {
        events := os_poll_events()
        for event := events.first; event != nil; event = event.next {
            if event.kind == .Window_Close {
                break loop
            } else if event.kind == .Press || event.kind == .Release {
                fmt.println(event.kind, event.key, os_key_name(event.key), event.modifiers, event.pos_x, event.pos_y)
            } else if event.kind == .Mouse_Move || event.kind == .Scroll {
                fmt.println(event.kind, "pos", event.pos_x, event.pos_y, "delta", event.delta_x, event.delta_y)
            }
        }

        now := time.tick_now()
        dt := time.duration_seconds(time.tick_diff(last_tick, now))
        last_tick = now

        time.sleep(time.Second / 144.0)
        free_all(context.temp_allocator)
    }
}

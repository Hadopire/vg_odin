package vg_odin

import "base:intrinsics"
import "core:math/rand"
import "core:fmt"

job_count :: 100
sample_count :: 100_000

monte_carlo_job :: proc(data: rawptr, index: int) {
    count := 0
    for _ in 0 ..< sample_count {
        x := rand.float32_range(-1.0, 1.0)
        y := rand.float32_range(-1.0, 1.0)
        if x * x + y * y <= 1.0 {
            count += 1
        }
    }
    intrinsics.atomic_add((^int)(data), count)
}

main :: proc() {
    job_init()
    defer job_shutdown()

    count: int
    params: [job_count]JobParam
    for &p in params {
        p.procedure = monte_carlo_job
        p.data = &count
    }

    counter := job_schedule(params[:])
    wait_and_release_counter(counter)

    fmt.println("pi:", 4.0 * f32(count) / (job_count * sample_count))
}
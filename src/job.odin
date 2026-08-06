package vg

import "base:intrinsics"
import "core:mem/virtual"
import "core:sync"
import "core:sys/info"
import "core:mem"
import "core:thread"
import "fiber"

JobProc :: #type proc(data: rawptr, index: int)

JobPriority :: enum {
    High,
    Normal,
    Low,
}

JobParam :: struct {
    priority:  JobPriority,
    procedure: JobProc,
    data:      rawptr,
}

JobCounter :: struct {
    next:          ^JobCounter,
    value:          int,
    waiters_mutex:  sync.Mutex,
    waiters_first: ^WorkerFiber,
    waiters_last:  ^WorkerFiber,
}

job_init :: proc(num_threads: int = 0, num_fibers: int = 128, fiber_stack_size: int = mem.Kilobyte * 256) {
    n := num_threads
    if n == 0 {
        _, logical, _ := info.cpu_core_count()
        n = logical - 1
    }
    job_system.running = true
    job_system.fiber_stack_size = max(fiber_stack_size, min_stack_size)

    if err := virtual.arena_init_growing(&job_system.arena); err != nil {
        panic("job_system: failed to init arena")
    }
    job_system.allocator = virtual.arena_allocator(&job_system.arena)

    init_fiber := new(WorkerFiber, job_system.allocator)
    init_fiber.fiber = fiber.current()
    init_fiber.fiber.data = init_fiber
    job_system.init_fiber = init_fiber
    is_init_thread = true

    job_system.fiber_storage = make([]WorkerFiber, num_fibers, job_system.allocator)
    for &work_fiber in job_system.fiber_storage {
        work_fiber.fiber = fiber.create(worker_fiber_proc, data = &work_fiber, stack_size = fiber_stack_size)
        sll_stack_push(&job_system.free_fibers, &work_fiber)
    }

    job_system.threads = make([]^thread.Thread, n, job_system.allocator)
    for i in 0 ..< n {
        t := thread.create(worker_thread_proc)
        job_system.threads[i] = t
        thread.start(t)
    }
}

job_shutdown :: proc() {
    assert(current_work_fiber() == job_system.init_fiber, "job_shutdown() must be called from the fiber that called job_system_init()")

    sync.mutex_lock(&job_system.queue_mutex)
    job_system.running = false
    sync.cond_broadcast(&job_system.queue_cond)
    sync.mutex_unlock(&job_system.queue_mutex)

    // if we are not running on the init thread, it means shutdown() was called from a worker thread
    // in this case, we need the init thread to take over from here
    // otherwise, this thread would commit sepuku and that would be sad
    relay: ^fiber.Fiber
    if intrinsics.volatile_load(&is_init_thread) == false {
        shutdown_relay_proc :: proc(f: ^fiber.Fiber) {
            sync.mutex_lock(&job_system.shutdown_mutex)
            job_system.shutdown_ready = true
            sync.mutex_unlock(&job_system.shutdown_mutex)
            sync.cond_signal(&job_system.shutdown_cond)
            fiber.switch_to(thread_fiber)
        }

        job_system.shutdown_fiber = current_work_fiber()
        relay = fiber.create(shutdown_relay_proc, allocator = job_system.allocator)
        fiber.switch_to(relay)
    }

    for worker_thread in job_system.threads {
        thread.destroy(worker_thread)
    }

    for &work_fiber in job_system.fiber_storage {
        fiber.destroy(work_fiber.fiber)
    }

    if relay != nil {
        fiber.destroy(relay)
    }

    virtual.arena_destroy(&job_system.arena)
}

job_schedule_single :: proc(priority: JobPriority, procedure: JobProc, data: rawptr, counter: ^JobCounter = nil) -> ^JobCounter {
    counter := counter
    if counter == nil {
        counter = new_counter(1)
    } else {
        intrinsics.atomic_add(&counter.value, 1)
    }

    sync.mutex_lock(&job_system.queue_mutex)
    job := new_job()
    job^ = Job { nil, procedure, data, 0, counter }
    q := &job_system.job_queues[priority]
    sll_queue_push(&q.first, &q.last, job)
    sync.cond_signal(&job_system.queue_cond)
    sync.mutex_unlock(&job_system.queue_mutex)

    return counter
}

job_schedule_batch :: proc(params: []JobParam, counter: ^JobCounter = nil) -> ^JobCounter {
    counter := counter
    if counter == nil {
        counter = new_counter(len(params))
    } else {
        intrinsics.atomic_add(&counter.value, len(params))
    }

    first, last, count := acquire_free_jobs(len(params))

    d := len(params) - count
    if d > 0 {
        jobs := make([]Job, d, job_system.allocator)
        for &job in jobs {
            sll_queue_push(&first, &last, &job)
        }
    }

    sync.mutex_lock(&job_system.queue_mutex)
    job := first
    for param, i in params {
        next := job.next
        job^ = Job { nil, param.procedure, param.data, i, counter }
        q := &job_system.job_queues[param.priority]
        sll_queue_push(&q.first, &q.last, job)
        job = next
    }
    sync.cond_broadcast(&job_system.queue_cond)
    sync.mutex_unlock(&job_system.queue_mutex)

    return counter
}

job_schedule :: proc{job_schedule_single, job_schedule_batch}

wait_for_counter :: proc(counter: ^JobCounter) {
    if intrinsics.atomic_load(&counter.value) != 0 {
        self := current_work_fiber()
        next := acquire_free_fiber()
        switch_and_handoff(next.fiber, .Wait_On_Counter, self, counter)
    }
}

wait_and_release_counter :: proc(counter: ^JobCounter) {
    wait_for_counter(counter)
    release_counter(counter)
}


/* internals */

@(private="file")
Job :: struct {
    next:      ^Job,
    procedure:  JobProc,
    data:       rawptr,
    index:      int,
    counter:   ^JobCounter,
}

@(private="file")
WorkerFiber :: struct {
    next:  ^WorkerFiber,
    fiber: ^fiber.Fiber,
}

@(private="file")
JobQueue :: struct {
    first, last: ^Job,
}

@(private="file")
FiberQueue :: struct {
    first, last: ^WorkerFiber,
}

@(private="file")
Handoff_Action :: enum {
    None,
    Return_To_Pool,
    Wait_On_Counter,
}

@(private="file")
Handoff :: struct {
    action:   Handoff_Action,
    fiber:   ^WorkerFiber,
    counter: ^JobCounter,
}

@(private="file")
PaddedMutex :: struct #align(64) {
    using mutex: sync.Mutex,
}

@(private="file")
JobSystem :: struct {
    running:          bool,
    arena:            virtual.Arena,
    allocator:        mem.Allocator,
    fiber_stack_size: int,
    threads:          []^thread.Thread,

    shutdown_mutex: PaddedMutex,
    shutdown_cond:  sync.Cond,
    init_fiber:     ^WorkerFiber, // the fiber who called init()
    shutdown_fiber: ^WorkerFiber, // the fiber who called shutdown()
    shutdown_ready: bool,

    fiber_storage:     []WorkerFiber,
    free_fibers:       ^WorkerFiber,
    free_fibers_mutex: PaddedMutex,

    free_jobs_mutex: PaddedMutex,
    free_jobs:       ^Job,

    free_counters_mutex: PaddedMutex,
    free_counters:       ^JobCounter,

    queue_mutex:     PaddedMutex,
    queue_cond:      sync.Cond,
    job_queues:      [JobPriority]JobQueue,
    rdy_fiber_queue: FiberQueue,
}

@(private="file")
job_system: JobSystem
@(private, thread_local)
pending_handoff: Handoff
@(private, thread_local)
is_init_thread: bool
@(private, thread_local)
thread_fiber: ^fiber.Fiber
@(private="file")
min_stack_size :: mem.Kilobyte * 64

@(private="file")
acquire_free_fiber :: proc() -> ^WorkerFiber {
    sync.mutex_lock(&job_system.free_fibers_mutex)
    fiber := job_system.free_fibers
    if fiber != nil {
        sll_stack_pop(&job_system.free_fibers)
    }
    sync.mutex_unlock(&job_system.free_fibers_mutex)

    if (fiber == nil) {
        panic("job system: fiber pool exhausted (too many simultaneous waits)")
    }
    return fiber
}

@(private="file")
release_fiber :: proc(work_fiber: ^WorkerFiber) {
    sync.mutex_lock(&job_system.free_fibers_mutex)
    sll_stack_push(&job_system.free_fibers, work_fiber)
    sync.mutex_unlock(&job_system.free_fibers_mutex)
}

@(private="file")
acquire_free_jobs :: proc(requested_count: int) -> (first, last: ^Job, count: int) {
    sync.mutex_lock(&job_system.free_jobs_mutex)
    for count < requested_count && job_system.free_jobs != nil {
        job := job_system.free_jobs
        sll_stack_pop(&job_system.free_jobs)
        sll_queue_push(&first, &last, job)
        count += 1
    }
    sync.mutex_unlock(&job_system.free_jobs_mutex)
    return
}

@(private="file")
new_job :: proc() -> ^Job {
    job, _, got := acquire_free_jobs(1)
    if got == 1 {
        return job
    }
    return new(Job, job_system.allocator)
}

@(private="file")
release_job :: proc(j: ^Job) {
    sync.mutex_lock(&job_system.free_jobs_mutex)
    sll_stack_push(&job_system.free_jobs, j)
    sync.mutex_unlock(&job_system.free_jobs_mutex)
}

@(private="file")
new_counter :: proc(count: int) -> ^JobCounter {
    sync.mutex_lock(&job_system.free_counters_mutex)
    counter := job_system.free_counters
    if counter != nil {
        sll_stack_pop(&job_system.free_counters)
    }
    sync.mutex_unlock(&job_system.free_counters_mutex)

    if counter == nil {
        counter = new(JobCounter, job_system.allocator)
    }

    intrinsics.atomic_store(&counter.value, count)
    counter.waiters_first, counter.waiters_last = nil, nil
    return counter
}

@(private="file")
release_counter :: proc(c: ^JobCounter) {
    sync.mutex_lock(&job_system.free_counters_mutex)
    sll_stack_push(&job_system.free_counters, c)
    sync.mutex_unlock(&job_system.free_counters_mutex)
}

@(private="file")
counter_signal :: proc(c: ^JobCounter) {
    if intrinsics.atomic_sub(&c.value, 1) != 1 {
        return
    }

    sync.mutex_lock(&c.waiters_mutex)
    ready_first, ready_last := c.waiters_first, c.waiters_last
    c.waiters_first, c.waiters_last = nil, nil
    sync.mutex_unlock(&c.waiters_mutex)

    for ready_first != nil {
        next := ready_first.next
        push_ready_fiber(ready_first)
        ready_first = next
    }
}

@(private="file")
counter_add_waiter :: proc(c: ^JobCounter, work_fiber: ^WorkerFiber) {
    sync.mutex_guard(&c.waiters_mutex)
    if intrinsics.atomic_load(&c.value) == 0 {
        push_ready_fiber(work_fiber)
        return
    }
    sll_queue_push(&c.waiters_first, &c.waiters_last, work_fiber)
}

@(private="file")
current_work_fiber :: proc() -> ^WorkerFiber {
    return (^WorkerFiber)(fiber.current().data)
}


@(private="file")
switch_and_handoff :: proc(target: ^fiber.Fiber, action: Handoff_Action, self: ^WorkerFiber, counter: ^JobCounter = nil) {
    pending_handoff = Handoff{action, self, counter}
    fiber.switch_to(target)
    resolve_handoff()
}

@(private="file")
resolve_handoff :: proc() {
    h := pending_handoff
    pending_handoff = Handoff{}
    switch h.action {
    case .None:
    case .Return_To_Pool:
        release_fiber(h.fiber)
    case .Wait_On_Counter:
        counter_add_waiter(h.counter, h.fiber)
    }
}

@(private="file")
push_ready_fiber :: proc(work_fiber: ^WorkerFiber) {
    sync.mutex_guard(&job_system.queue_mutex)
    sll_queue_push(&job_system.rdy_fiber_queue.first, &job_system.rdy_fiber_queue.last, work_fiber)
    sync.cond_signal(&job_system.queue_cond)
}

@(private="file")
try_pop_ready_fiber :: proc() -> ^WorkerFiber {
    work_fiber := job_system.rdy_fiber_queue.first
    if work_fiber != nil {
        sll_queue_pop(&job_system.rdy_fiber_queue.first, &job_system.rdy_fiber_queue.last)
    }
    return work_fiber
}

@(private="file")
try_pop_job :: proc() -> ^Job {
    for &q in job_system.job_queues {
        job := q.first
        if job != nil {
            sll_queue_pop(&q.first, &q.last)
            return job
        }
    }
    return nil
}

@(private="file")
worker_fiber_proc :: proc(f: ^fiber.Fiber) {
    resolve_handoff()
    self := (^WorkerFiber)(f.data)

    for {
        job_or_fiber: union { ^Job, ^WorkerFiber }

        sync.mutex_lock(&job_system.queue_mutex)
        for job_system.running {
            job := try_pop_job()
            if job != nil {
                job_or_fiber = job
                break
            }

            fiber := try_pop_ready_fiber()
            if fiber != nil {
                job_or_fiber = fiber
                break
            }

            sync.cond_wait(&job_system.queue_cond, &job_system.queue_mutex)
        }
        sync.mutex_unlock(&job_system.queue_mutex)

        if job_system.running == false {
            break
        }

        switch _ in job_or_fiber {
        case ^Job:
            job := job_or_fiber.(^Job)
            job.procedure(job.data, job.index)
            counter_signal(job.counter)
            release_job(job)
        case ^WorkerFiber:
            work_fiber := job_or_fiber.(^WorkerFiber)
            switch_and_handoff(work_fiber.fiber, .Return_To_Pool, self)
        }
    }

    // if we are running on the init thread, it means shutdown() was called from a worker thread
    // in this case, shutdown() would destroy it's own execution thread
    // therefore, here, we need to switch to the fiber currently running shutdown()
    if is_init_thread {
        sync.mutex_lock(&job_system.shutdown_mutex)
        for !job_system.shutdown_ready {
            sync.cond_wait(&job_system.shutdown_cond, &job_system.shutdown_mutex)
        }
        sync.mutex_unlock(&job_system.shutdown_mutex)
        fiber.switch_to(job_system.shutdown_fiber.fiber)
    }

    fiber.switch_to(thread_fiber)
}

@(private="file")
worker_thread_proc :: proc(t: ^thread.Thread) {
    thread_fiber = fiber.convert_thread_to_fiber()
    worker_fiber := acquire_free_fiber()
    fiber.switch_to(worker_fiber.fiber)
    fiber.convert_fiber_to_thread(thread_fiber)
}
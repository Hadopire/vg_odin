package fiber

import "base:runtime"
import "core:mem"
import "core:mem/virtual"

FiberProc :: #type proc(f: ^Fiber)

Fiber :: struct {
    using specific:   OsFiber,
    procedure:        FiberProc,
    data:             rawptr,
    init_ctx:         runtime.Context,
    arena:            virtual.Arena,
    create_allocator: mem.Allocator,
}

create :: proc(procedure: FiberProc, data: rawptr = nil, stack_size: int = 0, allocator := context.allocator, create_allocator := context.allocator) -> ^Fiber {
    return _create(procedure, data, stack_size, allocator, create_allocator)
}

destroy :: proc(f: ^Fiber) {
    _destroy(f)
}

convert_thread_to_fiber :: proc(allocator := context.allocator, create_allocator := context.allocator) -> ^Fiber {
    return _convert_thread_to_fiber(allocator, create_allocator)
}

convert_fiber_to_thread :: proc(f: ^Fiber) {
    _convert_fiber_to_thread(f)
}

switch_to :: proc(f: ^Fiber) {
    _switch_to(f)
}

current :: proc() -> ^Fiber {
    return _current()
}

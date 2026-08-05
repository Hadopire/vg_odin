#+build windows
#+private
package fiber

import "core:mem"
import "core:mem/virtual"
import "core:math/rand"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
    ConvertFiberToThread :: proc() -> win32.BOOL ---
}

OsFiber :: struct {
    win32_fiber: win32.LPVOID,
}

@(thread_local)
current_fiber: ^Fiber

trampoline :: proc "system" (param: win32.LPVOID) {
    f := (^Fiber)(param)
    context = f.init_ctx
    f.procedure(f)
}

_create :: proc(procedure: FiberProc, data: rawptr, stack_size: int, allocator: mem.Allocator, create_allocator: mem.Allocator) -> ^Fiber {
    f := new(Fiber, create_allocator)
    if f == nil {
        return nil
    }

    if arena_err := virtual.arena_init_growing(&f.arena); arena_err != nil {
        free(f, create_allocator)
        return nil
    }

    f.create_allocator       = create_allocator
    f.procedure              = procedure
    f.data                   = data
    f.init_ctx               = context
    f.init_ctx.allocator     = allocator
    f.init_ctx.temp_allocator = virtual.arena_allocator(&f.arena)

    win32_fiber := win32.CreateFiber(win32.SIZE_T(stack_size), trampoline, f)
    if win32_fiber == nil {
        virtual.arena_destroy(&f.arena)
        free(f, create_allocator)
        return nil
    }
    f.win32_fiber = win32_fiber
    return f
}

_destroy :: proc(f: ^Fiber) {
    win32.DeleteFiber(f.win32_fiber)
    virtual.arena_destroy(&f.arena)
    free(f, f.create_allocator)
}

_convert_thread_to_fiber :: proc(allocator: mem.Allocator, create_allocator: mem.Allocator) -> ^Fiber {
    fiber := new(Fiber, create_allocator)
    if fiber == nil {
        return nil
    }

    if err := virtual.arena_init_growing(&fiber.arena); err != nil {
        free(fiber, create_allocator)
        return nil
    }

    fiber.create_allocator       = create_allocator
    fiber.init_ctx               = context
    fiber.init_ctx.allocator     = allocator
    fiber.init_ctx.temp_allocator = virtual.arena_allocator(&fiber.arena)
    fiber.init_ctx.random_generator = rand.default_random_generator()

    win32_fiber := win32.ConvertThreadToFiber(nil)
    if win32_fiber == nil {
        virtual.arena_destroy(&fiber.arena)
        free(fiber, create_allocator)
        return nil
    }
    fiber.win32_fiber = win32_fiber

    current_fiber = fiber
    context = fiber.init_ctx
    return fiber
}

_convert_fiber_to_thread :: proc(f: ^Fiber) {
    ConvertFiberToThread()
    current_fiber = nil
    virtual.arena_destroy(&f.arena)
    free(f, f.create_allocator)
}

_switch_to :: proc(f: ^Fiber) {
    current_fiber = f
    win32.SwitchToFiber(f.win32_fiber)
}

_current :: proc() -> ^Fiber {
    return current_fiber
}

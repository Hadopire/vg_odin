package vg

import "base:intrinsics"

field_ptr :: proc(obj: ^$T, $field_name: string) -> ^^T
    where intrinsics.type_has_field(T, field_name),
          intrinsics.type_field_type(T, field_name) == ^T {
    return (^^T)(uintptr(obj) + offset_of_by_string(T, field_name))
}

dll_insert_named :: proc(first, last: ^^$T, after, node: ^T, $next, $prev: string, nil_value: ^T = nil) {
    node_next := field_ptr(node, next)
    node_prev := field_ptr(node, prev)

    switch {
    case first^ == nil_value:
        first^ = node
        last^ = node
        node_next^ = nil_value
        node_prev^ = nil_value
    case after == nil_value:
        node_next^ = first^
        field_ptr(first^, prev)^ = node
        first^ = node
        node_prev^ = nil_value
    case after == last^:
        field_ptr(last^, next)^ = node
        node_prev^ = last^
        last^ = node
        node_next^ = nil_value
    case:
        after_next := field_ptr(after, next)
        if after != nil_value && after_next^ != nil_value {
            field_ptr(after_next^, prev)^ = node
        }
        node_next^ = after_next^
        after_next^ = node
        node_prev^ = after
    }
}

dll_insert_default :: proc(first, last: ^^$T, after, node: ^T, nil_value: ^T = nil) {
    dll_insert_named(first, last, after, node, "next", "prev", nil_value)
}

dll_insert :: proc{dll_insert_default, dll_insert_named}

dll_push_back_named :: proc(first, last: ^^$T, node: ^T, $next, $prev: string, nil_value: ^T = nil) {
    dll_insert_named(first, last, last^, node, next, prev, nil_value)
}

dll_push_back_default :: proc(first, last: ^^$T, node: ^T, nil_value: ^T = nil) {
    dll_push_back_named(first, last, node, "next", "prev", nil_value)
}

dll_push_back :: proc{dll_push_back_default, dll_push_back_named}

dll_push_front_named :: proc(first, last: ^^$T, node: ^T, $next, $prev: string, nil_value: ^T = nil) {
    dll_insert_named(first, last, nil_value, node, next, prev, nil_value)
}

dll_push_front_default :: proc(first, last: ^^$T, node: ^T, nil_value: ^T = nil) {
    dll_push_front_named(first, last, node, "next", "prev", nil_value)
}

dll_push_front :: proc{dll_push_front_default, dll_push_front_named}

dll_remove_named :: proc(first, last: ^^$T, node: ^T, $next, $prev: string, nil_value: ^T = nil) {
    node_next := field_ptr(node, next)
    node_prev := field_ptr(node, prev)

    if node == first^ {
        first^ = node_next^
    }
    if node == last^ {
        last^ = node_prev^
    }
    if node_prev^ != nil_value {
        field_ptr(node_prev^, next)^ = node_next^
    }
    if node_next^ != nil_value {
        field_ptr(node_next^, prev)^ = node_prev^
    }
}

dll_remove_default :: proc(first, last: ^^$T, node: ^T, nil_value: ^T = nil) {
    dll_remove_named(first, last, node, "next", "prev", nil_value)
}

dll_remove :: proc{dll_remove_default, dll_remove_named}

sll_queue_push_named :: proc(first, last: ^^$T, node: ^T, $next: string, nil_value: ^T = nil) {
    node_next := field_ptr(node, next)
    if first^ == nil_value {
        first^ = node
        last^ = node
    } else {
        field_ptr(last^, next)^ = node
        last^ = node
    }
    node_next^ = nil_value
}

sll_queue_push_default :: proc(first, last: ^^$T, node: ^T, nil_value: ^T = nil) {
    sll_queue_push_named(first, last, node, "next", nil_value)
}

sll_queue_push :: proc{sll_queue_push_default, sll_queue_push_named}

sll_queue_push_front_named :: proc(first, last: ^^$T, node: ^T, $next: string, nil_value: ^T = nil) {
    node_next := field_ptr(node, next)
    if first^ == nil_value {
        first^ = node
        last^ = node
        node_next^ = nil_value
    } else {
        node_next^ = first^
        first^ = node
    }
}

sll_queue_push_front_default :: proc(first, last: ^^$T, node: ^T, nil_value: ^T = nil) {
    sll_queue_push_front_named(first, last, node, "next", nil_value)
}

sll_queue_push_front :: proc{sll_queue_push_front_default, sll_queue_push_front_named}

sll_queue_pop_named :: proc(first, last: ^^$T, $next: string, nil_value: ^T = nil) {
    if first^ == last^ {
        first^ = nil_value
        last^ = nil_value
    } else {
        first^ = field_ptr(first^, next)^
    }
}

sll_queue_pop_default :: proc(first, last: ^^$T, nil_value: ^T = nil) {
    sll_queue_pop_named(first, last, "next", nil_value)
}

sll_queue_pop :: proc{sll_queue_pop_default, sll_queue_pop_named}

sll_stack_push_named :: proc(first: ^^$T, node: ^T, $next: string) {
    field_ptr(node, next)^ = first^
    first^ = node
}

sll_stack_push_default :: proc(first: ^^$T, node: ^T) {
    sll_stack_push_named(first, node, "next")
}

sll_stack_push :: proc{sll_stack_push_default, sll_stack_push_named}

sll_stack_pop_named :: proc(first: ^^$T, $next: string) {
    first^ = field_ptr(first^, next)^
}

sll_stack_pop_default :: proc(first: ^^$T) {
    sll_stack_pop_named(first, "next")
}

sll_stack_pop :: proc{sll_stack_pop_default, sll_stack_pop_named}

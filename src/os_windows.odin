#+build windows
package vg

import "base:runtime"
import win32 "core:sys/windows"
import "core:mem"
import "core:unicode/utf8"
import "fiber"

main :: proc() {
    win32.SetConsoleOutputCP(.UTF8)

    // dpi awareness

    SetProcessDpiAwarenessContextProc :: #type proc "system" (value: win32.DPI_AWARENESS_CONTEXT) -> win32.BOOL
    set_dpi_awareness_context: SetProcessDpiAwarenessContextProc
    user32 := win32.LoadLibraryW(win32.L("user32.dll"))
    if user32 != nil {
        set_dpi_awareness_context = SetProcessDpiAwarenessContextProc(win32.GetProcAddress(user32, "SetProcessDpiAwarenessContext"))
        win32.FreeLibrary(user32)
    }
    if set_dpi_awareness_context != nil {
        set_dpi_awareness_context(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
    } else {
        SetProcessDpiAwarenessProc :: #type proc "system" (value: win32.PROCESS_DPI_AWARENESS) -> win32.HRESULT
        shcore := win32.LoadLibraryW(win32.L("shcore.dll"))
        if shcore != nil {
            set_process_dpi_awareness := SetProcessDpiAwarenessProc(win32.GetProcAddress(shcore, "SetProcessDpiAwareness"))
            set_process_dpi_awareness(.PROCESS_PER_MONITOR_DPI_AWARE)
            win32.FreeLibrary(shcore)
        } else {
            win32.SetProcessDPIAware()
        }
    }

    // fibers

    event_fiber = fiber.create(fiber_proc, stack_size = mem.Kilobyte * 256)
    main_fiber := fiber.convert_thread_to_fiber()
    defer fiber.destroy(event_fiber)
    defer fiber.convert_fiber_to_thread(main_fiber)
    winproc_context = context
    event_allocator = context.temp_allocator
    from_fiber = main_fiber

    // window

    instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))
    class_name: win32.wstring = win32.L("vg_odin_window_class")
    window_class := win32.WNDCLASSEXW{
        cbSize        = size_of(win32.WNDCLASSEXW),
        style         = win32.CS_HREDRAW | win32.CS_VREDRAW,
        lpfnWndProc   = win_proc,
        hInstance     = instance,
        hCursor       = win32.LoadCursorA(nil, win32.IDC_ARROW),
        lpszClassName = class_name,
    }
    win32.RegisterClassExW(&window_class)

    window := new(Win32Window)
    defer free(window)
    window.hwnd = win32.CreateWindowExW(0, class_name, win32.L("vg_odin"), win32.WS_OVERLAPPEDWINDOW, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, nil, nil, instance, window)
    hwnd := window.hwnd

    raw_devices := [2]win32.RAWINPUTDEVICE{
        {
            usUsagePage = win32.HID_USAGE_PAGE_GENERIC,
            usUsage     = win32.HID_USAGE_GENERIC_KEYBOARD,
            hwndTarget  = hwnd,
        },
        {
            usUsagePage = win32.HID_USAGE_PAGE_GENERIC,
            usUsage     = win32.HID_USAGE_GENERIC_MOUSE,
            hwndTarget  = hwnd,
        },
    }
    win32.RegisterRawInputDevices(&raw_devices[0], len(raw_devices), size_of(win32.RAWINPUTDEVICE))

    // state initalization

    update_key_names()

    point: win32.POINT
    win32.GetCursorPos(&point)
    last_absolute_x = int(point.x)
    last_absolute_y = int(point.y)

    win32.ShowWindow(hwnd, win32.SW_SHOW)
    entry(WindowHandle(window))
}

_os_poll_events :: proc(allocator: mem.Allocator) -> OsEventList {
    event_list = {}
    winproc_context = context
    event_allocator = allocator
    from_fiber = fiber.current()
    fiber.switch_to(event_fiber)
    return event_list
}

_os_mouse_position :: proc(window: WindowHandle) -> (width: i32, height: i32) {
    return cursor_client_pos((^Win32Window)(window).hwnd)
}

_os_window_size :: proc(window: WindowHandle) -> (width: i32, height: i32) {
    win32_window := (^Win32Window)(window)
    rect: win32.RECT
    win32.GetClientRect(win32_window.hwnd, &rect)
    return i32(rect.right - rect.left), i32(rect.bottom - rect.top)
}

_os_window_hwnd :: proc(window: WindowHandle) -> win32.HWND {
    return (^Win32Window)(window).hwnd
}

/* internals */

@(private="file")
min_client_width  :: 128
@(private="file")
min_client_height :: 96

@(private="file")
Win32Window :: struct {
    hwnd:       win32.HWND,
    minimized:  bool,
}

@(private="file")
event_list:        OsEventList
@(private="file")
winproc_context:   runtime.Context
@(private="file")
event_allocator:   mem.Allocator
@(private="file")
event_fiber:       ^fiber.Fiber
@(private="file")
from_fiber:        ^fiber.Fiber
@(private="file")
last_absolute_x:   int
@(private="file")
last_absolute_y:   int
@(private="file")
dummy_window: Win32Window
@(private="file")
key_name_storage: [OsKey][4]u8

@(private="file")
push_event :: proc (kind: OsEventKind, window: WindowHandle) -> ^OsEvent {
    event := new(OsEvent, allocator = event_allocator)
    event.kind = kind
    event.window = window
    sll_queue_push(&event_list.first, &event_list.last, event)
    return event
}

@(private="file")
push_key_event :: proc(kind: OsEventKind, window: WindowHandle, key: OsKey) -> ^OsEvent {
    event := push_event(kind, window)
    event.key = key
    if win32.GetKeyState(win32.VK_CONTROL) < 0 {
        event.modifiers += {.Ctrl}
    }
    if win32.GetKeyState(win32.VK_SHIFT) < 0 {
        event.modifiers += {.Shift}
    }
    if win32.GetKeyState(win32.VK_MENU) < 0 {
        event.modifiers += {.Alt}
    }
    return event
}

@(private="file")
win32_window_from_hwnd :: proc (hwnd: win32.HWND) -> ^Win32Window {
    win32_window := (^Win32Window)(uintptr(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA)))
    return win32_window != nil ? win32_window : &dummy_window
}

@(private="file")
win_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
    context = winproc_context
    window := win32_window_from_hwnd(hwnd)

    result: win32.LRESULT
    switch msg {
    case win32.WM_CREATE:
        create := (^win32.CREATESTRUCTW)(uintptr(lparam))
        win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, win32.LONG_PTR(uintptr(create.lpCreateParams)))
        dark: win32.BOOL = true
        win32.DwmSetWindowAttribute(hwnd, u32(win32.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &dark, size_of(dark))
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)

    case win32.WM_DESTROY:
        push_event(.Window_Close, WindowHandle(window))
        win32.PostQuitMessage(0)
        result = 0

    case win32.WM_SIZE:
        if wparam == win32.SIZE_MINIMIZED {
            window.minimized = true
            push_event(.Window_Minimize, WindowHandle(window))
        } else if window.minimized{
            window.minimized = false
            push_event(.Window_Restore, WindowHandle(window))
        }
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)

    case win32.WM_TIMER:
        fiber.switch_to(from_fiber)
        result = 0

    case win32.WM_INPUTLANGCHANGE:
        update_key_names()
        result = 1

    case win32.WM_INPUT:
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)

        raw: win32.RAWINPUT
        size := win32.UINT(size_of(raw))
        win32.GetRawInputData(win32.HRAWINPUT(lparam), win32.RID_INPUT, &raw, &size, size_of(win32.RAWINPUTHEADER))

        if raw.header.dwType == win32.RIM_TYPEKEYBOARD {
            key := win_key_to_os_key(raw.data.keyboard)
            if key != .None {
                kind: OsEventKind = .Release if int(raw.data.keyboard.Flags) & win32.RI_KEY_BREAK != 0 else .Press
                push_key_event(kind, WindowHandle(window), key)
            }
        }

        if raw.header.dwType == win32.RIM_TYPEMOUSE {
            mouse := raw.data.mouse
            delta_x, delta_y: int
            moved: bool

            if int(mouse.usFlags) & win32.MOUSE_MOVE_ABSOLUTE != 0 {
                screen_x, screen_y: int
                if int(mouse.usFlags) & win32.MOUSE_VIRTUAL_DESKTOP != 0 {
                    screen_x = int(win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN)) +
                               int(mouse.lLastX) * int(win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN)) / 65535
                    screen_y = int(win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN)) +
                               int(mouse.lLastY) * int(win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN)) / 65535
                } else {
                    screen_x = int(mouse.lLastX) * int(win32.GetSystemMetrics(win32.SM_CXSCREEN)) / 65535
                    screen_y = int(mouse.lLastY) * int(win32.GetSystemMetrics(win32.SM_CYSCREEN)) / 65535
                }

                delta_x = screen_x - last_absolute_x
                delta_y = screen_y - last_absolute_y
                moved = delta_x != 0 || delta_y != 0

                last_absolute_x = screen_x
                last_absolute_y = screen_y
            } else {
                delta_x = int(mouse.lLastX)
                delta_y = int(mouse.lLastY)
                moved = delta_x != 0 || delta_y != 0
            }

            if moved {
                event := push_event(.Mouse_Move, WindowHandle(window))
                event.pos_x, event.pos_y = cursor_client_pos(hwnd)
                event.delta_x = i32(delta_x)
                event.delta_y = i32(delta_y)
            }

            TransitionState :: struct {
                flag: win32.USHORT,
                kind: OsEventKind,
                key:  OsKey,
            }

            transition_states :: [?]TransitionState{
                {flag = win32.RI_MOUSE_BUTTON_1_DOWN, kind = .Press,   key = .Mouse_Left},
                {flag = win32.RI_MOUSE_BUTTON_1_UP,   kind = .Release, key = .Mouse_Left},
                {flag = win32.RI_MOUSE_BUTTON_2_DOWN, kind = .Press,   key = .Mouse_Right},
                {flag = win32.RI_MOUSE_BUTTON_2_UP,   kind = .Release, key = .Mouse_Right},
                {flag = win32.RI_MOUSE_BUTTON_3_DOWN, kind = .Press,   key = .Mouse_Middle},
                {flag = win32.RI_MOUSE_BUTTON_3_UP,   kind = .Release, key = .Mouse_Middle},
                {flag = win32.RI_MOUSE_BUTTON_4_DOWN, kind = .Press,   key = .Mouse_X1},
                {flag = win32.RI_MOUSE_BUTTON_4_UP,   kind = .Release, key = .Mouse_X1},
                {flag = win32.RI_MOUSE_BUTTON_5_DOWN, kind = .Press,   key = .Mouse_X2},
                {flag = win32.RI_MOUSE_BUTTON_5_UP,   kind = .Release, key = .Mouse_X2},
            }

            for transition in transition_states {
                if raw.data.mouse.usButtonFlags & transition.flag != 0 {
                    event := push_key_event(transition.kind, WindowHandle(window), transition.key)
                    event.pos_x, event.pos_y = cursor_client_pos(hwnd)
                }
            }

            button_flags := int(mouse.usButtonFlags)
            if button_flags & (win32.RI_MOUSE_WHEEL | win32.RI_MOUSE_HWHEEL) != 0 {
                event := push_event(.Scroll, WindowHandle(window))
                event.pos_x, event.pos_y = cursor_client_pos(hwnd)
                if button_flags & win32.RI_MOUSE_HWHEEL != 0 {
                    event.delta_x = i32(mouse.usButtonData)
                } else {
                    event.delta_y = i32(mouse.usButtonData)
                }
            }
        }

    case win32.WM_ENTERSIZEMOVE:
        push_event(.Window_Drag_Begin, WindowHandle(window))
        win32.SetTimer(hwnd, 1, 16, nil)
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)

    case win32.WM_EXITSIZEMOVE:
        push_event(.Window_Drag_End, WindowHandle(window))
        win32.KillTimer(hwnd, 1)
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)

    case win32.WM_GETMINMAXINFO:
        rect := win32.RECT{ 0, 0, min_client_width, min_client_height }
        win32.AdjustWindowRect(&rect, win32.WS_OVERLAPPEDWINDOW, false)
        info := (^win32.MINMAXINFO)(uintptr(lparam))
        info.ptMinTrackSize = { rect.right - rect.left, rect.bottom - rect.top }
        result = 0

    case win32.WM_NCCALCSIZE:
        // fixes the resize artefacts on flip model swapchains
        // resize the swapchain and present BEFORE returning from WM_NCCALCSIZE

        //frame_x := win32.GetSystemMetrics(win32.SM_CXSIZEFRAME)
        //frame_y := win32.GetSystemMetrics(win32.SM_CYSIZEFRAME)
        //title   := win32.GetSystemMetrics(win32.SM_CYCAPTION)
        //padding := win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER)
        //window_style := u32(win32.GetWindowLongW(hwnd, win32.GWL_STYLE))
        //is_fullscreen := (window_style & win32.WS_OVERLAPPEDWINDOW) == 0
        //if is_fullscreen == false {
        //    rect := wparam == 0 ? (^win32.RECT)(uintptr(lparam)) : &(^win32.NCCALCSIZE_PARAMS)(uintptr(lparam)).rgrc[0]
        //    rect.top    += title + padding
        //    rect.right  -= frame_x + padding
        //    rect.left   += frame_x + padding
        //    rect.bottom -= frame_y + padding
        //}

        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)
        fiber.switch_to(from_fiber)
        win32.DwmFlush()

    case:
        result = win32.DefWindowProcW(hwnd, msg, wparam, lparam)
    }

    return result
}

@(private="file")
fiber_proc :: proc(f: ^fiber.Fiber) {
    for {
        msg: win32.MSG
        for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
            win32.TranslateMessage(&msg)
            win32.DispatchMessageW(&msg)
        }

        fiber.switch_to(from_fiber)
    }
}

@(private="file")
update_key_names :: proc() {
    for key, code in scancode_to_key {
        if key == .None {
            continue
        }

        vkey := win32.MapVirtualKeyW(win32.UINT(code), win32.MAPVK_VSC_TO_VK_EX)
        char := rune(win32.MapVirtualKeyW(vkey, win32.MAPVK_VK_TO_CHAR) & 0x7FFFFFFF)
        if char <= ' ' || char == 0x7F {
            continue
        }

        bytes, width := utf8.encode_rune(char)
        key_name_storage[key] = bytes
        os_key_names[key] = string(key_name_storage[key][:width])
    }
}

@(private="file")
win_key_to_os_key :: proc(keyboard: win32.RAWKEYBOARD) -> OsKey {
    if int(keyboard.VKey) == 0xFF {
        return .None
    }

    flags := int(keyboard.Flags)
    if flags & win32.RI_KEY_E1 != 0 {
        return .Pause
    }

    code := int(keyboard.MakeCode)
    if code >= len(scancode_to_key) {
        return .None
    }
    if flags & win32.RI_KEY_E0 != 0 {
        return extended_scancode_to_key[code]
    }
    return scancode_to_key[code]
}

@(private="file")
cursor_client_pos :: proc(hwnd: win32.HWND) -> (x, y: i32) {
    point: win32.POINT
    win32.GetCursorPos(&point)
    win32.ScreenToClient(hwnd, &point)
    return i32(point.x), i32(point.y)
}

@(private="file")
scancode_to_key := [128]OsKey{
    win32.KB_A = .A,
    win32.KB_B = .B,
    win32.KB_C = .C,
    win32.KB_D = .D,
    win32.KB_E = .E,
    win32.KB_F = .F,
    win32.KB_G = .G,
    win32.KB_H = .H,
    win32.KB_I = .I,
    win32.KB_J = .J,
    win32.KB_K = .K,
    win32.KB_L = .L,
    win32.KB_M = .M,
    win32.KB_N = .N,
    win32.KB_O = .O,
    win32.KB_P = .P,
    win32.KB_Q = .Q,
    win32.KB_R = .R,
    win32.KB_S = .S,
    win32.KB_T = .T,
    win32.KB_U = .U,
    win32.KB_V = .V,
    win32.KB_W = .W,
    win32.KB_X = .X,
    win32.KB_Y = .Y,
    win32.KB_Z = .Z,
    win32.KB_0_RIGHTBRACKET = .Num_0,
    win32.KB_1_BANG = .Num_1,
    win32.KB_2_AT = .Num_2,
    win32.KB_3_HASH = .Num_3,
    win32.KB_4_DOLLAR = .Num_4,
    win32.KB_5_PERCENT = .Num_5,
    win32.KB_6_CARET = .Num_6,
    win32.KB_7_AMPERSAND = .Num_7,
    win32.KB_8_STAR = .Num_8,
    win32.KB_9_LEFTBRACKET = .Num_9,
    win32.KP_0_INSERT = .Numpad_0,
    win32.KP_1_END = .Numpad_1,
    win32.KP_2_DOWNARROW = .Numpad_2,
    win32.KP_3_PAGEDN = .Numpad_3,
    win32.KP_4_LEFTARROW = .Numpad_4,
    win32.KP_5 = .Numpad_5,
    win32.KP_6_RIGHTARROW = .Numpad_6,
    win32.KP_7_HOME = .Numpad_7,
    win32.KP_8_UPARROW = .Numpad_8,
    win32.KP_9_PAGEUP = .Numpad_9,
    win32.KP_PLUS = .Numpad_Add,
    win32.KP_DASH = .Numpad_Subtract,
    win32.KP_STAR = .Numpad_Multiply,
    win32.KP_PERIOD = .Numpad_Decimal,
    win32.KB_F1 = .F1,
    win32.KB_F2 = .F2,
    win32.KB_F3 = .F3,
    win32.KB_F4 = .F4,
    win32.KB_F5 = .F5,
    win32.KB_F6 = .F6,
    win32.KB_F7 = .F7,
    win32.KB_F8 = .F8,
    win32.KB_F9 = .F9,
    win32.KB_F10 = .F10,
    win32.KB_F11 = .F11,
    win32.KB_F12 = .F12,
    win32.KB_F13 = .F13,
    win32.KB_F14 = .F14,
    win32.KB_F15 = .F15,
    win32.KB_F16 = .F16,
    win32.KB_F17 = .F17,
    win32.KB_F18 = .F18,
    win32.KB_F19 = .F19,
    win32.KB_F20 = .F20,
    win32.KB_F21 = .F21,
    win32.KB_F22 = .F22,
    win32.KB_F23 = .F23,
    win32.KB_F24 = .F24,
    win32.KB_LEFTSHIFT = .Left_Shift,
    win32.KB_RIGHTSHIFT = .Right_Shift,
    win32.KB_LEFTCONTROL = .Left_Ctrl,
    win32.KB_LEFTALT = .Left_Alt,
    win32.KB_ESCAPE = .Escape,
    win32.KB_RETURN_ENTER = .Enter,
    win32.KB_SPACEBAR = .Space,
    win32.KB_TAB = .Tab,
    win32.KB_DELETE = .Backspace,
    win32.KB_CAPSLOCK = .Caps_Lock,
    win32.KP_NUMLOCK_CLEAR = .Num_Lock,
    win32.KB_SCROLLLOCK = .Scroll_Lock,
    win32.KB_GRAVEACC_TILDE = .Grave,
    win32.KB_DASH_UNDERSCORE = .Minus,
    win32.KB_EQUALS_PLUS = .Equal,
    win32.KB_LEFTBRACE = .Left_Bracket,
    win32.KB_RIGHTBRACE = .Right_Bracket,
    win32.KB_PIPE_SLASH = .Backslash,
    win32.KB_SEMICOLON_COLON = .Semicolon,
    win32.KB_APOSTR_DOUBLEQUOT = .Apostrophe,
    win32.KB_COMMA = .Comma,
    win32.KB_PERIOD = .Period,
    win32.KB_QUESTIONMARK = .Slash,
    win32.KB_NONUS_SLASHBAR = .ISO_Backslash,
}

@(private="file")
extended_scancode_to_key := [128]OsKey{
    win32.KB_RIGHTCONTROL & 0xFF = .Right_Ctrl,
    win32.KB_RIGHTALT & 0xFF = .Right_Alt,
    win32.KB_LEFTGUI & 0xFF = .Left_Super,
    win32.KB_RIGHTGUI & 0xFF = .Right_Super,
    win32.KB_APPLICATION & 0xFF = .Menu,
    win32.KB_INSERT & 0xFF = .Insert,
    win32.KB_DELETEFORWARD & 0xFF = .Delete,
    win32.KB_HOME & 0xFF = .Home,
    win32.KB_END & 0xFF = .End,
    win32.KB_PAGEUP & 0xFF = .Page_Up,
    win32.KB_PAGEDOWN & 0xFF = .Page_Down,
    win32.KB_LEFTARROW & 0xFF = .Left,
    win32.KB_RIGHTARROW & 0xFF = .Right,
    win32.KB_UPARROW & 0xFF = .Up,
    win32.KB_DOWNARROW & 0xFF = .Down,
    win32.KB_PRINTSCREEN & 0xFF = .Print_Screen,
    win32.KP_ENTER & 0xFF = .Numpad_Enter,
    win32.KP_FORWARDSLASH & 0xFF = .Numpad_Divide,
}

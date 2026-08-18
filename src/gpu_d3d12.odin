#+build windows
#+private file
package vg

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import win32 "core:sys/windows"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "d3d12ma"

BACK_BUFFER_COUNT :: 2

RTV_DSV_HEAP_SIZE :: 1024
SAMPLER_HEAP_SIZE :: 2048
SRV_HEAP_SIZE     :: 1_000_000

Descriptor :: struct {
    next:        ^Descriptor,
    heap:        ^DescriptorHeap,
    index:        int,
    release_id:   int,
}

DescriptorHeap :: struct {
    heap:          ^d3d12.IDescriptorHeap,
    type:           d3d12.DESCRIPTOR_HEAP_TYPE,
    cpu_start:      d3d12.CPU_DESCRIPTOR_HANDLE,
    gpu_start:      d3d12.GPU_DESCRIPTOR_HANDLE,
    stride:         int,
    shader_visible: bool,

    capacity:       int,
    used:           int,
    first_free:     ^Descriptor,
    first_pending:  ^Descriptor,
    last_pending:   ^Descriptor,

    temp_capacity:  int,
    temp_head:      int,
}

Buffer :: struct {
    next:        ^Buffer,
    resource:    ^d3d12.IResource,
    allocation:  ^d3d12ma.Allocation,
    size:         int,
    mapped:       rawptr,
    release_id:   int,
}

Texture :: struct {
    next:        ^Texture,
    resource:    ^d3d12.IResource,
    allocation:  ^d3d12ma.Allocation,
    width:        int,
    height:       int,
    depth:        int,
    mips:         int,
    array_size:   int,
    format:       GpuFormat,
    release_id:   int,
}

PipelineLayout :: struct {
    next:        ^PipelineLayout,
    signature:   ^d3d12.IRootSignature,
    release_id:   int,
}

Pipeline :: struct {
    next:        ^Pipeline,
    state:       ^d3d12.IPipelineState,
    layout:      ^PipelineLayout,
    release_id:   int,
}

CommandList :: struct {
    next:        ^CommandList,
    allocator:   ^d3d12.ICommandAllocator,
    list:        ^d3d12.IGraphicsCommandList7,
    queue:        GpuQueue,
    id:           int,
    fence_value:  int,
}

Queue :: struct {
    queue:            ^d3d12.ICommandQueue,
    fence:            ^d3d12.IFence,
    fence_event:       win32.HANDLE,
    last_fence_value:  int,
    free_lists:       ^CommandList,
}

Swapchain :: struct {
    next:              ^Swapchain,
    swapchain:         ^dxgi.ISwapChain4,
    flags:              dxgi.SWAP_CHAIN,
    width:              int,
    height:             int,
    latency_waitable:   win32.HANDLE,
    back_buffers:       [BACK_BUFFER_COUNT]Texture,
    back_buffer_views:  [BACK_BUFFER_COUNT]^Descriptor,
    fence_values:       [BACK_BUFFER_COUNT]int,
    back_buffer_index:  int,
}

Gpu :: struct {
    factory:          ^dxgi.IFactory7,
    adapter:          ^dxgi.IAdapter1,
    device:           ^d3d12.IDevice,
    allocator:        ^d3d12ma.Allocator,
    queues:            [GpuQueue]Queue,

    arena:             virtual.Arena,
    arena_allocator:   mem.Allocator,

    srv_heap:          DescriptorHeap,
    sampler_heap:      DescriptorHeap,
    rtv_heap:          DescriptorHeap,
    dsv_heap:          DescriptorHeap,

    free_buffers:     ^Buffer,
    free_textures:    ^Texture,
    free_swapchains:  ^Swapchain,
    free_layouts:     ^PipelineLayout,
    free_pipelines:   ^Pipeline,

    first_pending_buffers:   ^Buffer,
    last_pending_buffers:    ^Buffer,
    first_pending_textures:  ^Texture,
    last_pending_textures:   ^Texture,
    first_pending_layouts:   ^PipelineLayout,
    last_pending_layouts:    ^PipelineLayout,
    first_pending_pipelines: ^Pipeline,
    last_pending_pipelines:  ^Pipeline,

    first_in_flight:  ^CommandList,
    last_in_flight:   ^CommandList,

    last_command_list_id: int,
    last_fence_value:     int,
}

gpu: Gpu

debug_message :: proc "c" (category: d3d12.MESSAGE_CATEGORY, severity: d3d12.MESSAGE_SEVERITY, id: d3d12.MESSAGE_ID, description: d3d12.LPCSTR, user_data: rawptr) {
    context = runtime.default_context()
    fmt.println("d3d12", severity, ":", description)
}

check :: proc(hr: d3d12.HRESULT, msg: string, loc := #caller_location) {
    if hr != win32.S_OK {
        fmt.panicf("d3d12: %s failed (hr = 0x%x)", msg, u32(hr), loc = loc)
    }
}

queue_list_type :: proc(kind: GpuQueue) -> d3d12.COMMAND_LIST_TYPE {
    switch kind {
    case .Direct:        return .DIRECT
    case .Async_Compute: return .COMPUTE
    case .Async_Copy:    return .COPY
    }
    return .DIRECT
}

@(private="package")
_gpu_init :: proc() {
    when ODIN_DEBUG {
        debug: ^d3d12.IDebug
        if d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&debug)) >= 0 {
            debug->EnableDebugLayer()
            debug->Release()
        }
    }

    factory_flags: dxgi.CREATE_FACTORY
    when ODIN_DEBUG {
        factory_flags += {.DEBUG}
    }
    check(dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory7_UUID, (^rawptr)(&gpu.factory)), "CreateDXGIFactory2")

    check(gpu.factory->EnumAdapterByGpuPreference(0, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&gpu.adapter)), "EnumAdapterByGpuPreference")
    check(d3d12.CreateDevice((^dxgi.IUnknown)(gpu.adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&gpu.device)), "CreateDevice")

    shader_model := d3d12.FEATURE_DATA_SHADER_MODEL{ HighestShaderModel = ._6_6 }
    check(gpu.device->CheckFeatureSupport(.SHADER_MODEL, &shader_model, size_of(shader_model)), "CheckFeatureSupport(SHADER_MODEL)")
    if shader_model.HighestShaderModel < ._6_6 {
        fmt.panicf("d3d12: shader model 6.6 required for bindless, adapter reports %v", shader_model.HighestShaderModel)
    }

    when ODIN_DEBUG {
        info_queue: ^d3d12.IInfoQueue1
        if gpu.device->QueryInterface(d3d12.IInfoQueue1_UUID, (^rawptr)(&info_queue)) >= 0 {
            cookie: u32
            info_queue->RegisterMessageCallback(debug_message, {}, nil, &cookie)
            info_queue->Release()
        }
    }

    options12 := d3d12.FEATURE_DATA_OPTIONS12{}
    check(gpu.device->CheckFeatureSupport(.OPTIONS12, &options12, size_of(options12)), "CheckFeatureSupport(OPTIONS12)")
    if !options12.EnhancedBarriersSupported {
        panic("d3d12: enhanced barriers are required but not supported by this driver")
    }

    if err := virtual.arena_init_growing(&gpu.arena); err != nil {
        panic("d3d12: failed to init arena")
    }
    gpu.arena_allocator = virtual.arena_allocator(&gpu.arena)

    check(d3d12ma.create_allocator(gpu.device, (^dxgi.IAdapter)(gpu.adapter), &gpu.allocator), "d3d12ma create_allocator")

    for kind in GpuQueue {
        queue := &gpu.queues[kind]
        queue_desc := d3d12.COMMAND_QUEUE_DESC{ Type = queue_list_type(kind) }
        check(gpu.device->CreateCommandQueue(&queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&queue.queue)), "CreateCommandQueue")
        check(gpu.device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&queue.fence)), "CreateFence")
        queue.fence_event = win32.CreateEventW(nil, false, false, nil)
    }

    descriptor_heap_init(&gpu.rtv_heap, .RTV, RTV_DSV_HEAP_SIZE, 0, false)
    descriptor_heap_init(&gpu.dsv_heap, .DSV, RTV_DSV_HEAP_SIZE, 0, false)
    descriptor_heap_init(&gpu.srv_heap, .CBV_SRV_UAV, SRV_HEAP_SIZE / 2, SRV_HEAP_SIZE / 2, true)
    descriptor_heap_init(&gpu.sampler_heap, .SAMPLER, SAMPLER_HEAP_SIZE, 0, true)
}

descriptor_heap_init :: proc(heap: ^DescriptorHeap, type: d3d12.DESCRIPTOR_HEAP_TYPE, capacity: int, temp_capacity: int, shader_visible: bool) {
    desc := d3d12.DESCRIPTOR_HEAP_DESC{
        Type           = type,
        NumDescriptors = u32(capacity + temp_capacity),
    }
    if shader_visible {
        desc.Flags = {.SHADER_VISIBLE}
    }
    check(gpu.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&heap.heap)), "CreateDescriptorHeap")

    heap.type = type
    heap.stride = int(gpu.device->GetDescriptorHandleIncrementSize(type))
    heap.capacity = capacity
    heap.temp_capacity = temp_capacity
    heap.shader_visible = shader_visible

    heap.heap->GetCPUDescriptorHandleForHeapStart(&heap.cpu_start)
    if shader_visible {
        heap.heap->GetGPUDescriptorHandleForHeapStart(&heap.gpu_start)
    }
}

descriptor_heap_destroy :: proc(heap: ^DescriptorHeap) {
    heap.heap->Release()
}

descriptor_alloc :: proc(heap: ^DescriptorHeap) -> ^Descriptor {
    descriptor := heap.first_free
    if descriptor != nil {
        sll_stack_pop(&heap.first_free)
        return descriptor
    }

    assert(heap.used < heap.capacity, "descriptor_alloc: heap is full")
    descriptor = new(Descriptor, gpu.arena_allocator)
    descriptor.heap = heap
    descriptor.index = heap.used
    heap.used += 1
    return descriptor
}


descriptor_alloc_temp :: proc(heap: ^DescriptorHeap) -> int {
    index := heap.capacity + heap.temp_head
    heap.temp_head += 1
    if heap.temp_head == heap.temp_capacity {
        heap.temp_head = 0
    }
    return index
}

descriptor_free :: proc(descriptor: ^Descriptor) {
    descriptor.release_id = gpu.last_command_list_id
    sll_queue_push(&descriptor.heap.first_pending, &descriptor.heap.last_pending, descriptor)
}

descriptor_recycle :: proc(heap: ^DescriptorHeap, completed: int) {
    for heap.first_pending != nil && heap.first_pending.release_id <= completed {
        node := heap.first_pending
        sll_queue_pop(&heap.first_pending, &heap.last_pending)
        sll_stack_push(&heap.first_free, node)
    }
}

@(private="package")
_gpu_equip_window :: proc(window: WindowHandle) -> GpuSwapchain {
    hwnd := win32.HWND(window)

    swapchain := gpu.free_swapchains
    if swapchain != nil {
        sll_stack_pop(&gpu.free_swapchains)
    } else {
        swapchain = new(Swapchain, gpu.arena_allocator)
    }
    swapchain^ = Swapchain{}

    allow_tearing: win32.BOOL
    gpu.factory->CheckFeatureSupport(.PRESENT_ALLOW_TEARING, &allow_tearing, size_of(allow_tearing))

    swapchain.flags = {.FRAME_LATENCY_WAITABLE_OBJECT}
    if allow_tearing {
        swapchain.flags += {.ALLOW_TEARING}
    }
    swapchain.width, swapchain.height = client_size(hwnd)

    swapchain_desc := dxgi.SWAP_CHAIN_DESC1{
        Width       = u32(swapchain.width),
        Height      = u32(swapchain.height),
        Format      = .R8G8B8A8_UNORM,
        SampleDesc  = { Count = 1 },
        BufferUsage = {.RENDER_TARGET_OUTPUT},
        BufferCount = BACK_BUFFER_COUNT,
        Scaling     = .NONE,
        SwapEffect  = .FLIP_DISCARD,
        AlphaMode   = .UNSPECIFIED,
        Flags       = swapchain.flags,
    }

    swapchain1: ^dxgi.ISwapChain1
    check(gpu.factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(gpu.queues[.Direct].queue), hwnd, &swapchain_desc, nil, nil, &swapchain1), "CreateSwapChainForHwnd")
    check(swapchain1->QueryInterface(dxgi.ISwapChain4_UUID, (^rawptr)(&swapchain.swapchain)), "QueryInterface(ISwapChain4)")
    swapchain1->Release()

    check(gpu.factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER}), "MakeWindowAssociation")
    check(swapchain.swapchain->SetMaximumFrameLatency(1), "SetMaximumFrameLatency")
    swapchain.latency_waitable = swapchain.swapchain->GetFrameLatencyWaitableObject()

    for index in 0 ..< BACK_BUFFER_COUNT {
        swapchain.back_buffer_views[index] = descriptor_alloc(&gpu.rtv_heap)
    }
    create_back_buffer_views(swapchain)

    return GpuSwapchain(swapchain)
}

@(private="package")
_gpu_unequip_window :: proc(handle: GpuSwapchain) {
    swapchain := (^Swapchain)(handle)
    wait_for_gpu()

    release_back_buffers(swapchain)
    for index in 0 ..< BACK_BUFFER_COUNT {
        _gpu_destroy_view(GpuView(swapchain.back_buffer_views[index]))
        swapchain.back_buffer_views[index] = nil
    }
    win32.CloseHandle(swapchain.latency_waitable)
    swapchain.swapchain->Release()
    swapchain.swapchain = nil

    sll_stack_push(&gpu.free_swapchains, swapchain)
}

@(private="package")
_gpu_swapchain_resize :: proc(handle: GpuSwapchain, width: int, height: int) {
    swapchain := (^Swapchain)(handle)
    if width == 0 || height == 0 || (width == swapchain.width && height == swapchain.height) {
        swapchain.width, swapchain.height = width, height
        return
    }

    wait_for_gpu()
    release_back_buffers(swapchain)

    check(swapchain.swapchain->ResizeBuffers(BACK_BUFFER_COUNT, u32(width), u32(height), .UNKNOWN, swapchain.flags), "ResizeBuffers")
    swapchain.width, swapchain.height = width, height
    create_back_buffer_views(swapchain)
}

@(private="package")
_gpu_back_buffer :: proc(handle: GpuSwapchain) -> GpuTexture {
    swapchain := (^Swapchain)(handle)
    return GpuTexture(&swapchain.back_buffers[swapchain.back_buffer_index])
}

@(private="package")
_gpu_swapchain_size :: proc(handle: GpuSwapchain) -> (width: int, height: int) {
    swapchain := (^Swapchain)(handle)
    return swapchain.width, swapchain.height
}

@(private="package")
_gpu_back_buffer_view :: proc(handle: GpuSwapchain) -> GpuView {
    swapchain := (^Swapchain)(handle)
    return GpuView(swapchain.back_buffer_views[swapchain.back_buffer_index])
}

@(private="package")
_gpu_command_list_begin :: proc(kind: GpuQueue) -> GpuCommandList {
    queue := &gpu.queues[kind]

    cmd := queue.free_lists
    if cmd != nil {
        sll_stack_pop(&queue.free_lists)
    } else {
        cmd = new(CommandList, gpu.arena_allocator)
        cmd.queue = kind
        list_type := queue_list_type(kind)
        check(gpu.device->CreateCommandAllocator(list_type, d3d12.ICommandAllocator_UUID, (^rawptr)(&cmd.allocator)), "CreateCommandAllocator")
        check(gpu.device->CreateCommandList(0, list_type, cmd.allocator, nil, d3d12.IGraphicsCommandList7_UUID, (^rawptr)(&cmd.list)), "CreateCommandList")
        check(cmd.list->Close(), "command list initial Close")
    }

    check(cmd.allocator->Reset(), "command allocator Reset")
    check(cmd.list->Reset(cmd.allocator, nil), "command list Reset")

    if kind != .Async_Copy {
        heaps := [2]^d3d12.IDescriptorHeap{ gpu.srv_heap.heap, gpu.sampler_heap.heap }
        cmd.list->SetDescriptorHeaps(2, &heaps[0])
    }

    gpu.last_command_list_id += 1
    cmd.id = gpu.last_command_list_id
    cmd.fence_value = 0
    sll_queue_push(&gpu.first_in_flight, &gpu.last_in_flight, cmd)

    return GpuCommandList(cmd)
}

@(private="package")
_gpu_command_list_end :: proc(handle: GpuCommandList) {
    cmd := (^CommandList)(handle)
    check(cmd.list->Close(), "command list Close")
}

@(private="package")
_gpu_submit :: proc(cmds: []GpuCommandList) {
    if len(cmds) == 0 {
        return
    }

    kind := (^CommandList)(cmds[0]).queue
    queue := &gpu.queues[kind]
    lists := make([]^d3d12.ICommandList, len(cmds), context.temp_allocator)
    for handle, index in cmds {
        cmd := (^CommandList)(handle)
        assert(cmd.queue == kind, "gpu_submit: every command list in a batch must target the same queue")
        lists[index] = (^d3d12.ICommandList)(cmd.list)
    }

    queue.queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    gpu.last_fence_value += 1
    queue.last_fence_value = gpu.last_fence_value
    check(queue.queue->Signal(queue.fence, u64(gpu.last_fence_value)), "Signal")

    for handle in cmds {
        cmd := (^CommandList)(handle)
        cmd.fence_value = gpu.last_fence_value
    }
}

@(private="package")
_gpu_set_render_targets :: proc(handle: GpuCommandList, colors: []GpuView, depth: GpuView) {
    cmd := (^CommandList)(handle)

    handles := make([]d3d12.CPU_DESCRIPTOR_HANDLE, len(colors), context.temp_allocator)
    for view, index in colors {
        handles[index] = descriptor_cpu(&gpu.rtv_heap, (^Descriptor)(view).index)
    }

    depth_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    depth_pointer: ^d3d12.CPU_DESCRIPTOR_HANDLE
    if depth != nil {
        depth_handle = descriptor_cpu(&gpu.dsv_heap, (^Descriptor)(depth).index)
        depth_pointer = &depth_handle
    }

    cmd.list->OMSetRenderTargets(u32(len(handles)), raw_data(handles), false, depth_pointer)
}

@(private="package")
_gpu_clear_render_target :: proc(handle: GpuCommandList, view: GpuView, color: [4]f32) {
    cmd := (^CommandList)(handle)
    color := color
    cmd.list->ClearRenderTargetView(descriptor_cpu(&gpu.rtv_heap, (^Descriptor)(view).index), &color, 0, nil)
}

@(private="package")
_gpu_set_viewport :: proc(handle: GpuCommandList, x: int, y: int, width: int, height: int) {
    cmd := (^CommandList)(handle)
    viewport := d3d12.VIEWPORT{
        TopLeftX = f32(x),
        TopLeftY = f32(y),
        Width    = f32(width),
        Height   = f32(height),
        MaxDepth = 1.0,
    }
    cmd.list->RSSetViewports(1, &viewport)
}

@(private="package")
_gpu_set_scissor :: proc(handle: GpuCommandList, x: int, y: int, width: int, height: int) {
    cmd := (^CommandList)(handle)
    scissor := d3d12.RECT{
        left   = i32(x),
        top    = i32(y),
        right  = i32(x + width),
        bottom = i32(y + height),
    }
    cmd.list->RSSetScissorRects(1, &scissor)
}

@(private="package")
_gpu_set_constants :: proc(handle: GpuCommandList, values: []u32) {
    cmd := (^CommandList)(handle)
    cmd.list->SetGraphicsRoot32BitConstants(0, u32(len(values)), raw_data(values), 0)
}

@(private="package")
_gpu_draw :: proc(handle: GpuCommandList, vertex_count: int, instance_count: int) {
    cmd := (^CommandList)(handle)
    cmd.list->IASetPrimitiveTopology(.TRIANGLELIST)
    cmd.list->DrawInstanced(u32(vertex_count), u32(instance_count), 0, 0)
}

@(private="package")
_gpu_copy_buffer :: proc(handle: GpuCommandList, dst_handle: GpuBuffer, dst_offset: int, src_handle: GpuBuffer, src_offset: int, size: int) {
    cmd := (^CommandList)(handle)
    dst := (^Buffer)(dst_handle)
    src := (^Buffer)(src_handle)
    assert(dst_offset + size <= dst.size, "gpu_copy_buffer: copy overruns the destination buffer")
    assert(src_offset + size <= src.size, "gpu_copy_buffer: copy overruns the source buffer")
    cmd.list->CopyBufferRegion(dst.resource, u64(dst_offset), src.resource, u64(src_offset), u64(size))
}

texture_footprint :: proc(texture: ^Texture, mip: int, slice: int) -> (footprint: d3d12.PLACED_SUBRESOURCE_FOOTPRINT, rows: int, row_size: int, total: int) {
    desc: d3d12.RESOURCE_DESC
    texture.resource->GetDesc(&desc)

    num_rows: u32
    row_size_bytes: u64
    total_bytes: u64
    gpu.device->GetCopyableFootprints(&desc, u32(mip + slice * texture.mips), 1, 0, &footprint, &num_rows, &row_size_bytes, &total_bytes)
    return footprint, int(num_rows), int(row_size_bytes), int(total_bytes)
}

@(private="package")
_gpu_texture_upload_size :: proc(handle: GpuTexture, mip: int, slice: int) -> int {
    texture := (^Texture)(handle)
    _, _, _, total := texture_footprint(texture, mip, slice)
    return total
}

@(private="package")
_gpu_set_texture_data :: proc(handle: GpuCommandList, texture_handle: GpuTexture, mip: int, slice: int, data: []byte, staging_handle: GpuBuffer, staging_offset: int) {
    cmd := (^CommandList)(handle)
    texture := (^Texture)(texture_handle)
    staging := (^Buffer)(staging_handle)

    footprint, rows, row_size, total := texture_footprint(texture, mip, slice)
    total_rows := rows * int(footprint.Footprint.Depth)
    row_pitch := int(footprint.Footprint.RowPitch)

    assert(staging_offset + total <= staging.size, "gpu_set_texture_data: upload overruns the staging buffer")
    assert(len(data) == total_rows * row_size, "gpu_set_texture_data: data size does not match the subresource")

    mapped := _gpu_map(staging_handle)
    for row in 0 ..< total_rows {
        copy(mapped[staging_offset + row * row_pitch:], data[row * row_size:][:row_size])
    }

    footprint.Offset = u64(staging_offset)

    destination := d3d12.TEXTURE_COPY_LOCATION{ pResource = texture.resource, Type = .SUBRESOURCE_INDEX }
    destination.SubresourceIndex = u32(mip + slice * texture.mips)

    source := d3d12.TEXTURE_COPY_LOCATION{ pResource = staging.resource, Type = .PLACED_FOOTPRINT }
    source.PlacedFootprint = footprint

    cmd.list->CopyTextureRegion(&destination, 0, 0, 0, &source, nil)
}

@(private="package")
_gpu_create_pipeline_layout :: proc(desc: GpuPipelineLayoutDesc) -> GpuPipelineLayout {
    parameter := d3d12.ROOT_PARAMETER1{
        ParameterType    = ._32BIT_CONSTANTS,
        ShaderVisibility = .ALL,
    }
    parameter.Constants = { ShaderRegister = 0, RegisterSpace = 0, Num32BitValues = u32(desc.constant_count) }

    root_desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC{ Version = ._1_1 }
    root_desc.Desc_1_1 = {
        NumParameters = 1,
        pParameters   = &parameter,
        Flags         = {.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED},
    }

    blob, error_blob: ^d3d12.IBlob
    if hr := d3d12.SerializeVersionedRootSignature(&root_desc, &blob, &error_blob); hr < 0 {
        if error_blob != nil {
            fmt.println("root signature error:", cstring(error_blob->GetBufferPointer()))
        }
        check(hr, "SerializeVersionedRootSignature")
    }

    layout := gpu.free_layouts
    if layout != nil {
        sll_stack_pop(&gpu.free_layouts)
    } else {
        layout = new(PipelineLayout, gpu.arena_allocator)
    }
    layout^ = PipelineLayout{}

    check(gpu.device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&layout.signature)), "CreateRootSignature")
    blob->Release()

    return GpuPipelineLayout(layout)
}

@(private="package")
_gpu_destroy_pipeline_layout :: proc(handle: GpuPipelineLayout) {
    layout := (^PipelineLayout)(handle)
    layout.release_id = gpu.last_command_list_id
    sll_queue_push(&gpu.first_pending_layouts, &gpu.last_pending_layouts, layout)
}

@(private="package")
_gpu_create_pipeline :: proc(desc: GpuPipelineDesc) -> GpuPipeline {
    layout := (^PipelineLayout)(desc.layout)

    blend_target := d3d12.RENDER_TARGET_BLEND_DESC{
        BlendEnable           = d3d12.BOOL(desc.blend.enable),
        SrcBlend              = blend_factor_to_d3d12[desc.blend.src],
        DestBlend             = blend_factor_to_d3d12[desc.blend.dst],
        BlendOp               = blend_op_to_d3d12[desc.blend.op],
        SrcBlendAlpha         = blend_factor_to_d3d12[desc.blend.src_alpha],
        DestBlendAlpha        = blend_factor_to_d3d12[desc.blend.dst_alpha],
        BlendOpAlpha          = blend_op_to_d3d12[desc.blend.op_alpha],
        LogicOp               = .NOOP,
        RenderTargetWriteMask = 0b1111,
    }
    if !desc.blend.enable {
        blend_target.SrcBlend = .ONE
        blend_target.DestBlend = .ZERO
        blend_target.BlendOp = .ADD
        blend_target.SrcBlendAlpha = .ONE
        blend_target.DestBlendAlpha = .ZERO
        blend_target.BlendOpAlpha = .ADD
    }

    state_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC{
        pRootSignature = layout.signature,
        VS             = { pShaderBytecode = raw_data(desc.vertex_shader), BytecodeLength = len(desc.vertex_shader) },
        PS             = { pShaderBytecode = raw_data(desc.pixel_shader), BytecodeLength = len(desc.pixel_shader) },
        SampleMask     = max(u32),
        RasterizerState = {
            FillMode        = desc.raster.wireframe ? .WIREFRAME : .SOLID,
            CullMode        = cull_to_d3d12[desc.raster.cull],
            DepthClipEnable = true,
        },
        DepthStencilState = {
            DepthEnable    = d3d12.BOOL(desc.depth.test),
            DepthWriteMask = desc.depth.write ? .ALL : .ZERO,
            DepthFunc      = compare_to_d3d12[desc.depth.compare],
        },
        PrimitiveTopologyType = .TRIANGLE,
        NumRenderTargets      = u32(len(desc.color_formats)),
        DSVFormat             = format_to_dxgi[desc.depth_format],
        SampleDesc            = { Count = 1 },
    }
    for format, index in desc.color_formats {
        state_desc.BlendState.RenderTarget[index] = blend_target
        state_desc.RTVFormats[index] = format_to_dxgi[format]
    }

    pipeline := gpu.free_pipelines
    if pipeline != nil {
        sll_stack_pop(&gpu.free_pipelines)
    } else {
        pipeline = new(Pipeline, gpu.arena_allocator)
    }
    pipeline^ = Pipeline{ layout = layout }

    check(gpu.device->CreateGraphicsPipelineState(&state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pipeline.state)), "CreateGraphicsPipelineState")
    return GpuPipeline(pipeline)
}

@(private="package")
_gpu_destroy_pipeline :: proc(handle: GpuPipeline) {
    pipeline := (^Pipeline)(handle)
    pipeline.release_id = gpu.last_command_list_id
    sll_queue_push(&gpu.first_pending_pipelines, &gpu.last_pending_pipelines, pipeline)
}

@(private="package")
_gpu_set_pipeline :: proc(handle: GpuCommandList, pipeline_handle: GpuPipeline) {
    cmd := (^CommandList)(handle)
    pipeline := (^Pipeline)(pipeline_handle)
    cmd.list->SetGraphicsRootSignature(pipeline.layout.signature)
    cmd.list->SetPipelineState(pipeline.state)
}

@(private="package")
_gpu_create_buffer :: proc(desc: GpuBufferDesc) -> GpuBuffer {
    resource_desc := d3d12.RESOURCE_DESC{
        Dimension        = .BUFFER,
        Width            = u64(desc.size),
        Height           = 1,
        DepthOrArraySize = 1,
        MipLevels        = 1,
        Format           = .UNKNOWN,
        SampleDesc       = { Count = 1 },
        Layout           = .ROW_MAJOR,
    }
    if desc.usage & GPU_BUFFER_USAGE_UAV != {} {
        resource_desc.Flags += {.ALLOW_UNORDERED_ACCESS}
    }

    heap_type: d3d12.HEAP_TYPE = .DEFAULT
    initial_state := d3d12.RESOURCE_STATE_COMMON
    switch desc.memory {
    case .Device:
        heap_type = .DEFAULT
    case .Upload:
        heap_type = .UPLOAD
        initial_state = d3d12.RESOURCE_STATE_GENERIC_READ
    case .Readback:
        heap_type = .READBACK
        initial_state = {.COPY_DEST}
    }

    buffer := gpu.free_buffers
    if buffer != nil {
        sll_stack_pop(&gpu.free_buffers)
    } else {
        buffer = new(Buffer, gpu.arena_allocator)
    }
    buffer^ = Buffer{ size = desc.size }

    check(d3d12ma.create_resource(gpu.allocator, heap_type, &resource_desc, initial_state, nil, &buffer.allocation, &buffer.resource), "d3d12ma create_resource(buffer)")
    return GpuBuffer(buffer)
}

@(private="package")
_gpu_destroy_buffer :: proc(handle: GpuBuffer) {
    buffer := (^Buffer)(handle)
    buffer.release_id = gpu.last_command_list_id
    sll_queue_push(&gpu.first_pending_buffers, &gpu.last_pending_buffers, buffer)
}

@(private="package")
_gpu_map :: proc(handle: GpuBuffer) -> []byte {
    buffer := (^Buffer)(handle)
    if buffer.mapped == nil {
        read_range := d3d12.RANGE{}
        check(buffer.resource->Map(0, &read_range, &buffer.mapped), "Map")
    }
    return ([^]byte)(buffer.mapped)[:buffer.size]
}

@(private="package")
_gpu_create_texture :: proc(desc: GpuTextureDesc) -> GpuTexture {
    depth := max(desc.depth, 1)
    mips := max(desc.mips, 1)
    array_size := max(desc.array_size, 1)

    dimension: d3d12.RESOURCE_DIMENSION = .TEXTURE2D
    if desc.depth > 1 {
        dimension = .TEXTURE3D
    }

    resource_desc := d3d12.RESOURCE_DESC1{
        Dimension        = dimension,
        Width            = u64(desc.width),
        Height           = u32(desc.height),
        DepthOrArraySize = u16(dimension == .TEXTURE3D ? depth : array_size),
        MipLevels        = u16(mips),
        Format           = format_to_dxgi[desc.format],
        SampleDesc       = { Count = 1 },
        Layout           = .UNKNOWN,
    }

    if .Rtv in desc.usage {
        resource_desc.Flags += {.ALLOW_RENDER_TARGET}
    }
    if desc.usage & GPU_TEXTURE_USAGE_DSV != {} {
        resource_desc.Flags += {.ALLOW_DEPTH_STENCIL}
    }
    if desc.usage & GPU_TEXTURE_USAGE_UAV != {} {
        resource_desc.Flags += {.ALLOW_UNORDERED_ACCESS}
    }

    clear_value: d3d12.CLEAR_VALUE
    clear_pointer: ^d3d12.CLEAR_VALUE
    if desc.usage & (GPU_TEXTURE_USAGE_DSV + {.Rtv}) != {} {
        clear_value.Format = resource_desc.Format
        if desc.usage & GPU_TEXTURE_USAGE_DSV != {} {
            clear_value.DepthStencil = { Depth = 1.0 }
        }
        clear_pointer = &clear_value
    }

    texture := gpu.free_textures
    if texture != nil {
        sll_stack_pop(&gpu.free_textures)
    } else {
        texture = new(Texture, gpu.arena_allocator)
    }
    texture^ = Texture{
        width      = desc.width,
        height     = desc.height,
        depth      = depth,
        mips       = mips,
        array_size = array_size,
        format     = desc.format,
    }

    initial_layout := texture_usage_to_d3d12_layout(desc.initial_usage)
    check(d3d12ma.create_resource3(gpu.allocator, .DEFAULT, &resource_desc, initial_layout, clear_pointer, &texture.allocation, &texture.resource), "d3d12ma create_resource3(texture)")
    return GpuTexture(texture)
}

@(private="package")
_gpu_destroy_texture :: proc(handle: GpuTexture) {
    texture := (^Texture)(handle)
    texture.release_id = gpu.last_command_list_id
    sll_queue_push(&gpu.first_pending_textures, &gpu.last_pending_textures, texture)
}


@(private="package")
_gpu_create_buffer_view :: proc(handle: GpuBuffer, desc: GpuBufferViewDesc) -> GpuView {
    buffer := (^Buffer)(handle)
    view := descriptor_alloc(&gpu.srv_heap)

    switch desc.kind {
    case .Srv:
        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format                  = .UNKNOWN,
            ViewDimension           = .BUFFER,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Buffer = {
            FirstElement        = u64(desc.first),
            NumElements         = u32(desc.count),
            StructureByteStride = u32(desc.stride),
        }
        gpu.device->CreateShaderResourceView(buffer.resource, &srv_desc, descriptor_cpu(&gpu.srv_heap, view.index))

    case .Uav:
        uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC{
            Format        = .UNKNOWN,
            ViewDimension = .BUFFER,
        }
        uav_desc.Buffer = {
            FirstElement        = u64(desc.first),
            NumElements         = u32(desc.count),
            StructureByteStride = u32(desc.stride),
        }
        gpu.device->CreateUnorderedAccessView(buffer.resource, nil, &uav_desc, descriptor_cpu(&gpu.srv_heap, view.index))

    case .Rtv, .Dsv:
        assert(false, "gpu_create_buffer_view: buffers cannot have render target or depth stencil views")
    }

    return GpuView(view)
}

@(private="package")
_gpu_create_texture_view :: proc(handle: GpuTexture, desc: GpuTextureViewDesc) -> GpuView {
    texture := (^Texture)(handle)
    format := desc.format if desc.format != .None else texture.format
    dxgi_format := format_to_dxgi[format]
    mip_count := max(desc.mip_count, 1)
    slice_count := max(desc.slice_count, 1)

    switch desc.kind {
    case .Srv:
        view := descriptor_alloc(&gpu.srv_heap)
        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format                  = dxgi_format,
            ViewDimension           = .TEXTURE2D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Texture2D = {
            MostDetailedMip = u32(desc.first_mip),
            MipLevels       = u32(mip_count),
        }
        gpu.device->CreateShaderResourceView(texture.resource, &srv_desc, descriptor_cpu(&gpu.srv_heap, view.index))
        return GpuView(view)

    case .Uav:
        view := descriptor_alloc(&gpu.srv_heap)
        uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC{
            Format        = dxgi_format,
            ViewDimension = .TEXTURE2D,
        }
        uav_desc.Texture2D = { MipSlice = u32(desc.first_mip) }
        gpu.device->CreateUnorderedAccessView(texture.resource, nil, &uav_desc, descriptor_cpu(&gpu.srv_heap, view.index))
        return GpuView(view)

    case .Rtv:
        view := descriptor_alloc(&gpu.rtv_heap)
        rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC{
            Format        = dxgi_format,
            ViewDimension = .TEXTURE2D,
        }
        rtv_desc.Texture2D = { MipSlice = u32(desc.first_mip) }
        gpu.device->CreateRenderTargetView(texture.resource, &rtv_desc, descriptor_cpu(&gpu.rtv_heap, view.index))
        return GpuView(view)

    case .Dsv:
        view := descriptor_alloc(&gpu.dsv_heap)
        dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC{
            Format        = dxgi_format,
            ViewDimension = .TEXTURE2D,
        }
        dsv_desc.Texture2D = { MipSlice = u32(desc.first_mip) }
        gpu.device->CreateDepthStencilView(texture.resource, &dsv_desc, descriptor_cpu(&gpu.dsv_heap, view.index))
        return GpuView(view)
    }

    return nil
}

@(private="package")
_gpu_destroy_view :: proc(handle: GpuView) {
    descriptor_free((^Descriptor)(handle))
}

@(private="package")
_gpu_view_index :: proc(handle: GpuView) -> int {
    return (^Descriptor)(handle).index
}

retire_command_lists :: proc() {
    for cmd := gpu.first_in_flight; cmd != nil; cmd = gpu.first_in_flight {
        if cmd.fence_value == 0 {
            return
        }
        queue := &gpu.queues[cmd.queue]
        if int(queue.fence->GetCompletedValue()) < cmd.fence_value {
            return
        }
        sll_queue_pop(&gpu.first_in_flight, &gpu.last_in_flight)
        sll_stack_push(&queue.free_lists, cmd)
    }
}

completed_command_list_id :: proc() -> int {
    if gpu.first_in_flight != nil {
        return gpu.first_in_flight.id - 1
    }
    return gpu.last_command_list_id
}

release_pending :: proc(completed: int) {
    for gpu.first_pending_buffers != nil && gpu.first_pending_buffers.release_id <= completed {
        buffer := gpu.first_pending_buffers
        sll_queue_pop(&gpu.first_pending_buffers, &gpu.last_pending_buffers)
        buffer.resource->Release()
        d3d12ma.release_allocation(buffer.allocation)
        sll_stack_push(&gpu.free_buffers, buffer)
    }

    for gpu.first_pending_layouts != nil && gpu.first_pending_layouts.release_id <= completed {
        layout := gpu.first_pending_layouts
        sll_queue_pop(&gpu.first_pending_layouts, &gpu.last_pending_layouts)
        layout.signature->Release()
        sll_stack_push(&gpu.free_layouts, layout)
    }

    for gpu.first_pending_pipelines != nil && gpu.first_pending_pipelines.release_id <= completed {
        pipeline := gpu.first_pending_pipelines
        sll_queue_pop(&gpu.first_pending_pipelines, &gpu.last_pending_pipelines)
        pipeline.state->Release()
        sll_stack_push(&gpu.free_pipelines, pipeline)
    }

    for gpu.first_pending_textures != nil && gpu.first_pending_textures.release_id <= completed {
        texture := gpu.first_pending_textures
        sll_queue_pop(&gpu.first_pending_textures, &gpu.last_pending_textures)
        texture.resource->Release()
        d3d12ma.release_allocation(texture.allocation)
        sll_stack_push(&gpu.free_textures, texture)
    }
}

@(private="package")
_gpu_collect :: proc() {
    retire_command_lists()
    completed := completed_command_list_id()
    descriptor_recycle(&gpu.srv_heap, completed)
    descriptor_recycle(&gpu.sampler_heap, completed)
    descriptor_recycle(&gpu.rtv_heap, completed)
    descriptor_recycle(&gpu.dsv_heap, completed)
    release_pending(completed)
}

buffer_usage_to_d3d12_sync_access :: proc(usage: GpuBufferUsage) -> (d3d12.BARRIER_SYNC_FLAGS, d3d12.BARRIER_ACCESS_FLAGS) {
    if usage == {} {
        return {}, {.NO_ACCESS}
    }

    sync: d3d12.BARRIER_SYNC_FLAGS
    access: d3d12.BARRIER_ACCESS_FLAGS
    for bit in usage {
        sync += buffer_usage_to_sync_d3d12[bit]
        access += buffer_usage_to_access_d3d12[bit]
    }

    return sync, access
}

texture_usage_to_d3d12_sync_access :: proc(usage: GpuTextureUsage) -> (d3d12.BARRIER_SYNC_FLAGS, d3d12.BARRIER_ACCESS_FLAGS) {
    if usage == {} {
        return {}, {.NO_ACCESS}
    }

    sync: d3d12.BARRIER_SYNC_FLAGS
    access: d3d12.BARRIER_ACCESS_FLAGS
    for bit in usage {
        sync += texture_usage_to_sync_d3d12[bit]
        access += texture_usage_to_access_d3d12[bit]
    }

    return sync, access
}


texture_usage_to_d3d12_layout :: proc(usage: GpuTextureUsage) -> d3d12.BARRIER_LAYOUT {
    if usage == {} {
        return .UNDEFINED
    }

    if (usage & GPU_TEXTURE_USAGE_SRV) == usage {
        return .SHADER_RESOURCE
    } else if (usage & GPU_TEXTURE_USAGE_UAV) == usage {
        return .UNORDERED_ACCESS
    } else if (usage & GPU_TEXTURE_USAGE_DSV) == usage {
        return .Dsv_Write in usage ? .DEPTH_STENCIL_WRITE : .DEPTH_STENCIL_READ
    }

    switch usage {
    case { .Rtv }:
        return .RENDER_TARGET
    case { .Copy_Source }:
        return .COPY_SOURCE
    case { .Copy_Dest }:
        return .COPY_DEST
    case { .Present }:
        return .PRESENT
    }

    return .COMMON
}

@(private="package")
_gpu_barrier :: proc(handle: GpuCommandList, textures: []GpuTextureBarrier, buffers: []GpuBufferBarrier) {
    cmd := (^CommandList)(handle)
    groups: [2]d3d12.BARRIER_GROUP
    group_count := 0

    texture_barriers := make([]d3d12.TEXTURE_BARRIER, len(textures), context.temp_allocator)
    for entry, index in textures {
        texture := (^Texture)(entry.texture)

        barrier := &texture_barriers[index]
        barrier.SyncBefore, barrier.AccessBefore = texture_usage_to_d3d12_sync_access(entry.before)
        barrier.SyncAfter, barrier.AccessAfter = texture_usage_to_d3d12_sync_access(entry.after)
        barrier.LayoutBefore = texture_usage_to_d3d12_layout(entry.before)
        barrier.LayoutAfter = texture_usage_to_d3d12_layout(entry.after)
        barrier.pResource = texture.resource

        sub := entry.subresources
        if sub == GPU_SUBRESOURCE_ALL {
            barrier.Subresources = { IndexOrFirstMipLevel = max(u32) }
        } else {
            barrier.Subresources = {
                IndexOrFirstMipLevel = u32(sub.first_mip),
                NumMipLevels         = u32(max(sub.mip_count, 1)),
                FirstArraySlice      = u32(sub.first_slice),
                NumArraySlices       = u32(max(sub.slice_count, 1)),
                NumPlanes            = 1,
            }
        }

        if entry.before == {} {
            barrier.Flags = .DISCARD
        }
    }

    if len(texture_barriers) > 0 {
        groups[group_count] = {
            Type        = .TEXTURE,
            NumBarriers = u32(len(texture_barriers)),
        }
        groups[group_count].pTextureBarriers = raw_data(texture_barriers)
        group_count += 1
    }

    buffer_barriers := make([]d3d12.BUFFER_BARRIER, len(buffers), context.temp_allocator)
    for entry, index in buffers {
        buffer := (^Buffer)(entry.buffer)
        barrier := &buffer_barriers[index]
        barrier.SyncBefore, barrier.AccessBefore = buffer_usage_to_d3d12_sync_access(entry.before)
        barrier.SyncAfter, barrier.AccessAfter = buffer_usage_to_d3d12_sync_access(entry.after)
        barrier.pRessource = buffer.resource
        barrier.Offset = 0
        barrier.Size = max(u64)
    }

    if len(buffer_barriers) > 0 {
        groups[group_count] = {
            Type        = .BUFFER,
            NumBarriers = u32(len(buffer_barriers)),
        }
        groups[group_count].pBufferBarriers = raw_data(buffer_barriers)
        group_count += 1
    }

    if group_count > 0 {
        cmd.list->Barrier(u32(group_count), &groups[0])
    }
}

descriptor_cpu :: proc(heap: ^DescriptorHeap, index: int) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    handle := heap.cpu_start
    handle.ptr += uint(index * heap.stride)
    return handle
}


descriptor_gpu :: proc(heap: ^DescriptorHeap, index: int) -> d3d12.GPU_DESCRIPTOR_HANDLE {
    assert(heap.shader_visible, "descriptor_gpu: heap is not shader visible")
    handle := heap.gpu_start
    handle.ptr += u64(index * heap.stride)
    return handle
}

@(private="package")
_gpu_shutdown :: proc() {
    wait_for_gpu()
    _gpu_collect()

    for kind in GpuQueue {
        queue := &gpu.queues[kind]
        for list := queue.free_lists; list != nil; list = list.next {
            list.list->Release()
            list.allocator->Release()
        }
        win32.CloseHandle(queue.fence_event)
        queue.fence->Release()
        queue.queue->Release()
    }

    descriptor_heap_destroy(&gpu.srv_heap)
    descriptor_heap_destroy(&gpu.sampler_heap)
    descriptor_heap_destroy(&gpu.rtv_heap)
    descriptor_heap_destroy(&gpu.dsv_heap)
    d3d12ma.release_allocator(gpu.allocator)
    gpu.device->Release()
    gpu.adapter->Release()
    gpu.factory->Release()
    virtual.arena_destroy(&gpu.arena)
}

@(private="package")
_gpu_swapchain_acquire :: proc(handle: GpuSwapchain) -> bool {
    chain := (^Swapchain)(handle)

    if chain.width == 0 || chain.height == 0 {
        return false
    }

    win32.WaitForSingleObject(chain.latency_waitable, win32.INFINITE)

    chain.back_buffer_index = int(chain.swapchain->GetCurrentBackBufferIndex())
    wait_for_fence(.Direct, chain.fence_values[chain.back_buffer_index])

    return true
}


@(private="package")
_gpu_swapchain_present :: proc(handle: GpuSwapchain) {
    chain := (^Swapchain)(handle)
    queue := &gpu.queues[.Direct]

    check(chain.swapchain->Present(1, {}), "Present")

    gpu.last_fence_value += 1
    queue.last_fence_value = gpu.last_fence_value
    check(queue.queue->Signal(queue.fence, u64(gpu.last_fence_value)), "Signal")
    chain.fence_values[chain.back_buffer_index] = gpu.last_fence_value
}

client_size :: proc(hwnd: win32.HWND) -> (width: int, height: int) {
    rect: win32.RECT
    win32.GetClientRect(hwnd, &rect)
    return int(rect.right - rect.left), int(rect.bottom - rect.top)
}

create_back_buffer_views :: proc(swapchain: ^Swapchain) {
    for index in 0 ..< BACK_BUFFER_COUNT {
        texture := &swapchain.back_buffers[index]
        texture^ = Texture{
            width      = swapchain.width,
            height     = swapchain.height,
            depth      = 1,
            mips       = 1,
            array_size = 1,
            format     = .RGBA8_Unorm,
        }
        check(swapchain.swapchain->GetBuffer(u32(index), d3d12.IResource_UUID, (^rawptr)(&texture.resource)), "GetBuffer")
        gpu.device->CreateRenderTargetView(texture.resource, nil, descriptor_cpu(&gpu.rtv_heap, swapchain.back_buffer_views[index].index))
    }
}

release_back_buffers :: proc(chain: ^Swapchain) {
    for &texture in chain.back_buffers {
        if texture.resource != nil {
            texture.resource->Release()
            texture.resource = nil
        }
    }
}

wait_for_fence :: proc(kind: GpuQueue, value: int) {
    queue := &gpu.queues[kind]
    if queue.fence->GetCompletedValue() >= u64(value) {
        return
    }
    check(queue.fence->SetEventOnCompletion(u64(value), queue.fence_event), "SetEventOnCompletion")
    win32.WaitForSingleObject(queue.fence_event, win32.INFINITE)
}

wait_for_gpu :: proc() {
    for kind in GpuQueue {
        queue := &gpu.queues[kind]
        gpu.last_fence_value += 1
        queue.last_fence_value = gpu.last_fence_value
        check(queue.queue->Signal(queue.fence, u64(gpu.last_fence_value)), "Signal")
    }

    for kind in GpuQueue {
        wait_for_fence(kind, gpu.queues[kind].last_fence_value)
    }
}

format_to_dxgi := [GpuFormat]dxgi.FORMAT {
    .None              = .UNKNOWN,
    .RGBA8_Unorm       = .R8G8B8A8_UNORM,
    .RGBA8_Unorm_Srgb  = .R8G8B8A8_UNORM_SRGB,
    .BGRA8_Unorm       = .B8G8R8A8_UNORM,
    .RG16_Float        = .R16G16_FLOAT,
    .RGBA16_Float      = .R16G16B16A16_FLOAT,
    .RGBA32_Float      = .R32G32B32A32_FLOAT,
    .R32_Float         = .R32_FLOAT,
    .D32_Float         = .D32_FLOAT,
    .D24_Unorm_S8_Uint = .D24_UNORM_S8_UINT,
}

cull_to_d3d12 := [GpuCullMode]d3d12.CULL_MODE {
    .None  = .NONE,
    .Front = .FRONT,
    .Back  = .BACK,
}

compare_to_d3d12 := [GpuCompare]d3d12.COMPARISON_FUNC {
    .Never         = .NEVER,
    .Less          = .LESS,
    .Equal         = .EQUAL,
    .Less_Equal    = .LESS_EQUAL,
    .Greater       = .GREATER,
    .Not_Equal     = .NOT_EQUAL,
    .Greater_Equal = .GREATER_EQUAL,
    .Always        = .ALWAYS,
}

blend_factor_to_d3d12 := [GpuBlendFactor]d3d12.BLEND {
    .Zero          = .ZERO,
    .One           = .ONE,
    .Src_Alpha     = .SRC_ALPHA,
    .Inv_Src_Alpha = .INV_SRC_ALPHA,
    .Src_Color     = .SRC_COLOR,
    .Inv_Src_Color = .INV_SRC_COLOR,
    .Dst_Alpha     = .DEST_ALPHA,
    .Inv_Dst_Alpha = .INV_DEST_ALPHA,
}

blend_op_to_d3d12 := [GpuBlendOp]d3d12.BLEND_OP {
    .Add              = .ADD,
    .Subtract         = .SUBTRACT,
    .Reverse_Subtract = .REV_SUBTRACT,
    .Min              = .MIN,
    .Max              = .MAX,
}

buffer_usage_to_sync_d3d12 := [GpuBufferUsageBit]d3d12.BARRIER_SYNC_FLAGS {
    .Constant_Vertex  = { .VERTEX_SHADING },
    .Constant_Pixel   = { .PIXEL_SHADING },
    .Constant_Compute = { .COMPUTE_SHADING },
    .Srv_Vertex       = { .VERTEX_SHADING },
    .Srv_Pixel        = { .PIXEL_SHADING },
    .Srv_Compute      = { .COMPUTE_SHADING },
    .Uav_Vertex       = { .VERTEX_SHADING },
    .Uav_Pixel        = { .PIXEL_SHADING },
    .Uav_Compute      = { .COMPUTE_SHADING },
    .Vertex_Or_Index  = { .VERTEX_SHADING, .INDEX_INPUT },
    .Indirect         = { .EXECUTE_INDIRECT },
    .Copy_Source      = { .COPY },
    .Copy_Dest        = { .COPY },
}

buffer_usage_to_access_d3d12 := [GpuBufferUsageBit]d3d12.BARRIER_ACCESS_FLAGS {
    .Constant_Vertex  = { .CONSTANT_BUFFER },
    .Constant_Pixel   = { .CONSTANT_BUFFER },
    .Constant_Compute = { .CONSTANT_BUFFER },
    .Srv_Vertex       = { .SHADER_RESOURCE },
    .Srv_Pixel        = { .SHADER_RESOURCE },
    .Srv_Compute      = { .SHADER_RESOURCE },
    .Uav_Vertex       = { .UNORDERED_ACCESS },
    .Uav_Pixel        = { .UNORDERED_ACCESS },
    .Uav_Compute      = { .UNORDERED_ACCESS },
    .Vertex_Or_Index  = { .VERTEX_BUFFER, .INDEX_BUFFER },
    .Indirect         = { .INDIRECT_ARGUMENT },
    .Copy_Source      = { .COPY_SOURCE },
    .Copy_Dest        = { .COPY_DEST },
}

texture_usage_to_sync_d3d12 := [GpuTextureUsageBit]d3d12.BARRIER_SYNC_FLAGS {
    .Srv_Vertex       = { .VERTEX_SHADING },
    .Srv_Pixel        = { .PIXEL_SHADING },
    .Srv_Compute      = { .COMPUTE_SHADING },
    .Uav_Vertex       = { .VERTEX_SHADING },
    .Uav_Pixel        = { .PIXEL_SHADING },
    .Uav_Compute      = { .COMPUTE_SHADING },
    .Rtv              = { .RENDER_TARGET },
    .Dsv_Read         = { .DEPTH_STENCIL },
    .Dsv_Write        = { .DEPTH_STENCIL },
    .Copy_Source      = { .COPY },
    .Copy_Dest        = { .COPY },
    .Present          = {  },
}

texture_usage_to_access_d3d12 := [GpuTextureUsageBit]d3d12.BARRIER_ACCESS_FLAGS {
    .Srv_Vertex       = { .SHADER_RESOURCE },
    .Srv_Pixel        = { .SHADER_RESOURCE },
    .Srv_Compute      = { .SHADER_RESOURCE },
    .Uav_Vertex       = { .UNORDERED_ACCESS },
    .Uav_Pixel        = { .UNORDERED_ACCESS },
    .Uav_Compute      = { .UNORDERED_ACCESS },
    .Rtv              = { .RENDER_TARGET },
    .Dsv_Read         = { .DEPTH_STENCIL_READ },
    .Dsv_Write        = { .DEPTH_STENCIL_WRITE },
    .Copy_Source      = { .COPY_SOURCE },
    .Copy_Dest        = { .COPY_DEST },
    .Present          = { .NO_ACCESS },
}
package vg

import "core:mem"
import "core:mem/virtual"

GpuBuffer         :: distinct rawptr
GpuTexture        :: distinct rawptr
GpuView           :: distinct rawptr
GpuSwapchain      :: distinct rawptr
GpuCommandList    :: distinct rawptr
GpuPipelineLayout :: distinct rawptr
GpuPipeline       :: distinct rawptr
GpuSampler        :: distinct rawptr
GpuFence          :: distinct rawptr

GpuTempView :: struct {
    idx: i32,
}

GpuPtr :: struct {
    view_index: i32,
    offset:     i32,
}

GpuQueue :: enum {
    Direct,
    Async_Compute,
    Async_Copy,
}

GpuMemory :: enum {
    Device,
    Upload,
    Readback,
}

GpuFormat :: enum {
    None,
    RGBA8_Unorm,
    RGBA8_Unorm_Srgb,
    BGRA8_Unorm,
    RG16_Float,
    RGBA16_Float,
    RGBA32_Float,
    R32_Float,
    R8_Unorm,
    D32_Float,
    D24_Unorm_S8_Uint,
}

GpuTopology :: enum {
    Triangle_List,
    Triangle_Strip,
    Line_List,
    Point_List,
}

GpuIndexFormat :: enum {
    Index16,
    Index32,
}

GpuFilter :: enum {
    Nearest,
    Linear,
}

GpuAddressMode :: enum {
    Repeat,
    Clamp,
    Mirror,
    Border,
}

GpuSamplerDesc :: struct {
    min:            GpuFilter,
    mag:            GpuFilter,
    mip:            GpuFilter,
    address_u:      GpuAddressMode,
    address_v:      GpuAddressMode,
    address_w:      GpuAddressMode,
    max_anisotropy: i32,
    compare:        GpuCompare,
}

GpuViewKind :: enum {
    Srv,
    Uav,
    Rtv,
    Dsv,
}

GpuBufferUsageBit :: enum u32 {
    Constant_Vertex,
    Constant_Pixel,
    Constant_Compute,
    Srv_Vertex,
    Srv_Pixel,
    Srv_Compute,
    Uav_Vertex,
    Uav_Pixel,
    Uav_Compute,
    Vertex_Or_Index,
    Indirect,
    Copy_Source,
    Copy_Dest,
}

GpuBufferUsage :: bit_set[GpuBufferUsageBit; u32]

GPU_BUFFER_USAGE_SRV :: GpuBufferUsage{.Srv_Vertex, .Srv_Pixel, .Srv_Compute}
GPU_BUFFER_USAGE_UAV :: GpuBufferUsage{.Uav_Vertex, .Uav_Pixel, .Uav_Compute}
GPU_BUFFER_USAGE_CONSTANT :: GpuBufferUsage{.Constant_Vertex, .Constant_Pixel, .Constant_Compute}
GPU_BUFFER_USAGE_WRITE :: GPU_BUFFER_USAGE_UAV + {.Copy_Dest}

GpuTextureUsageBit :: enum u32 {
    Srv_Vertex,
    Srv_Pixel,
    Srv_Compute,
    Uav_Vertex,
    Uav_Pixel,
    Uav_Compute,
    Rtv,
    Dsv_Read,
    Dsv_Write,
    Copy_Source,
    Copy_Dest,
    Present,
}

GpuTextureUsage :: bit_set[GpuTextureUsageBit; u32]

GPU_TEXTURE_USAGE_SRV :: GpuTextureUsage{.Srv_Vertex, .Srv_Pixel, .Srv_Compute}
GPU_TEXTURE_USAGE_UAV :: GpuTextureUsage{.Uav_Vertex, .Uav_Pixel, .Uav_Compute}
GPU_TEXTURE_USAGE_DSV :: GpuTextureUsage{.Dsv_Read, .Dsv_Write}
GPU_TEXTURE_USAGE_WRITE :: GPU_TEXTURE_USAGE_UAV + {.Rtv, .Dsv_Write, .Copy_Dest}

GpuBufferDesc :: struct {
    size:   i64,
    usage:  GpuBufferUsage,
    memory: GpuMemory,
}

GpuTextureDesc :: struct {
    width:         i32,
    height:        i32,
    depth:         i32,             // 0 or 1 = Texture2D, >1 = Texture3D
    mips:          i32,             // 0 = one mip
    array_size:    i32,             // 0 or 1 = Texture2D, >1 = Texture2DArray (ignored if depth > 1)
    format:        GpuFormat,
    usage:         GpuTextureUsage,
    initial_usage: GpuTextureUsage,
}

GpuSBufferViewDesc :: struct {
    kind:   GpuViewKind,
    first:  i64,
    count:  i64,
    stride: i64,
}

GpuRawBufferViewDesc :: struct {
    kind:   GpuViewKind,
    offset: i64,
    size:   i64,
}

GpuTextureViewDesc :: struct {
    kind:        GpuViewKind,
    format:      GpuFormat,   // .None uses the texture's own format
    first_mip:   i32,
    mip_count:   i32,         // 0 = one mip
    first_slice: i32,
    slice_count: i32,         // 0 = every slice from first_slice
}

GpuCullMode :: enum {
    None,
    Front,
    Back,
}

GpuCompare :: enum {
    Never,
    Less,
    Equal,
    Less_Equal,
    Greater,
    Not_Equal,
    Greater_Equal,
    Always,
}

GpuBlendFactor :: enum {
    Zero,
    One,
    Src_Alpha,
    Inv_Src_Alpha,
    Src_Color,
    Inv_Src_Color,
    Dst_Alpha,
    Inv_Dst_Alpha,
}

GpuBlendOp :: enum {
    Add,
    Subtract,
    Reverse_Subtract,
    Min,
    Max,
}

GpuRasterState :: struct {
    cull:      GpuCullMode,
    wireframe: bool,
}

GpuDepthState :: struct {
    test:    bool,
    write:   bool,
    compare: GpuCompare,
}

GpuBlendState :: struct {
    enable:    bool,
    src:       GpuBlendFactor,
    dst:       GpuBlendFactor,
    op:        GpuBlendOp,
    src_alpha: GpuBlendFactor,
    dst_alpha: GpuBlendFactor,
    op_alpha:  GpuBlendOp,
}

GpuPipelineLayoutDesc :: struct {
    constant_count: i32,
}

GpuPipelineDesc :: struct {
    layout:        GpuPipelineLayout,
    vertex_shader: []byte,
    pixel_shader:  []byte,
    color_formats: []GpuFormat,
    depth_format:  GpuFormat,
    topology:      GpuTopology,
    raster:        GpuRasterState,
    depth:         GpuDepthState,
    blend:         GpuBlendState,
}

GpuSubresource :: struct {
    first_mip:   i32,
    mip_count:   i32,
    first_slice: i32,
    slice_count: i32,
}

GPU_SUBRESOURCE_ALL :: GpuSubresource{}

GpuBufferBarrier :: struct {
    buffer: GpuBuffer,
    before: GpuBufferUsage,
    after:  GpuBufferUsage,
}

GpuTextureBarrier :: struct {
    texture:      GpuTexture,
    before:       GpuTextureUsage,
    after:        GpuTextureUsage,
    subresources: GpuSubresource,
}

GpuArenaBlock :: struct {
    next:        ^GpuArenaBlock,
    buffer:      GpuBuffer,
    view:        GpuView,
    mapped:      []byte,
    size:        i64,
    pos:         i64,
    fence_value: i64,
}

GpuArena :: struct {
    arena:           ^virtual.Arena,
    current:         ^GpuArenaBlock,
    first_pending:   ^GpuArenaBlock,
    last_pending:    ^GpuArenaBlock,
    first_free:      ^GpuArenaBlock,
    cmt_size:        i64,
}

gpu_init :: proc() {
    _gpu_init()
}

gpu_shutdown :: proc() {
    _gpu_shutdown()
}

gpu_equip_window :: proc(window: WindowHandle) -> GpuSwapchain {
    return _gpu_equip_window(window)
}

gpu_unequip_window :: proc(swapchain: GpuSwapchain) {
    _gpu_unequip_window(swapchain)
}

gpu_swapchain_size :: proc(swapchain: GpuSwapchain) -> (width: i32, height: i32) {
    return _gpu_swapchain_size(swapchain)
}

gpu_swapchain_resize :: proc(swapchain: GpuSwapchain, width: i32, height: i32) {
    _gpu_swapchain_resize(swapchain, width, height)
}

gpu_swapchain_wait :: proc(swapchain: GpuSwapchain) {
    _gpu_swapchain_wait(swapchain)
}

gpu_swapchain_acquire :: proc(swapchain: GpuSwapchain) {
    _gpu_swapchain_acquire(swapchain)
}

gpu_swapchain_present :: proc(swapchain: GpuSwapchain) {
    _gpu_swapchain_present(swapchain)
}

gpu_collect :: proc() {
    _gpu_collect()
}

gpu_back_buffer :: proc(swapchain: GpuSwapchain) -> GpuTexture {
    return _gpu_back_buffer(swapchain)
}

gpu_back_buffer_view :: proc(swapchain: GpuSwapchain) -> GpuView {
    return _gpu_back_buffer_view(swapchain)
}

gpu_command_list_begin :: proc(queue: GpuQueue) -> GpuCommandList {
    return _gpu_command_list_begin(queue)
}

gpu_command_list_end :: proc(cmd: GpuCommandList) {
    _gpu_command_list_end(cmd)
}

gpu_submit_one :: proc (cmd: GpuCommandList) {
    submits := [1]GpuCommandList{ cmd }
    gpu_submit_multiple(submits[:])
}

gpu_submit_multiple :: proc(cmds: []GpuCommandList) {
    _gpu_submit(cmds)
}

gpu_submit :: proc{ gpu_submit_one, gpu_submit_multiple }

gpu_set_render_target_one:: proc(cmd: GpuCommandList, color: GpuView, depth: GpuView = nil) {
    colors := [1]GpuView{ color }
    _gpu_set_render_targets(cmd, colors[:], depth)
}

gpu_set_render_target_multiple :: proc(cmd: GpuCommandList, colors: []GpuView, depth: GpuView = nil) {
    _gpu_set_render_targets(cmd, colors, depth)
}

gpu_set_render_target :: proc{ gpu_set_render_target_one, gpu_set_render_target_multiple }

gpu_clear_render_target :: proc(cmd: GpuCommandList, view: GpuView, color: [4]f32) {
    _gpu_clear_render_target(cmd, view, color)
}

gpu_clear_depth_stencil :: proc(cmd: GpuCommandList, view: GpuView, depth: f32 = 1, stencil: i32 = 0) {
    _gpu_clear_depth_stencil(cmd, view, depth, stencil)
}

gpu_set_viewport :: proc(cmd: GpuCommandList, x: i32, y: i32, width: i32, height: i32) {
    _gpu_set_viewport(cmd, x, y, width, height)
}

gpu_set_scissor :: proc(cmd: GpuCommandList, x: i32, y: i32, width: i32, height: i32) {
    _gpu_set_scissor(cmd, x, y, width, height)
}

gpu_push_constant_i32 :: proc(cmd: GpuCommandList, start_index: i32, value: i32) -> i32 {
    value := value
    _gpu_push_constant(cmd, start_index, (([^]i32)(&value))[:1])
    return start_index + 1
}

gpu_push_constant_i64 :: proc(cmd: GpuCommandList, start_index: i32, value: i64) -> i32 {
    value := value
    _gpu_push_constant(cmd, start_index, (([^]i32)(&value))[:2])
    return start_index + 2
}

gpu_push_constant_slice :: proc(cmd: GpuCommandList, start_index: i32, values: []i32) -> i32 {
    _gpu_push_constant(cmd, start_index, values)
    return start_index + i32(len(values))
}

gpu_push_constant_view :: proc(cmd: GpuCommandList, start_index: i32, view: GpuView) -> i32 {
    return gpu_push_constant_i32(cmd, start_index, gpu_view_index(view))
}

gpu_push_constant_temp_view :: proc(cmd: GpuCommandList, start_index: i32, view: GpuTempView) -> i32 {
    return gpu_push_constant_i32(cmd, start_index, gpu_view_index(view))
}

gpu_push_constant_sampler :: proc(cmd: GpuCommandList, start_index: i32, sampler: GpuSampler) -> i32 {
    return gpu_push_constant_i32(cmd, start_index, gpu_sampler_index(sampler))
}

gpu_push_constant_ptr :: proc(cmd: GpuCommandList, start_index: i32, ptr: GpuPtr) -> i32 {
    ptr := ptr
    return gpu_push_constant_slice(cmd, start_index, (([^]i32)(&ptr))[:2])
}

gpu_push_constant :: proc{
    gpu_push_constant_i32,
    gpu_push_constant_i64,
    gpu_push_constant_slice,
    gpu_push_constant_view,
    gpu_push_constant_temp_view,
    gpu_push_constant_sampler,
    gpu_push_constant_ptr,
}

gpu_draw :: proc(cmd: GpuCommandList, vertex_count: i32, instance_count: i32 = 1) {
    _gpu_draw(cmd, vertex_count, instance_count)
}

gpu_set_index_buffer :: proc(cmd: GpuCommandList, buffer: GpuBuffer, offset: i32, format: GpuIndexFormat) {
    _gpu_set_index_buffer(cmd, buffer, offset, format)
}

gpu_draw_indexed :: proc(cmd: GpuCommandList, index_count: i32, instance_count: i32 = 1, first_index: i32 = 0, base_vertex: i32 = 0) {
    _gpu_draw_indexed(cmd, index_count, instance_count, first_index, base_vertex)
}

gpu_copy_buffer :: proc(cmd: GpuCommandList, dst: GpuBuffer, dst_offset: i64, src: GpuBuffer, src_offset: i64, size: i64) {
    _gpu_copy_buffer(cmd, dst, dst_offset, src, src_offset, size)
}

gpu_texture_upload_size :: proc(texture: GpuTexture, mip: i32, slice: i32) -> i64 {
    return _gpu_texture_upload_size(texture, mip, slice)
}

gpu_set_texture_data :: proc(cmd: GpuCommandList, texture: GpuTexture, mip: i32, slice: i32, data: []byte, staging: GpuBuffer, staging_offset: i64) {
    _gpu_set_texture_data(cmd, texture, mip, slice, data, staging, staging_offset)
}

gpu_copy_buffer_to_texture :: proc(cmd: GpuCommandList, dst: GpuTexture, mip: i32, slice: i32, x: i32, y: i32, width: i32, height: i32, src: GpuBuffer, src_offset: i64, src_row_pitch: i32) {
    _gpu_copy_buffer_to_texture(cmd, dst, mip, slice, x, y, width, height, src, src_offset, src_row_pitch)
}

gpu_create_pipeline_layout :: proc(desc: GpuPipelineLayoutDesc) -> GpuPipelineLayout {
    return _gpu_create_pipeline_layout(desc)
}

gpu_destroy_pipeline_layout :: proc(layout: GpuPipelineLayout) {
    _gpu_destroy_pipeline_layout(layout)
}

gpu_create_pipeline :: proc(desc: GpuPipelineDesc) -> GpuPipeline {
    return _gpu_create_pipeline(desc)
}

gpu_destroy_pipeline :: proc(pipeline: GpuPipeline) {
    _gpu_destroy_pipeline(pipeline)
}

gpu_set_pipeline :: proc(cmd: GpuCommandList, pipeline: GpuPipeline) {
    _gpu_set_pipeline(cmd, pipeline)
}

gpu_create_buffer :: proc(desc: GpuBufferDesc) -> GpuBuffer {
    return _gpu_create_buffer(desc)
}

gpu_destroy_buffer :: proc(buffer: GpuBuffer) {
    _gpu_destroy_buffer(buffer)
}

gpu_create_texture :: proc(desc: GpuTextureDesc) -> GpuTexture {
    return _gpu_create_texture(desc)
}

gpu_destroy_texture :: proc(texture: GpuTexture) {
    _gpu_destroy_texture(texture)
}

gpu_map :: proc(buffer: GpuBuffer) -> []byte {
    return _gpu_map(buffer)
}

gpu_arena_alloc :: proc(arena: ^virtual.Arena, commit_size: i64) -> ^GpuArena {
    gpu_arena, _ := virtual.new(arena, GpuArena)
    gpu_arena.arena = arena
    gpu_arena.cmt_size = commit_size
    gpu_arena.current = gpu_arena_alloc_block(gpu_arena, commit_size)
    return gpu_arena
}

gpu_arena_release :: proc (gpu_arena: ^GpuArena) {
    for gpu_arena.current != nil {
        block := gpu_arena.current
        sll_stack_pop(&gpu_arena.current)
        gpu_destroy_view(block.view)
        gpu_destroy_buffer(block.buffer)
    }

    for gpu_arena.first_pending != nil {
        block := gpu_arena.first_pending
        sll_queue_pop(&gpu_arena.first_pending, &gpu_arena.last_pending)
        gpu_destroy_view(block.view)
        gpu_destroy_buffer(block.buffer)
    }
}

gpu_arena_reset :: proc(gpu_arena: ^GpuArena, retire_value: i64, completed_value: i64) {
    for gpu_arena.current != nil {
        block := gpu_arena.current
        block.fence_value = retire_value
        sll_stack_pop(&gpu_arena.current)
        sll_queue_push(&gpu_arena.first_pending, &gpu_arena.last_pending, block)
    }

    for gpu_arena.first_pending != nil && gpu_arena.first_pending.fence_value <= completed_value {
        block := gpu_arena.first_pending
        sll_queue_pop(&gpu_arena.first_pending, &gpu_arena.last_pending)

        if gpu_arena.current == nil {
            sll_stack_push(&gpu_arena.current, block)
            gpu_arena.current.pos = 0
        } else {
            gpu_destroy_view(block.view)
            gpu_destroy_buffer(block.buffer)
            sll_stack_push(&gpu_arena.first_free, block)
        }
    }

    if gpu_arena.current == nil {
        gpu_arena.current = gpu_arena_alloc_block(gpu_arena, gpu_arena.cmt_size)
    }
}

gpu_arena_alloc_block :: proc(gpu_arena: ^GpuArena, size: i64) -> ^GpuArenaBlock {
    block: ^GpuArenaBlock

    if gpu_arena.first_free != nil {
        block = gpu_arena.first_free
        sll_stack_pop(&gpu_arena.first_free)
    } else {
        block, _ = virtual.new(gpu_arena.arena, GpuArenaBlock)
    }

    block^ = {}
    block.size = max(size, gpu_arena.cmt_size)
    block.buffer = gpu_create_buffer({size = block.size, usage = GPU_BUFFER_USAGE_SRV + {.Copy_Source}, memory = .Upload})
    block.view = gpu_create_raw_buffer_view(block.buffer, {kind = .Srv, offset = 0, size = block.size})
    block.mapped = gpu_map(block.buffer)

    return block
}

gpu_arena_push_bytes :: proc(gpu_arena: ^GpuArena, size: i64) -> (data: []byte, ptr: GpuPtr) {
    assert(size != 0)

    current := gpu_arena.current
    bot := i64(mem.align_formula(int(current.pos), 16))
    top := bot + size

    if top > current.size {
        current = gpu_arena_alloc_block(gpu_arena, size)
        sll_stack_push(&gpu_arena.current, current)
        bot = 0
        top = bot + size
    }

    current.pos = top
    return current.mapped[bot:][:size], {gpu_view_index(current.view), i32(bot)}
}

gpu_arena_push_typed :: proc(gpu_arena: ^GpuArena, $T: typeid) -> (data: ^T, ptr: GpuPtr) {
    bytes, block_ptr := gpu_arena_push_bytes(gpu_arena, size_of(T))
    return (^T)(raw_data(bytes)), block_ptr
}

gpu_arena_push_array :: proc(gpu_arena: ^GpuArena, $T: typeid, count: i64) -> (data: []T, ptr: GpuPtr) {
    bytes, block_ptr := gpu_arena_push_bytes(gpu_arena, size_of(T) * count)
    return (([^]T)(raw_data(bytes)))[:count], block_ptr
}

gpu_arena_push :: proc{ gpu_arena_push_bytes, gpu_arena_push_typed, gpu_arena_push_array }

gpu_create_sbuffer_view :: proc(buffer: GpuBuffer, desc: GpuSBufferViewDesc) -> GpuView {
    return _gpu_create_sbuffer_view(buffer, desc)
}

gpu_create_raw_buffer_view :: proc(buffer: GpuBuffer, desc: GpuRawBufferViewDesc) -> GpuView {
    return _gpu_create_raw_buffer_view(buffer, desc)
}

gpu_create_texture_view :: proc(texture: GpuTexture, desc: GpuTextureViewDesc) -> GpuView {
    return _gpu_create_texture_view(texture, desc)
}

gpu_create_temp_sbuffer_view :: proc(buffer: GpuBuffer, desc: GpuSBufferViewDesc) -> GpuTempView {
    return _gpu_create_temp_sbuffer_view(buffer, desc)
}

gpu_create_temp_raw_buffer_view :: proc(buffer: GpuBuffer, desc: GpuRawBufferViewDesc) -> GpuTempView {
    return _gpu_create_temp_raw_buffer_view(buffer, desc)
}

gpu_create_temp_texture_view :: proc(texture: GpuTexture, desc: GpuTextureViewDesc) -> GpuTempView {
    return _gpu_create_temp_texture_view(texture, desc)
}

gpu_destroy_view :: proc(view: GpuView) {
    _gpu_destroy_view(view)
}

gpu_create_fence :: proc() -> GpuFence {
    return _gpu_create_fence()
}

gpu_destroy_fence :: proc(fence: GpuFence) {
    _gpu_destroy_fence(fence)
}

gpu_fence_signal :: proc(fence: GpuFence, queue: GpuQueue, value: i64) {
    _gpu_fence_signal(fence, queue, value)
}

gpu_fence_value :: proc(fence: GpuFence) -> i64 {
    return _gpu_fence_value(fence)
}

gpu_fence_complete :: proc(fence: GpuFence, value: i64) -> bool {
    return _gpu_fence_value(fence) >= value
}

gpu_fence_wait :: proc(fence: GpuFence, value: i64) {
    _gpu_fence_wait(fence, value)
}

gpu_queue_wait :: proc(queue: GpuQueue) {
    _gpu_queue_wait(queue)
}

gpu_create_sampler :: proc(desc: GpuSamplerDesc) -> GpuSampler {
    return _gpu_create_sampler(desc)
}

gpu_destroy_sampler :: proc(sampler: GpuSampler) {
    _gpu_destroy_sampler(sampler)
}

gpu_sampler_index :: proc(sampler: GpuSampler) -> i32 {
    return _gpu_sampler_index(sampler)
}

gpu_view_index_default :: proc(view: GpuView) -> i32 {
    return _gpu_view_index(view)
}

gpu_view_index_temp :: proc(view: GpuTempView) -> i32 {
    return view.idx
}

gpu_view_index :: proc{ gpu_view_index_default, gpu_view_index_temp }

gpu_texture_barrier_one :: proc(cmd: GpuCommandList, barrier: GpuTextureBarrier) {
    barriers := [1]GpuTextureBarrier{ barrier }
    gpu_barrier(cmd, barriers[:], nil)
}

gpu_texture_barrier_multiple :: proc(cmd: GpuCommandList, barriers: []GpuTextureBarrier) {
    gpu_barrier(cmd, barriers, nil)
}

gpu_buffer_barrier_one :: proc(cmd: GpuCommandList, barrier: GpuBufferBarrier) {
    barriers := [1]GpuBufferBarrier{ barrier }
    gpu_barrier(cmd, nil, barriers[:])
}

gpu_buffer_barrier_multiple :: proc(cmd: GpuCommandList, barriers: []GpuBufferBarrier) {
    gpu_barrier(cmd, nil, barriers)
}

gpu_barrier_default :: proc(cmd: GpuCommandList, textures: []GpuTextureBarrier, buffers: []GpuBufferBarrier) {
    _gpu_barrier(cmd, textures, buffers)
}

gpu_barrier :: proc { gpu_barrier_default, gpu_texture_barrier_one, gpu_texture_barrier_multiple, gpu_buffer_barrier_one, gpu_buffer_barrier_multiple }

package vg

GpuBuffer         :: distinct rawptr
GpuTexture        :: distinct rawptr
GpuView           :: distinct rawptr
GpuSwapchain      :: distinct rawptr
GpuCommandList    :: distinct rawptr
GpuPipelineLayout :: distinct rawptr
GpuPipeline       :: distinct rawptr

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
    D32_Float,
    D24_Unorm_S8_Uint,
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
    size:   int,
    usage:  GpuBufferUsage,
    memory: GpuMemory,
}

GpuTextureDesc :: struct {
    width:         int,
    height:        int,
    depth:         int,
    mips:          int,
    array_size:    int,
    format:        GpuFormat,
    usage:         GpuTextureUsage,
    initial_usage: GpuTextureUsage,
}

GpuBufferViewDesc :: struct {
    kind:   GpuViewKind,
    first:  int,
    count:  int,
    stride: int,
}

GpuTextureViewDesc :: struct {
    kind:        GpuViewKind,
    format:      GpuFormat,
    first_mip:   int,
    mip_count:   int,
    first_slice: int,
    slice_count: int,
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
    constant_count: int,
}

GpuPipelineDesc :: struct {
    layout:        GpuPipelineLayout,
    vertex_shader: []byte,
    pixel_shader:  []byte,
    color_formats: []GpuFormat,
    depth_format:  GpuFormat,
    raster:        GpuRasterState,
    depth:         GpuDepthState,
    blend:         GpuBlendState,
}

GpuSubresource :: struct {
    first_mip:   int,
    mip_count:   int,
    first_slice: int,
    slice_count: int,
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

gpu_swapchain_resize :: proc(swapchain: GpuSwapchain, width: int, height: int) {
    _gpu_swapchain_resize(swapchain, width, height)
}

gpu_swapchain_acquire :: proc(swapchain: GpuSwapchain) -> bool {
    return _gpu_swapchain_acquire(swapchain)
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

gpu_swapchain_size :: proc(swapchain: GpuSwapchain) -> (width: int, height: int) {
    return _gpu_swapchain_size(swapchain)
}

gpu_command_list_begin :: proc(queue: GpuQueue) -> GpuCommandList {
    return _gpu_command_list_begin(queue)
}

gpu_command_list_end :: proc(cmd: GpuCommandList) {
    _gpu_command_list_end(cmd)
}

gpu_submit :: proc(cmds: []GpuCommandList) {
    _gpu_submit(cmds)
}

gpu_set_render_targets :: proc(cmd: GpuCommandList, colors: []GpuView, depth: GpuView = nil) {
    _gpu_set_render_targets(cmd, colors, depth)
}

gpu_clear_render_target :: proc(cmd: GpuCommandList, view: GpuView, color: [4]f32) {
    _gpu_clear_render_target(cmd, view, color)
}

gpu_set_viewport :: proc(cmd: GpuCommandList, x: int, y: int, width: int, height: int) {
    _gpu_set_viewport(cmd, x, y, width, height)
}

gpu_set_scissor :: proc(cmd: GpuCommandList, x: int, y: int, width: int, height: int) {
    _gpu_set_scissor(cmd, x, y, width, height)
}

gpu_set_constants :: proc(cmd: GpuCommandList, values: []u32) {
    _gpu_set_constants(cmd, values)
}

gpu_draw :: proc(cmd: GpuCommandList, vertex_count: int, instance_count: int = 1) {
    _gpu_draw(cmd, vertex_count, instance_count)
}

gpu_copy_buffer :: proc(cmd: GpuCommandList, dst: GpuBuffer, dst_offset: int, src: GpuBuffer, src_offset: int, size: int) {
    _gpu_copy_buffer(cmd, dst, dst_offset, src, src_offset, size)
}

gpu_texture_upload_size :: proc(texture: GpuTexture, mip: int, slice: int) -> int {
    return _gpu_texture_upload_size(texture, mip, slice)
}

gpu_set_texture_data :: proc(cmd: GpuCommandList, texture: GpuTexture, mip: int, slice: int, data: []byte, staging: GpuBuffer, staging_offset: int) {
    _gpu_set_texture_data(cmd, texture, mip, slice, data, staging, staging_offset)
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

gpu_create_buffer_view :: proc(buffer: GpuBuffer, desc: GpuBufferViewDesc) -> GpuView {
    return _gpu_create_buffer_view(buffer, desc)
}

gpu_create_texture_view :: proc(texture: GpuTexture, desc: GpuTextureViewDesc) -> GpuView {
    return _gpu_create_texture_view(texture, desc)
}

gpu_destroy_view :: proc(view: GpuView) {
    _gpu_destroy_view(view)
}

gpu_view_index :: proc(view: GpuView) -> int {
    return _gpu_view_index(view)
}

gpu_barrier :: proc(cmd: GpuCommandList, textures: []GpuTextureBarrier, buffers: []GpuBufferBarrier) {
    _gpu_barrier(cmd, textures, buffers)
}

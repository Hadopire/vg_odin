#+build windows
package d3d12ma

import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

foreign import lib "../../third_party/d3d12ma/d3d12ma.lib"

Allocator  :: struct {}
Allocation :: struct {}

Statistics :: struct {
    BlockCount:      u32,
    AllocationCount: u32,
    BlockBytes:      u64,
    AllocationBytes: u64,
}

DetailedStatistics :: struct {
    Stats:              Statistics,
    UnusedRangeCount:   u32,
    AllocationSizeMin:  u64,
    AllocationSizeMax:  u64,
    UnusedRangeSizeMin: u64,
    UnusedRangeSizeMax: u64,
}

TotalStatistics :: struct {
    HeapType:           [5]DetailedStatistics,
    MemorySegmentGroup: [2]DetailedStatistics,
    Total:              DetailedStatistics,
}

Budget :: struct {
    Stats:       Statistics,
    UsageBytes:  u64,
    BudgetBytes: u64,
}

@(default_calling_convention = "c", link_prefix = "d3d12ma_")
foreign lib {
    create_allocator :: proc(device: ^d3d12.IDevice, adapter: ^dxgi.IAdapter, out_allocator: ^^Allocator) -> d3d12.HRESULT ---
    release_allocator :: proc(allocator: ^Allocator) ---
    create_resource :: proc(allocator: ^Allocator, heap_type: d3d12.HEAP_TYPE, resource_desc: ^d3d12.RESOURCE_DESC, initial_state: d3d12.RESOURCE_STATES, clear_value: ^d3d12.CLEAR_VALUE, out_allocation: ^^Allocation, out_resource: ^^d3d12.IResource) -> d3d12.HRESULT ---
    create_resource3 :: proc(allocator: ^Allocator, heap_type: d3d12.HEAP_TYPE, resource_desc: ^d3d12.RESOURCE_DESC1, initial_layout: d3d12.BARRIER_LAYOUT, clear_value: ^d3d12.CLEAR_VALUE, out_allocation: ^^Allocation, out_resource: ^^d3d12.IResource) -> d3d12.HRESULT ---
    release_allocation :: proc(allocation: ^Allocation) ---
    get_budget :: proc(allocator: ^Allocator, local: ^Budget, non_local: ^Budget) ---
    calculate_statistics :: proc(allocator: ^Allocator, stats: ^TotalStatistics) ---
}

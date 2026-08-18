#include "D3D12MemAlloc.h"

extern "C" {

HRESULT d3d12ma_create_allocator(ID3D12Device *device, IDXGIAdapter *adapter, D3D12MA::Allocator **out_allocator) {
    D3D12MA::ALLOCATOR_DESC desc = {};
    desc.pDevice = device;
    desc.pAdapter = adapter;
    return D3D12MA::CreateAllocator(&desc, out_allocator);
}

void d3d12ma_release_allocator(D3D12MA::Allocator *allocator) {
    allocator->Release();
}

HRESULT d3d12ma_create_resource(D3D12MA::Allocator *allocator, D3D12_HEAP_TYPE heap_type, const D3D12_RESOURCE_DESC *resource_desc, D3D12_RESOURCE_STATES initial_state, const D3D12_CLEAR_VALUE *clear_value, D3D12MA::Allocation **out_allocation, ID3D12Resource **out_resource) {
    D3D12MA::ALLOCATION_DESC alloc_desc = {};
    alloc_desc.HeapType = heap_type;
    return allocator->CreateResource(&alloc_desc, resource_desc, initial_state, clear_value, out_allocation, IID_PPV_ARGS(out_resource));
}

HRESULT d3d12ma_create_resource3(D3D12MA::Allocator *allocator, D3D12_HEAP_TYPE heap_type, const D3D12_RESOURCE_DESC1 *resource_desc, D3D12_BARRIER_LAYOUT initial_layout, const D3D12_CLEAR_VALUE *clear_value, D3D12MA::Allocation **out_allocation, ID3D12Resource **out_resource) {
    D3D12MA::ALLOCATION_DESC alloc_desc = {};
    alloc_desc.HeapType = heap_type;
    return allocator->CreateResource3(&alloc_desc, resource_desc, initial_layout, clear_value, 0, NULL, out_allocation, IID_PPV_ARGS(out_resource));
}

void d3d12ma_release_allocation(D3D12MA::Allocation *allocation) {
    allocation->Release();
}

void d3d12ma_get_budget(D3D12MA::Allocator *allocator, D3D12MA::Budget *local, D3D12MA::Budget *non_local) {
    allocator->GetBudget(local, non_local);
}

void d3d12ma_calculate_statistics(D3D12MA::Allocator *allocator, D3D12MA::TotalStatistics *stats) {
    allocator->CalculateStatistics(stats);
}

}

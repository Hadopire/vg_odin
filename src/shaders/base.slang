module base;

public struct Ptr<T> {
    uint heap_idx;
    uint offset;

    static const int alignment = (sizeof(T, DefaultDataLayout) % 16 == 0) ? 16 : ((sizeof(T, DefaultDataLayout) % 8 == 0) ? 8 : 4);

    T load() {
        ByteAddressBuffer buffer = ResourceDescriptorHeap[heap_idx];
        return buffer.LoadAligned<T>(offset, 16);
    }

    __subscript(uint index) -> T {
        get {
            ByteAddressBuffer buffer = ResourceDescriptorHeap[heap_idx];
            return buffer.LoadAligned<T>(offset + index * sizeof(T, DefaultDataLayout), alignment);
        }
    }
}

public struct Array<T> {
    Ptr<T> ptr;
    uint   count;

    __subscript(uint index) -> T {
        get { return ptr[index]; }
    }
}

public struct Texture2 {
    uint texture_idx;
    uint sampler_idx;

    float4 sample(float2 uv) {
        Texture2D<float4> texture = ResourceDescriptorHeap[texture_idx];
        SamplerState sampler = SamplerDescriptorHeap[sampler_idx];
        return texture.Sample(sampler, uv);
    }

    float3 sample_normal(float2 uv) {
        float4 color = sample(uv);
        return normalize(color.rgb * 2.0 - 1.0);
    }
}

public struct Texture2Array {
    uint texture_idx;
    uint sampler_idx;

    float4 sample(float2 uv, int slice) {
        Texture2DArray<float4> texture = ResourceDescriptorHeap[texture_idx];
        SamplerState sampler = SamplerDescriptorHeap[sampler_idx];
        return texture.Sample(sampler, float3(uv, slice));
    }
}

public struct Vertex8 {
    float4 pos_u;
    float4 normal_v;

    float3 position() {
        return pos_u.xyz;
    }

    float3 normal() {
        return normal_v.xyz;
    }

    float2 uv() {
        return float2(pos_u.w, normal_v.w);
    }
};

public struct Camera {
    float4x4 view_projection;
};

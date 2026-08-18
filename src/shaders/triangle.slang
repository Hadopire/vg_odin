struct Vertex {
    float2 pos;
    float3 color;
};

struct PushConstants {
    uint vertex_buffer;
    uint texture;
};

ConstantBuffer<PushConstants> push;

struct VsOutput {
    float4 pos   : SV_Position;
    float3 color : COLOR;
};

[shader("vertex")]
VsOutput vs_main(uint vertex_id : SV_VertexID) {
    StructuredBuffer<Vertex> vertices = ResourceDescriptorHeap[push.vertex_buffer];
    Vertex vertex = vertices[vertex_id];

    VsOutput output;
    output.pos = float4(vertex.pos, 0.0, 1.0);
    output.color = vertex.color;
    return output;
}

[shader("fragment")]
float4 fs_main(VsOutput input) : SV_Target {
    Texture2D<float4> checker = ResourceDescriptorHeap[push.texture];
    int2 coord = int2(input.pos.xy) & 63;
    return checker.Load(int3(coord, 0)) * float4(input.color, 1.0);
}

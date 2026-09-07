struct Vertex {
    float3 position;
    float3 normal;
    float2 uv;
};

struct Camera {
    float4x4 view_projection;
};

struct Transform {
    float4x4 model;
    float4   color;
};

struct PushConstants {
    StructuredBuffer<Vertex>.Handle    vertices;
    StructuredBuffer<Camera>.Handle    camera;
    StructuredBuffer<Transform>.Handle transforms;
    Texture2D<float4>.Handle           albedo;
    SamplerState.Handle                sampler;
    uint                               transform_index;
};

ConstantBuffer<PushConstants> push;

struct VsOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
};

[shader("vertex")]
VsOutput vs_main(uint vertex_id : SV_VertexID) {
    Vertex vertex = push.vertices[vertex_id];
    Transform transform = push.transforms[push.transform_index];
    float4 world = mul(transform.model, float4(vertex.position, 1.0));

    VsOutput output;
    output.position = mul(push.camera[0].view_projection, world);
    output.uv = vertex.uv;
    output.color = transform.color;
    return output;
}

[shader("fragment")]
float4 fs_main(VsOutput input) : SV_Target {
    return push.albedo.Sample(push.sampler, input.uv) * input.color;
}

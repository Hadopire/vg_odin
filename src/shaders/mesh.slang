#include "macros.slang"

import base;

struct Transform {
    float4x4 model;
    float4   color;
};

struct PushConstants {
    PUSH_PTR(Vertex8, vertices)
    PUSH_PTR(Camera, camera)
    PUSH_PTR(Transform, transform)
    PUSH_TEXTURE(albedo)
};

ConstantBuffer<PushConstants> push;

struct VsOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
};

[shader("vertex")]
VsOutput vs_main(uint vertex_id : SV_VertexID) {
    Vertex8   vertex = push.vertices[vertex_id];
    Transform transform = push.transform.load();
    float4    world = mul(transform.model, float4(vertex.position(), 1.0));
    float4x4  vp = push.camera.load().view_projection;

    VsOutput output;
    output.position = mul(vp, world);
    output.uv = vertex.uv();
    output.color = transform.color;
    return output;
}

[shader("fragment")]
float4 fs_main(VsOutput input) : SV_Target {
    return push.albedo.sample(input.uv) * input.color;
}

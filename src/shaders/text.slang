#include "macros.slang"

import base;

struct TextQuad {
    float2 pos;
    float2 size;
    float2 uv_min;
    float2 uv_max;
    float4 color;
    int    page;
    int3   padding;
};

struct TextConstants {
    float2 screen_size;
};

struct PushConstants {
    PUSH_PTR(TextQuad, quads)
    PUSH_PTR(TextConstants, constants)
    PUSH_TEXTURE_ARRAY(atlas)
};

ConstantBuffer<PushConstants> push;

struct VsOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
    nointerpolation int page : PAGE;
};

static const float2 quad_corners[6] = {
    float2(0, 0), float2(1, 0), float2(1, 1),
    float2(0, 0), float2(1, 1), float2(0, 1),
};

[shader("vertex")]
VsOutput vs_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    TextQuad quad = push.quads[instance_id];
    float2   corner = quad_corners[vertex_id];
    float2   pixel = quad.pos + quad.size * corner;
    float2   screen = push.constants.load().screen_size;

    VsOutput output;
    output.position = float4(pixel.x / screen.x * 2.0 - 1.0, 1.0 - pixel.y / screen.y * 2.0, 0.0, 1.0);
    output.uv = lerp(quad.uv_min, quad.uv_max, corner);
    output.color = quad.color;
    output.page = quad.page;
    return output;
}

[shader("fragment")]
float4 fs_main(VsOutput input) : SV_Target {
    float coverage = push.atlas.sample(input.uv, input.page).r;
    return float4(input.color.rgb, input.color.a * coverage);
}

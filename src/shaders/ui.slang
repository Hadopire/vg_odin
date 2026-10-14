#include "macros.slang"

import base;

struct Rect {
    float4 dst;
    float4 uv;
    float4 clip;
    uint   colors[4];
    float  corner_radius;
    float  edge_softness;
    float  border_thickness;
    uint   texture;
};

struct UiConstants {
    float2 screen_size;
};

struct PushConstants {
    PUSH_PTR(Rect, rects)
    PUSH_PTR(UiConstants, constants)
    uint sampler;
};

struct VsOutput {
    float4                 pos              : SV_Position;
    float2                 uv               : TEXCOORD0;
    float4                 color            : COLOR0;
    float2                 rect_pos         : RECT_POS;
    nointerpolation float2 half_size        : HALF_SIZE;
    nointerpolation float  corner_radius    : CORNER_RADIUS;
    nointerpolation float  antialias        : ANTIALIAS;
    nointerpolation float  border_thickness : BORDER_THICKNESS;
    nointerpolation uint   texture          : TEXTURE;
};

static const float2 quad_corners[4] = {
    float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1),
};

float rounded_rect_sdf(float2 p, float2 b, float r) {
    float2 d = abs(p) - b + r;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

ConstantBuffer<PushConstants> push;

[shader("vertex")]
VsOutput vs_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    Rect   rect = push.rects[instance_id];
    float2 clipped_min = max(rect.dst.xy, rect.clip.xy);
    float2 clipped_max = max(min(rect.dst.zw, rect.clip.zw), clipped_min);
    float2 pos = lerp(clipped_min, clipped_max, quad_corners[vertex_id]);
    float2 screen = push.constants.load().screen_size;
    float2 half_size = (rect.dst.zw - rect.dst.xy) * 0.5 - rect.edge_softness;

    float2 t = (pos - rect.dst.xy) / (rect.dst.zw - rect.dst.xy);
    float4 top_left     = unpackUnorm4x8ToFloat(rect.colors[0]);
    float4 bottom_left  = unpackUnorm4x8ToFloat(rect.colors[1]);
    float4 top_right    = unpackUnorm4x8ToFloat(rect.colors[2]);
    float4 bottom_right = unpackUnorm4x8ToFloat(rect.colors[3]);

    VsOutput output;
    output.pos = float4(pos.x / screen.x * 2.0 - 1.0, 1.0 - pos.y / screen.y * 2.0, 0.0, 1.0);
    output.uv = lerp(rect.uv.xy, rect.uv.zw, t);
    output.color = lerp(lerp(top_left, bottom_left, t.y), lerp(top_right, bottom_right, t.y), t.x);
    output.rect_pos = pos - (rect.dst.xy + rect.dst.zw) * 0.5;
    output.half_size = half_size;
    output.corner_radius = min(rect.corner_radius, min(half_size.x, half_size.y));
    output.antialias = max(rect.edge_softness, 0.5);
    output.border_thickness = rect.border_thickness;
    output.texture = rect.texture;
    return output;
}

[shader("fragment")]
float4 fs_main(VsOutput input) : SV_Target {
    float coverage = 1.0 - smoothstep(-input.antialias, input.antialias, rounded_rect_sdf(input.rect_pos, input.half_size, input.corner_radius));

    if (input.border_thickness > 0.0) {
        float2 inner_half_size = input.half_size - input.border_thickness;
        float  inner_radius = max(input.corner_radius - input.border_thickness, 0.0);
        coverage *= smoothstep(-input.antialias, input.antialias, rounded_rect_sdf(input.rect_pos, inner_half_size, inner_radius));
    }

    if (input.texture != 0) {
        coverage *= Texture2(input.texture, push.sampler).sample_non_uniform(input.uv).r;
    }

    return float4(input.color.rgb, input.color.a * coverage);
}

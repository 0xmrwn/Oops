// A port of the dot scope shader of Hex (anomalyco/hex, ios/HEXShared/DotScopeShader.metal at v3.4.0; MIT,
// Copyright (c) 2026 Christopher Langton). The original's home-indicator swipe cue is not ported.
// See THIRD_PARTY_NOTICES.md.

#include <metal_stdlib>
using namespace metal;

// Port of `src/rune_hud.wgsl` + OpenCode iOS bar-windowing (`DotScopeShaders.metal`).
// Positions are in points from the view's center (x right, y down);
// colors are premultiplied display-sRGB written into a `.bgra8Unorm` layer.

struct DotScopeVaryings {
    float4 position [[position]];
    float2 uv;
};

struct DotScopeUniforms {
    float4 metrics0; // x: res.x, y: res.y, z: backingScale, w: pitch
    float4 metrics1; // x: width, y: height, z: opacity, w: scale
    float4 metrics2; // x: softness, y: columns, z: rows, w: radius
    float4 state;    // x: glow, y: grid, z: live, w: isDark (1 = dark, 0 = light)
    float4 window;   // x: leadingInset, y: trailingInset, z: windowFade, w: curve (1 = capsule curve)
    float4 base;     // rgb: base color, w: drawPlate (1 = pill+rim+shadow, 0 = embedded)
    float4 core;     // rgb: core color, w: cool
    float4 plate;    // rgba
    float4 rim;      // rgba
    float4 shadow;   // rgba
};

static_assert(sizeof(DotScopeUniforms) == 160, "DotScopeUniforms must match Swift layout");

struct DotScopePackedDot {
    ushort power;
    ushort fresh;
};


static inline float ds_sstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float3 ds_saturate3(float3 c, float k) {
    float l = dot(c, float3(0.299f, 0.587f, 0.114f));
    return clamp(float3(l) + (c - float3(l)) * k, 0.0f, 1.0f);
}

static inline float ds_rounded_box(float2 point, float2 half_size, float radius) {
    float2 q = abs(point) - half_size + radius;
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - radius;
}

static inline float ds_coverage(float distance, float softness) {
    return ds_sstep(softness, -softness, distance);
}

// Capsule-curved window matching OpenCode iOS `scopeWindow`:
// each row's fade starts `rim_inset` inward from the rounded end cap so dots
// follow the capsule curvature and dissolve softly into leading/trailing controls.
static inline float ds_scope_window(float2 point, float2 half_size, float radius, float4 window) {
    float fade = window.z;
    if (fade <= 0.01f) {
        return 1.0f;
    }
    float width = half_size.x * 2.0f;
    float x_from_left = point.x + half_size.x;
    float x_from_right = width - x_from_left;
    float dy = max(abs(point.y) - (half_size.y - radius), 0.0f);
    float rim_inset = radius - sqrt(max(radius * radius - dy * dy, 0.0f));
    float curve = window.w;

    float lead = window.x + curve * rim_inset;
    float trail = window.y + curve * rim_inset;

    float s_l = ds_sstep(lead, lead + fade, x_from_left);
    float s_r = ds_sstep(trail, trail + fade, x_from_right);
    float win_l = window.x > 0.5f ? s_l : mix(1.0f, s_l, curve * 0.72f);
    float win_r = window.y > 0.5f ? s_r : mix(1.0f, s_r, curve * 0.72f);
    return min(win_l, win_r);
}

static inline float ds_glow_lobe(float2 p_bar, float width, float half_h, float g, bool left) {
    constexpr float glow_centre = 28.0f;
    constexpr float reach_in = 34.0f;
    constexpr float reach_loud = 36.0f;
    constexpr float reach_out = 26.0f;
    constexpr float glow_height = 0.44f;

    float x = left ? p_bar.x : (width - p_bar.x);
    float dx = x - glow_centre;
    float sx = dx > 0.0f ? (reach_in + reach_loud * g) : reach_out;
    float yn = (p_bar.y - half_h) / max(half_h, 1.0f);
    float sy = glow_height * (0.85f + 0.15f * g);
    return g * exp(-(dx * dx) / (2.0f * sx * sx)) * exp(-(yn * yn) / (2.0f * sy * sy));
}

static inline void ds_composite(thread float4 &destination, float3 color, float alpha_in) {
    float alpha = clamp(alpha_in, 0.0f, 1.0f);
    destination = float4(
        color * alpha + destination.rgb * (1.0f - alpha),
        alpha + destination.a * (1.0f - alpha)
    );
}

static inline float4 ds_dithered(float4 result_in, float2 position) {
    float4 result = result_in;
    if (result.a > 0.0f) {
        float2 pixel = floor(position);
        float n1 = fract(52.9829189f * fract(dot(pixel, float2(0.06711056f, 0.00583715f))));
        float n2 = fract(
            52.9829189f * fract(dot(pixel + float2(17.0f, 31.0f), float2(0.06711056f, 0.00583715f)))
        );
        float dither = ((n1 - n2) / 255.0f) * result.a;
        result = float4(clamp(result.rgb + float3(dither), float3(0.0f), float3(result.a)), result.a);
    }
    return result;
}

vertex DotScopeVaryings dot_scope_vertex(uint vertex_id [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    float2 p = positions[vertex_id];
    DotScopeVaryings out;
    out.position = float4(p, 0.0f, 1.0f);
    out.uv = float2(p.x * 0.5f + 0.5f, 0.5f - p.y * 0.5f);
    return out;
}

fragment float4 dot_scope_fragment(
    DotScopeVaryings in [[stage_in]],
    constant DotScopeUniforms &u [[buffer(0)]],
    constant DotScopePackedDot *dots [[buffer(1)]]
) {
    float2 resolution = u.metrics0.xy;
    float backing_scale = max(u.metrics0.z, 1.0f);
    float pitch = u.metrics0.w;
    float width = u.metrics1.x;
    float height = u.metrics1.y;
    float opacity = u.metrics1.z;
    float scale = max(u.metrics1.w, 0.001f);
    float softness = max(u.metrics2.x, 0.0f);
    int columns = int(u.metrics2.y + 0.5f);
    int rows = int(u.metrics2.z + 0.5f);
    float radius = clamp(u.metrics2.w, 0.0f, height * 0.5f);

    float glow = u.state.x;
    float grid = u.state.y;
    float live = u.state.z;
    bool is_dark = u.state.w > 0.5f;
    bool draw_plate = u.base.w > 0.5f;
    float cool = u.core.w;

    float2 position = in.uv * resolution;
    float2 window_point = (position - resolution * 0.5f) / backing_scale;
    float2 point = window_point / scale;
    float pixel = 1.0f / (backing_scale * scale);
    float aa = pixel * 0.75f + softness * 0.72f;
    float2 half_size = float2(width, height) * 0.5f;
    float distance = ds_rounded_box(point, half_size, radius);

    float4 result = float4(0.0f);

    if (draw_plate && u.shadow.a > 0.001f) {
        float shadow_distance = ds_rounded_box(point - float2(0.0f, 3.0f), half_size, radius);
        ds_composite(result, u.shadow.rgb, u.shadow.a * (0.5f - 0.5f * tanh(shadow_distance / 6.5f)));
    }

    float shape = ds_coverage(distance, aa);

    if (draw_plate) {
        ds_composite(result, u.plate.rgb, u.plate.a * shape);
        if (u.rim.a > 0.001f) {
            ds_composite(result, u.rim.rgb, u.rim.a * ds_coverage(abs(distance) - 0.3f, aa));
        }
    }

    float point_win = ds_scope_window(point, half_size, radius, u.window);

    // Soft button-anchored glow lobes matching OpenCode iOS `glowAt`.
    float rest_glow = 0.045f * max(live, cool * 0.6f);
    float lobe_g = min(1.0f, glow * 0.85f + rest_glow);
    if (lobe_g > 0.005f) {
        float2 p_bar = point + half_size;
        float peak = (is_dark ? 0.30f : 0.18f) * 0.55f;
        float a_l = min(1.0f, ds_glow_lobe(p_bar, width, half_size.y, lobe_g, true)) * peak;
        float a_r = min(1.0f, ds_glow_lobe(p_bar, width, half_size.y, lobe_g * 0.92f, false)) * peak;
        float combined = (1.0f - (1.0f - a_l) * (1.0f - a_r)) * point_win * shape;
        if (combined > 0.001f) {
            float3 mid = mix(u.base.rgb, u.core.rgb, 0.5f);
            float3 glow_col = is_dark
                ? ds_saturate3(mid, 1.5f)
                : mix(ds_saturate3(u.base.rgb, 1.8f), float3(1.0f), 0.12f);
            ds_composite(result, glow_col, combined);
        }
    }

    float2 center_offset = float2(float(columns) - 1.0f, float(rows) - 1.0f) * 0.5f;
    int i0 = int(rint(point.x / pitch + center_offset.x));
    int j0 = int(rint(point.y / pitch + center_offset.y));
    float unlit = is_dark ? 0.055f : 0.10f;
    float full = is_dark ? 0.85f : 0.88f;
    float curve_exp = is_dark ? 0.90f : 0.76f;
    float presence = 0.5f + 0.5f * max(live, cool);
    float px_scale = backing_scale * scale;

    for (int dj = -1; dj <= 1; dj++) {
        for (int di = -1; di <= 1; di++) {
            int i = i0 + di;
            int j = j0 + dj;
            if (i < 0 || j < 0 || i >= columns || j >= rows) {
                continue;
            }
            float2 center = (float2(float(i), float(j)) - center_offset) * pitch;
            float cap = -ds_rounded_box(center, half_size, radius);
            float mask = ds_sstep(2.0f, 6.2f, cap);
            if (mask <= 0.0f) {
                continue;
            }
            float win = ds_scope_window(center, half_size, radius, u.window);
            if (win <= 0.001f) {
                continue;
            }
            float blur = 1.0f - win;
            DotScopePackedDot packed = dots[j * columns + i];
            float power = max(float(packed.power) / 65535.0f, 1e-5f);
            float fresh = float(packed.fresh) / 65535.0f;
            float row = abs(center.y) / max(half_size.y, 1.0f);
            float floor_alpha = unlit * (1.0f - 0.7f * ds_sstep(0.35f, 0.95f, row)) * presence * grid;
            float alpha = floor_alpha + (full - floor_alpha) * pow(power, curve_exp * mix(1.4f, 1.0f, fresh));
            float dot_radius = (0.25f + 0.17f * pow(power, 0.6f))
                * mix(1.0f, mix(0.82f, 1.0f, fresh), ds_sstep(0.03f, 0.2f, power))
                * pitch
                * (1.0f + 0.35f * blur);

            float dist_px = length(point - center) * px_scale;
            float rad_px = dot_radius * px_scale;
            float soft_px = 1.0f + 2.6f * blur * backing_scale + softness * 0.72f * px_scale;
            float cov = clamp((rad_px - dist_px) / soft_px + 0.5f, 0.0f, 1.0f);
            float halo = 0.20f * power * power
                * exp(-max(dist_px - rad_px, 0.0f) / ((0.12f + 0.20f * blur) * pitch * px_scale))
                * (1.0f - cov);

            float dot_alpha = (alpha * cov + halo) * mask * win * shape;
            float core_mix = clamp(power * power * 1.1f, 0.0f, 0.9f) * mix(0.3f, 1.0f, fresh);
            float3 color = mix(u.base.rgb, u.core.rgb, core_mix);
            ds_composite(result, color, dot_alpha);
        }
    }

    result *= opacity;
    return ds_dithered(result, position);
}

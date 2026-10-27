#include <metal_stdlib>
using namespace metal;

namespace
{
    constant float kLineWidth = 0.6;
    constant float kGlow = 1.0;
    constant float kUndulation = 1.0;
    constant float kPetal = 1.0;
    constant float kGlass = 1.0;

    // HDR: extra brightness (in multiples of SDR white) added to the line cores, capped by the display headroom.
    constant float kMaxHdrBoost = 3.0;
    constant float kHdrIdle = 0.15;
    constant float kHdrActive = 0.5;
    constant float kHdrFlash = 0.8;

    constant float3 kPalette[5] = {
        float3(1.0, 0.25, 0.6),
        float3(0.55, 0.3, 1.0),
        float3(0.2, 0.5, 1.0),
        float3(0.2, 0.95, 0.95),
        float3(1.0, 0.55, 0.3),
    };

    /// Smoothstep that is well defined when edge0 > edge1.
    float ramp(float edge0, float edge1, float x)
    {
        float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    /// sRGB transfer function decode, so the SDR look matches the original design exactly.
    float3 srgbToLinear(float3 c)
    {
        c = max(c, 0.0);
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    /// GLSL-style modulo (result has the sign of y).
    float wrap(float x, float y)
    {
        return x - y * floor(x / y);
    }

    /// Sine with a fractional lobe count, blended between the neighbouring integers so the curve stays closed.
    float lobes(float theta, float k, float phase)
    {
        float k0 = floor(k);
        return mix(sin(k0 * theta + phase), sin((k0 + 1.0) * theta + phase), k - k0);
    }

    /// Underwater light caustics.
    float caustic(float2 uv, float t)
    {
        float2 p = float2(wrap(uv.x * 6.2831, 6.2831), wrap(uv.y * 6.2831, 6.2831)) - 250.0;
        float2 i = p;
        float c = 1.0;
        const float intensity = 0.005;
        for (int n = 0; n < 4; n++)
        {
            float tt = t * (1.0 - 3.5 / float(n + 1));
            i = p + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
            c += 1.0 / length(float2(p.x / (sin(i.x + tt) / intensity), p.y / (cos(i.y + tt) / intensity)));
        }
        c /= 4.0;
        c = 1.17 - pow(c, 1.4);
        return pow(abs(c), 8.0);
    }
}

/// Must match `OrbUniforms` in RingOrbView.swift.
struct OrbUniforms
{
    float2 size;          // points
    float scale;          // pixels per point
    float centerY;        // fraction of height from the top
    float time;
    float frequency;
    float amplitude;
    float flow;           // integrated ring motion phase (driven by frequency)
    float causticPhase;   // integrated caustic animation phase
    float converge;       // 0...1, rings collapse into one at the end of a run
    float flash;          // 0...1, soft white bloom at the end of a run
    float headroom;       // current EDR headroom, 1 on SDR displays
};

struct OrbVertexOut
{
    float4 position [[position]];
};

/// Full-screen triangle.
vertex OrbVertexOut ringOrbVertex(uint vertexID [[vertex_id]])
{
    const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    OrbVertexOut out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    return out;
}

/// Five colored wavy rings over a glass lens, output in extended linear sRGB.
fragment half4 ringOrbFragment(OrbVertexOut in [[stage_in]], constant OrbUniforms& u [[buffer(0)]])
{
    float2 position = in.position.xy / u.scale;
    float2 size = u.size;
    float centerY = u.centerY;
    float time = u.time;
    float frequency = u.frequency;
    float amplitude = u.amplitude;
    float flow = u.flow;
    float causticPhase = u.causticPhase;
    float converge = u.converge;
    float flash = u.flash;

    float s = min(size.x, size.y);
    float2 p = (position - float2(0.5 * size.x, centerY * size.y)) / s * 2.0;
    p.y = -p.y;
    float r = length(p);
    float w = 2.0 / s;

    float t = clamp(log(frequency / 60.0) / log(500.0 / 60.0), 0.0, 1.0);
    float lobeCount = 2.0 + t * 6.0;
    float active = max(amplitude, 0.0);
    float spread = active * (1.0 - converge);
    float baseRadius = 0.6 + 0.018 * sin(time * 1.25) + 0.03 * amplitude * kUndulation - 0.02 * converge;
    float petalOffset = kPetal * (0.008 + 0.06 * spread) * (1.0 - converge);
    float rotation = flow * 0.3;

    float3 col = float3(0.0);
    float3 coreLight = float3(0.0);
    for (int i = 0; i < 5; i++)
    {
        float fi = float(i);
        float angle = rotation + fi * 1.2566;
        float2 q = p - petalOffset * float2(cos(angle), sin(angle));
        float rq = length(q);
        float theta = atan2(q.y, q.x);

        float waveAmp = (0.006 * (1.0 - converge) + 0.12 * spread * kUndulation) * (0.7 + 0.3 * sin(time * (0.8 + fi * 0.13) + fi * 1.7));
        float phase = flow * (1.0 + fi * 0.17) * (i % 2 == 0 ? 1.0 : -1.0) + fi * 1.3;
        float dev = 0.65 * lobes(theta, lobeCount + fi * 0.5, phase) + 0.35 * lobes(theta, lobeCount * 1.6 + fi, -phase * 1.4);
        float ringRadius = baseRadius + waveAmp * dev;
        float d = abs(rq - ringRadius);
        // Constant width keeps the line crisp; wave crests carry energy as brightness instead.
        float lineWidth = w * kLineWidth;

        float3 tint = mix(kPalette[i], kPalette[(i + 1) % 5], 0.5 + 0.5 * sin(theta + time * 0.4 + fi));
        tint = mix(tint, float3(0.85, 0.93, 1.0), flash * 0.6);
        float core = exp(-d * d / (lineWidth * lineWidth)) * 0.85 * (1.0 + 0.9 * abs(dev) * spread);
        coreLight += tint * core;
        col += tint * (core + exp(-d / (0.035 * kGlow)) * (0.18 + 0.35 * amplitude + 0.4 * flash) * 0.6);
        col += tint * ramp(ringRadius, ringRadius - 0.5, rq) * 0.035 * (0.4 + amplitude + flash);
    }

    // Glass lens inside the rings, refracting the caustics behind it.
    float inside = ramp(baseRadius + w, baseRadius - w, r);
    // Offset vanishes at the center so the refraction has no seam there.
    float2 lens = p * (baseRadius - r) * 0.8 * inside;

    float2 uv = float2(position.x, size.y - position.y) / size.y * 0.95 + 0.02 + lens;
    float light = caustic(uv, causticPhase);
    float2 tintCoord = clamp(p / baseRadius, -1.0, 1.0);
    float3 glassTint = mix(mix(kPalette[2], kPalette[3], 0.5 + 0.5 * tintCoord.x), kPalette[1], 0.5 - 0.5 * tintCoord.y);
    col += glassTint * light * inside * kGlass * (0.08 + 0.22 * active + 0.25 * flash);
    col += float3(0.55, 0.75, 1.0) * inside * exp((r - baseRadius) / 0.07) * (0.07 * kGlass + 0.15 * flash);

    col = 1.0 - exp(-col * 1.3);
    col += float3(0.02, 0.023, 0.035);

    // SDR look stays as designed; only the line cores reach above white when the display allows it.
    float3 linearColor = srgbToLinear(col);
    float boost = clamp(u.headroom - 1.0, 0.0, kMaxHdrBoost) * (kHdrIdle + kHdrActive * spread + kHdrFlash * flash);
    linearColor += coreLight * boost;
    return half4(half3(min(linearColor, max(u.headroom, 1.0))), 1.0h);
}

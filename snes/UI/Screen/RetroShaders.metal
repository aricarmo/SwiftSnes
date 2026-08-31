//  RetroShaders.metal
//  Filtros retro de exibição (scanlines, máscara de fósforo, curvatura).
//  Só pós-processamento: o frame já chega pronto do PPU, aqui ele vira
//  "tela de tubo".

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct DisplayUniforms {
    float2 viewportSize;
    float2 textureSize;
    float2 contentOrigin;
    float2 contentSize;
    uint filterMode;
    uint integerScalingEnabled;
    float scanlineStrength;
    float maskStrength;
    float bloomStrength;
    float curvature;
    float vignetteStrength;
    float sharpness;
    float brightness;
    float contrast;
    float saturation;
    float userSharpness;
    float glowAmount;
};

constant float2 positions[4] = {
    float2(-1, -1),
    float2( 1, -1),
    float2(-1,  1),
    float2( 1,  1)
};

constant float2 texCoords[4] = {
    float2(0, 1),
    float2(1, 1),
    float2(0, 0),
    float2(1, 0)
};

vertex VertexOut screenVertex(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

inline float gaussian1D(float distance, float sigma) {
    float safeSigma = max(sigma, 0.001);
    return exp(-0.5 * (distance * distance) / (safeSigma * safeSigma));
}

inline float3 applyDisplayGrade(float3 color,
                                float brightness,
                                float contrast,
                                float saturation) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, saturation);
    color = ((color - 0.5) * contrast) + 0.5;
    color *= brightness;
    return max(color, 0.0);
}

inline float3 sampleNearestRGB(texture2d<float> tex,
                               sampler texSampler,
                               float2 textureSize,
                               float2 texelCoord) {
    if (texelCoord.x < 0.5 || texelCoord.y < 0.5 ||
        texelCoord.x > textureSize.x - 0.5 || texelCoord.y > textureSize.y - 0.5) {
        return float3(0.0);
    }
    return tex.sample(texSampler, texelCoord / textureSize).rgb;
}

inline float3 apertureGrilleMask(float screenX,
                                 float strength,
                                 float pitch,
                                 float softness,
                                 float lift) {
    float phase = fract(screenX / max(pitch, 1.0)) * 3.0;
    float3 lobes = float3(
        exp(-softness * pow(phase - 0.35, 2.0)),
        exp(-softness * pow(phase - 1.50, 2.0)),
        exp(-softness * pow(phase - 2.65, 2.0))
    );
    lobes = clamp(lobes + lift, 0.0, 1.0);
    return mix(float3(1.0 - strength), float3(1.0), lobes);
}

inline float trinitronCellShape(float localTexelX,
                                float localTexelY,
                                float centerX,
                                float width,
                                float height,
                                float exponent) {
    float phaseX = fract(localTexelX) * 3.0;
    float phaseY = fract(localTexelY);
    float dx = abs(phaseX - centerX) / max(width, 0.001);
    float dy = abs(phaseY - 0.5) / max(height, 0.001);
    float shape = pow(dx, exponent) + pow(dy, exponent);
    return clamp(1.0 - shape, 0.0, 1.0);
}

inline float3 trinitronCellMask(float localTexelX,
                                float localTexelY,
                                float strength) {
    float3 cells = float3(
        trinitronCellShape(localTexelX, localTexelY, 0.44, 0.34, 0.92, 4.0),
        trinitronCellShape(localTexelX, localTexelY, 1.50, 0.34, 0.92, 4.0),
        trinitronCellShape(localTexelX, localTexelY, 2.56, 0.34, 0.92, 4.0)
    );
    float3 glow = float3(
        trinitronCellShape(localTexelX, localTexelY, 0.44, 0.68, 1.20, 2.0),
        trinitronCellShape(localTexelX, localTexelY, 1.50, 0.68, 1.20, 2.0),
        trinitronCellShape(localTexelX, localTexelY, 2.56, 0.68, 1.20, 2.0)
    );
    cells = clamp(cells + glow * 0.34, 0.0, 1.0);
    return mix(float3(1.0 - strength * 0.52), float3(1.0), cells);
}

inline float trinitronScanlineMask(float localTexelY, float strength) {
    float phase = fract(localTexelY);
    float beam = exp(-16.0 * pow(phase - 0.5, 2.0));
    return mix(1.0 - strength * 0.55, 1.0, beam);
}

inline float3 samplePhosphorBloom(texture2d<float> tex,
                                  sampler texSampler,
                                  float2 sampleUV,
                                  float2 textureSize,
                                  float sigmaX,
                                  float sigmaY,
                                  float beamMix,
                                  float haloThreshold,
                                  float haloScale,
                                  float sparkScale,
                                  float highlightThreshold,
                                  bool wideSupport) {
    float2 texelSpace = sampleUV * textureSize;
    float2 center = floor(texelSpace) + 0.5;
    int minY = wideSupport ? -2 : -1;
    int maxY = wideSupport ? 2 : 1;
    int minX = wideSupport ? -3 : -2;
    int maxX = wideSupport ? 3 : 2;

    float3 accum = float3(0.0);
    float total = 0.0;
    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            float2 sampleCoord = center + float2(float(x), float(y));
            float2 delta = texelSpace - sampleCoord;
            float weight = gaussian1D(delta.x, sigmaX) * gaussian1D(delta.y, sigmaY);
            accum += sampleNearestRGB(tex, texSampler, textureSize, sampleCoord) * weight;
            total += weight;
        }
    }

    float3 direct = sampleNearestRGB(tex, texSampler, textureSize, center);
    float3 beam = accum / max(total, 0.0001);
    float3 lateral = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(-1.0, 0.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(1.0, 0.0))
    ) * 0.5;
    float3 farLateral = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(-2.0, 0.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(2.0, 0.0))
    ) * 0.5;
    float3 vertical = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(0.0, -1.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(0.0, 1.0))
    ) * 0.5;
    float highlight = smoothstep(highlightThreshold, 1.0, max(max(direct.r, direct.g), direct.b));
    float3 halo = max(beam - haloThreshold, 0.0) * haloScale * mix(0.65, 1.35, highlight);
    float3 spark = max(lateral - max(haloThreshold - 0.05, 0.02), 0.0) * sparkScale * mix(0.45, 1.15, highlight);
    float3 spill = float3(0.0);
    if (wideSupport) {
        float3 outerRing = farLateral * 0.72 + vertical * 0.42;
        spill = max(outerRing - max(haloThreshold - 0.08, 0.01), 0.0) * (sparkScale * 1.15) * mix(0.45, 1.30, highlight);
        halo *= 1.14;
    }
    return mix(direct, beam, beamMix) + halo + spark + spill;
}

fragment float4 screenFragment(VertexOut in [[stage_in]],
                               constant DisplayUniforms &uniforms [[buffer(0)]],
                               texture2d<float> tex [[texture(0)]]) {
    constexpr sampler nearestSampler(address::clamp_to_zero, mag_filter::nearest, min_filter::nearest);
    constexpr sampler linearSampler(address::clamp_to_zero, mag_filter::linear, min_filter::linear);

    float2 screenPos = in.position.xy;
    float2 rectMin = uniforms.contentOrigin;
    float2 rectMax = uniforms.contentOrigin + uniforms.contentSize;
    if (screenPos.x < rectMin.x || screenPos.y < rectMin.y ||
        screenPos.x >= rectMax.x || screenPos.y >= rectMax.y) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float2 localUV = (screenPos - rectMin) / uniforms.contentSize;
    float2 sampleUV = localUV;
    if (uniforms.filterMode == 2u) {
        float2 centered = localUV * 2.0 - 1.0;
        float radius = dot(centered, centered);
        centered *= 1.0 + uniforms.curvature * radius;
        sampleUV = centered * 0.5 + 0.5;
        if (sampleUV.x < 0.0 || sampleUV.y < 0.0 || sampleUV.x > 1.0 || sampleUV.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float2 texelSize = 1.0 / uniforms.textureSize;
    float2 texelCoord = sampleUV * uniforms.textureSize;
    float2 nearestUV = (floor(texelCoord) + 0.5) * texelSize;
    float4 color = tex.sample(nearestSampler, nearestUV);
    float displayBrightness = clamp(uniforms.brightness, 0.4, 2.2);
    float displayContrast = clamp(uniforms.contrast, 0.4, 2.0);
    float displaySaturation = clamp(uniforms.saturation, 0.0, 2.0);
    float filterSharpness = max(uniforms.sharpness * uniforms.userSharpness, 0.05);

    if (uniforms.filterMode == 0u) {
        color.rgb = applyDisplayGrade(color.rgb, displayBrightness, displayContrast, displaySaturation);
        return float4(min(color.rgb, 1.0), color.a);
    }

    if (uniforms.filterMode == 3u || uniforms.filterMode == 4u) {
        bool hotPhosphor = uniforms.filterMode == 4u;
        float focus = clamp(filterSharpness, 0.0, 1.0);
        float glowBoost = max(displayBrightness - 1.0, 0.0);
        float trinitronGlow = clamp(uniforms.glowAmount, 0.25, 2.0);
        float sigmaX = hotPhosphor
            ? mix(1.92, 1.28, focus) + glowBoost * 0.30 + (trinitronGlow - 1.0) * 0.38
            : mix(1.05, 0.62, focus);
        float sigmaY = hotPhosphor
            ? mix(1.14, 0.72, focus) + glowBoost * 0.18 + (trinitronGlow - 1.0) * 0.20
            : mix(0.78, 0.46, focus);
        float3 phosphor = samplePhosphorBloom(
            tex,
            nearestSampler,
            sampleUV,
            uniforms.textureSize,
            sigmaX,
            sigmaY,
            hotPhosphor ? min(0.95, 0.82 + glowBoost * 0.05 + (trinitronGlow - 1.0) * 0.08) : min(0.88, 0.78 + glowBoost * 0.04),
            hotPhosphor ? 0.08 : 0.18,
            hotPhosphor
                ? (0.40 + uniforms.bloomStrength * 0.52) * (1.0 + glowBoost * 1.05) * mix(0.70, 1.55, clamp(trinitronGlow * 0.5, 0.0, 1.0))
                : (0.30 + uniforms.bloomStrength * 0.45) * (1.0 + glowBoost * 0.75),
            hotPhosphor
                ? uniforms.bloomStrength * 0.30 * (1.0 + glowBoost * 1.10) * mix(0.72, 1.70, clamp(trinitronGlow * 0.5, 0.0, 1.0))
                : uniforms.bloomStrength * 0.22 * (1.0 + glowBoost * 0.80),
            hotPhosphor ? 0.34 : 0.55,
            hotPhosphor
        );
        if (hotPhosphor) {
            float texelScaleX = max(uniforms.contentSize.x / uniforms.textureSize.x, 1.0);
            float texelScaleY = max(uniforms.contentSize.y / uniforms.textureSize.y, 1.0);
            float localTexelX = (screenPos.x - rectMin.x) / texelScaleX;
            float localTexelY = (screenPos.y - rectMin.y) / texelScaleY;
            float3 cellMask = trinitronCellMask(localTexelX, localTexelY, uniforms.maskStrength);
            float lineMask = trinitronScanlineMask(localTexelY, uniforms.scanlineStrength);
            float beamLuma = dot(phosphor, float3(0.2126, 0.7152, 0.0722));
            float highlightGlow = smoothstep(0.40, 1.0, beamLuma);
            float grayPedestal = (0.022 + beamLuma * 0.078) * (1.0 + glowBoost * 0.42 + (trinitronGlow - 1.0) * 0.18);

            phosphor *= mix(float3(1.0), cellMask, 0.58);
            phosphor *= mix(1.0, lineMask, 0.60);
            phosphor += (float3(grayPedestal) * (float3(0.60) + cellMask * 0.50)) * lineMask;
            phosphor += float3(highlightGlow * beamLuma * (0.14 + glowBoost * 0.08 + (trinitronGlow - 1.0) * 0.12));
            phosphor += max(phosphor - 0.12, 0.0) * (0.18 + glowBoost * 0.12 + (trinitronGlow - 1.0) * 0.18);
            phosphor = pow(max(phosphor, 0.0), float3(0.88));
        } else {
            float3 mask = apertureGrilleMask(
                screenPos.x - rectMin.x,
                uniforms.maskStrength,
                3.0,
                5.0,
                0.16
            );
            phosphor *= mask;
            phosphor = pow(max(phosphor, 0.0), float3(0.95));
        }
        phosphor = applyDisplayGrade(phosphor, displayBrightness, displayContrast, displaySaturation);
        return float4(min(phosphor, 1.0), 1.0);
    }

    if (uniforms.bloomStrength > 0.0) {
        float4 bloom = tex.sample(linearSampler, sampleUV + float2(texelSize.x, 0.0));
        bloom += tex.sample(linearSampler, sampleUV - float2(texelSize.x, 0.0));
        bloom += tex.sample(linearSampler, sampleUV + float2(0.0, texelSize.y));
        bloom += tex.sample(linearSampler, sampleUV - float2(0.0, texelSize.y));
        bloom *= 0.25;
        color.rgb = mix(color.rgb, max(color.rgb, bloom.rgb), uniforms.bloomStrength);
    }

    float scaleY = max(uniforms.contentSize.y / uniforms.textureSize.y, 1.0);
    float scanPhase = fract((screenPos.y - rectMin.y) / scaleY);
    float beam = 1.0 - uniforms.scanlineStrength * pow(abs(scanPhase - 0.5) * 2.0, max(filterSharpness, 1.0));
    color.rgb *= beam;

    if (uniforms.maskStrength > 0.0) {
        uint triad = uint(floor(screenPos.x)) % 3u;
        float dim = 1.0 - uniforms.maskStrength;
        float3 mask = float3(dim, dim, dim);
        if (triad == 0u) {
            mask.r = 1.0;
        } else if (triad == 1u) {
            mask.g = 1.0;
        } else {
            mask.b = 1.0;
        }
        color.rgb *= mask;
    }

    if (uniforms.vignetteStrength > 0.0) {
        float2 vignetteUV = sampleUV * (1.0 - sampleUV.yx);
        float vignette = clamp(pow(16.0 * vignetteUV.x * vignetteUV.y, 0.25), 0.0, 1.0);
        color.rgb *= mix(1.0, vignette, uniforms.vignetteStrength);
    }

    color.rgb = applyDisplayGrade(color.rgb, displayBrightness, displayContrast, displaySaturation);
    return float4(min(color.rgb, 1.0), 1.0);
}

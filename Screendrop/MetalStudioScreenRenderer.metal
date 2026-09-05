#include <metal_stdlib>
using namespace metal;

struct StudioQuadVertex {
    float2 position;
    float2 texCoord;
};

struct StudioRenderUniforms {
    float2 canvasSize;
    float4 drawRect;
    float4 cardRect;
    float2 sourceSize;
    float cardCornerRadius;
    float sampleAlpha;
    uint filterKind;
    uint clipEnabled;
    uint resamplerEnabled;
};

struct StudioVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 canvasPosition;
};

vertex StudioVertexOut studioScreenVertex(
    const device StudioQuadVertex *vertices [[buffer(0)]],
    constant StudioRenderUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    StudioQuadVertex quad = vertices[vertexID];
    float2 canvasPosition = uniforms.drawRect.xy
        + quad.position * uniforms.drawRect.zw;

    StudioVertexOut output;
    output.position = float4(
        canvasPosition.x / uniforms.canvasSize.x * 2.0 - 1.0,
        1.0 - canvasPosition.y / uniforms.canvasSize.y * 2.0,
        0.0,
        1.0
    );
    output.texCoord = quad.texCoord;
    output.canvasPosition = canvasPosition;
    return output;
}

float sinc(float x) {
    if (abs(x) < 0.0001) {
        return 1.0;
    }
    float piX = 3.14159265358979323846 * x;
    return sin(piX) / piX;
}

float catmullRomWeight(float distance) {
    float x = abs(distance);
    if (x <= 1.0) {
        return 1.5 * x * x * x - 2.5 * x * x + 1.0;
    }
    if (x < 2.0) {
        return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
    }
    return 0.0;
}

float mitchellWeight(float distance) {
    constexpr float B = 1.0 / 3.0;
    constexpr float C = 1.0 / 3.0;
    float x = abs(distance);
    if (x < 1.0) {
        return ((12.0 - 9.0 * B - 6.0 * C) * x * x * x
            + (-18.0 + 12.0 * B + 6.0 * C) * x * x
            + (6.0 - 2.0 * B)) / 6.0;
    }
    if (x < 2.0) {
        return ((-B - 6.0 * C) * x * x * x
            + (6.0 * B + 30.0 * C) * x * x
            + (-12.0 * B - 48.0 * C) * x
            + (8.0 * B + 24.0 * C)) / 6.0;
    }
    return 0.0;
}

float lanczosWeight(float distance, float radius) {
    float x = abs(distance);
    if (x >= radius) {
        return 0.0;
    }
    return sinc(x) * sinc(x / radius);
}

float reconstructionRadius(uint filterKind) {
    switch (filterKind) {
    case 1: return 3.0; // Lanczos-3
    case 2: return 5.0; // Lanczos-5
    case 3: return 2.0; // Mitchell-Netravali
    default: return 2.0; // Catmull-Rom
    }
}

float reconstructionWeight(uint filterKind, float distance) {
    switch (filterKind) {
    case 1:
        return lanczosWeight(distance, 3.0);
    case 2:
        return lanczosWeight(distance, 5.0);
    case 3:
        return mitchellWeight(distance);
    default:
        return catmullRomWeight(distance);
    }
}

float areaWeight(float sampleCenter, float sourceCenter, float scale) {
    if (scale >= 1.0) {
        return max(0.0, 1.0 - abs(sampleCenter - sourceCenter));
    }

    float halfFootprint = 0.5 / scale;
    float left = max(sampleCenter - 0.5, sourceCenter - halfFootprint);
    float right = min(sampleCenter + 0.5, sourceCenter + halfFootprint);
    return max(0.0, right - left);
}

float4 legacyCatmullRomSample(
    texture2d<float> sourceTexture,
    float2 sourcePosition
) {
    float2 basePosition = floor(sourcePosition);
    float2 fraction = sourcePosition - basePosition;
    int2 maximumPosition = int2(
        sourceTexture.get_width() - 1,
        sourceTexture.get_height() - 1
    );

    float4 result = float4(0.0);
    float weightSum = 0.0;
    for (int y = -1; y <= 2; ++y) {
        float weightY = catmullRomWeight(float(y) - fraction.y);
        for (int x = -1; x <= 2; ++x) {
            float weight = weightY * catmullRomWeight(float(x) - fraction.x);
            int2 position = int2(basePosition) + int2(x, y);
            position = clamp(position, int2(0), maximumPosition);
            result += sourceTexture.read(uint2(position)) * weight;
            weightSum += weight;
        }
    }
    return result / max(weightSum, 0.0001);
}

float4 areaSample(
    texture2d<float> sourceTexture,
    float2 sourcePosition,
    float2 scale
) {
    float2 clampedScale = max(scale, float2(0.0001));
    float2 halfFootprint = 0.5 / clampedScale;
    int2 textureMaximum = int2(
        sourceTexture.get_width() - 1,
        sourceTexture.get_height() - 1
    );
    int2 lower = int2(floor(sourcePosition - halfFootprint));
    int2 upper = int2(ceil(sourcePosition + halfFootprint));
    lower = max(lower, int2(0));
    upper = min(upper, textureMaximum);

    float4 result = float4(0.0);
    float weightSum = 0.0;
    for (int y = lower.y; y <= upper.y; ++y) {
        float weightY = areaWeight(float(y), sourcePosition.y, clampedScale.y);
        for (int x = lower.x; x <= upper.x; ++x) {
            float weightX = areaWeight(float(x), sourcePosition.x, clampedScale.x);
            float weight = weightX * weightY;
            result += sourceTexture.read(uint2(x, y)) * weight;
            weightSum += weight;
        }
    }
    return result / max(weightSum, 0.0001);
}

float4 reconstructionSample(
    texture2d<float> sourceTexture,
    float2 sourcePosition,
    float2 scale,
    uint filterKind
) {
    // A separable reconstruction kernel is evaluated directly in the
    // fragment. For minification, shrinking the kernel in source-pixel space
    // integrates a wider source footprint instead of reusing only four
    // neighboring pixels. The final normalization handles clamped edges.
    float2 effectiveScale = min(max(scale, float2(0.0001)), float2(1.0));
    float radius = reconstructionRadius(filterKind);
    float2 support = radius / effectiveScale;
    int2 textureMaximum = int2(
        sourceTexture.get_width() - 1,
        sourceTexture.get_height() - 1
    );
    int2 lower = int2(ceil(sourcePosition - support));
    int2 upper = int2(floor(sourcePosition + support));
    lower = max(lower, int2(0));
    upper = min(upper, textureMaximum);

    float4 result = float4(0.0);
    float weightSum = 0.0;
    for (int y = lower.y; y <= upper.y; ++y) {
        float distanceY = (float(y) - sourcePosition.y) * effectiveScale.y;
        float weightY = reconstructionWeight(filterKind, distanceY) * effectiveScale.y;
        for (int x = lower.x; x <= upper.x; ++x) {
            float distanceX = (float(x) - sourcePosition.x) * effectiveScale.x;
            float weightX = reconstructionWeight(filterKind, distanceX) * effectiveScale.x;
            float weight = weightX * weightY;
            result += sourceTexture.read(uint2(x, y)) * weight;
            weightSum += weight;
        }
    }
    return result / max(weightSum, 0.0001);
}

float4 screenSample(
    texture2d<float> sourceTexture,
    sampler textureSampler,
    float2 uv,
    float2 scale,
    uint filterKind,
    uint resamplerEnabled
) {
    if (resamplerEnabled == 0) {
        return sourceTexture.sample(textureSampler, uv);
    }

    float2 textureSize = float2(
        sourceTexture.get_width(),
        sourceTexture.get_height()
    );
    // Fragment texCoords are interpolated over the rectangle edges. Subtract
    // half a texel so the first output pixel center maps to source texel zero;
    // this is the same center convention used by the explicit reconstruction
    // kernels and is recorded by the raw-frame harness.
    float2 sourcePosition = uv * textureSize - 0.5;
    if (filterKind == 0) {
        return legacyCatmullRomSample(sourceTexture, sourcePosition);
    }
    if (filterKind == 4) {
        return areaSample(sourceTexture, sourcePosition, scale);
    }
    return reconstructionSample(sourceTexture, sourcePosition, scale, filterKind);
}

float roundedRectangleDistance(float2 point, float4 rect, float radius) {
    float2 halfSize = rect.zw * 0.5;
    float2 center = rect.xy + halfSize;
    float2 q = abs(point - center) - (halfSize - float2(radius));
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 studioScreenFragment(
    StudioVertexOut input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant StudioRenderUniforms &uniforms [[buffer(1)]]
) {
    float2 scale = uniforms.drawRect.zw / max(uniforms.sourceSize, float2(0.0001));
    float4 color = screenSample(
        sourceTexture,
        textureSampler,
        input.texCoord,
        scale,
        uniforms.filterKind,
        uniforms.resamplerEnabled
    );

    float coverage = 1.0;
    if (uniforms.clipEnabled != 0) {
        float radius = min(
            uniforms.cardCornerRadius,
            min(uniforms.cardRect.z, uniforms.cardRect.w) * 0.5
        );
        if (radius > 0.5) {
            float distance = roundedRectangleDistance(
                input.canvasPosition,
                uniforms.cardRect,
                radius
            );
            float antialiasWidth = max(fwidth(distance), 0.75);
            coverage = 1.0 - smoothstep(
                -antialiasWidth,
                antialiasWidth,
                distance
            );
        } else {
            float2 lower = uniforms.cardRect.xy;
            float2 upper = lower + uniforms.cardRect.zw;
            float edgeDistance = min(
                min(input.canvasPosition.x - lower.x, upper.x - input.canvasPosition.x),
                min(input.canvasPosition.y - lower.y, upper.y - input.canvasPosition.y)
            );
            coverage = smoothstep(-0.5, 0.5, edgeDistance);
        }
    }

    if (coverage <= 0.0) {
        discard_fragment();
    }
    return float4(color.rgb, color.a * uniforms.sampleAlpha * coverage);
}

fragment float4 studioScreenCopyFragment(
    StudioVertexOut input [[stage_in]],
    texture2d<float> accumulationTexture [[texture(0)]],
    sampler accumulationSampler [[sampler(0)]]
) {
    return accumulationTexture.sample(accumulationSampler, input.texCoord);
}

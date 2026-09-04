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
    float cardCornerRadius;
    float sampleAlpha;
    uint clipEnabled;
    uint useBicubic;
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

// Catmull-Rom cubic reconstruction. It is intentionally explicit rather
// than relying on a sampler's filter mode: zoomed frames need a stable,
// high-quality result at every magnification, including fractional sample
// positions during motion blur.
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

float4 bicubicSample(texture2d<float> texture, float2 uv) {
    float2 textureSize = float2(texture.get_width(), texture.get_height());
    float2 sourcePosition = uv * textureSize - 0.5;
    float2 basePosition = floor(sourcePosition);
    float2 fraction = sourcePosition - basePosition;
    int2 maximumPosition = int2(texture.get_width() - 1, texture.get_height() - 1);

    float4 result = float4(0.0);
    float weightSum = 0.0;
    for (int y = -1; y <= 2; ++y) {
        float weightY = catmullRomWeight(float(y) - fraction.y);
        for (int x = -1; x <= 2; ++x) {
            float weight = weightY * catmullRomWeight(float(x) - fraction.x);
            int2 position = int2(basePosition) + int2(x, y);
            position = clamp(position, int2(0), maximumPosition);
            result += texture.read(uint2(position)) * weight;
            weightSum += weight;
        }
    }
    return result / max(weightSum, 0.0001);
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
    float4 color = uniforms.useBicubic != 0
        ? bicubicSample(sourceTexture, input.texCoord)
        : sourceTexture.sample(textureSampler, input.texCoord);

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

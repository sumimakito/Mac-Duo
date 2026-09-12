import Foundation

/// The whole effect in one fragment shader.
///
/// Each screen pixel maps back into the picture through the inverse
/// perspective, then takes one sample from a Gaussian pyramid at a level
/// chosen by the blur wanted there. The texture already holds the picture on
/// black, so the two blur together and the picture edge needs no special
/// handling.
enum DepthShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;          // screen-to-picture matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;  // screen size, padded origin in picture points
        float4 paddedAndBlur;    // padded size, max radius in pixels, blur strength
        float4 shape;            // blur floor, max dim, pixel scale, max level
        float4 light;            // dim floor, dim strength, dim reach, unused
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
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

    float4 bicubicPyramidSample(texture2d<float> picture,
                                sampler linearSampler,
                                float2 texCoord,
                                float mipLevel) {
        // Each pyramid level is Gaussian blurred, but a single bilinear
        // reconstruction sample can still reveal its coarse texel grid at
        // large radii. Mitchell-Netravali reconstruction smooths that grid
        // while avoiding the ringing of a sharper cubic kernel.
        uint levelIndex = uint(mipLevel);
        float2 mipSize = float2(
            picture.get_width(levelIndex),
            picture.get_height(levelIndex)
        );
        float2 mipTexel = 1.0 / mipSize;
        float2 mipPoint = texCoord / mipTexel - 0.5;
        float2 base = floor(mipPoint);
        float2 fraction = mipPoint - base;
        float4 weightsX = float4(
            mitchellWeight(fraction.x + 1.0),
            mitchellWeight(fraction.x),
            mitchellWeight(1.0 - fraction.x),
            mitchellWeight(2.0 - fraction.x)
        );
        float4 weightsY = float4(
            mitchellWeight(fraction.y + 1.0),
            mitchellWeight(fraction.y),
            mitchellWeight(1.0 - fraction.y),
            mitchellWeight(2.0 - fraction.y)
        );

        float4 colour = float4(0.0);
        for (uint y = 0; y < 4; ++y) {
            for (uint x = 0; x < 4; ++x) {
                float2 samplePoint = (base + float2(float(x) - 1.0, float(y) - 1.0) + 0.5) * mipTexel;
                colour += picture.sample(
                    linearSampler,
                    samplePoint,
                    level(mipLevel)
                ) * weightsX[x] * weightsY[y];
            }
        }
        return colour;
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]]) {
        // The Gaussian pyramid stores one blur radius per mip level. Blend
        // adjacent levels explicitly so the blur changes continuously without
        // relying on implicit fractional-LOD behavior.
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

        float2 screenSize = uniforms.screenAndOrigin.xy;
        float2 paddedOrigin = uniforms.screenAndOrigin.zw;
        float2 paddedSize = uniforms.paddedAndBlur.xy;
        float maxRadius = uniforms.paddedAndBlur.z;
        float strength = uniforms.paddedAndBlur.w;
        float blurFloor = uniforms.shape.x;
        float maxDim = uniforms.shape.y;
        float pixelScale = uniforms.shape.z;
        float maxLevel = uniforms.shape.w;
        float dimFloor = uniforms.light.x;
        float dimStrength = uniforms.light.y;
        float dimReach = uniforms.light.z;
        constexpr float verticalBlurCurve = 2.25;
        constexpr float radiusResponseCurve = 1.2;

        // Fragment coordinates are pixels with y down; the geometry is points
        // with y up.
        float2 screenPoint = float2(position.x / pixelScale,
                                    screenSize.y - position.y / pixelScale);

        float3x3 screenToPicture = float3x3(uniforms.column0.xyz,
                                            uniforms.column1.xyz,
                                            uniforms.column2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        if (abs(mapped.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 picturePoint = mapped.xy / mapped.z;

        float2 unit = (picturePoint - paddedOrigin) / paddedSize;
        if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        float height = clamp(picturePoint.y / screenSize.y, 0.0, 1.0);
        // Keep the hinge edge nearly sharp and concentrate the blur toward
        // the far edge. The response curve also prevents modest lid travel
        // from jumping into a strong low-resolution pyramid level.
        float verticalSpread = pow(height, verticalBlurCurve);
        float spatialBlur = blurFloor + (1.0 - blurFloor) * verticalSpread;
        float radiusStrength = pow(max(strength, 0.0), radiusResponseCurve);
        float blurRadius = radiusStrength * spatialBlur * maxRadius;
        // Naming this `level` would shadow Metal's level() selector.
        float mipLevel = clamp(log2(max(blurRadius, 1.0)), 0.0, maxLevel);
        float lowerLevel = floor(mipLevel);
        float upperLevel = min(lowerLevel + 1.0, maxLevel);
        float levelFraction = mipLevel - lowerLevel;
        float4 lowerColour = bicubicPyramidSample(picture, linearSampler, texCoord, lowerLevel);
        float4 upperColour = bicubicPyramidSample(picture, linearSampler, texCoord, upperLevel);
        float4 colour = mix(lowerColour, upperColour, levelFraction);
        // smoothstep rather than a clamped ratio, so the height where the
        // dimming reaches full strength leaves no visible edge.
        float spread = smoothstep(0.0, max(dimReach, 0.02), height);
        float fade = dimStrength * (dimFloor + (1.0 - dimFloor) * spread);
        // The sample is linear light. Raising the factor to 2.2 keeps the
        // dimming setting a fraction of the encoded brightness.
        colour.rgb *= pow(1.0 - maxDim * fade, 2.2);
        return float4(colour.rgb, 1.0);
    }
    """
}

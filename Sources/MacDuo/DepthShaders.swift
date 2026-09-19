import Foundation

/// The whole effect in one fragment shader.
///
/// Each screen pixel maps back into the picture through the inverse
/// perspective, then reconstructs the Gaussian pyramid levels chosen by the
/// blur wanted there. The texture already holds the picture on black, so the
/// two blur together and the picture edge needs no special handling.
enum DepthShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;          // framebuffer-to-texture matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 blur;             // hinge radius, radius range, max level, unused
        float4 height;           // offset and scale from texture v, unused
        float4 light;            // max dim, dim floor, dim strength, dim reach
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    struct CubicAxis {
        float3 coordinates;
        float3 weights;
    };

    CubicAxis mitchellAxis(float coordinate, float mipSize) {
        float mipTexel = 1.0 / mipSize;
        float mipPoint = coordinate * mipSize - 0.5;
        float base = floor(mipPoint);
        float fraction = mipPoint - base;
        float squared = fraction * fraction;

        // Closed forms for Mitchell-Netravali with B = C = 1/3. The middle
        // weights are positive, so one linear sample evaluates both exactly.
        float w0 = 1.0 / 18.0 + fraction * (
            -0.5 + fraction * (5.0 / 6.0 - 7.0 / 18.0 * fraction)
        );
        float w1 = 8.0 / 9.0 + squared * (-2.0 + 7.0 / 6.0 * fraction);
        float w2 = 1.0 / 18.0 + fraction * (
            0.5 + fraction * (1.5 - 7.0 / 6.0 * fraction)
        );
        float w3 = squared * (-1.0 / 3.0 + 7.0 / 18.0 * fraction);
        float middleWeight = w1 + w2;
        float middleOffset = w2 / middleWeight;

        CubicAxis axis;
        axis.coordinates = (
            base + float3(-0.5, 0.5 + middleOffset, 2.5)
        ) * mipTexel;
        axis.weights = float3(w0, middleWeight, w3);
        return axis;
    }

    float4 sampleMitchellRow(texture2d<float> picture,
                             sampler linearSampler,
                             float3 xCoordinates,
                             float yCoordinate,
                             float3 xWeights,
                             float mipLevel) {
        return picture.sample(
            linearSampler, float2(xCoordinates.x, yCoordinate), level(mipLevel)
        ) * xWeights.x + picture.sample(
            linearSampler, float2(xCoordinates.y, yCoordinate), level(mipLevel)
        ) * xWeights.y + picture.sample(
            linearSampler, float2(xCoordinates.z, yCoordinate), level(mipLevel)
        ) * xWeights.z;
    }

    float4 bicubicPyramidSample(texture2d<float> picture,
                                sampler linearSampler,
                                float2 texCoord,
                                uint mipLevel) {
        // Each pyramid level is Gaussian blurred, but one bilinear sample can
        // reveal its coarse texel grid. This is the same 4x4 Mitchell filter
        // grouped into nine hardware-linear samples.
        CubicAxis x = mitchellAxis(
            texCoord.x, float(picture.get_width(mipLevel))
        );
        CubicAxis y = mitchellAxis(
            texCoord.y, float(picture.get_height(mipLevel))
        );
        float levelIndex = float(mipLevel);
        return sampleMitchellRow(
            picture, linearSampler, x.coordinates, y.coordinates.x, x.weights, levelIndex
        ) * y.weights.x + sampleMitchellRow(
            picture, linearSampler, x.coordinates, y.coordinates.y, x.weights, levelIndex
        ) * y.weights.y + sampleMitchellRow(
            picture, linearSampler, x.coordinates, y.coordinates.z, x.weights, levelIndex
        ) * y.weights.z;
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]]) {
        // The Gaussian pyramid stores one blur radius per mip level. Blend
        // adjacent levels explicitly so the blur changes continuously without
        // relying on implicit fractional-LOD behavior.
        constexpr sampler linearSampler(filter::linear, mip_filter::nearest, address::clamp_to_edge);

        float hingeRadius = uniforms.blur.x;
        float radiusRange = uniforms.blur.y;
        float maxLevel = uniforms.blur.z;
        float heightOffset = uniforms.height.x;
        float heightScale = uniforms.height.y;
        float maxDim = uniforms.light.x;
        float dimFloor = uniforms.light.y;
        float dimStrength = uniforms.light.z;
        float dimReach = uniforms.light.w;
        constexpr float verticalBlurCurve = 2.25;

        float3x3 pixelToTexture = float3x3(uniforms.column0.xyz,
                                           uniforms.column1.xyz,
                                           uniforms.column2.xyz);
        float3 mapped = pixelToTexture * float3(position.xy, 1.0);
        if (abs(mapped.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 texCoord = mapped.xy / mapped.z;
        if (texCoord.x < 0.0 || texCoord.x > 1.0 || texCoord.y < 0.0 || texCoord.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        float height = clamp(heightOffset + heightScale * texCoord.y, 0.0, 1.0);
        // Keep the hinge edge nearly sharp and concentrate the blur toward
        // the far edge. The response curve also prevents modest lid travel
        // from jumping into a strong low-resolution pyramid level.
        float verticalSpread = pow(height, verticalBlurCurve);
        float blurRadius = hingeRadius + radiusRange * verticalSpread;
        // Naming this `level` would shadow Metal's level() selector.
        float mipLevel = clamp(log2(max(blurRadius, 1.0)), 0.0, maxLevel);
        uint lowerLevel = uint(floor(mipLevel));
        uint upperLevel = min(lowerLevel + 1u, uint(maxLevel));
        float levelFraction = mipLevel - float(lowerLevel);
        float4 lowerColour = bicubicPyramidSample(picture, linearSampler, texCoord, lowerLevel);
        float4 colour = lowerColour;
        if (upperLevel > lowerLevel && levelFraction > 0.0) {
            float4 upperColour = bicubicPyramidSample(picture, linearSampler, texCoord, upperLevel);
            colour = mix(lowerColour, upperColour, levelFraction);
        }
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

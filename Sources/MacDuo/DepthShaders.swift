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
        float4 overlayRect;      // user picture rect in picture points, w <= 0 disables
        float4 overlayInfo;      // overlay pyramid max level, unused, unused, unused
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]],
                                   texture2d<float> overlay [[texture(1)]]) {
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
        float blur = strength * (blurFloor + (1.0 - blurFloor) * height);
        // Naming this `level` would shadow Metal's level() selector.
        float mipLevel = clamp(log2(max(blur * maxRadius, 1.0)), 0.0, maxLevel);

        float4 colour = picture.sample(linearSampler, texCoord, level(mipLevel));
        // A user picture composited into the picture space, so it leans, blurs
        // and dims with the screen content under the same depth gradient.
        if (uniforms.overlayRect.z > 0.0 && uniforms.overlayRect.w > 0.0) {
            float2 anchor = (picturePoint - uniforms.overlayRect.xy) / uniforms.overlayRect.zw;
            if (anchor.x >= 0.0 && anchor.x <= 1.0 && anchor.y >= 0.0 && anchor.y <= 1.0) {
                float overlayLevel = clamp(mipLevel, 0.0, uniforms.overlayInfo.x);
                float4 over = overlay.sample(linearSampler, float2(anchor.x, 1.0 - anchor.y), level(overlayLevel));
                colour.rgb = mix(colour.rgb, over.rgb, over.a);
            }
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

import Foundation

/// The whole effect in one fragment shader.
///
/// Each screen pixel maps back into the picture through the inverse
/// perspective, then takes one sample from a Gaussian pyramid at a level
/// chosen by the lid-driven blur at that point. The texture already holds
/// the picture on black, so the two blur together and the picture edge
/// needs no special handling.
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
        float4 pose;             // sin sep, cos sep, eye along, eye depth
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]]) {
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
        float sinSep = uniforms.pose.x;
        float cosSep = uniforms.pose.y;
        float eyeAlong = uniforms.pose.z;
        float eyeDepth = uniforms.pose.w;

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

        // Receded depth behind the glass, in screen heights. Grows as the lid
        // closes and toward the far edge. Blur and dim both read this, so they
        // travel together instead of painting a 2D height band.
        float behind = height * max(sinSep, 0.0);
        float3 world = float3(picturePoint.x, picturePoint.y * cosSep, picturePoint.y * sinSep);
        float3 eye = float3(screenSize.x * 0.5, eyeAlong, eyeDepth);
        float3 toEye = eye - world;
        float dist = length(toEye);
        float3 normal = float3(0.0, -sinSep, cosSep);
        float ndotv = saturate(dot(normal, toEye / max(dist, 1e-4)));
        float facingFade = pow(1.0 - ndotv, 1.35);
        float depthFalloff = 1.0 - exp(-behind / 0.55 * 2.2);

        // blurFloor (模糊范围) still means evenness: 0 keeps the hinge sharp,
        // 1 blurs the whole picture. The falloff itself follows the lid.
        float concentrated = pow(max(depthFalloff, 0.0), mix(1.8, 1.0, blurFloor));
        float blurSpatial = saturate(
            mix(concentrated, 1.0, blurFloor) + facingFade * mix(0.12, 0.28, blurFloor)
        );
        float blur = strength * blurSpatial;
        // Naming this `level` would shadow Metal's level() selector.
        float mipLevel = clamp(log2(max(blur * maxRadius, 1.0)), 0.0, maxLevel);

        float4 colour = picture.sample(linearSampler, texCoord, level(mipLevel));

        // dimReach scales how much tilt/height is needed to go dark, so the
        // shadow grows down from the top while the lid travels.
        float depthScale = mix(0.25, 1.35, saturate(dimReach));
        float depthFade = 1.0 - exp(-behind / max(depthScale, 0.05) * 2.2);
        float spatial = saturate(depthFade * 0.85 + facingFade * 0.35);
        float fade = dimStrength * (dimFloor + (1.0 - dimFloor) * spatial);
        // The sample is linear light. Raising the factor to 2.2 keeps the
        // dimming setting a fraction of the encoded brightness.
        colour.rgb *= pow(1.0 - maxDim * fade, 2.2);
        return float4(colour.rgb, 1.0);
    }
    """
}

import Foundation

/// The effect in two kinds of pass.
///
/// `downsampleFragment` builds a blur pyramid, one render pass per level, each
/// half the size of the one before. `compositeFragment` maps each screen pixel
/// back into the picture through the inverse perspective and reads the pyramid
/// at the level the blur wants there.
///
/// Each level is read with a cubic B-spline rather than one bilinear tap. A
/// bilinear read of a small level shows its texels as soft squares and
/// diamonds, which is what made the old blur look pixelated. The B-spline is
/// smooth across texels, so a pyramid read this way passes for a true Gaussian.
enum DepthShaders {

    /// Blur of pyramid level `n` read with the B-spline, as a Gaussian sigma
    /// in full size pixels, divided by `2^n`. The [1 3 3 1] reduction adds a
    /// variance of 3/4 texel² per level and the B-spline read another 1/3, so
    /// level n carries about (1/4 + 1/3) 4^n, whose root is 0.76 · 2^n.
    static let sigmaPerLevel: Double = 0.76

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;   // screen-to-picture matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 screen;    // screen size in points, pixel scale, pyramid levels built
        float4 blur;      // max sigma in pixels, blur strength, hinge floor, unused
        float4 light;     // dim floor, dim strength, dim reach, max dim
        float4 gap;       // sin of the glass-to-picture angle, gap for full blur in points,
                          // largest multiple of the full blur, unused
    };

    constant float sigmaPerLevel = \(sigmaPerLevel);

    vertex float4 fullscreenVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    // Halves the picture with a [1 3 3 1] kernel on each axis: four bilinear
    // taps three quarters of a source texel either side of the centre. Beyond
    // the edge reads as black, so the black around the picture blurs in the
    // way a wider picture on a black margin would.
    fragment float4 downsampleFragment(float4 position [[position]],
                                       constant float2 &targetSize [[buffer(0)]],
                                       texture2d<float> source [[texture(0)]]) {
        constexpr sampler edge(filter::linear, address::clamp_to_zero);
        // Normalised coordinates keep every level aligned with the picture
        // even when a level's size rounds down.
        float2 uv = position.xy / targetSize;
        float2 offset = 0.75 / float2(source.get_width(), source.get_height());
        float3 sum = source.sample(edge, uv + float2(-offset.x, -offset.y)).rgb
                   + source.sample(edge, uv + float2( offset.x, -offset.y)).rgb
                   + source.sample(edge, uv + float2(-offset.x,  offset.y)).rgb
                   + source.sample(edge, uv + float2( offset.x,  offset.y)).rgb;
        return float4(sum * 0.25, 1.0);
    }

    // A cubic B-spline read in four bilinear taps (GPU Gems 2, chapter 20).
    static float3 bspline(texture2d<float> picture, float2 uv, uint lod) {
        constexpr sampler edge(filter::linear, mip_filter::nearest, address::clamp_to_zero);
        float2 size = float2(picture.get_width(lod), picture.get_height(lod));
        float2 p = uv * size - 0.5;
        float2 i = floor(p);
        float2 f = p - i;
        float2 f2 = f * f;
        float2 f3 = f2 * f;
        float2 w0 = (-f3 + 3.0 * f2 - 3.0 * f + 1.0) / 6.0;
        float2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
        float2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
        float2 w3 = f3 / 6.0;
        float2 g0 = w0 + w1;
        float2 g1 = w2 + w3;
        float2 h0 = (i - 0.5 + w1 / g0) / size;
        float2 h1 = (i + 1.5 + w3 / g1) / size;
        float l = float(lod);
        float3 a = picture.sample(edge, float2(h0.x, h0.y), level(l)).rgb;
        float3 b = picture.sample(edge, float2(h1.x, h0.y), level(l)).rgb;
        float3 c = picture.sample(edge, float2(h0.x, h1.y), level(l)).rgb;
        float3 d = picture.sample(edge, float2(h1.x, h1.y), level(l)).rgb;
        return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
    }

    static float3 encodeSRGB(float3 linear) {
        float3 low = linear * 12.92;
        float3 high = 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
        return select(high, low, linear <= 0.0031308);
    }

    fragment float4 compositeFragment(float4 position [[position]],
                                      constant Uniforms &uniforms [[buffer(0)]],
                                      texture2d<float> base [[texture(0)]],
                                      texture2d<float> pyramid [[texture(1)]]) {
        constexpr sampler edge(filter::linear, address::clamp_to_zero);

        float2 screenSize = uniforms.screen.xy;
        float pixelScale = uniforms.screen.z;
        float levels = uniforms.screen.w;

        // Fragment coordinates are pixels with y down; the geometry is points
        // with y up.
        float2 screenPoint = float2(position.x / pixelScale,
                                    screenSize.y - position.y / pixelScale);
        float3x3 screenToPicture = float3x3(uniforms.column0.xyz,
                                            uniforms.column1.xyz,
                                            uniforms.column2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        float2 picturePoint = mapped.xy / (abs(mapped.z) < 1e-6 ? 1e-6 : mapped.z);
        float2 unit = picturePoint / screenSize;
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        // How many picture pixels one screen pixel covers. Where perspective
        // shrinks the picture this adds to the blur, or it would shimmer.
        float2 basePixels = texCoord * float2(base.get_width(), base.get_height());
        float footprint = max(length(dfdx(basePixels)), length(dfdy(basePixels)));

        float height = saturate(unit.y);
        // The picture stays where the glass started, so it sits behind the
        // glass by its height times the sine of the angle between them. Like a
        // picture behind frosted glass, it softens with that gap.
        float gap = max(picturePoint.y, 0.0) * uniforms.gap.x;
        float gapBlur = min(gap / uniforms.gap.y, uniforms.gap.z);
        float blur = uniforms.blur.z * uniforms.blur.y + (1.0 - uniforms.blur.z) * gapBlur;
        float sigma = blur * uniforms.blur.x;
        float shrink = 0.5 * max(footprint - 1.0, 0.0);
        sigma = sqrt(sigma * sigma + shrink * shrink);

        // Past three sigmas outside the picture nothing reaches.
        float2 margin = 3.0 * sigma / float2(base.get_width(), base.get_height()) + 0.001;
        if (any(texCoord < -margin) || any(texCoord > 1.0 + margin) || mapped.z <= 0.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        // 0 is the picture itself, n is pyramid level n - 1.
        float lod = clamp(log2(max(sigma, 1e-4) / sigmaPerLevel), 0.0, levels);
        float3 colour;
        if (lod <= 0.0) {
            colour = base.sample(edge, texCoord).rgb;
        } else if (lod < 1.0) {
            colour = mix(base.sample(edge, texCoord).rgb, bspline(pyramid, texCoord, 0), lod);
        } else {
            uint lower = uint(lod);
            float blend = lod - float(lower);
            colour = bspline(pyramid, texCoord, lower - 1);
            if (blend > 0.002 && float(lower) < levels) {
                colour = mix(colour, bspline(pyramid, texCoord, lower), blend);
            }
        }

        // smoothstep rather than a clamped ratio, so the height where the
        // dimming reaches full strength leaves no visible edge.
        float spread = smoothstep(0.0, max(uniforms.light.z, 0.02), height);
        float fade = uniforms.light.y * (uniforms.light.x + (1.0 - uniforms.light.x) * spread);
        // The sample is linear light. Raising the factor to 2.2 keeps the
        // dimming setting a fraction of the encoded brightness.
        colour *= pow(1.0 - uniforms.light.w * fade, 2.2);

        // Encoded here rather than by an sRGB target, so the dither lands on
        // the 8 bit steps themselves. Wide dark blurs band without it.
        float3 encoded = encodeSRGB(saturate(colour));
        float noise = fract(52.9829189 * fract(dot(position.xy, float2(0.06711056, 0.00583715))));
        encoded += (noise - 0.5) / 255.0;
        return float4(encoded, 1.0);
    }
    """
}

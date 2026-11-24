// Mr. Pixel Camera — Organic 35mm Kodak Vision3 Motion Picture Film Grain
// Breaks up digital MJPEG banding & adds subtle photographic micro-texture at < 0.05 ms GPU cost.

uniform float Grain_Amount<
    string label = "35mm Grain Intensity";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 0.12;
    float step = 0.002;
> = 0.036;

uniform float Grain_Size<
    string label = "Grain Size";
    string widget_type = "slider";
    float minimum = 1.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.50;

uniform float Color_Grain<
    string label = "Organic Chroma Variance";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.02;
> = 0.22;

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 col = image.Sample(textureSampler, v_in.uv);
    if (Grain_Amount <= 0.0005) {
        return col;
    }

    // Quantize to subtle 35mm emulsion grain cells & animate smoothly at 24fps film cadence
    float2 cell = floor((v_in.uv * uv_size) / max(1.0, Grain_Size));
    float t = floor(elapsed_time * 24.0);
    float2 seed = cell + float2(t * 17.13, t * 31.71);

    // Triangular-distributed organic noise (avoids harsh uniform digital snow)
    float n1 = hash12(seed) + hash12(seed + float2(13.7, 29.3)) - 1.0;
    float nr = hash12(seed + float2(7.1, 3.9)) - 0.5;
    float nb = hash12(seed + float2(19.3, 11.7)) - 0.5;

    float3 grain = float3(
        n1 + nr * Color_Grain,
        n1,
        n1 + nb * Color_Grain
    );

    // Silver-halide luminance weighting: strongest in midtones, gently tapered in deep shadows & highlights
    float luma = dot(col.rgb, float3(0.2126, 0.7152, 0.0722));
    float midWeight = smoothstep(0.03, 0.22, luma) * (1.0 - smoothstep(0.75, 0.98, luma) * 0.75);

    float3 outRgb = clamp(col.rgb + grain * Grain_Amount * midWeight, 0.0, 1.0);
    return float4(outRgb, col.a);
}

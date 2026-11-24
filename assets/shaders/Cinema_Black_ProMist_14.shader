// Mr. Pixel Camera — Tiffen Black Pro-Mist 1/4 Optical Diffusion & Warm Halation
// Crafted for OBS Studio (Apple Silicon OpenGL/Metal) + Pixel 10 Pro Cinema Pipeline
// Preserves deep shadows & micro-contrast while blooming bright highlights with subtle warm halation.

uniform float Mist_Strength<
    string label = "Pro-Mist Strength";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 0.34;

uniform float Highlight_Threshold<
    string label = "Highlight Threshold";
    string widget_type = "slider";
    float minimum = 0.30;
    float maximum = 0.95;
    float step = 0.01;
> = 0.65;

uniform float Mist_Radius<
    string label = "Diffusion Radius (px)";
    string widget_type = "slider";
    float minimum = 2.0;
    float maximum = 24.0;
    float step = 0.5;
> = 13.0;

uniform float Halation_Warmth<
    string label = "Optical Halation Warmth";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 0.45;

uniform float Shadow_Protect<
    string label = "Shadow Black Protection";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 0.90;

float luma709(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float3 extractHighlight(float3 col, float thresh)
{
    float l = luma709(col);
    float w = smoothstep(thresh, min(0.99, thresh + 0.30), l);
    return col * w;
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 base = image.Sample(textureSampler, v_in.uv);
    if (Mist_Strength <= 0.001) {
        return base;
    }

    float2 px = uv_pixel_interval;
    float r1 = Mist_Radius * 0.45;
    float r2 = Mist_Radius;

    float3 bloom = float3(0.0, 0.0, 0.0);
    float wSum = 0.0;

    // 12-tap dual-ring optical diffusion kernel (fast, artifact-free, 60 FPS safe)
    for (int i = 0; i < 6; i++) {
        float a1 = float(i) * 1.04719755; // 60 deg
        float a2 = a1 + 0.52359877;       // +30 deg stagger

        float2 uv1 = clamp(v_in.uv + float2(cos(a1), sin(a1)) * r1 * px, float2(0.001, 0.001), float2(0.999, 0.999));
        float2 uv2 = clamp(v_in.uv + float2(cos(a2), sin(a2)) * r2 * px, float2(0.001, 0.001), float2(0.999, 0.999));

        float3 s1 = image.Sample(textureSampler, uv1).rgb;
        float3 s2 = image.Sample(textureSampler, uv2).rgb;

        bloom += extractHighlight(s1, Highlight_Threshold) * 1.35;
        bloom += extractHighlight(s2, Highlight_Threshold) * 0.75;
        wSum += 2.10;
    }
    bloom /= wSum;

    // Subtle filmic warm red-amber optical halation tint (Tiffen / Kodak Vision3 feel)
    float3 halationTint = lerp(float3(1.0, 1.0, 1.0), float3(1.16, 0.98, 0.84), Halation_Warmth);
    bloom *= halationTint;

    // Shadow protection keeps blacks rich instead of milky
    float baseLuma = luma709(base.rgb);
    float shadowMask = lerp(1.0, smoothstep(0.05, 0.35, baseLuma) * 0.65 + 0.35, Shadow_Protect);

    // Filmic screen-like blend prevents harsh clipping on bright highlights
    float3 glow = bloom * (Mist_Strength * 1.45) * shadowMask;
    float3 result = 1.0 - (1.0 - base.rgb) * (1.0 - clamp(glow, 0.0, 0.65));

    // Gentle highlight shoulder roll-off
    result = clamp(result, 0.0, 1.0);
    return float4(result, base.a);
}

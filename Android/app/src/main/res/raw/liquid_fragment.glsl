precision highp float;
uniform sampler2D uTexSampler;
uniform float uAspect;
uniform float uTime;
varying vec2 vTexSamplingCoord;

// 注意：GLSL 的 pow(x, 2.0) 在 x<0 时结果未定义（返回 NaN），会让整块像素变黑。
// 这里一律用乘法代替 pow，边缘处任何一点点负误差都不会污染结果。

float roundedBoxSdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

vec3 sampleGlass(vec2 uv, float spread, float aspect) {
    // 螺旋采样做磨砂背景；RGB 三通道用不同半径 → 色散（chromatic aberration）
    const int N = 10;
    vec3 acc = vec3(0.0);
    for (int i = 0; i < N; i++) {
        float fi = float(i);
        float ang = fi * 2.39996323;                       // 黄金角
        float rad = sqrt((fi + 0.5) / float(N)) * spread;
        vec2 off = vec2(cos(ang) / aspect, sin(ang)) * rad;
        acc.r += texture2D(uTexSampler, clamp(uv + off * 1.22, vec2(0.002), vec2(0.998))).r;
        acc.g += texture2D(uTexSampler, clamp(uv + off, vec2(0.002), vec2(0.998))).g;
        acc.b += texture2D(uTexSampler, clamp(uv + off * 0.78, vec2(0.002), vec2(0.998))).b;
    }
    return acc / float(N);
}

void main() {
    vec2 uv = vTexSamplingCoord;
    float t = uTime;
    float aspect = max(uAspect, 0.0001);
    float shortScale = min(1.0, uAspect);

    float marginY = 0.020 * shortScale;
    float capsuleH = 0.155 * shortScale;
    float marginX = 0.020 / aspect;
    float left = marginX;
    float right = 1.0 - marginX;
    float bottom = marginY;
    float top = bottom + capsuleH;
    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);
    vec2 halfSize = vec2((right - left) * 0.5, capsuleH * 0.5);
    float radius = capsuleH * 0.48;

    float d = roundedBoxSdf(uv - center, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, uv);
        return;
    }

    vec2 local = (uv - center) / vec2(max(right - left, 0.001), capsuleH);
    float depth = clamp(-d / capsuleH, 0.0, 1.0);          // 0=边界 1=内部
    float rim = 1.0 - smoothstep(0.0, 0.20, depth);        // 边缘强度

    // 形状法线（SDF 有限差分），用于边缘折射
    float e = 0.0018;
    vec2 grad = vec2(
        roundedBoxSdf(uv - center + vec2(e, 0.0), halfSize, radius) - d,
        roundedBoxSdf(uv - center + vec2(0.0, e), halfSize, radius) - d);
    vec2 nrm = normalize(grad + vec2(1e-6));

    // ---- 液态流动：多层正弦叠加，相位随时间漂移 ----
    float breathe = 0.85 + 0.15 * sin(t * 0.8);
    float wave = sin(local.x * 12.0 + t * 1.6) * 0.50
               + sin(local.x * 7.0 - local.y * 3.0 + t * 1.1) * 0.35
               + sin(local.y * 9.0 + t * 2.0) * 0.30;
    vec2 flow = vec2(wave * 0.9, wave * 0.55) * 0.026 * capsuleH * breathe;

    // ---- 边缘折射：凸透镜把背景向外挤压，越靠边越强 ----
    float lensPower = rim * rim * 0.075 * capsuleH;
    vec2 refractOffset = nrm * lensPower * vec2(1.0 / aspect, 1.0);

    float spread = (0.0055 + 0.0035 * (1.0 - depth)) * shortScale;  // 边缘更糊
    vec3 glass = sampleGlass(uv + refractOffset + flow, spread, aspect);

    // 玻璃本体：轻微提亮 + 冷色调，像一层薄玻璃
    glass = mix(glass, vec3(1.0), 0.10);
    glass = mix(glass, glass * vec3(0.94, 0.97, 1.06), 0.55);

    // ---- 镜面高光：沿边缘一圈，随时间游走，上边更亮 ----
    float shimmer = 0.55 + 0.30 * sin(t * 1.8 + local.x * 5.5);
    float topBias = 0.45 + 0.55 * smoothstep(-0.5, 0.5, -local.y);
    glass += vec3(1.0) * rim * rim * shimmer * topBias * 0.42;

    // 顶部内壁的一道细亮线
    float sheen = (1.0 - smoothstep(0.0, 0.30, abs(local.y + 0.30)))
                * (1.0 - smoothstep(0.30, 0.52, abs(local.x)));
    glass += vec3(1.0) * sheen * 0.16;

    // 底部内反射的暖光
    float bottomGlow = smoothstep(0.10, 0.52, local.y) * 0.10;
    glass += vec3(1.0, 0.95, 0.88) * bottomGlow;

    // 极轻的彩虹衍射，随时间缓慢平移
    float rx = local.x + 0.05 * sin(t * 0.6);
    vec3 rainbow = vec3(0.30, 0.75, 1.0) * max(0.0, 0.34 - rx - local.y) * 0.030
                 + vec3(0.86, 0.42, 1.0) * max(0.0, 0.28 - abs(rx)) * 0.032
                 + vec3(1.0, 0.72, 0.30) * max(0.0, 0.34 + rx + local.y) * 0.024;
    glass += rainbow * (0.55 + 0.45 * rim);

    gl_FragColor = vec4(clamp(glass, 0.0, 1.0), 1.0);
}

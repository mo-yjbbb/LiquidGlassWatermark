precision highp float;
uniform sampler2D uTexSampler;
uniform float uAspect;
uniform float uTime;
// 视频分辨率与静态图不同，Transformer 会把输入帧拉伸到目标画布；这两个值把采样坐标
// 还原回等比 centerCrop，避免画面变形、胶囊被挤成尖角。未设置时退化为 (1,1)。
uniform float uScaleX;
uniform float uScaleY;
varying vec2 vTexSamplingCoord;

// 编写约束（踩过的坑，别改回去）：
// 1) 不要用 pow(x, 2.0)：GLSL 中 x<0 时结果未定义（NaN），会让整块像素变黑。用 x*x。
// 2) 不要在循环里做纹理采样：部分 GLSL ES 1.0 驱动对此支持很差。一律手写展开。
// 3) smoothstep(edge0, edge1, x) 必须 edge0 < edge1，反向写法结果未定义。
// 4) SDF 参数里出现负数会让形状彻底崩坏，所有尺寸项都要夹住下限。

float roundedBoxSdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 uv = vTexSamplingCoord;
    float t = uTime;
    float aspect = max(uAspect, 0.0001);
    float shortScale = min(1.0, uAspect);

    // 把输出画布坐标还原回源画面的等比 centerCrop 区域（胶囊内外都要用，必须先算）
    vec2 scale = mix(vec2(1.0), vec2(uScaleX, uScaleY), step(0.01, min(uScaleX, uScaleY)));
    vec2 src = (uv - 0.5) * scale + 0.5;

    // 与 LiquidGlassRenderer（静态图）完全同一套比例：短边 1.2% 边距、13.5% 高度、
    // 圆角为高度的 0.47 倍 —— 这样长按播放时胶囊位置和大小都不会跳变。
    // 注意 uv 两个轴的像素密度不同：横屏短边是高度、竖屏短边是宽度，
    // 所以 x 方向要用 min(1, 1/aspect)，直接写 1/aspect 会让竖屏边距被放大。
    float marginY = 0.012 * shortScale;
    float capsuleH = 0.135 * shortScale;
    float marginX = 0.012 * min(1.0, 1.0 / aspect);
    float left = marginX;
    float right = 1.0 - marginX;
    float bottom = marginY;
    float top = bottom + capsuleH;

    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);
    vec2 halfSize = vec2(max(right - left, 0.002) * 0.5, capsuleH * 0.5);
    float radius = capsuleH * 0.47;

    float d = roundedBoxSdf(uv - center, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, src);
        return;
    }

    vec2 local = (uv - center) / vec2(max(right - left, 0.002), capsuleH);
    float depth = clamp(-d / capsuleH, 0.0, 1.0);           // 0=边界 1=中心
    float rim = 1.0 - smoothstep(0.0, 0.16, depth);         // 只在很靠边的一圈

    // ---- 液态流动：三层正弦，相位随时间漂移 ----
    float breathe = 0.85 + 0.15 * sin(t * 0.8);
    float wave = sin(local.x * 11.0 + t * 1.6) * 0.50
               + sin(local.x * 6.5 - local.y * 2.5 + t * 1.1) * 0.32
               + sin(local.y * 8.0 + t * 2.0) * 0.26;
    vec2 flow = vec2(wave * 0.85, wave * 0.50) * 0.020 * capsuleH * breathe;

    // ---- 端头折射：只沿水平方向把两端轻轻顶出去，幅度很小，不会让形状变形 ----
    float lens = rim * rim * 0.022 * capsuleH;
    vec2 refractOff = vec2(local.x * 2.0 * lens / aspect, 0.0);

    vec2 baseUv = clamp(src + flow + refractOff, vec2(0.003), vec2(0.997));

    // ---- 轻度磨砂：5 点固定采样（手写展开） ----
    float sp = (0.0018 + 0.0014 * (1.0 - depth)) * shortScale;
    vec2 sx = vec2(sp / aspect, 0.0);
    vec2 sy = vec2(0.0, sp);
    vec3 c0 = texture2D(uTexSampler, baseUv).rgb;
    vec3 c1 = texture2D(uTexSampler, clamp(baseUv + sx, vec2(0.003), vec2(0.997))).rgb;
    vec3 c2 = texture2D(uTexSampler, clamp(baseUv - sx, vec2(0.003), vec2(0.997))).rgb;
    vec3 c3 = texture2D(uTexSampler, clamp(baseUv + sy, vec2(0.003), vec2(0.997))).rgb;
    vec3 c4 = texture2D(uTexSampler, clamp(baseUv - sy, vec2(0.003), vec2(0.997))).rgb;
    vec3 glass = (c0 * 2.0 + c1 + c2 + c3 + c4) / 6.0;

    // ---- 色散：R/B 各多取一个偏移采样，只在边缘明显 ----
    float disp = (0.0010 + 0.0016 * rim) * shortScale / aspect;
    float rOff = texture2D(uTexSampler, clamp(baseUv + vec2(disp, 0.0), vec2(0.003), vec2(0.997))).r;
    float bOff = texture2D(uTexSampler, clamp(baseUv - vec2(disp, 0.0), vec2(0.003), vec2(0.997))).b;
    glass.r = mix(glass.r, rOff, 0.60);
    glass.b = mix(glass.b, bOff, 0.60);

    // ---- 玻璃本体：极轻的提亮与冷调，保证底下内容始终看得清 ----
    glass = mix(glass, vec3(1.0), 0.06);
    glass *= vec3(0.98, 0.99, 1.04);

    // ---- 高光：顶部一条会游走的柔光带 + 边缘一圈很淡的轮廓光，强度都压得很低 ----
    float topBand = smoothstep(0.05, 0.55, -local.y);
    float sheen = topBand * (0.34 + 0.18 * sin(t * 1.7 + local.x * 4.0));
    glass += vec3(1.0) * sheen * 0.10;
    glass += vec3(1.0) * rim * 0.07;

    gl_FragColor = vec4(clamp(glass, 0.0, 1.0), 1.0);
}

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
// 5) 变量必须先声明再使用，分支里用到的要提前算好。

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
    // 圆角 = 半高（正半圆端头）。uv 两个轴的像素密度不同：横屏短边是高度、竖屏短边
    // 是宽度，所以 x 方向要用 min(1, 1/aspect)，直接写 1/aspect 会让竖屏边距放大。
    float marginY = 0.012 * shortScale;
    float capsuleH = 0.135 * shortScale;
    float marginX = 0.012 * min(1.0, 1.0 / aspect);
    float left = marginX;
    float right = 1.0 - marginX;
    float bottom = marginY;
    float top = bottom + capsuleH;
    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);
    vec2 halfSize = vec2(max(right - left, 0.002) * 0.5, capsuleH * 0.5);
    float radius = capsuleH * 0.5;              // 正半圆端头

    float d = roundedBoxSdf(uv - center, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, src);
        return;
    }

    vec2 local = (uv - center) / vec2(max(right - left, 0.002), capsuleH);
    float u = local.x + 0.5;                    // 0..1 沿胶囊长轴
    float v = local.y + 0.5;                    // 0..1 沿胶囊短轴
    float envelope = sin(3.14159265 * v);       // 上下缘为 0、中间最强

    // ---- 折射扭曲：直接沿用 LiquidGlassRenderer.drawLiquidMesh 的公式，位移幅度
    //      与静态图一致（约 0.4 倍胶囊高），只额外叠加时间相位让液面流动起来 ----
    float e0 = u / 0.115;
    float e1 = (u - 1.0) / 0.115;
    float endLens = exp(-e0 * e0) - exp(-e1 * e1);
    float breathe = 0.88 + 0.12 * sin(t * 0.9);
    float dx = (sin(u * 25.1327 + v * 2.2 + t * 1.5) * 0.095 + endLens * 0.30) * capsuleH * envelope * breathe;
    float dy = (sin(u * 10.053 + t * 1.1) * 0.22 + cos(u * 18.850 + v + t * 1.7) * 0.10) * capsuleH * 0.38 * envelope * breathe;
    vec2 flow = vec2(dx / aspect, dy);

    vec2 baseUv = clamp(src + flow, vec2(0.003), vec2(0.997));

    // ---- 轻度磨砂：5 点固定采样（手写展开，循环内采样在部分驱动上会出问题）----
    float depth = clamp(-d / capsuleH, 0.0, 1.0);          // 0=边界 1=中心
    float sp = (0.0016 + 0.0012 * (1.0 - depth)) * shortScale;
    vec2 sx = vec2(sp / aspect, 0.0);
    vec2 sy = vec2(0.0, sp);
    vec3 c0 = texture2D(uTexSampler, baseUv).rgb;
    vec3 c1 = texture2D(uTexSampler, clamp(baseUv + sx, vec2(0.003), vec2(0.997))).rgb;
    vec3 c2 = texture2D(uTexSampler, clamp(baseUv - sx, vec2(0.003), vec2(0.997))).rgb;
    vec3 c3 = texture2D(uTexSampler, clamp(baseUv + sy, vec2(0.003), vec2(0.997))).rgb;
    vec3 c4 = texture2D(uTexSampler, clamp(baseUv - sy, vec2(0.003), vec2(0.997))).rgb;
    vec3 glass = (c0 * 2.0 + c1 + c2 + c3 + c4) / 6.0;

    // ---- 色散：边缘更明显 ----
    float rim = 1.0 - smoothstep(0.0, 0.18, depth);
    float disp = (0.0014 + 0.0022 * rim) * shortScale / aspect;
    glass.r = mix(glass.r, texture2D(uTexSampler, clamp(baseUv + vec2(disp, 0.0), vec2(0.003), vec2(0.997))).r, 0.65);
    glass.b = mix(glass.b, texture2D(uTexSampler, clamp(baseUv - vec2(disp, 0.0), vec2(0.003), vec2(0.997))).b, 0.65);

    // ---- 玻璃本体：极轻的提亮与冷调，保证底下内容始终看得清 ----
    glass = mix(glass, vec3(1.0), 0.05);
    glass *= vec3(0.98, 0.99, 1.04);

    // ---- 边缘描边：只在上缘和下缘发光（对应静态图的渐变描边），左右中段不发光，
    //      这样不会出现"整圈发光"那种廉价感 ----
    float rimW = 1.0 - smoothstep(0.0, 0.055, depth);
    float upper = smoothstep(0.0, 0.32, -local.y);
    float lower = smoothstep(0.0, 0.32, local.y);
    glass += vec3(1.0) * rimW * (upper * 0.55 + lower * 0.42) * 0.42;

    gl_FragColor = vec4(clamp(glass, 0.0, 1.0), 1.0);
}

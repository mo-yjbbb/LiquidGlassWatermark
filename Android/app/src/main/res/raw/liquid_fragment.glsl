precision highp float;
uniform sampler2D uTexSampler;
uniform float uAspect;        // 输出画布的宽高比（= 输入视频的宽高比）
uniform float uTargetAspect;  // 静态图的宽高比
uniform float uTime;
varying vec2 vTexSamplingCoord;

// 编写约束（踩过的坑，别改回去）：
// 1) 不要用 pow(x, 2.0)：GLSL 中 x<0 时结果未定义（NaN），会让整块像素变黑。用 x*x。
// 2) 不要在循环里做纹理采样：部分 GLSL ES 1.0 驱动对此支持很差。一律手写展开。
// 3) smoothstep(edge0, edge1, x) 必须 edge0 < edge1，反向写法结果未定义。
// 4) SDF 参数里出现负数会让形状彻底崩坏，所有尺寸项都要夹住下限。
// 5) 变量必须先声明再使用，分支里用到的要提前算好。
// 6) uniform 未赋值时默认为 0，需要时要用 step/mix 兜底。

float roundedBoxSdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 uv = vTexSamplingCoord;
    float t = uTime;
    float aspect = max(uAspect, 0.0001);
    // 静态图比例未设置时退化为画布比例，保证安全区 = 整个画布
    float target = mix(aspect, max(uTargetAspect, 0.0001), step(0.01, uTargetAspect));

    // ---- 安全区：输出画布内、按静态图比例居中的最大矩形 ----
    // 视频分辨率往往和静态图不同，相册播放时会把视频拉伸或 centerCrop 到静态图的显示
    // 区域。把胶囊画在这个安全区里，两种情况都不会变形：
    //   拉伸     -> 安全区被拉满整屏，胶囊正好恢复成静态图上的比例
    //   centerCrop -> 安全区就是可见区域，胶囊完整可见
    float wide = step(target, aspect);
    float safeW = mix(1.0, target / aspect, wide);
    float safeH = mix(aspect / target, 1.0, wide);

    // 安全区的短边，换算成"画布高度为 1"的归一化单位
    float shortUv = min(safeH, safeW * aspect);

    // 与 LiquidGlassRenderer 同一套比例：短边 1.2% 边距、13.5% 高度、圆角 = 半高
    float marginY = 0.012 * shortUv;
    float capsuleH = 0.135 * shortUv;
    float marginX = marginY / aspect;

    float bottom = 0.5 - safeH * 0.5 + marginY;
    float top = bottom + capsuleH;
    float left = 0.5 - safeW * 0.5 + marginX;
    float right = 0.5 + safeW * 0.5 - marginX;

    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);
    vec2 halfSize = vec2(max(right - left, 0.002) * 0.5, capsuleH * 0.5);
    float radius = capsuleH * 0.5;              // 正半圆端头

    float d = roundedBoxSdf(uv - center, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, uv);
        return;
    }

    vec2 local = (uv - center) / vec2(max(right - left, 0.002), capsuleH);
    float u = local.x + 0.5;                    // 0..1 沿胶囊长轴
    float v = local.y + 0.5;                    // 0..1 沿胶囊短轴
    float envelope = sin(3.14159265 * v);       // 上下缘为 0、中间最强

    // ---- 折射扭曲：沿用 LiquidGlassRenderer.drawLiquidMesh 的公式，位移幅度与静态图
    //      一致（约 0.4 倍胶囊高），只额外叠加时间相位让液面流动 ----
    float e0 = u / 0.115;
    float e1 = (u - 1.0) / 0.115;
    float endLens = exp(-e0 * e0) - exp(-e1 * e1);
    float breathe = 0.88 + 0.12 * sin(t * 0.9);
    float dx = (sin(u * 25.1327 + v * 2.2 + t * 1.5) * 0.095 + endLens * 0.30) * capsuleH * envelope * breathe;
    float dy = (sin(u * 10.053 + t * 1.1) * 0.22 + cos(u * 18.850 + v + t * 1.7) * 0.10) * capsuleH * 0.38 * envelope * breathe;
    vec2 flow = vec2(dx / aspect, dy);

    vec2 baseUv = clamp(uv + flow, vec2(0.003), vec2(0.997));

    // ---- 轻度磨砂：5 点固定采样 ----
    float depth = clamp(-d / capsuleH, 0.0, 1.0);          // 0=边界 1=中心
    float sp = (0.0016 + 0.0012 * (1.0 - depth)) * shortUv;
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
    float disp = (0.0014 + 0.0022 * rim) * shortUv / aspect;
    glass.r = mix(glass.r, texture2D(uTexSampler, clamp(baseUv + vec2(disp, 0.0), vec2(0.003), vec2(0.997))).r, 0.65);
    glass.b = mix(glass.b, texture2D(uTexSampler, clamp(baseUv - vec2(disp, 0.0), vec2(0.003), vec2(0.997))).b, 0.65);

    // ---- 玻璃本体：极轻的提亮与冷调 ----
    glass = mix(glass, vec3(1.0), 0.05);
    glass *= vec3(0.98, 0.99, 1.04);

    // ---- 边缘描边：只在上缘和下缘发光（对应静态图的渐变描边），左右中段不发光 ----
    float rimW = 1.0 - smoothstep(0.0, 0.055, depth);
    float upper = smoothstep(0.0, 0.32, -local.y);
    float lower = smoothstep(0.0, 0.32, local.y);
    glass += vec3(1.0) * rimW * (upper * 0.55 + lower * 0.42) * 0.42;

    gl_FragColor = vec4(clamp(glass, 0.0, 1.0), 1.0);
}

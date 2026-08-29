precision highp float;
uniform sampler2D uTexSampler;
uniform float uAspect;
uniform float uTime;
varying vec2 vTexSamplingCoord;

float roundedBoxSdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 uv = vTexSamplingCoord;
    float t = uTime;
    float shortScale = min(1.0, uAspect);
    float marginY = 0.012 * shortScale;
    float capsuleH = 0.135 * shortScale;
    float marginX = 0.012 / max(uAspect, 0.0001);
    float left = marginX;
    float right = 1.0 - marginX;
    float bottom = marginY;
    float top = bottom + capsuleH;
    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);
    vec2 halfSize = vec2((right-left)*0.5, capsuleH*0.5);
    float radius = capsuleH * 0.47;
    float d = roundedBoxSdf(uv-center, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, uv);
        return;
    }

    vec2 local = (uv-center) / vec2(max(right-left, 0.001), capsuleH);
    float verticalEnvelope = sin(clamp((uv.y-bottom)/capsuleH, 0.0, 1.0)*3.14159265);
    float endLens = exp(-pow((local.x+0.5)/0.115,2.0)) - exp(-pow((local.x-0.5)/0.115,2.0));
    // 呼吸：折射强度随时间起伏，像液面缓慢涨落
    float breathe = 0.78 + 0.22*sin(t*0.9);
    // 波浪相位随时间漂移，液态流动感
    float waveX = sin((local.x+0.5)*25.1327 + local.y*2.2 + t*1.7) * 0.095 * breathe;
    float waveY = (sin((local.x+0.5)*10.053 + t*1.1) * 0.050
                 + cos((local.x+0.5)*18.850 + local.y + t*1.9) * 0.025) * breathe;
    vec2 bend = vec2((waveX + endLens*0.30) * capsuleH / max(uAspect,0.001), waveY*capsuleH) * verticalEnvelope;
    vec2 displaced = clamp(uv + bend, vec2(0.001), vec2(0.999));

    // 色散强度周期涨落：色散像光在液面晃动一样时强时弱
    float spectral = (0.00095 + 0.00075*(0.5+0.5*sin(t*1.25))) * shortScale;
    vec3 base;
    base.r = texture2D(uTexSampler, displaced + vec2(spectral/max(uAspect,0.001),0.0)).r;
    base.g = texture2D(uTexSampler, displaced).g;
    base.b = texture2D(uTexSampler, displaced - vec2(spectral/max(uAspect,0.001),0.0)).b;

    vec2 px = vec2(0.0012/max(uAspect,0.001), 0.0012);
    vec3 sx = texture2D(uTexSampler, displaced+px).rgb - texture2D(uTexSampler, displaced-px).rgb;
    vec3 sy = texture2D(uTexSampler, displaced+px.yx).rgb - texture2D(uTexSampler, displaced-px.yx).rgb;
    vec3 photoReflection = abs(sx)+abs(sy);
    base = 1.0-(1.0-base)*(1.0-photoReflection*0.22);

    float y = clamp((uv.y-bottom)/capsuleH,0.0,1.0);
    float edge = smoothstep(0.055,0.0,min(y,1.0-y));
    float sideFade = smoothstep(0.0,0.20,abs(local.x));
    vec3 sampledLight = texture2D(uTexSampler, displaced).rgb;
    vec3 highlight = mix(vec3(1.0), sampledLight*1.35+0.25,0.38);
    // 高光微闪：镜面反光沿胶囊缓慢游走
    float shimmer = 0.40 + 0.16*sin(t*2.1 + local.x*3.0);
    base = 1.0-(1.0-base)*(1.0-highlight*edge*sideFade*shimmer);

    // 彩虹色带随时间缓慢平移漂移（衍射色散的动态感）
    float rx = local.x + 0.06*sin(t*0.6);
    vec3 rainbow = vec3(0.30,0.75,1.0)*max(0.0,0.35-rx-local.y)*0.018
                 + vec3(0.86,0.42,1.0)*max(0.0,0.30-abs(rx))*0.020
                 + vec3(1.0,0.72,0.30)*max(0.0,0.35+rx+local.y)*0.014;
    base = 1.0-(1.0-base)*(1.0-rainbow);
    base = mix(base, vec3(1.0), 0.03);
    gl_FragColor = vec4(base,1.0);
}

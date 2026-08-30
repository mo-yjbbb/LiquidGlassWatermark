precision highp float;
uniform sampler2D uTexSampler;
uniform float uAspect;
uniform float uTargetAspect;
varying vec2 vTexSamplingCoord;

float roundedBoxSdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 uv = vTexSamplingCoord;
    float aspect = max(uAspect, 0.0001);
    float target = mix(aspect, max(uTargetAspect, 0.0001), step(0.01, uTargetAspect));

    float wide = step(target, aspect);
    float safeW = mix(1.0, target / aspect, wide);
    float safeH = mix(aspect / target, 1.0, wide);
    float shortUv = min(safeH, safeW * aspect);
    float marginY = 0.012 * shortUv;
    float capsuleH = 0.135 * shortUv;
    float marginX = marginY / aspect;

    float bottom = 0.5 - safeH * 0.5 + marginY;
    float top = bottom + capsuleH;
    float left = 0.5 - safeW * 0.5 + marginX;
    float right = 0.5 + safeW * 0.5 - marginX;
    vec2 center = vec2((left + right) * 0.5, (bottom + top) * 0.5);

    // SDF is evaluated in physical units. This keeps the ends perfectly
    // semicircular at every video aspect ratio.
    vec2 physical = vec2((uv.x - center.x) * aspect, uv.y - center.y);
    vec2 halfSize = vec2(max(right-left, 0.002) * 0.5 * aspect, capsuleH * 0.5);
    float radius = capsuleH * 0.5;
    float d = roundedBoxSdf(physical, halfSize, radius);
    if (d > 0.0) {
        gl_FragColor = texture2D(uTexSampler, uv);
        return;
    }

    // Stationary optical displacement from the capsule surface normals.
    // No time/noise/sine waves: every displaced pixel is sampled from the
    // current photo/video frame directly below this physical lens.
    float ny = (uv.y - center.y) / max(capsuleH * 0.5, 0.0001);
    float endDistance = min((uv.x-left)*aspect, (right-uv.x)*aspect) / max(capsuleH,0.0001);
    float endInfluence = clamp(1.0-endDistance/0.50, 0.0, 1.0);
    float nx = uv.x < center.x ? -1.0 : 1.0;
    float lensProfile = 0.34+0.66*pow(abs(ny),1.25);
    vec2 flow = vec2(nx*endInfluence*max(0.0,1.0-ny*ny)*capsuleH*0.215/aspect,
                     ny*(1.0-0.24*endInfluence)*lensProfile*capsuleH*0.135);
    vec2 baseUv = clamp(uv-flow, vec2(0.003), vec2(0.997));

    float depth = clamp(-d / max(capsuleH,0.0001), 0.0, 1.0);
    float sp = (0.0010 + 0.0007*(1.0-depth))*shortUv;
    vec2 sx = vec2(sp/aspect,0.0);
    vec2 sy = vec2(0.0,sp);
    vec3 c0 = texture2D(uTexSampler,baseUv).rgb;
    vec3 c1 = texture2D(uTexSampler,clamp(baseUv+sx,vec2(0.003),vec2(0.997))).rgb;
    vec3 c2 = texture2D(uTexSampler,clamp(baseUv-sx,vec2(0.003),vec2(0.997))).rgb;
    vec3 c3 = texture2D(uTexSampler,clamp(baseUv+sy,vec2(0.003),vec2(0.997))).rgb;
    vec3 c4 = texture2D(uTexSampler,clamp(baseUv-sy,vec2(0.003),vec2(0.997))).rgb;
    vec3 glass = (c0*3.0+c1+c2+c3+c4)/7.0;

    // Reflection, RGB dispersion and diffraction all use the full capsule mask.
    vec3 photoReflection = abs(c1-c2)+abs(c3-c4);
    glass = 1.0-(1.0-glass)*(1.0-photoReflection*0.42);

    float rim = 1.0-smoothstep(0.0,0.18,depth);
    float dispersion = (0.0022+0.0025*rim)*shortUv/aspect;
    glass.r = mix(glass.r,texture2D(uTexSampler,clamp(baseUv+vec2(dispersion,0.0),vec2(0.003),vec2(0.997))).r,0.82);
    glass.b = mix(glass.b,texture2D(uTexSampler,clamp(baseUv-vec2(dispersion,0.0),vec2(0.003),vec2(0.997))).b,0.82);

    float lx=(uv.x-center.x)/max(right-left,0.002);
    float spectrumPos=clamp(0.5+lx+ny*0.12,0.0,1.0);
    vec3 spectrum=mix(vec3(0.20,0.58,1.0),vec3(1.0,0.30,0.62),spectrumPos);
    spectrum=mix(spectrum,vec3(1.0,0.72,0.22),smoothstep(0.70,1.0,spectrumPos));
    glass=1.0-(1.0-glass)*(1.0-spectrum*0.032);

    glass = mix(glass,vec3(1.0),0.03);

    // A thin boundary highlight, restricted to the horizontal top/bottom
    // and fading through the corners. It must never become an inner ring.
    float rimW = 1.0-smoothstep(0.0,0.018,depth);
    float upper = smoothstep(0.0,0.96,-ny);
    float lower = smoothstep(0.0,0.96, ny);
    vec3 sampledLight = texture2D(uTexSampler,baseUv).rgb;
    vec3 highlight = mix(vec3(1.0),sampledLight*1.25+0.18,0.36);
    glass = 1.0-(1.0-glass)*(1.0-highlight*rimW*(upper*0.55+lower*0.46)*0.38);
    gl_FragColor = vec4(clamp(glass,0.0,1.0),1.0);
}

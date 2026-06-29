//
//  Shaders.metal
//  MRIcroX
//
//  Metal Shading Language port of the OpenGL renderer's GLSL shaders.
//  This file replaces the loose .frag bundle resources; it is compiled into
//  default.metallib by the Metal build phase and shared by the macOS and iPad
//  targets (unified renderer).
//
//  Status (Metal/iPad port):
//   - [x] passthrough vertex + default ray-cast (this file)
//   - [x] advanced_MR / advanced_CT fragment paths
//   - [x] Sobel gradient as a compute kernel
//   - [x] 2D slice / line / colored-quad / text pipelines
//
//  Translation notes (GLSL 120 -> MSL):
//   - `varying vColor`        -> stage_in member, set by the vertex stage
//   - `uniform ...`           -> a single `VolumeUniforms` constant buffer
//   - `sampler3D`             -> texture3d<float> + sampler
//   - `texture3D(v, p)`       -> v.sample(samp, p)
//   - `gl_FragColor`          -> fragment function return value
//   - `gl_FragCoord.xy`       -> the [[position]] input (framebuffer coords)
//   - `ftransform()`          -> mvp * float4(position, 1.0) (CPU-built MVP)
//   GLSL default uniform values are made explicit on the CPU side instead.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors the uniforms of the ray-cast shaders. Field order/packing MUST match
// NIIVolumeUniforms in NIIMetalRenderer.h exactly (keep both in sync). Layout is
// arranged matrices->float4->float3->float run->int to keep 16-byte alignment
// identical between MSL and simd.
struct VolumeUniforms {
    float4x4   mvp;            // model-view-projection (replaces ftransform / matrix stack)
    float3x3   normalMatrix;   // advanced: inverse(rot*scale) 3x3 for gradient->normal
    float4     clipPlane;      // xyz = plane normal, w = offset (>1.0 disables clipping)
    float3     rayDir;         // normalized cube-space ray direction
    float3     textureSz;      // volume dims; x<1 signals "no volume"
    float3     lightPosition;  // advanced: view-centered light direction
    float      stepSize;       // ray march step (cube-space)
    float      sliceSize;      // smallest voxel edge (cube-space) for opacity correction
    float      clipThick;      // slab thickness for clip plane (GLSL default 2.0)
    float      overlayClip;    // GLSL default 0.0
    float      overlayFuzzy;   // GLSL default 0.5
    float      overlayDepth;   // GLSL default 0.3
    float      brighten;       // advanced MR (default 1.5)
    float      surfaceColor;   // advanced MR (default 1.0)
    float      backAlpha;      // advanced MR (default 0.95)
    float      ambient;        // advanced CT (default 0.8)
    float      diffuse;        // advanced CT (default 0.3)
    float      specular;       // advanced CT (default 0.1)
    float      shininess;      // advanced CT (default 20.0)
    float      surfaceHardness;// advanced CT (default 0.75)
    int        overlays;       // number of active overlays
};

struct VertexIn {
    float3 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 vColor;   // cube-space entry coordinate, == vertex position (0..1)
};

// Passthrough vertex stage: equivalent to vert_default in nii_render.m
// (vColor = gl_Vertex.xyz; gl_Position = ftransform();).
vertex VertexOut volumeVertex(VertexIn in [[stage_in]],
                              constant VolumeUniforms& u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.vColor   = in.position;
    return out;
}

// Linear, clamp-to-edge sampler matching the OpenGL 3D texture parameters
// (GL_LINEAR + GL_CLAMP_TO_EDGE on S/T/R) set in nii_render.m bindSubGL.
constexpr sampler volSampler(filter::linear,
                             mip_filter::none,
                             address::clamp_to_edge);
// Nearest-neighbour variant for 2D slices when smoothing is off (isSmooth2D).
constexpr sampler volSamplerNearest(filter::nearest,
                                    mip_filter::none,
                                    address::clamp_to_edge);

// --- ray helpers (1:1 with default_shader.frag) ---------------------------

static float3 GetBackPosition(float3 startPosition, float3 rayDir) {
    float3 invR = 1.0 / rayDir;
    float3 tbot = invR * (float3(0.0) - startPosition);
    float3 ttop = invR * (float3(1.0) - startPosition);
    float3 tmax = max(ttop, tbot);
    float2 t = min(tmax.xx, tmax.yz);
    return startPosition + (rayDir * min(t.x, t.y));
}

static void fastPass(float len, float3 dir, texture3d<float> vol,
                     thread float4& samplePos, constant VolumeUniforms& u) {
    float adv = max(u.stepSize, u.sliceSize * 1.95);
    float4 deltaDir = float4(dir.xyz * adv, adv);
    while (vol.sample(volSampler, samplePos.xyz).a < 0.01) {
        samplePos += deltaDir;
        if (samplePos.a > len) return;
    }
    samplePos -= deltaDir;
}

static float4 applyClip(float3 dir, thread float4& samplePos, thread float& len,
                        constant VolumeUniforms& u) {
    float cdot = dot(dir, u.clipPlane.xyz);
    if ((u.clipPlane.a > 1.0) || (cdot == 0.0)) return samplePos;
    bool frontface = (cdot > 0.0);
    float dis = (-u.clipPlane.a - dot(u.clipPlane.xyz, samplePos.xyz - 0.5)) / cdot;
    float disBackFace = (-(u.clipPlane.a - u.clipThick) - dot(u.clipPlane.xyz, samplePos.xyz - 0.5)) / cdot;
    if ((frontface && (dis >= len)) || (!frontface && (dis <= 0.0))) {
        samplePos.a = len + 1.0;
        return samplePos;
    }
    if (frontface) {
        dis = max(0.0, dis);
        samplePos = float4(samplePos.xyz + dir * dis, dis);
        len = min(disBackFace, len);
    }
    if (!frontface) {
        len = min(dis, len);
        disBackFace = max(0.0, disBackFace);
        samplePos = float4(samplePos.xyz + dir * disBackFace, disBackFace);
    }
    return samplePos;
}

// Pseudo-random ray jitter; matches the GLSL fract(sin(dot)) hash.
static float jitter(float2 fragCoord) {
    return fract(sin(fragCoord.x * 12.9898 + fragCoord.y * 78.233) * 43758.5453);
}

// --- default ray-cast fragment (port of default_shader.frag main()) -------

fragment float4 volumeFragmentDefault(VertexOut in [[stage_in]],
                                      constant VolumeUniforms& u [[buffer(1)]],
                                      texture3d<float> intensityVol   [[texture(0)]],
                                      texture3d<float> intensityOverlay[[texture(1)]]) {
    float2 fragCoord = in.position.xy;
    float3 start = in.vColor;
    float3 backPosition = GetBackPosition(start, u.rayDir);
    float3 dir = backPosition - start;
    float len = length(dir);
    dir = normalize(dir);
    float4 deltaDir = float4(dir.xyz * u.stepSize, u.stepSize);
    float4 colorSample;
    float bgNearest = len; // assume no hit
    float4 colAcc = float4(0.0);

    float noClipLen = len;
    float4 samplePos = float4(start.xyz, 0.0);
    float4 clipPos = applyClip(dir, samplePos, len, u);
    float opacityCorrection = u.stepSize / u.sliceSize;

    // fast pass - optional
    fastPass(len, dir, intensityVol, samplePos, u);
    if ((u.textureSz.x < 1) || ((samplePos.a > len) && (u.overlays < 1))) { // no hit
        return colAcc;
    }
    if (samplePos.a < clipPos.a) {
        samplePos = clipPos;
        bgNearest = clipPos.a;
        float stepSizeX2 = samplePos.a + (u.stepSize * 2.0);
        while (samplePos.a <= stepSizeX2) {
            colorSample = intensityVol.sample(volSampler, samplePos.xyz);
            colorSample.a = 1.0 - pow((1.0 - colorSample.a), opacityCorrection);
            colorSample.a = clamp(colorSample.a * 3.0, 0.0, 1.0);
            colorSample.rgb *= colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            samplePos += deltaDir;
        }
    }
    // jitter ray
    samplePos += deltaDir * jitter(fragCoord);
    deltaDir = float4(dir.xyz * u.stepSize, u.stepSize);
    while (samplePos.a <= len) {
        colorSample = intensityVol.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            colorSample.a = 1.0 - pow((1.0 - colorSample.a), opacityCorrection);
            bgNearest = min(samplePos.a, bgNearest);
            colorSample.rgb *= colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            if (colAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    colAcc.a = colAcc.a / 0.95;
    if (u.overlays < 1) {
        return colAcc;
    }

    // overlay pass
    float4 overAcc = float4(0.0);
    if (u.overlayClip > 0)
        samplePos = clipPos;
    else {
        len = noClipLen;
        samplePos = float4(start.xyz + deltaDir.xyz * jitter(fragCoord), 0.0);
    }
    clipPos = samplePos;
    fastPass(len, dir, intensityOverlay, samplePos, u);
    if (samplePos.a > len) { // no hit
        return colAcc;
    }
    if (samplePos.a < clipPos.a)
        samplePos = clipPos;
    float overFarthest = len;
    while (samplePos.a <= len) {
        colorSample = intensityOverlay.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            if (overAcc.a < 0.3)
                overFarthest = samplePos.a;
            colorSample.a = 1.0 - pow((1.0 - colorSample.a), u.stepSize / u.sliceSize);
            colorSample.a *= u.overlayFuzzy;
            colorSample.rgb *= colorSample.a;
            overAcc = (1.0 - overAcc.a) * colorSample + overAcc;
            if (overAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    overAcc.a = overAcc.a / 0.95;
    float overMix = overAcc.a;
    if (((overFarthest) > bgNearest) && (colAcc.a > 0.0)) { // background (partially) occludes overlay
        float dx = (overFarthest - bgNearest) / 1.73;
        dx = colAcc.a * pow(dx, u.overlayDepth);
        overMix *= 1.0 - dx;
    }
    colAcc.rgb = mix(colAcc.rgb, overAcc.rgb, overMix);
    colAcc.a = max(colAcc.a, overAcc.a);
    return colAcc;
}

// --- advanced MR fragment (port of advanced_MR_shader.frag) ---------------
// Gradient-based matcap lighting for the background; Phong for the overlay.

fragment float4 volumeFragmentAdvancedMR(VertexOut in [[stage_in]],
                                         constant VolumeUniforms& u [[buffer(1)]],
                                         texture3d<float> intensityVol    [[texture(0)]],
                                         texture3d<float> intensityOverlay[[texture(1)]],
                                         texture3d<float> gradientVol     [[texture(2)]],
                                         texture3d<float> gradientOverlay [[texture(3)]],
                                         texture2d<float> matcap2D        [[texture(4)]]) {
    float2 fragCoord = in.position.xy;
    float3 start = in.vColor;
    float3 dir = GetBackPosition(start, u.rayDir) - start;
    float len = length(dir);
    dir = normalize(dir);
    float4 deltaDir = float4(dir * u.stepSize, u.stepSize);
    float4 gradSample, colorSample;
    float bgNearest = len;
    float4 colAcc = float4(0.0), prevGrad = float4(0.0);
    float noClipLen = len;
    float4 samplePos = float4(start, 0.0);
    float4 clipPos = applyClip(dir, samplePos, len, u);
    float opacityCorrection = u.stepSize / u.sliceSize;
    fastPass(len, dir, intensityVol, samplePos, u);
    if ((u.textureSz.x < 1) || ((samplePos.a > len) && (u.overlays < 1))) return colAcc;
    if (samplePos.a < clipPos.a) {
        samplePos = clipPos; bgNearest = clipPos.a;
        float stepSizeX2 = samplePos.a + u.stepSize * 2.0;
        while (samplePos.a <= stepSizeX2) {
            colorSample = intensityVol.sample(volSampler, samplePos.xyz);
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, opacityCorrection);
            colorSample.a = clamp(colorSample.a * 3.0, 0.0, 1.0);
            colorSample.rgb *= colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            samplePos += deltaDir;
        }
    }
    float ran = jitter(fragCoord);
    samplePos += deltaDir * ran;
    int nHit = 0;
    float3 defaultDiffuse = float3(0.5);
    while (samplePos.a <= len) {
        colorSample = intensityVol.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, opacityCorrection);
            if (nHit < 1) { nHit++; bgNearest = samplePos.a; }
            gradSample = gradientVol.sample(volSampler, samplePos.xyz);
            gradSample.rgb = normalize(gradSample.rgb * 2.0 - 1.0);
            if (gradSample.a < prevGrad.a) gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            float3 n = normalize(u.normalMatrix * gradSample.rgb);
            float3 dmc = matcap2D.sample(volSampler, n.xy * 0.5 + 0.5).rgb;
            float3 surf = mix(defaultDiffuse, colorSample.rgb, u.surfaceColor);
            colorSample.rgb = dmc * surf * u.brighten * colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            if (colAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    colAcc.a = (colAcc.a / 0.95) * u.backAlpha;
    if (u.overlays < 1) return colAcc;
    // overlay pass (Phong, fixed coefficients per the GLSL)
    float overFarthest = len;
    float ambient = 1.0, diffuse = 0.3, specular = 0.25, shininess = 10.0;
    float4 overAcc = float4(0.0);
    prevGrad = float4(0.0);
    if (u.overlayClip > 0) samplePos = clipPos;
    else { len = noClipLen; samplePos = float4(start + deltaDir.xyz * ran, 0.0); }
    clipPos = samplePos;
    fastPass(len, dir, intensityOverlay, samplePos, u);
    if (samplePos.a < clipPos.a) samplePos = clipPos;
    while (samplePos.a <= len) {
        colorSample = intensityOverlay.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            if (overAcc.a < 0.3) overFarthest = samplePos.a;
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, opacityCorrection);
            colorSample.a *= u.overlayFuzzy;
            gradSample = gradientOverlay.sample(volSampler, samplePos.xyz);
            gradSample.rgb = normalize(gradSample.rgb * 2.0 - 1.0);
            if (gradSample.a < prevGrad.a) gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            float lightNormDot = dot(gradSample.rgb, u.lightPosition);
            float3 a = colorSample.rgb * ambient;
            float3 dd = max(lightNormDot, 0.0) * colorSample.rgb * diffuse;
            float s = specular * pow(max(dot(reflect(u.lightPosition, gradSample.rgb), dir), 0.0), shininess);
            colorSample.rgb = (a + dd + s) * colorSample.a;
            overAcc = (1.0 - overAcc.a) * colorSample + overAcc;
            if (overAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    overAcc.a = overAcc.a / 0.95;
    float overMix = overAcc.a;
    if ((overFarthest > bgNearest) && (colAcc.a > 0.0)) {
        float dx = (overFarthest - bgNearest) / 1.73;
        dx = colAcc.a * pow(dx, u.overlayDepth);
        overMix *= 1.0 - dx;
    }
    colAcc.rgb = mix(colAcc.rgb, overAcc.rgb, overMix);
    colAcc.a = max(colAcc.a, overAcc.a);
    return colAcc;
}

// --- advanced CT fragment (port of advanced_CT_shader.frag) ----------------
// Phong lighting + a "surface hardness" highlight of the strongest gradient.

fragment float4 volumeFragmentAdvancedCT(VertexOut in [[stage_in]],
                                         constant VolumeUniforms& u [[buffer(1)]],
                                         texture3d<float> intensityVol    [[texture(0)]],
                                         texture3d<float> intensityOverlay[[texture(1)]],
                                         texture3d<float> gradientVol     [[texture(2)]],
                                         texture3d<float> gradientOverlay [[texture(3)]]) {
    float2 fragCoord = in.position.xy;
    float3 start = in.vColor;
    float3 dir = GetBackPosition(start, u.rayDir) - start;
    float len = length(dir);
    dir = normalize(dir);
    float4 deltaDir = float4(dir * u.stepSize, u.stepSize);
    float4 gradSample, colorSample;
    float bgNearest = len;
    float4 colAcc = float4(0.0), prevGrad = float4(0.0);
    float noClipLen = len;
    float4 samplePos = float4(start, 0.0);
    float4 clipPos = applyClip(dir, samplePos, len, u);
    float opacityCorrection = u.stepSize / u.sliceSize;
    fastPass(len, dir, intensityVol, samplePos, u);
    if ((u.textureSz.x < 1) || ((samplePos.a > len) && (u.overlays < 1))) return colAcc;
    if (samplePos.a < clipPos.a) {
        samplePos = clipPos; bgNearest = clipPos.a;
        float stepSizeX2 = samplePos.a + u.stepSize * 2.0;
        while (samplePos.a <= stepSizeX2) {
            colorSample = intensityVol.sample(volSampler, samplePos.xyz);
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, opacityCorrection);
            colorSample.a = clamp(colorSample.a * 3.0, 0.0, 1.0);
            colorSample.rgb *= colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            samplePos += deltaDir;
        }
    }
    float ran = jitter(fragCoord);
    samplePos += deltaDir * ran;
    float3 lightN = normalize(u.lightPosition);
    float4 gradMax = float4(0.0), colorMax = float4(0.0);
    while (samplePos.a <= len) {
        colorSample = intensityVol.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, opacityCorrection);
            bgNearest = min(samplePos.a, bgNearest);
            gradSample = gradientVol.sample(volSampler, samplePos.xyz);
            gradSample.rgb = normalize(gradSample.rgb * 2.0 - 1.0);
            if (gradSample.a > gradMax.a) gradMax = gradSample;
            if (colorSample.a > colorMax.a) colorMax = colorSample;
            if (gradSample.a < prevGrad.a) gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            float3 a = colorSample.rgb * u.ambient;
            float3 dd = max(dot(gradSample.rgb, lightN), 0.0) * colorSample.rgb * u.diffuse;
            float s = u.specular * pow(max(dot(reflect(lightN, gradSample.rgb), dir), 0.0), u.shininess);
            colorSample.rgb = (a + dd + s) * colorSample.a;
            colAcc = (1.0 - colAcc.a) * colorSample + colAcc;
            if (colAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    colAcc.a = colAcc.a / 0.95;
    if ((samplePos.a < len) && (gradMax.a > 0.02) && (bgNearest > clipPos.a)) {
        float ambientCT = u.ambient * 0.65;
        float lightNormDot = dot(gradMax.rgb, lightN);
        float3 a = colorMax.rgb * ambientCT;
        float3 dd = max(lightNormDot, 0.0) * colorMax.rgb * u.diffuse;
        float s = u.specular * pow(max(dot(reflect(lightN, gradMax.rgb), dir), 0.0), u.shininess);
        colorMax.rgb = a + dd + s;
        colAcc.rgb = mix(colAcc.rgb, colorMax.rgb, u.surfaceHardness);
    }
    if (u.overlays < 1) return colAcc;
    float4 overAcc = float4(0.0);
    prevGrad = float4(0.0);
    if (u.overlayClip > 0) samplePos = clipPos;
    else { len = noClipLen; samplePos = float4(start + deltaDir.xyz * ran, 0.0); }
    clipPos = samplePos;
    fastPass(len, dir, intensityOverlay, samplePos, u);
    if (samplePos.a > len) return colAcc;
    if (samplePos.a < clipPos.a) samplePos = clipPos;
    float overFarthest = len;
    while (samplePos.a <= len) {
        colorSample = intensityOverlay.sample(volSampler, samplePos.xyz);
        if (colorSample.a > 0.0) {
            if (overAcc.a < 0.3) overFarthest = samplePos.a;
            colorSample.a = 1.0 - pow(1.0 - colorSample.a, u.stepSize / u.sliceSize);
            colorSample.a *= u.overlayFuzzy;
            float3 a = colorSample.rgb * u.ambient;
            gradSample = gradientOverlay.sample(volSampler, samplePos.xyz);
            gradSample.rgb = normalize(gradSample.rgb * 2.0 - 1.0);
            if (gradSample.a < prevGrad.a) gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            float lightNormDot = dot(gradSample.rgb, u.lightPosition);
            float3 dd = max(lightNormDot, 0.0) * colorSample.rgb * u.diffuse;
            float s = u.specular * pow(max(dot(reflect(u.lightPosition, gradSample.rgb), dir), 0.0), u.shininess);
            colorSample.rgb = (a + dd + s) * colorSample.a;
            overAcc = (1.0 - overAcc.a) * colorSample + overAcc;
            if (overAcc.a > 0.95) break;
        }
        samplePos += deltaDir;
    }
    overAcc.a = overAcc.a / 0.95;
    float overMix = overAcc.a;
    if ((overFarthest > bgNearest) && (colAcc.a > 0.0)) {
        float dx = (overFarthest - bgNearest) / 1.73;
        dx = colAcc.a * pow(dx, u.overlayDepth);
        overMix *= 1.0 - dx;
    }
    colAcc.rgb = mix(colAcc.rgb, overAcc.rgb, overMix);
    colAcc.a = max(colAcc.a, overAcc.a);
    return colAcc;
}

// ===========================================================================
// Gradient compute kernels (replace performBlurSobel's render-to-3D-texture).
// Two passes matching kBlurShaderFrag (2x2x2 box blur of alpha) then
// sobel_shader.frag (central-difference gradient + packed normal). Run over the
// whole volume in one dispatch each instead of per-Z-slice fullscreen quads.
// ===========================================================================

kernel void gradientBlur(texture3d<float, access::sample> intensity [[texture(0)]],
                         texture3d<float, access::write>  blurOut   [[texture(1)]],
                         uint3 gid [[thread_position_in_grid]]) {
    uint3 dim = uint3(blurOut.get_width(), blurOut.get_height(), blurOut.get_depth());
    if (gid.x >= dim.x || gid.y >= dim.y || gid.z >= dim.z) return;
    float3 d  = 0.5 / float3(dim);                 // dX/dY/dZ = 0.5/voxelDim
    float3 vx = (float3(gid) + 0.5) / float3(dim); // voxel-center texcoord
    float s = 0.0;
    s += intensity.sample(volSampler, vx + float3(+d.x,+d.y,+d.z)).a;
    s += intensity.sample(volSampler, vx + float3(+d.x,+d.y,-d.z)).a;
    s += intensity.sample(volSampler, vx + float3(+d.x,-d.y,+d.z)).a;
    s += intensity.sample(volSampler, vx + float3(+d.x,-d.y,-d.z)).a;
    s += intensity.sample(volSampler, vx + float3(-d.x,+d.y,+d.z)).a;
    s += intensity.sample(volSampler, vx + float3(-d.x,+d.y,-d.z)).a;
    s += intensity.sample(volSampler, vx + float3(-d.x,-d.y,+d.z)).a;
    s += intensity.sample(volSampler, vx + float3(-d.x,-d.y,-d.z)).a;
    blurOut.write(float4(0.0, 0.0, 0.0, s * 0.125), gid);
}

kernel void gradientSobel(texture3d<float, access::sample> blurred [[texture(0)]],
                          texture3d<float, access::write>  gradOut [[texture(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint3 dim = uint3(gradOut.get_width(), gradOut.get_height(), gradOut.get_depth());
    if (gid.x >= dim.x || gid.y >= dim.y || gid.z >= dim.z) return;
    float3 d  = 1.2 / float3(dim);                 // dX/dY/dZ = 1.2/voxelDim
    float3 vx = (float3(gid) + 0.5) / float3(dim);
    // T=+dX, B=-dX; A=+dY, P=-dY; R=+dZ, L=-dZ (matches sobel_shader.frag)
    float TAR = blurred.sample(volSampler, vx + float3(+d.x,+d.y,+d.z)).a;
    float TAL = blurred.sample(volSampler, vx + float3(+d.x,+d.y,-d.z)).a;
    float TPR = blurred.sample(volSampler, vx + float3(+d.x,-d.y,+d.z)).a;
    float TPL = blurred.sample(volSampler, vx + float3(+d.x,-d.y,-d.z)).a;
    float BAR = blurred.sample(volSampler, vx + float3(-d.x,+d.y,+d.z)).a;
    float BAL = blurred.sample(volSampler, vx + float3(-d.x,+d.y,-d.z)).a;
    float BPR = blurred.sample(volSampler, vx + float3(-d.x,-d.y,+d.z)).a;
    float BPL = blurred.sample(volSampler, vx + float3(-d.x,-d.y,-d.z)).a;
    float4 g;
    g.r = BAR+BAL+BPR+BPL - TAR-TAL-TPR-TPL;
    g.g = TPR+TPL+BPR+BPL - TAR-TAL-BAR-BAL;
    g.b = TAL+TPL+BAL+BPL - TAR-TPR-BAR-BPR;
    g.a = (abs(g.r)+abs(g.g)+abs(g.b)) * 0.5;
    float m = length(g.rgb);
    g.rgb = (m > 1e-6) ? (g.rgb / m) : float3(0.0);
    g.rgb = g.rgb * 0.5 + 0.5;
    gradOut.write(g, gid);
}

// ===========================================================================
// 2D slice pipeline (port of drawAx/drawCoro/drawSag in nii_img.mm)
//
// Each slice is a pixel-space quad sampling the 3D volume at fixed texcoords.
// The GL path used glOrtho(0,W,0,H), glColor3f(1,1,1) (passthrough), standard
// SRC_ALPHA/ONE_MINUS_SRC_ALPHA blending, and glAlphaFunc(GL_GREATER, 0.01)
// (a discard). Unlike the 3D ray-cast, the 2D color is NOT premultiplied.
// ===========================================================================

struct Slice2DUniforms {
    float4x4 mvp;   // ortho pixel-space projection (0..W, 0..H)
    int smooth;     // 1 = linear interpolation, 0 = nearest (isSmooth2D)
};

struct SliceVertexIn {
    float2 position [[attribute(0)]];
    float3 texcoord [[attribute(1)]];
};

struct SliceVertexOut {
    float4 position [[position]];
    float3 texcoord;
};

vertex SliceVertexOut sliceVertex(SliceVertexIn in [[stage_in]],
                                  constant Slice2DUniforms& u [[buffer(1)]]) {
    SliceVertexOut out;
    out.position = u.mvp * float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 sliceFragment(SliceVertexOut in [[stage_in]],
                              texture3d<float> vol [[texture(0)]],
                              constant Slice2DUniforms &u [[buffer(1)]]) {
    float4 c = u.smooth ? vol.sample(volSampler, in.texcoord)
                        : vol.sample(volSamplerNearest, in.texcoord);
    if (c.a <= 0.01) discard_fragment(); // glAlphaFunc(GL_GREATER, 0.01)
    return float4(c.rgb, 1.0); // opaque: GL disables blend for 2D slices
}

// ===========================================================================
// Line pipeline (port of drawXBar crosshairs / drawVectors DTI lines)
// Solid-color primitives in pixel space.
// ===========================================================================

struct LineUniforms {
    float4x4 mvp;
    float4   color;
};

struct LineVertexOut {
    float4 position [[position]];
};

vertex LineVertexOut lineVertex(const device float2* verts [[buffer(0)]],
                                constant LineUniforms& u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    LineVertexOut out;
    out.position = u.mvp * float4(verts[vid], 0.0, 1.0);
    return out;
}

fragment float4 lineFragment(constant LineUniforms& u [[buffer(1)]]) {
    return u.color;
}

// ===========================================================================
// Colored geometry pipeline (orientation cube DrawCube, colorbar gradient,
// histogram bars). Per-vertex color, transformed by an MVP. Used in 3D (cube)
// and 2D pixel space (colorbar/histogram).
// ===========================================================================

struct ColoredUniforms { float4x4 mvp; };

struct ColoredVertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct ColoredVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex ColoredVertexOut coloredVertex(ColoredVertexIn in [[stage_in]],
                                      constant ColoredUniforms& u [[buffer(1)]]) {
    ColoredVertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 coloredFragment(ColoredVertexOut in [[stage_in]]) {
    return in.color;
}

// ===========================================================================
// Text pipeline (replaces GLString). Samples a premultiplied-alpha glyph
// texture (rasterized from NSAttributedString) and tints it. Blended with
// One / OneMinusSrcAlpha to match GLString's premultiplied draw.
// ===========================================================================

struct TextUniforms {
    float4x4 mvp;
    float4   tint;
};

struct TextVertexIn {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct TextVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex TextVertexOut textVertex(TextVertexIn in [[stage_in]],
                                constant TextUniforms& u [[buffer(1)]]) {
    TextVertexOut out;
    out.position = u.mvp * float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 textFragment(TextVertexOut in [[stage_in]],
                             constant TextUniforms& u [[buffer(1)]],
                             texture2d<float> glyphs [[texture(0)]]) {
    return glyphs.sample(volSampler, in.texcoord) * u.tint;
}

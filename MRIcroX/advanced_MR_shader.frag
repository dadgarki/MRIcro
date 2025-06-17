#version 120
varying vec3 vColor;
uniform vec3 rayDir;
uniform int overlays;
uniform float stepSize, sliceSize;
uniform vec3 lightPosition;
uniform vec4 clipPlane;
uniform sampler3D intensityVol, gradientVol, intensityOverlay, gradientOverlay;
uniform float clipThick = 2.0;
uniform vec3 textureSz = vec3(3.0, 2.0, 1.0);
uniform float ambient = 0.8;
uniform float diffuse = 0.3;
uniform float specular = 0.1;
uniform float shininess= 20.0;
//uniform float backAlpha = 0.95;
uniform float overlayClip = 0.0;
uniform float overlayFuzzy = 0.5;
uniform float overlayDepth = 0.3;
vec3 GetBackPosition (vec3 startPosition) {
 vec3 invR = 1.0 / rayDir;
 vec3 tbot = invR * (vec3(0.0)-startPosition);
 vec3 ttop = invR * (vec3(1.0)-startPosition);
 vec3 tmax = max(ttop, tbot);
 vec2 t = min(tmax.xx, tmax.yz);
 return startPosition + (rayDir * min(t.x, t.y));
}
void fastPass (float len, vec3 dir, sampler3D vol, inout vec4 samplePos){
    vec4 deltaDir = vec4(dir.xyz * max(stepSize, sliceSize * 1.95), max(stepSize, sliceSize * 1.95));
    //samplePos.a = 0.0;
    while  (texture3D(intensityVol,samplePos.xyz).a < 0.01) {
        samplePos += deltaDir;
        if (samplePos.a > len) return;
    }
    samplePos -= deltaDir;
}
vec4 applyClip(vec3 dir, inout vec4 samplePos, inout float len) {
    float cdot = dot(dir,clipPlane.xyz);
    if  ((clipPlane.a > 1.0) || (cdot == 0.0)) return samplePos;
    bool frontface = (cdot > 0.0);
    float dis = (-clipPlane.a - dot(clipPlane.xyz, samplePos.xyz-0.5)) / cdot;
    float  disBackFace = (-(clipPlane.a-clipThick) - dot(clipPlane.xyz, samplePos.xyz-0.5)) / cdot;
    if (((frontface) && (dis >= len)) || ((!frontface) && (dis <= 0.0))) {
        samplePos.a = len + 1.0;
        return samplePos;
    }
    if (frontface) {
        dis = max(0.0, dis);
        samplePos = vec4(samplePos.xyz+dir * dis, dis);
        len = min(disBackFace, len);
    }
    if (!frontface) {
        len = min(dis, len);
        disBackFace = max(0.0, disBackFace);
        samplePos = vec4(samplePos.xyz+dir * disBackFace, disBackFace);
    }
    return samplePos;
}
void main() {
    vec3 start = vColor;//gl_TexCoord[1].xyz;
    vec3 backPosition = GetBackPosition(start);
    vec3 dir = backPosition - start;
    float len = length(dir);
    dir = normalize(dir);
    vec4 deltaDir = vec4(dir.xyz * stepSize, stepSize);
    vec4 gradSample, colorSample;
    float bgNearest = len; //assume no hit
    vec4 colAcc = vec4(0.0,0.0,0.0,0.0);
    vec4 prevGrad = vec4(0.0,0.0,0.0,0.0);
    //background pass
    float noClipLen = len;
    vec4 samplePos = vec4(start.xyz, 0.0);
    vec4 clipPos = applyClip(dir, samplePos, len);
    float stepSizeX2 = samplePos.a + (stepSize * 2.0);
    float opacityCorrection = stepSize/sliceSize;
    //fast pass - optional
    fastPass (len, dir, intensityVol, samplePos);
    if ((textureSz.x < 1) || ((samplePos.a > len) && ( overlays < 1 ))) { //no hit
        gl_FragColor = colAcc;
        return;
    }
    if (samplePos.a < clipPos.a) {
        samplePos = clipPos;
        bgNearest = clipPos.a;
        float stepSizeX2 = samplePos.a + (stepSize * 2.0);
        while (samplePos.a <= stepSizeX2) {
            colorSample = texture3D(intensityVol,samplePos.xyz);
            colorSample.a = 1.0-pow((1.0 - colorSample.a), opacityCorrection);
            colorSample.a = clamp(colorSample.a*3.0,0.0, 1.0);
            colorSample.rgb *= colorSample.a;
            colAcc= (1.0 - colAcc.a) * colorSample + colAcc;
            samplePos += deltaDir;
        }
        //gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); return;
    }
    //end fastpass - optional
    float ran = fract(sin(gl_FragCoord.x * 12.9898 + gl_FragCoord.y * 78.233) * 43758.5453);
    samplePos += deltaDir * ran; //jitter ray
    deltaDir = vec4(dir.xyz * stepSize, stepSize);
    vec3 defaultDiffuse = vec3(0.5, 0.5, 0.5);
    vec3 lightPositionN = normalize(lightPosition);
    //colAcc = vec4(0,0.2,0.0,0.0);//background
    while (samplePos.a <= len) {
        colorSample = texture3D(intensityVol,samplePos.xyz);
        if (colorSample.a > 0.0) {
            colorSample.a = 1.0-pow((1.0 - colorSample.a), opacityCorrection);
            bgNearest = min(samplePos.a,bgNearest);
            gradSample = texture3D(gradientVol,samplePos.xyz);
            gradSample.rgb = normalize(gradSample.rgb*2.0 - 1.0);
            if (gradSample.a < prevGrad.a)
                gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            vec3 a = colorSample.rgb * ambient;
            vec3 d = max(dot(gradSample.rgb, lightPositionN), 0.0) * colorSample.rgb * diffuse;
            float s =   specular * pow(max(dot(reflect(lightPositionN, gradSample.rgb), dir), 0.0), shininess);
            colorSample.rgb = (a + d + s) * colorSample.a;
            colAcc= (1.0 - colAcc.a) * colorSample + colAcc;
            if ( colAcc.a > 0.95 )
                break;
        }
        samplePos += deltaDir;
    } //while samplePos.a < len
    colAcc.a = colAcc.a/0.95;
    //colAcc.a *= backAlpha;
    if ( overlays < 1 ) {
        gl_FragColor = colAcc;
        return;
    }
    //overlay pass
    if (overlayClip > 0)
        samplePos = clipPos;
    else {
        len = noClipLen;
        samplePos = vec4(start.xyz +deltaDir.xyz* (fract(sin(gl_FragCoord.x * 12.9898 + gl_FragCoord.y * 78.233) * 43758.5453)), 0.0);
    }
    //fast pass - optional
    clipPos = samplePos;
    fastPass (len, dir, intensityOverlay, samplePos);
    if (samplePos.a > len) { //no hit
        gl_FragColor = colAcc;
        return;
    }
    if (samplePos.a < clipPos.a)
        samplePos = clipPos;
    //end fastpass - optional
    vec4 overAcc = vec4(0.0,0.0,0.0,0.0);
    prevGrad = vec4(0.0,0.0,0.0,0.0);
    float overFarthest = len;
    while (samplePos.a <= len) {
        colorSample = texture3D(intensityOverlay,samplePos.xyz);
        if (colorSample.a > 0.00) {
            if (overAcc.a < 0.3)
                overFarthest = samplePos.a;
            colorSample.a = 1.0-pow((1.0 - colorSample.a), stepSize/sliceSize);
            colorSample.a *=  overlayFuzzy;
            vec3 a = colorSample.rgb * ambient;
            float s =  0;
            vec3 d = vec3(0.0, 0.0, 0.0);
            gradSample = texture3D(gradientOverlay,samplePos.xyz); //interpolate gradient direction and magnitude
            gradSample.rgb = normalize(gradSample.rgb*2.0 - 1.0);
            if (gradSample.a < prevGrad.a)
                gradSample.rgb = prevGrad.rgb;
            prevGrad = gradSample;
            float lightNormDot = dot(gradSample.rgb, lightPosition);
            d = max(lightNormDot, 0.0) * colorSample.rgb * diffuse;
            s =   specular * pow(max(dot(reflect(lightPosition, gradSample.rgb), dir), 0.0), shininess);
            colorSample.rgb = a + d + s;
            colorSample.rgb *= colorSample.a;
            overAcc= (1.0 - overAcc.a) * colorSample + overAcc;
            if (overAcc.a > 0.95 )
                break;
        }
        samplePos += deltaDir;
    } //while samplePos.a < len
    overAcc.a = overAcc.a/0.95;
    float overMix = overAcc.a;
    if (((overFarthest) > bgNearest) && (colAcc.a > 0.0)) { //background (partially) occludes overlay
        float dx = (overFarthest - bgNearest)/1.73;
        dx = colAcc.a * pow(dx, overlayDepth);
        overMix *= 1.0 - dx;
    }
    colAcc.rgb = mix(colAcc.rgb, overAcc.rgb, overMix);
    colAcc.a = max(colAcc.a, overAcc.a);
    gl_FragColor = colAcc;
}


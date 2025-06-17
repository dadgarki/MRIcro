uniform float coordZ, dX, dY, dZ;
uniform sampler3D intensityVol;
void main(void) {
  vec3 vx = vec3(gl_TexCoord[0].xy, coordZ);
  float TAR = texture3D(intensityVol,vx+vec3(+dX,+dY,+dZ)).a;
  float TAL = texture3D(intensityVol,vx+vec3(+dX,+dY,-dZ)).a;
  float TPR = texture3D(intensityVol,vx+vec3(+dX,-dY,+dZ)).a;
  float TPL = texture3D(intensityVol,vx+vec3(+dX,-dY,-dZ)).a;
  float BAR = texture3D(intensityVol,vx+vec3(-dX,+dY,+dZ)).a;
  float BAL = texture3D(intensityVol,vx+vec3(-dX,+dY,-dZ)).a;
  float BPR = texture3D(intensityVol,vx+vec3(-dX,-dY,+dZ)).a;
  float BPL = texture3D(intensityVol,vx+vec3(-dX,-dY,-dZ)).a;
  vec4 gradientSample;
  gradientSample.r =   BAR+BAL+BPR+BPL -TAR-TAL-TPR-TPL;
  gradientSample.g =  TPR+TPL+BPR+BPL -TAR-TAL-BAR-BAL;
  gradientSample.b =  TAL+TPL+BAL+BPL -TAR-TPR-BAR-BPR;
  gradientSample.a = (abs(gradientSample.r)+abs(gradientSample.g)+abs(gradientSample.b))*0.5;
  gradientSample.rgb = normalize(gradientSample.rgb);
  gradientSample.rgb =  (gradientSample.rgb * 0.5)+0.5;
  gl_FragColor = gradientSample;
}

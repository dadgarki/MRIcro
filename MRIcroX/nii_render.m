//
//  nii_render.m
//  MRIpro
//
//  Created by Chris Rorden on 9/2/12.
//  Copyright 2012 U South Carolina. All rights reserved.
//

#import "nii_render.h"
#include "nii_io.h"
#include <math.h>
#include <stdio.h>
#include "nii_definetypes.h"
#import <OpenGL/glu.h>
//#include <GLKit/GLKMatrix4.h>
#import <Foundation/Foundation.h>

// Function to read a file into a string
char* read_file(const char* filename) {
    FILE* file = fopen(filename, "rb"); // Open in binary mode
    if (!file) {
        perror("Failed to open file");
        return NULL;
    }

    // Get file size
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);

    // Allocate buffer for the file content
    char* buffer = (char*)malloc(file_size + 1); // +1 for the null terminator
    if (!buffer) {
        perror("Failed to allocate memory");
        fclose(file);
        return NULL;
    }

    // Read file contents into buffer
    fread(buffer, 1, file_size, file);
    buffer[file_size] = '\0'; // Null-terminate the string

    fclose(file); // Close the file
    return buffer;
}

GLuint initVertFrag(const char *vert, const char *frag)
{
#ifdef MY_DEBUG //from nii_io.h
    printf("creating new shader\n");
#endif
    GLuint fr = glCreateShader(GL_FRAGMENT_SHADER);
    if (!fr)
        return 0;
    glShaderSource(fr, 1, &frag, NULL);
    glCompileShader(fr);
    GLint status = 0;
    glGetShaderiv(fr, GL_COMPILE_STATUS, &status);
    if(!status) { //report compiling errors.
        char str[4096];
        glGetShaderInfoLog(fr, sizeof(str), NULL, str);
        NSLog(@"GLSL Fragment shader compile error.");
        NSLog(@"%s", str);
        glDeleteShader(fr);
        return 0;
    }
    GLuint ProgramID = glCreateProgram();
    glAttachShader(ProgramID, fr);
    GLuint vt = 0;
    if (strlen(vert) > 0) {
        vt = glCreateShader(GL_VERTEX_SHADER);
        if (!vt)
            return 0;
        glShaderSource(vt, 1, &vert, NULL);
        glCompileShader(vt);
        #ifdef MY_DEBUG //from nii_io.h
        glGetShaderiv(vt, GL_INFO_LOG_LENGTH, &status); //show ANY information
        if (status > 1)
        {
            char str[4096];
            glGetShaderInfoLog(vt, sizeof(str), NULL, str);
            NSLog(@"GLSL Vertex shader information.");
            NSLog(@"%s", str);
        }
        #endif
        glGetShaderiv(vt, GL_COMPILE_STATUS, &status);
        if(!status) { //report compiling errors.
            char str[4096];
            glGetShaderInfoLog(vt, sizeof(str), NULL, str);
            NSLog(@"GLSL Vertex shader compile error.");
            NSLog(@"%s", str);
            glDeleteShader(vt);
            return 0;
        }
        glAttachShader(ProgramID, vt);
    }
    glLinkProgram(ProgramID);
    glUseProgram(ProgramID);
    glDetachShader(ProgramID, fr);
    glDeleteShader(fr);
    if (strlen(vert) > 0) {
        glDetachShader(ProgramID, vt);
        glDeleteShader(vt);
    }
    glUseProgram(0);
    return ProgramID;
}

#ifdef MY_USE_GLSL_FOR_GRADIENTS

const char *kBlurShaderFrag =
"uniform float coordZ, dX, dY, dZ;" \
"uniform sampler3D intensityVol;" \
"void main(void) {\n " \
"  vec3 vx = vec3(gl_TexCoord[0].xy, coordZ);\n"\
"  float samp = texture3D(intensityVol,vx+vec3(+dX,+dY,+dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(+dX,+dY,-dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(+dX,-dY,+dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(+dX,-dY,-dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(-dX,+dY,+dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(-dX,+dY,-dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(-dX,-dY,+dZ)).a;\n"\
"      samp += texture3D(intensityVol,vx+vec3(-dX,-dY,-dZ)).a;\n"\
"  gl_FragColor.a = samp* 0.125;"\
"}";

char *kSobelShaderFrag = NULL;

GLuint bindBlankGL(NII_PREFS* prefs) { //creates an empty texture in VRAM without requiring memory copy from RAM
    //later run glDeleteTextures(1,&oldHandle);
    GLenum error = glGetError();
    if (error) NSLog(@"bindBlankGL init error %d\n", error);
    GLuint handle;
    glGenTextures(1, &handle);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glBindTexture(GL_TEXTURE_3D, handle);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); //, GL_CLAMP_TO_BORDER) will wrap
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA8, prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3], 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    //NSLog(@"voxelDim %d %d %d\n", prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3]);
    error = glGetError();
    if (error) NSLog(@"bindBlankGL memory exhausted %d\n", error);
    return handle;
}
void performBlurSobel(NII_PREFS* prefs, bool isOverlay) {
    GLsizei XSz = prefs->voxelDim[1];
    GLsizei YSz = prefs->voxelDim[2];
    int ZSz = prefs->voxelDim[3];
    GLuint fb = 0;
    //glFinish();//<-wait for jobs to finish: we need these to draw XCODE Flicker (not double-buffered?)
    glGenFramebuffersEXT(1, &fb);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,fb);
    glDisable(GL_CULL_FACE);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
    glViewport(0, 0, XSz, YSz);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho (0, 1,0, 1, -1, 1);  //gluOrtho2D(0, 1, 0, 1);  https://www.opengl.org/sdk/docs/man2/xhtml/gluOrtho2D.xml
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glDisable(GL_BLEND);
    GLuint tempTex3D = bindBlankGL(prefs);
    glUseProgram(prefs->glslprogramIntBlur);
    glActiveTexture( GL_TEXTURE1);
    if (isOverlay)
        glBindTexture(GL_TEXTURE_3D, prefs->gradientOverlay3D);//input texture is overlay
    else
        glBindTexture(GL_TEXTURE_3D, prefs->gradientTexture3D);//input texture is background
    //NSLog(@"%d-->%d", prefs->gradientTexture3D,prefs->gradientOverlay3D);
    //NSLog(@"%d-->%d +%d", prefs->gradientTexture3D, prefs->gradientOverlay3D, isOverlay);
    glUniform1i(glGetUniformLocation(prefs->glslprogramIntBlur, "intensityVol"), 1);
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntBlur, "dX"), 0.5/(float)prefs->voxelDim[1]);
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntBlur, "dY"), 0.5/(float)prefs->voxelDim[2]);
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntBlur, "dZ"), 0.5/(float)prefs->voxelDim[3]);
    for (int i = 0; i < ZSz; i++) {
        float coordZ = (float)1/(float)ZSz * ((float)i + 0.5);
        glUniform1f(glGetUniformLocation(prefs->glslprogramIntBlur, "coordZ"), coordZ);
        glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, tempTex3D, 0, i);//output texture
        glClear(GL_DEPTH_BUFFER_BIT);  // clear depth bit (before render every layer)
        glBegin(GL_QUADS);
        glTexCoord2f(0, 0);
        glVertex2f(0, 0);
        glTexCoord2f(1.0, 0);
        glVertex2f(1.0, 0.0);
        glTexCoord2f(1.0, 1.0);
        glVertex2f(1.0, 1.0);
        glTexCoord2f(0, 1.0);
        glVertex2f(0.0, 1.0);
        glEnd();
        //}
    } //for each slice
    glUseProgram(0);
    //STEP 2: run sobel program gradientTexture -> tempTex3D
    // glUseProgramObjectARB(prefs->glslprogramIntSobel);
    glUseProgram(prefs->glslprogramIntSobel);
    glActiveTexture( GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_3D, tempTex3D);//input texture
    //glEnable(GL_TEXTURE_2D);
    //glDisable(GL_TEXTURE_2D);
    //glUniform1i(glGetUniformLocation(prefs->glslprogramInt, name), value);
    glUniform1i(glGetUniformLocation(prefs->glslprogramIntSobel, "intensityVol"), 1);
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntSobel, "dX"), 1.2/(float)XSz); //1.0 for SOBEL - center excluded
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntSobel, "dY"), 1.2/(float)YSz);
    glUniform1f(glGetUniformLocation(prefs->glslprogramIntSobel, "dZ"), 1.2/(float)ZSz);
    for (int i = 0; i < ZSz; i++) {
        float coordZ = (float)1/(float)ZSz * ((float)i + 0.5);
        glUniform1f(glGetUniformLocation(prefs->glslprogramIntSobel ,"coordZ"), coordZ);
        if (isOverlay)
            glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, prefs->gradientOverlay3D, 0, i);//output texture is overlay
        else
            glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, prefs->gradientTexture3D, 0, i);//output texture is background
        glBegin(GL_QUADS);
        glTexCoord2f(0, 0);
        glVertex2f(0, 0);
        glTexCoord2f(1.0, 0);
        glVertex2f(1.0, 0.0);
        glTexCoord2f(1.0, 1.0);
        glVertex2f(1.0, 1.0);
        glTexCoord2f(0, 1.0);
        glVertex2f(0.0, 1.0);
        glEnd();
    } //for each slice
    glUseProgram(0);
    //glFinish();//<-wait for jobs to finish: we need these to draw XCODE Flicker (not double-buffered?)
    //clean up:
    glDeleteTextures(1,&tempTex3D);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,0);
    glDeleteFramebuffers(1,&fb);
    glActiveTexture( GL_TEXTURE0 );
}

void doShaderBlurSobel (NII_PREFS* prefs) {
    if (kSobelShaderFrag == NULL) {
        NSString * bundlePath = [[NSBundle mainBundle] resourcePath];
        NSString *shaderPath = [bundlePath stringByAppendingPathComponent:@"sobel_shader.frag"];
        kSobelShaderFrag = read_file(shaderPath.UTF8String);
    }
    
    const char *vert_empty ="";
    if (!prefs->advancedRender) return; //gradients only used by advanced rendering
    if ((!prefs->glslUpdateGradientsBG) &&  (!prefs->glslUpdateGradientsOverlay)) return;
    if (prefs->glslprogramIntBlur == 0)
        prefs->glslprogramIntBlur=  initVertFrag(vert_empty, kBlurShaderFrag);
    if (prefs->glslprogramIntSobel == 0)
        prefs->glslprogramIntSobel=  initVertFrag(vert_empty, kSobelShaderFrag);
//#define MY_DEBUG
#ifdef MY_DEBUG
    NSDate *methodStart = [NSDate date];
#endif
    if (prefs->glslUpdateGradientsOverlay)
        performBlurSobel(prefs, true);
    if (prefs->glslUpdateGradientsBG)
        performBlurSobel(prefs, false);
#ifdef MY_DEBUG
    NSLog(@"glsl = %1f", (1000.0*[[NSDate date] timeIntervalSinceDate:methodStart]));
#endif
    prefs->glslUpdateGradientsBG = false;
    prefs->glslUpdateGradientsOverlay = false;
    GLenum error = glGetError();
    if (error) NSLog(@"doShaderBlurSobel error %d\n", error);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
}
#else //MY_USE_GLSL_FOR_GRADIENTS
void doShaderBlurSobel (NII_PREFS* prefs){
    //done by CPU
}
#endif

GLuint bindSubGL(NII_PREFS* prefs, uint32_t *data, GLuint oldHandle) {
    GLuint handle;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    if (oldHandle != 0) glDeleteTextures(1,&oldHandle);
    glGenTextures(1, &handle);
    glBindTexture(GL_TEXTURE_3D, handle);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); //, GL_CLAMP_TO_BORDER) will wrap
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA8, prefs->voxelDim[1], prefs->voxelDim[2], prefs->voxelDim[3], 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
    return handle;
}

void disableRenderBuffers ()
{
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
}

void drawVertex(float x, float y, float z)
{
    glColor3f(x,y,z);
    glMultiTexCoord3f(GL_TEXTURE1, x, y, z);
    glVertex3f(x,y,z);
}

void drawQuads( float x, float y, float z)
//x,y,z typically 1.
// useful for clipping
// If x=0.5 then only left side of texture drawn
// If y=0.5 then only posterior side of texture drawn
// If z=0.5 then only inferior side of texture drawn
{
    //NSLog(@">>> drawQuads Start:\n");
    //glBindTexture(GL_TEXTURE_3D, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBegin(GL_QUADS);
    //* Back side
    glNormal3f(0.0, 0.0, -1.0);
    drawVertex(0.0, 0.0, 0.0);
    drawVertex(0.0, y, 0.0);
    drawVertex(x, y, 0.0);
    drawVertex(x, 0.0, 0.0);
    //* Front side
    glNormal3f(0.0, 0.0, 1.0);
    drawVertex(0.0, 0.0, z);
    drawVertex(x, 0.0, z);
    drawVertex(x, y, z);
    drawVertex(0.0, y, z);
    //* Top side
    glNormal3f(0.0, 1.0, 0.0);
    drawVertex(0.0, y, 0.0);
    drawVertex(0.0, y, z);
    drawVertex(x, y, z);
    drawVertex(x, y, 0.0);
    //* Bottom side
    glNormal3f(0.0, -1.0, 0.0);
    drawVertex(0.0, 0.0, 0.0);
    drawVertex(x, 0.0, 0.0);
    drawVertex(x, 0.0, z);
    drawVertex(0.0, 0.0, z);
    //* Left side
    glNormal3f(-1.0, 0.0, 0.0);
    drawVertex(0.0, 0.0, 0.0);
    drawVertex(0.0, 0.0, z);
    drawVertex(0.0, y, z);
    drawVertex(0.0, y, 0.0);
    //* Right side
    glNormal3f(1.0, 0.0, 0.0);
    drawVertex(x, 0.0, 0.0);
    drawVertex(x, y, 0.0);
    drawVertex(x, y, z);
    drawVertex(x, 0.0, z);
    glEnd();
    //NSLog(@">>>  drawQuads End\n");
}

void uniform1i(const char* name, int value, NII_PREFS* prefs )
{
    glUniform1i(glGetUniformLocation(prefs->glslprogramCur, name), value);
}

void uniform1f(const char* name, float value, NII_PREFS* prefs )
{
    glUniform1f(glGetUniformLocation(prefs->glslprogramCur, name), value);
}

void uniform3fv(const char* name, float v1, float v2, float v3, NII_PREFS* prefs)
{
    glUniform3f(glGetUniformLocation(prefs->glslprogramCur, name), v1, v2, v3);
}

void uniform4fv(const char* name, float v1, float v2, float v3, float v4, NII_PREFS* prefs)
{
    glUniform4f(glGetUniformLocation(prefs->glslprogramCur, name), v1, v2, v3, v4);
}

void uniformMatrix3fv(const char*name, float* values, NII_PREFS* prefs)
{
    glUniformMatrix3fv(glGetUniformLocation(prefs->glslprogramCur, name), 1, GL_FALSE, values);
}

/*const char *vert_defaultOLD =
"void main() {\n"
" gl_TexCoord[1] = gl_MultiTexCoord1;\n"
" gl_Position = ftransform();\n"
"}";*/

const char *vert_default =
"#version 120\n"
"//varying vec3 TexCoord1;\n"
"varying vec3 vColor;\n"
"//uniform mat4 ModelViewProjectionMatrix;\n"
"void main() {\n"
" vColor = gl_Vertex.xyz;\n"
" //gl_TexCoord[1] = gl_MultiTexCoord1;\n"
" gl_Position = ftransform();\n"
" //gl_Position = ModelViewProjectionMatrix * vec4(gl_Vertex.xyz, 1.0);\n"
" //TexCoord1 = gl_TexCoord[1].rgb; //gl_Vertex.rgb;\n"
"}\n";

char *frag_default = NULL;     // load default_shader.frag
char *frag_advanced_CT = NULL; // load advanced_CT_shader.frag
char *frag_advanced_MR = NULL; // load advanced_MR_shader.frag

void initShaderWithFile (NII_PREFS* prefs) {
    
    NSString * bundlePath = [[NSBundle mainBundle] resourcePath];
    if (frag_default == NULL) {
        NSString *shaderPath = [bundlePath stringByAppendingPathComponent:@"default_shader.frag"];
        frag_default = read_file(shaderPath.UTF8String);
    }
    if (frag_advanced_CT == NULL) {
        NSString *shaderPath = [bundlePath stringByAppendingPathComponent:@"advanced_CT_shader.frag"];
        frag_advanced_CT = read_file(shaderPath.UTF8String);
    }
    if (frag_advanced_MR == NULL) {
        NSString *shaderPath = [bundlePath stringByAppendingPathComponent:@"advanced_MR_shader.frag"];
        frag_advanced_MR = read_file(shaderPath.UTF8String);
    }
    
    if (prefs->glslprogramMR != 0) glDeleteShader(prefs->glslprogramMR);
    #ifdef  MY_USE_ADVANCED_GLSL
    if (prefs->glslprogramCT != 0) glDeleteShader(prefs->glslprogramCT);
    prefs->glslprogramCT=  initVertFrag(vert_default, frag_advanced_CT);
    if (prefs->advancedRender)
        prefs->glslprogramMR = initVertFrag(vert_default, frag_advanced_MR);//frag_advanced);
    else
#endif
        prefs->glslprogramMR = initVertFrag(vert_default, frag_default);
}

float kDefaultDistance = 2.25;//2.25;

float lerp (float p1, float p2, float frac)
{
    return round(p1 + frac * (p2 - p1));
}//linear interpolation

float computeStepSize (int quality1to4,  NII_PREFS* prefs) {
    float q = MAX(quality1to4 - 1.0, 0.0);
    q = MIN(q, 4);
    float slices = (float) prefs->renderSlices;
    float f = lerp(slices*0.4,slices, q/4.0);
    //NSLog(@"%g %g %g -> %g", slices*0.4, slices*1.0, q/4.0, f);
    if (f < 10.0) f = 10.0;
    //NSLog(@"%d %d -> %g", quality1to5, prefs->renderSlices, 1.0/f);
    return 1.0/f;
}

double defuzz(double x)
{
    const double fuzz = 1.0E-6;
    if (fabs(x) < fuzz) return 0.0;
    return x;
}

double degToRad(double degree)
{
    #define pi 3.14159265
    double radian = 0.0;
    radian = degree * (pi/180);
    return radian;
}

void sph2cartDeg90(float azimuth, float elevation, float* lX, float* lY, float *lZ)
//convert spherical AZIMUTH,ELEVATION,RANGE to Cartesion
//see Matlab's [x,y,z] = sph2cart(THETA,PHI,R)
// reverse with cart2sph
{
    float E,Phi,Theta;
    E = azimuth;
    while (E < 0)
        E = E + 360;
    while (E > 360)
        E = E - 360;
    Theta = degToRad(E);
    E = elevation;
    while (E > 90)
        E = E - 90;
    while (E < -90)
        E = E + 90;
    Phi = degToRad(E);
    *lX = cos(Phi)*cos(Theta);
    *lY = cos(Phi)*sin(Theta);
    *lZ = sin(Phi);
}

void sph2cartDeg90x(float Azimuth, float Elevation, float R, float* lX, float* lY, float* lZ)
//convert spherical AZIMUTH,ELEVATION,RANGE to Cartesion
//see Matlab's [x,y,z] = sph2cart(THETA,PHI,R)
// reverse with cart2sph
{
    int n;
    float E,Phi,Theta;
    Theta = degToRad(Azimuth-90);
    E = Elevation;
    if ((E > 360) || (E < -360)) {
        n = trunc(E / 360) ;
        E = E - (n * 360);
    }
    if (((E > 89) && (E < 91)) || ((E < -269) && (E > -271)))
        E = 90;
    if (((E > 269) && (E < 271)) || ((E < -89) && (E > -91)) )
        E = -90;
    Phi = degToRad(E);
    *lX = R * cos(Phi)*cos(Theta);
    *lY = R * cos(Phi)*sin(Theta);
    *lZ = R * sin(Phi);
}

void lightUniforms (NII_PREFS* prefs)
{
    float lX,lY,lZ,lA;
     // lMgl: array[0..15] of  GLfloat;
    //sph2cartDeg90x(0,80,1,&lX,&lY,&lZ);//0,80 are azimuth and elevation of light source
    sph2cartDeg90x(90,20,1,&lX,&lY,&lZ);//0,80 are azimuth and elevation of light source
    if (true) { //gPrefs.RayCastViewCenteredLight
        //Could be done in GLSL with following lines of code, but would be computed once per pixel, vs once per volume
        //vec3 lightPosition =  normalize(gl_ModelViewMatrixInverse * vec4(lightPosition,0.0)).xyz ;
        GLfloat lMgl[16];
        float lB,lC;
        glGetFloatv(GL_TRANSPOSE_MODELVIEW_MATRIX, lMgl);
        lA = lY;
        lB = lZ;
        lC = lX;
        lX = defuzz(lA*lMgl[0]+lB*lMgl[4]+lC*lMgl[8]);
        lY = defuzz(lA*lMgl[1]+lB*lMgl[5]+lC*lMgl[9]);
        lZ = defuzz(lA*lMgl[2]+lB*lMgl[6]+lC*lMgl[10]);
    }
    lA = sqrt(lX*lX+lY*lY+lZ*lZ);
    if (lA > 0.0) { //normalize
        lX = lX/lA;
        lY = lY/lA;
        lZ = lZ/lA;
    }
    uniform3fv("lightPosition",lX,lY,lZ, prefs);
}

void clipUniforms (NII_PREFS* prefs)
{
    float lD,lX,lY,lZ;
    sph2cartDeg90x(prefs->clipAzimuth,prefs->clipElevation,1,&lX,&lY,&lZ);
    if (prefs->clipDepth < 1)
        lD = 2.0;
    else
        lD = 0.5-(prefs->clipDepth/1000.0);
    uniform4fv("clipPlane",-lX,-lY,-lZ,lD, prefs);
    //uniform1f( "clipPlaneDepth", lD, prefs);
}

void MakeCube(float sz)
{
    float sz2;
    sz2 = sz;
    glColor4f(0.2,0.2,0.2,1);
    //GLuint idx = glGenLists(1);
    //glNewList(idx, GL_COMPILE);
    float t = 0.2*sz; //thickness
    float t2 = t / 2.0;
    float m = 0.55*sz; //marginLR
    float mv = 0.3*sz; //marginTB

    // Bottom side
    glBegin(GL_QUADS);
    glVertex3f(-sz, -sz, -sz2);
    glVertex3f(-sz, sz, -sz2);
    glVertex3f(sz, sz, -sz2);
    glVertex3f(sz, -sz, -sz2);
    glEnd();
    //Bottom side "I"
    glColor4f(0,0,0,1);
    glBegin(GL_QUADS); //I
    glVertex3f(t2, -sz+mv, -sz2);
    glVertex3f(-t2, -sz+mv, -sz2);
    glVertex3f(-t2, sz-mv, -sz2);
    glVertex3f(t2, sz-mv, -sz2);
    glEnd();
    // Top side
    glColor4f(0.8,0.8,0.8,1);
    glBegin(GL_QUADS);
    glVertex3f(-sz, -sz, sz2);
    glVertex3f(sz, -sz, sz2);
    glVertex3f(sz, sz, sz2);
    glVertex3f(-sz, sz, sz2);
    glEnd();
    //Top side "S"
    glColor4f(0,0,0,1);
    glBegin(GL_QUADS); //S
    glVertex3f(sz-m-t, -sz+mv, sz2);
    glVertex3f(sz-m-t, -sz+mv+t, sz2);
    glVertex3f(-sz+m, -sz+mv+t, sz2);
    glVertex3f(-sz+m, -sz+mv, sz2);
    
    glVertex3f(sz-m-t, -t2, sz2);
    glVertex3f(sz-m-t, t2, sz2);
    glVertex3f(-sz+m+t, t2, sz2);
    glVertex3f(-sz+m+t, -t2, sz2);
    
    glVertex3f(sz-m, sz-mv-t, sz2);
    glVertex3f(sz-m, sz-mv, sz2);
    glVertex3f(-sz+m+t, sz-mv, sz2);
    glVertex3f(-sz+m+t, sz-mv-t, sz2);
    
    glVertex3f(-sz+m+t, 0-t2, sz2);
    glVertex3f(-sz+m+t, sz-mv, sz2);
    glVertex3f(-sz+m, sz-mv-t, sz2);
    glVertex3f(-sz+m, 0+t2, sz2);

    glVertex3f(sz-m, -sz+mv+t, sz2);
    glVertex3f(sz-m, -t2, sz2);
    glVertex3f(sz-m-t, t2, sz2);
    glVertex3f(sz-m-t, -sz+mv, sz2);
    glEnd();
    
    // Front side
    glColor4f(0,0,0.65,1);
    glBegin(GL_QUADS);
    glVertex3f(-sz, sz2, -sz);
    glVertex3f(-sz, sz2, sz);
    glVertex3f(sz, sz2, sz);
    glVertex3f(sz, sz2, -sz);
    glEnd();
    
    //A
    glColor4f(0.0,0.0,0.0,1);
    glBegin(GL_QUADS);


    glVertex3f(-sz+m, sz2, -sz+mv);
    glVertex3f(-t2, sz2, sz-mv);
    glVertex3f(t2, sz2, sz-mv);
    glVertex3f(-sz+m+t, sz2, -sz+mv);

    glVertex3f(sz-m, sz2, -sz+mv);
    glVertex3f(sz-m-t, sz2, -sz+mv);
    glVertex3f(-t2, sz2, sz-mv);
    glVertex3f(t2, sz2, sz-mv);
    
    glVertex3f(-sz+m+t, sz2, -t-t2);
    glVertex3f(-sz+m+t, sz2, -t2);
    glVertex3f(sz-m-t, sz2, -t2);
    glVertex3f(sz-m-t, sz2, -t-t2);
    glEnd();
    // Back side
    glColor4f(0.35,0,0.35,1);
    glBegin(GL_QUADS);
    glVertex3f(-sz, -sz2, -sz);
    glVertex3f(sz, -sz2, -sz);
    glVertex3f(sz, -sz2, sz);
    glVertex3f(-sz, -sz2, sz);
    glEnd();
    //P
    glColor4f(0.0,0.0,0.0,1);
    glBegin(GL_QUADS);
    glVertex3f(-sz+m, -sz2, -sz+mv);
    glVertex3f(-sz+m+t, -sz2, -sz+mv);
    glVertex3f(-sz+m+t, -sz2, sz-mv);
    glVertex3f(-sz+m, -sz2, sz-mv);
    
    glVertex3f(sz-m-t, -sz2, -t2);
    glVertex3f(sz-m, -sz2, -t2+t);
    glVertex3f(sz-m, -sz2, sz-mv-t);
    glVertex3f(sz-m-t, -sz2, sz-mv);

    glVertex3f(-sz+m, -sz2, sz-mv-t);
    glVertex3f(sz-m-t, -sz2, sz-mv-t);
    glVertex3f(sz-m-t, -sz2, sz-mv);
    glVertex3f(-sz+m, -sz2, sz-mv);

    glVertex3f(-sz+m, -sz2, -t2);
    glVertex3f(sz-m-t, -sz2, -t2);
    glVertex3f(sz-m-t, -sz2, t2);
    glVertex3f(-sz+m, -sz2, t2);

    glEnd();
    
    glColor4f(0.7,0,0,1);
    glBegin(GL_QUADS);
    // Left side
    glVertex3f(-sz2, -sz, -sz);
    glVertex3f(-sz2, -sz, sz);
    glVertex3f(-sz2, sz, sz);
    glVertex3f(-sz2, sz, -sz);
    glEnd();
    // L
    glColor4f(0,0,0,1);
    glBegin(GL_QUADS);
    glVertex3f(-sz2, sz-m, -sz+mv);
    glVertex3f(-sz2, sz-m-t, -sz+mv);
    glVertex3f(-sz2, sz-m-t, sz-mv);
    glVertex3f(-sz2, sz-m, sz-mv);

    glVertex3f(-sz2, -sz+m, -sz+mv);
    glVertex3f(-sz2, -sz+m, -sz+mv+t);
    glVertex3f(-sz2, sz-m-t, -sz+mv+t);
    glVertex3f(-sz2, sz-m-t, -sz+mv);
    glEnd();
    // Right side
    glColor4f(0,0.6,0,1);
    glBegin(GL_QUADS);
    glVertex3f(sz2, -sz, -sz);
    glVertex3f(sz2, sz, -sz);
    glVertex3f(sz2, sz, sz);
    glVertex3f(sz2, -sz, sz);
    glEnd();
    // R
    glColor4f(0,0,0,1);
    glBegin(GL_QUADS);
    glVertex3f(sz2, -sz+m+t, -sz+mv);
    glVertex3f(sz2, -sz+m+t, sz-mv);
    glVertex3f(sz2, -sz+m, sz-mv);
    glVertex3f(sz2, -sz+m, -sz+mv);

    glVertex3f(sz2, -sz+m, sz-mv-t);
    glVertex3f(sz2, sz-m, sz-mv-t);
    glVertex3f(sz2, sz-m-t, sz-mv);
    glVertex3f(sz2, -sz+m, sz-mv);
    
    glVertex3f(sz2, -sz+m, -t2);
    glVertex3f(sz2, sz-m-t, -t2);
    glVertex3f(sz2, sz-m, t2);
    glVertex3f(sz2, -sz+m, t2);

    glVertex3f(sz2, sz-m, t2);
    glVertex3f(sz2, sz-m, sz-mv-t);
    glVertex3f(sz2, sz-m-t, sz-mv-t);
    glVertex3f(sz2, sz-m-t, t2);
    
    glVertex3f(sz2, sz-m, -sz+mv);
    glVertex3f(sz2, sz-m-t, -t2);
    glVertex3f(sz2, sz-m-t-t, -t2);
    glVertex3f(sz2, sz-m-t, -sz+mv);

    glEnd();
}

void DrawCube (NII_PREFS* prefs)//Enter2D = reshapeGL
{
    glViewport(prefs->scrnOffsetX, prefs->scrnOffsetY, prefs->scrnWid, prefs->scrnHt);
    glEnable(GL_CULL_FACE);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    float mx = prefs->renderWid;
    if (mx > prefs->renderHt) mx = prefs->renderWid;
    mx = mx *0.04f;
    glOrtho(0, prefs->scrnWid, 0, prefs->scrnHt,-mx*2, mx*2);
    //glOrtho(0, width, 0, height,-10, 10);//gluOrtho2D(0, width, 0, height);
    //glEnable(GL_DEPTH_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable (GL_LIGHTING);
    glDisable (GL_BLEND);
    glTranslatef(prefs->renderLeft+ 1.8*mx,1.8*mx,-mx);
    glRotatef(90-prefs->renderElevation,-1,0,0);
    glRotatef(prefs->renderAzimuth,0,0,1);
    MakeCube(mx);
    glDisable(GL_CULL_FACE);
    //glDisable(GL_DEPTH_TEST);
}

int getMaxInt(int v1, int v2, int v3)
{
    int ret;
    if ((v1 > v2) && (v1 > v3)) //v1 biggest
        ret = v1;
    else if  (v2 > v3) //v2 > v3, v2 >= v1
        ret = v2;
    else //v3 >= v2, v3 >= v1
        ret = v3;
    return ret;
}

float getMaxFloat(float v1, float v2, float v3)
{
    float ret;
    if ((v1 > v2) && (v1 > v3)) //v1 > v2, v1 > v3
        ret = v1;
    else if  (v2 > v3) //v2 > v3, v2 >= v1
        ret = v2;
    else //v3 >= v2, v3 >= v1
        ret = v3;
    return ret;
}

void  createRender (NII_PREFS* prefs)  //InitGL
{
    initShaderWithFile(prefs);
}

void loadCube (NII_PREFS* prefs) { //TODO draw cube
    float vtx[24]  = {
          0,0,0,
          0,1,0,
          1,1,0,
          1,0,0,
          0,0,1,
          0,1,1,
          1,1,1,
          1,0,1
    };
    float idx[14] = {0,1,3,2,6,1,5,4, 6,7,3, 4, 0, 1}; //reversed winding
    if (prefs->dlBox3D != 0) glDeleteLists(prefs->dlBox3D, 1);
    prefs->dlBox3D = glGenLists(1);
    glNewList(prefs->dlBox3D, GL_COMPILE);
    glBegin(GL_TRIANGLE_STRIP);
    int nface = 14;
    for (int i = 0; i < nface; i++) {
        int v = idx[i];
        glVertex3f(vtx[v*3], vtx[(v*3)+1], vtx[(v*3)+2]);
    }
    glEnd();
    glEndList();
}

void recalcRender (NII_PREFS* prefs)  //DisplayGL
{
    //we will want to render more points for higher resolution volumes
    prefs->renderSlices = getMaxInt(prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3]);
    if (prefs->renderSlices < 1) prefs->renderSlices = 100;
    //normalize so longest length=1.0 e.g. 25x75x100mm volume is0.25x0.75x1.0
    float maxFOV = getMaxFloat(prefs->fieldOfViewMM[1],prefs->fieldOfViewMM[2],prefs->fieldOfViewMM[3]);
    if ((prefs->fieldOfViewMM[1] > 0.0) && (prefs->fieldOfViewMM[2] > 0.0) && (prefs->fieldOfViewMM[3] > 0.0)) {
        //NSLog(@"%gx%gx%g", prefs->fieldOfViewMM[1], prefs->fieldOfViewMM[2], prefs->fieldOfViewMM[3]);
        maxFOV = sqrt(pow(prefs->fieldOfViewMM[1],2)+pow(prefs->fieldOfViewMM[2],2)+pow(prefs->fieldOfViewMM[3],2))/2.0;
    }
    if (maxFOV <= 0) maxFOV = 1;
    prefs->TexScale[1] = prefs->fieldOfViewMM[1]/maxFOV;
    prefs->TexScale[2] = prefs->fieldOfViewMM[2]/maxFOV;
    prefs->TexScale[3] = prefs->fieldOfViewMM[3]/maxFOV;
    #ifdef MY_DEBUG //from nii_io.h
    NSLog(@"%dx%dx%d max=%d FOV=%g",prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3], prefs->renderSlices, maxFOV);
    #endif
}

void resize2(int wx, int hx, NII_PREFS* prefs)
{
    int kMaxDistance = 40.0;
    float whratio,scale, w, h;
    w = wx;
    h = hx;
    if (h == 0) h = 1;
    //glViewport(prefs->scrnOffsetX,prefs->scrnOffsetY, w, h);
    glViewport(prefs->scrnOffsetX+prefs->renderLeft, prefs->scrnOffsetY+prefs->renderBottom, prefs->renderWid, prefs->renderHt);
    //glViewport(prefs->scrnOffsetX,prefs->scrnOffsetY, w, h);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    if (prefs->renderDistance == 0) {
        scale = 1.0;
    } else {
        scale = 1.0/fabs(kDefaultDistance/(prefs->renderDistance+1.0));
    }
    whratio = w/h;
    glOrtho(whratio*-0.5*scale,whratio*0.5*scale,-0.5*scale,0.5*scale, 0.01, kMaxDistance);
#ifdef MY_DEBUG //from nii_io.h
    NSLog(@"Resize %dx%d rendDx=%g scale=%g",prefs->renderWid, prefs->renderHt, prefs->renderDistance, scale);
#endif
    glMatrixMode(GL_MODELVIEW);
}

/*
void ReportMat (mat44 m) {
    NSLog(@"m=[%g %g %g; %g %g %g; %g %g %g]",
          m.m[0][0],m.m[0][1],m.m[0][2],
          m.m[1][0],m.m[1][1],m.m[1][2],
          m.m[2][0],m.m[2][1],m.m[2][2]);
}

void ReportVec (vec4 v) {
    NSLog(@"v=[%g %g %g %g]",
          v.v[0],v.v[1],v.v[2],v.v[3]);
}*/

mat44 RotateX(float deg, mat44 m) {
    mat44 r;
    float radx = deg * M_PI / 180.0;
    float s = sin(radx);
    float c = cos(radx);
    //NSLog(@"%g %g %g %g", deg, radx, s, c);
    LOAD_MAT44(r,1,0,0,0, 0,c,-s,0, 0,s,c,0);
    return nifti_mat44_mul( m , r );
}

/*mat44 RotateY(float deg, mat44 m) {
    mat44 r;
    float radx = deg * M_PI / 180.0;
    float s = sin(radx); //0.374
    float c = cos(radx); //0.927
    //NSLog(@"?? %g %g %g %g", deg, radx, s, c);
    LOAD_MAT44(r,c,0,s,0, 0,1,0,0, -s,0,c,0);
    return nifti_mat44_mul( m , r );
}*/

mat44 RotateZ(float deg, mat44 m) {
    mat44 r;
    float radx = deg * M_PI / 180.0;
    float s = sin(radx); //0.374
    float c = cos(radx); //0.927
    //NSLog(@"?? %g %g %g %g", deg, radx, s, c);
    LOAD_MAT44(r,c,-s,0,0, s,c,0,0, 0,0,1,0);
    return nifti_mat44_mul( m , r );
}

vec4 addFuzz(vec4 v) {
    float kEPS = 0.0001;
    vec4 ret = v;
    if (fabs(v.v[0]) < kEPS) ret.v[0] = kEPS;
    if (fabs(v.v[1]) < kEPS) ret.v[1] = kEPS;
    if (fabs(v.v[2]) < kEPS) ret.v[2] = kEPS;
    if (fabs(v.v[3]) < kEPS) ret.v[3] = kEPS;
    return ret;
}

void drawBox(NII_PREFS* prefs) {
    //initShaderWithFile(prefs);
    if (prefs->dlBox3D == 0) loadCube(prefs);
    //dbug
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    resize2(prefs->renderWid, prefs->renderHt, prefs);
    //glViewport(prefs->scrnOffsetX, prefs->scrnOffsetY, prefs->scrnWid, prefs->scrnHt);
    //glClearColor(prefs->backColor[0],prefs->backColor[1],prefs->backColor[2], 0.0);
    //glClearColor(0.5,0.5,0.6, 0.2);
    //glClear(GL_DEPTH_BUFFER_BIT);
    //glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );
    
    mat44 m;
    LOAD_MAT44(m,1,0,0,0, 0,1,0,0, 0,0,1, 0);
    //float azi = 110;
    //float elev = 30;
    //glRotatef(90-prefs->renderElevation,-1,0,0);
    //glRotatef(prefs->renderAzimuth,0,0,1);
    mat44 r = RotateX(-(90-prefs->renderElevation),m);
    //ReportMat(r);
    m = RotateZ(prefs->renderAzimuth,r);
    mat44 mscale;
    //NSLog(@"scale %g %g %g", prefs->TexScale[1],prefs->TexScale[2],prefs->TexScale[3]);
    LOAD_MAT44(mscale,prefs->TexScale[1],0,0,0, 0,prefs->TexScale[2],0,0, 0,0,prefs->TexScale[3], 0);
    //modelMatrix *= TMat4.Scale(0.80859375, 1, 0.83984375);//
    m = nifti_mat44_mul(m,mscale);
    //ReportMat(m);
    r = nifti_mat44_inverse(m);
    vec4 rayDir = setVec4(0,0,-1);
    rayDir = nifti_vect44mat44_mul(rayDir, r );
    rayDir.v[3] = 0.0;
    rayDir = nifti_vect44_norm(rayDir);
    rayDir = addFuzz(rayDir);
    //ReportVec(rayDir);
    //glDisable (GL_BLEND);
    glTranslatef(0,0,-prefs->renderDistance*2); //fails with close zoom - unit cube
    glTranslatef(0,0,1.75); //make sure we do not clip a corner: unit cube so sqrt(3) = 1.732
    glRotatef(90-prefs->renderElevation,-1,0,0);
    glRotatef(prefs->renderAzimuth,0,0,1);
    glTranslatef(-prefs->TexScale[1]/2,-prefs->TexScale[2]/2,-prefs->TexScale[3]/2);
    glMatrixMode(GL_MODELVIEW);
    glScalef(prefs->TexScale[1],prefs->TexScale[2],prefs->TexScale[3]);
    //initShaderWithFile(prefs);
    //NSLog(@"<<<< %d %d", prefs->intensityTexture3D, prefs->gradientTexture3D);
    glEnable(GL_CULL_FACE);
    
    glEnable (GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    //glCullFace(GL_FRONT);
    glCullFace(GL_BACK);
    glEnable (GL_TEXTURE_3D);
    if (prefs->colorScheme >= 20)
        prefs->glslprogramCur = prefs->glslprogramCT;
    else
        prefs->glslprogramCur = prefs->glslprogramMR;
    glUseProgram(prefs->glslprogramCur);
    uniform1i( "intensityVol", 1, prefs );
    glActiveTexture( GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_3D, prefs->intensityTexture3D);
    #ifdef  MY_USE_ADVANCED_GLSL
    uniform1i( "overlays",prefs->numOverlay, prefs );
    uniform1i( "intensityOverlay",3, prefs );
    glActiveTexture( GL_TEXTURE3);
    if (prefs->numOverlay > 0) {
        glBindTexture(GL_TEXTURE_3D, prefs->intensityOverlay3D);
    } else {
        glBindTexture(GL_TEXTURE_3D, prefs->intensityTexture3D);
    }
    if (prefs->advancedRender) {
        uniform1i( "gradientVol",2, prefs );
        glActiveTexture( GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_3D, prefs->gradientTexture3D);
        uniform1i( "gradientOverlay",4, prefs );
        glActiveTexture( GL_TEXTURE4);
        if (prefs->numOverlay > 0) {
            glBindTexture(GL_TEXTURE_3D, prefs->gradientOverlay3D);
        } else {
            glBindTexture(GL_TEXTURE_3D, prefs->gradientTexture3D);
        }
    }
    
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, prefs->matcap2D);
    
    #endif
    clipUniforms(prefs);
    uniform3fv("rayDir",rayDir.v[0], rayDir.v[1], rayDir.v[2], prefs);//<<<
    uniform3fv("textureSz",prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3], prefs);
    lightUniforms(prefs);
    uniform1f( "sliceSize", 1.0/(float)prefs->renderSlices, prefs );
    uniform1f( "stepSize", computeStepSize(3, prefs), prefs );
    
    mat44 normalMatrix = nifti_mat44_inverse(m);
    float nMtx[9];
    nMtx[0] = normalMatrix.m[0][0];
    nMtx[1] = normalMatrix.m[0][1];
    nMtx[2] = normalMatrix.m[0][2];
    nMtx[3] = normalMatrix.m[1][0];
    nMtx[4] = normalMatrix.m[1][1];
    nMtx[5] = normalMatrix.m[1][2];
    nMtx[6] = normalMatrix.m[2][0];
    nMtx[7] = normalMatrix.m[2][1];
    nMtx[8] = normalMatrix.m[2][2];
    uniformMatrix3fv("NormalMatrix", nMtx, prefs);
    
    glCallList(prefs->dlBox3D);
    glUseProgram(0);
    glDisable(GL_CULL_FACE);
    glActiveTexture( GL_TEXTURE0 ); //this can be called in rayCasting, but MUST be called before 2D can be done
    GLenum error = glGetError();
    if (error) NSLog(@"drawBox init error %d\n", error);
    glDisable (GL_BLEND);
    glDisable (GL_TEXTURE_3D);
}
            
void redrawRender (NII_PREFS* prefs)  //DisplayGL
{
    //GLenum stat = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    //if (stat != GL_FRAMEBUFFER_COMPLETE) return;
    //GLenum error = glGetError();
    //if (error) NSLog(@"redrawRender init error %d\n", error);
    
    if ((prefs->renderHt < 1) || (prefs->renderWid < 1))
        return;
    //glDisable (GL_TEXTURE_3D);//this is critical!
    #ifdef  MY_USE_ADVANCED_GLSL
    doShaderBlurSobel (prefs);
    #endif
    //glDisable (GL_TEXTURE_3D);//this is critical!
    glActiveTexture( GL_TEXTURE0 ); //this can be called in rayCasting, but MUST be called before 2D can be done
 
    drawBox(prefs);
    
    if (prefs->showCube)
        DrawCube(prefs);
}

void initTRayCast (NII_PREFS* prefs)
{
    //prefs->perspective = FALSE;
    prefs->TexScale[1] = 1;
    prefs->TexScale[2] = 1;
    prefs->TexScale[3] = 1;
    //prefs->showGradient = 0;
    prefs->rayCastQuality1to4 = 3;
    prefs->showCube = TRUE;
    prefs->clipAzimuth = 180;
    prefs->clipElevation = 0;
    prefs->clipDepth = 0;
    prefs->renderAzimuth = 110;
    prefs->renderElevation = 15;
    prefs->renderDistance = kDefaultDistance;
    prefs->renderSlices = 256;
    prefs->gradientTexture3D = 0;
    prefs->intensityTexture3D = 0;
    prefs->gradientOverlay3D = 0;
    prefs->intensityOverlay3D = 0;
    prefs->matcap2D = 0;
    prefs->glslprogramIntBlur = 0;
    prefs->glslprogramIntSobel = 0;
    prefs->glslUpdateGradientsOverlay = false;
    prefs->glslUpdateGradientsBG = false;
    prefs->glslprogramMR = 0;
    prefs->glslprogramCT = 0;
    prefs->dlBox3D = 0;
    prefs->glslprogramCur = 0;
    //prefs->finalImage = 0;
    //prefs->renderBuffer = 0;
    //prefs->frameBuffer = 0;
    //prefs->backFaceBuffer = 0;
    prefs->renderLeft = 0;
    prefs->renderBottom = 0;
    prefs->displayModeGL = GL_2D_AND_3D; //options: GL_2D_AND_3D GL_2D_ONLY GL_3D_ONLY
}//initTRayCast

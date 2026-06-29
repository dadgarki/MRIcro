//
//  nii_render.m
//  MRIpro
//
//  Created by Chris Rorden on 9/2/12.
//  Copyright 2012 U South Carolina. All rights reserved.
//
//  OpenGL retired: the GPU rendering that used to live here (shader setup,
//  ray-cast drawBox/DrawCube, Sobel blur FBO, immediate-mode geometry, volume
//  texture uploads) is now done by NIIMetalRenderer / Shaders.metal. Only the
//  platform-neutral CPU helpers that nii_img's Metal redraw path still calls
//  remain: render-resolution / texture-scale setup (recalcRender) and the
//  one-time render defaults (initTRayCast).
//

#import "nii_render.h"
#include "nii_io.h"
#include <math.h>
#include <stdio.h>
#include "nii_definetypes.h"
#import <Foundation/Foundation.h>

float kDefaultDistance = 2.25;//default render camera distance (was used by the GL projection)

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

void recalcRender (NII_PREFS* prefs)  //DisplayGL
{
    //we will want to render more points for higher resolution volumes
    prefs->renderSlices = getMaxInt(prefs->voxelDim[1],prefs->voxelDim[2],prefs->voxelDim[3]);
    if (prefs->renderSlices < 1) prefs->renderSlices = 100;
    //normalize so longest length=1.0 e.g. 25x75x100mm volume is0.25x0.75x1.0
    float maxFOV = getMaxFloat(prefs->fieldOfViewMM[1],prefs->fieldOfViewMM[2],prefs->fieldOfViewMM[3]);
    if ((prefs->fieldOfViewMM[1] > 0.0) && (prefs->fieldOfViewMM[2] > 0.0) && (prefs->fieldOfViewMM[3] > 0.0)) {
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

void initTRayCast (NII_PREFS* prefs)
{
    prefs->TexScale[1] = 1;
    prefs->TexScale[2] = 1;
    prefs->TexScale[3] = 1;
    prefs->rayCastQuality1to4 = 3;
    prefs->showCube = TRUE;
    prefs->clipAzimuth = 180;
    prefs->clipElevation = 0;
    prefs->clipDepth = 0;
    prefs->renderAzimuth = 110;
    prefs->renderElevation = 15;
    prefs->renderDistance = kDefaultDistance;
    prefs->renderSlices = 256;
    prefs->renderLeft = 0;
    prefs->renderBottom = 0;
    prefs->displayModeGL = GL_2D_AND_3D; //options: GL_2D_AND_3D GL_2D_ONLY GL_3D_ONLY
}//initTRayCast

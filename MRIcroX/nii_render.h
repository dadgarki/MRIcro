//
//  nii_render.h
//  MRIpro
//
//  Created by Chris Rorden on 9/2/12.
//  Copyright 2012 U South Carolina. All rights reserved.
//

#import <Foundation/Foundation.h>
#include "nii_definetypes.h"

#ifndef MRIpro_nii_render_h
#define MRIpro_nii_render_h

#ifdef  __cplusplus
extern "C" { 
#endif
    
#define MY_USE_ADVANCED_GLSL //<- if not set, only basic rendering
//#define MY_SHOW_GRADIENTS //shows angle calculations, requires MY_USE_ADVANCED_GLSL
#define MY_USE_GLSL_FOR_GRADIENTS
    // CPU-only helpers retained after the OpenGL→Metal migration. The former GL
    // entry points (createRender/redrawRender/initShaderWithFile/doShaderBlurSobel/
    // bindSubGL) were removed — rendering is now done by NIIMetalRenderer.
    void initTRayCast (NII_PREFS* prefs);
    void recalcRender(NII_PREFS* prefs) ;
#ifdef  __cplusplus
}
#endif

#endif


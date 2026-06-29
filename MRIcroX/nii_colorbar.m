//
//  nii_colorbar.m
//  MRIpro
//
//  Created by Chris Rorden on 9/2/12.
//  Copyright 2012 U South Carolina. All rights reserved.
//
//  OpenGL retired: the colorbar gradient, min/max labels and histogram that
//  used to be drawn here with immediate-mode OpenGL + GLString are now rendered
//  by NIIMetalRenderer (drawColoredVerts:/drawLines:/drawGlyphTexture:),
//  composed in nii_img's drawMetalOverlays. This translation unit is now empty.
//

#import <Foundation/Foundation.h>

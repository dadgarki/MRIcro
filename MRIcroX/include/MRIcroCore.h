//
//  MRIcroCore.h
//  Umbrella header for the MRIcroCore Swift package.
//
//  Exposes the consumable rendering surface: the platform-neutral image/control
//  seam (nii_img) plus the unified Metal renderer (NIIMetalRenderer / NIIMetalText).
//  The UI layers (AppKit/UIKit) are intentionally NOT part of this package.
//
//  Headers are referenced relative to this file (which lives in MRIcroX/include);
//  clang resolves quoted includes relative to the including file, so each header's
//  own `#include "nii_*.h"` chains correctly back into MRIcroX/ at module build.
//

#import "../nii_img.h"
#import "../NIIMetalRenderer.h"
#import "../NIIMetalText.h"

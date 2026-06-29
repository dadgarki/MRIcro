//
//  NIIViewController.h
//  MRIcroX (iOS / iPadOS)
//
//  UIKit host for the unified Metal renderer. Owns an MTKView and a shared
//  nii_img controller, and bridges UIKit gesture recognizers to the same
//  platform-neutral input seam the macOS nii_GLView uses (setMouseDown:,
//  setRightMouseDragXY:, setScrollWheel:, setMagnify:, setSwipe:). This is the
//  iPad counterpart of nii_GLView; the renderer + core are shared unchanged.
//
//  Only built for the iOS target (guarded so the file is inert if it ever lands
//  in a macOS compile).
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>

@interface NIIViewController : UIViewController <MTKViewDelegate>

/// Load a NIfTI/DICOM file at `path` (security-scoped URL resolved by the
/// document-picker layer). Pass nil/empty to load the built-in dummy volume.
- (void)loadImageAtPath:(NSString *)path;

@end

#endif

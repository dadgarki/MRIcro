//
//  NIIMetalRenderer.h
//  MRIcroX
//
//  The "renderer seam": a platform-neutral interface that replaces the OpenGL
//  entry points in nii_render.m. nii_img's doRedraw drives this instead of
//  calling GL directly, so the exact same renderer backs both the macOS (AppKit)
//  and iPad (UIKit) targets — the unified Metal renderer.
//
//  Ownership: this object owns all GPU resources that NII_PREFS used to hold as
//  GLuint handles (3D volume/gradient/overlay textures, pipeline states, the
//  cube vertex/index buffers, sampler state). Those fields in NII_PREFS are now
//  unused by Metal (see nii_platform.h) and are retired once OpenGL is deleted.
//
//  This header is ObjC so it can be imported from both .m (UI glue) and .mm
//  (nii_img). The implementation is .mm (NIIMetalRenderer.mm) because it bridges
//  to the C++ core. Metal symbols are forward-declared via @protocol so this
//  header stays cheap to include.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "nii_definetypes.h"

@class MTKView;
@protocol MTLDevice;
@protocol MTLTexture;

NS_ASSUME_NONNULL_BEGIN

/// CPU-side mirror of `VolumeUniforms` in Shaders.metal. Field order and packing
/// MUST stay identical to the MSL struct — keep both in sync when either changes.
typedef struct {
    simd_float4x4 mvp;
    simd_float3x3 normalMatrix;
    simd_float4   clipPlane;
    simd_float3   rayDir;
    simd_float3   textureSz;
    simd_float3   lightPosition;
    float         stepSize;
    float         sliceSize;
    float         clipThick;
    float         overlayClip;
    float         overlayFuzzy;
    float         overlayDepth;
    float         brighten;
    float         surfaceColor;
    float         backAlpha;
    float         ambient;
    float         diffuse;
    float         specular;
    float         shininess;
    float         surfaceHardness;
    int           overlays;
} NIIVolumeUniforms;

@interface NIIMetalRenderer : NSObject

/// The Metal device this renderer owns. Reuse it for any CPU-side text/label
/// rasterization that needs a device — do NOT call MTLCreateSystemDefaultDevice()
/// per draw (Metal best practice is a single device per app).
@property (nonatomic, readonly, nullable) id<MTLDevice> device;

/// Create a renderer bound to the device of the given MTKView and load
/// default.metallib (the compiled Shaders.metal). Returns nil if Metal is
/// unavailable or the library/pipelines fail to build.
- (nullable instancetype)initWithMTKView:(MTKView *)view;

/// Create a renderer with no view, for offscreen rendering (validation /
/// screenshots). Loads the shader library from `libraryURL` (a default.metallib)
/// if non-nil, else the device's default library. Renders to an RGBA8 target.
+ (nullable instancetype)offscreenRendererWithDevice:(id<MTLDevice>)device
                                          libraryURL:(nullable NSURL *)libraryURL;

/// Render the current volume to an offscreen RGBA8 image of the given size and
/// return newly-allocated width*height*4 bytes (caller frees). `bgRGBA` is the
/// clear color. Returns NULL if no volume is loaded. Also backs screenshots.
- (nullable void *)renderOffscreenRGBA:(NII_PREFS *)prefs
                                 width:(int)width
                                height:(int)height
                            background:(const float[_Nonnull 4])bgRGBA;

/// Offscreen full-frame composition (3D + 2D slices per displayModeGL) for
/// validation. Uses prefs->scrnDim/scrnWid/scrnHt as-is. Caller frees.
- (nullable void *)renderFullFrameOffscreenRGBA:(NII_PREFS *)prefs
                                          width:(int)width
                                         height:(int)height
                                     background:(const float[_Nonnull 4])bgRGBA;

/// Render a single 2D slice filling the image (orient = GL_2D_AXIAL /
/// GL_2D_CORONAL / GL_2D_SAGITTAL), sampling the intensity volume at
/// prefs->sliceFrac, with crosshairs. For validation and reused by the 2D
/// layout path. Returns newly-allocated width*height*4 RGBA8 (caller frees).
- (nullable void *)renderSliceOffscreenRGBA:(NII_PREFS *)prefs
                                orientation:(int)orient
                                      width:(int)width
                                     height:(int)height
                                 background:(const float[_Nonnull 4])bgRGBA;

#pragma mark - Volume texture management (replaces bindSubGL / glTexImage3D)

/// Upload an RGBA8 volume (LUT-applied voxels, as produced by recalcSubGL) into
/// the intensity 3D texture. `data` is voxelDim[1]*voxelDim[2]*voxelDim[3] RGBA bytes.
- (void)uploadIntensityVolume:(const void *)data dims:(const int[_Nonnull 4])voxelDim;

/// Upload an RGBA8 overlay volume into the overlay 3D texture (or clear when NULL).
- (void)uploadOverlayVolume:(nullable const void *)data dims:(const int[_Nonnull 4])voxelDim;

/// Replace a sub-box of an ALREADY UPLOADED volume, for data that changes faster than a
/// whole-volume upload can keep up with (see nii_img's updateStreamingOverlay). `bytes`
/// is tightly packed RGBA8 for the box, x fastest. No-op if the texture does not exist
/// yet or the box lies outside it — callers fall back to the full path.
/// Returns NO when nothing was uploaded.
- (BOOL)replaceIntensityRegion:(const void *)bytes
                        origin:(const int[_Nonnull 3])origin
                          size:(const int[_Nonnull 3])size;
- (BOOL)replaceOverlayRegion:(const void *)bytes
                      origin:(const int[_Nonnull 3])origin
                        size:(const int[_Nonnull 3])size;
/// YES once both the intensity volume and (if overlays are loaded) the overlay volume
/// exist, i.e. the region path has something to write into.
@property (nonatomic, readonly) BOOL hasIntensityVolume;
@property (nonatomic, readonly) BOOL hasOverlayVolume;

/// YES once the Sobel gradient texture exists (needed by the advanced/matcap path).
@property (nonatomic, readonly) BOOL hasGradients;

/// Recompute the gradient 3D texture(s) from the current intensity/overlay
/// volume(s) via the blur+Sobel compute kernels (replaces performBlurSobel's
/// render-to-3D-texture). Needed before advanced (MR/CT) rendering.
- (void)recomputeGradients;

/// Upload the RGBA8 matcap image (2D) used by the advanced MR shader for
/// gradient-based lighting (the GL path bound prefs->matcap2D).
- (void)uploadMatcapRGBA:(const void *)data width:(int)w height:(int)h;

/// Decode the bundled 00ShinyWhite.jpg matcap into this renderer (the same image
/// the GL path loads via loadMatCap). Call once per renderer.
- (void)loadMatcapFromBundle;

#pragma mark - Frame rendering (replaces redrawRender / redraw2D)

/// Render the 3D ray-cast only into the view (used by the live 3D window).
- (void)renderFrameWithPrefs:(NII_PREFS *)prefs inView:(MTKView *)view;

/// Render the full frame for the current prefs into the view's drawable: 3D
/// ray-cast (unless 2D-only) + 2D slice composition per prefs->displayModeGL.
/// Used by the standalone live preview window.
- (void)renderFullFrameWithPrefs:(NII_PREFS *)prefs inView:(MTKView *)view;

#pragma mark - Open-frame overlay composition (driven by nii_img's redraw)

/// Begin a frame: clear + 3D + 2D slices, leaving the encoder OPEN in pixel
/// space so the caller can add overlays (text/colorbar/DTI). Returns NO if no
/// drawable is available. Pair with -endFrame.
- (BOOL)beginFrameInView:(MTKView *)view prefs:(NII_PREFS *)prefs;

/// Draw a premultiplied glyph texture (from NIIMetalText) with its bottom-left
/// at pixel (x,y), tinted. Must be between begin/end.
- (void)drawGlyphTexture:(id<MTLTexture>)tex width:(int)w height:(int)h
                     atX:(float)x y:(float)y tint:(simd_float4)tint;

/// Draw solid-color line segments in pixel space (xy = 2 floats per vertex,
/// count vertices). Must be between begin/end.
- (void)drawLines:(const float *)xy count:(int)count color:(simd_float4)color width:(float)widthPx;

/// Draw per-vertex-colored triangles (verts = 7 floats each: x,y,z,r,g,b,a) in
/// the frame's pixel space. For the colorbar gradient. Must be between begin/end.
- (void)drawColoredVerts:(const float *)verts count:(int)count;

/// Draw the 3D orientation indicator (DrawCube replacement): the 6 anatomical
/// letters (L/R/A/P/S/I) as billboards at a small cube's projected face centers,
/// rotating with the view. Must be between begin/end (3D modes only).
- (void)drawOrientCubeForPrefs:(NII_PREFS *)prefs;

/// Finish the open frame: end encoding, present, commit.
- (void)endFrameInView:(MTKView *)view;

/// Offscreen frame for screenshots (composes overlays). Pair with
/// -endOffscreenReadback. Begin -> draw overlays -> end returns RGBA8 bytes.
- (BOOL)beginOffscreenFrameWidth:(int)w height:(int)h prefs:(NII_PREFS *)prefs;
- (nullable void *)endOffscreenReadback;

#pragma mark - Mosaic (montage of slices, replaces redrawMosaic's GL FBO path)

/// Begin a BLANK offscreen frame for the mosaic montage: clears to the prefs
/// background and leaves the encoder open in pixel space (ortho2D over w×h,
/// viewport 0,0,w,h, origin bottom-left like the slice path). Unlike
/// -beginOffscreenFrameWidth: it does NOT encode the 3D/2D scene — the caller
/// paints each cell with -drawMosaicSliceOrient: and labels with
/// -drawGlyphTexture:, then finishes with -endOffscreenReadback. Returns NO if
/// no volume is loaded. Readback is top-origin RGBA8 (no vertical flip needed).
- (BOOL)beginMosaicFrameWidth:(int)w height:(int)h prefs:(NII_PREFS *)prefs;

/// Draw one mosaic cell: a slice quad (no crosshairs) sampling the intensity
/// volume at the given per-cell `sliceFrac` (only the component for `orient` is
/// used). `orient` uses the mosaic convention: 1=axial, 2=coronal, 3=sagittal,
/// 4=sagittal-mirror. Axial/coronal honor prefs->viewRadiological. Must be
/// called between -beginMosaicFrameWidth: and -endOffscreenReadback.
- (void)drawMosaicSliceOrient:(int)orient x:(float)x y:(float)y w:(float)w h:(float)h
                    sliceFrac:(const double[_Nonnull 4])sliceFrac prefs:(NII_PREFS *)prefs;

@end

NS_ASSUME_NONNULL_END

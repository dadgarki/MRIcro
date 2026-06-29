//
//  nii_platform.h
//  MRIcroX
//
//  Cross-platform typedefs so the shared core and UI glue compile for both
//  macOS (AppKit) and iOS/iPadOS (UIKit). Introduced for the Metal/iPad port.
//
//  Rules of thumb:
//   - The portable C/C++ core (DICOM/NIfTI/math/codecs) must NOT depend on any
//     windowing framework. It may include this header for shared scalar typedefs.
//   - Platform color/image types differ between AppKit and UIKit; use the
//     PlatformColor/PlatformImage aliases below instead of NSColor/UIColor
//     directly so call sites stay source-compatible across targets.
//

#ifndef nii_platform_h
#define nii_platform_h

#include <stdint.h>

// TARGET_OS_* macros (TARGET_OS_OSX / TARGET_OS_IOS) come from here.
#if defined(__APPLE__)
    #include <TargetConditionals.h>
#endif

// ---------------------------------------------------------------------------
// GPU resource handles in shared structs.
//
// Historically NII_PREFS stored OpenGL object names as GLuint (== unsigned int),
// which dragged <OpenGL/gl.h> into every file that included nii_definetypes.h —
// a header that has no business knowing about a windowing/graphics API and which
// does not exist on iOS at all.
//
// kRenderHandle is an opaque 32-bit GPU object name. It stays ABI-identical to
// GLuint while the OpenGL renderer is still in the tree, so existing GL call
// sites (glGenTextures(&handle), glCallList(handle), ...) keep compiling
// untouched. The Metal renderer does NOT use these fields — it owns its
// id<MTLTexture>/id<MTLRenderPipelineState> objects in NIIMetalRenderer — so
// once OpenGL is deleted these handle fields go away entirely.
// ---------------------------------------------------------------------------
typedef uint32_t kRenderHandle;

#ifdef __OBJC__
    #if defined(TARGET_OS_OSX) && TARGET_OS_OSX
        @class NSColor;
        @class NSImage;
        typedef NSColor   PlatformColor;
        typedef NSImage   PlatformImage;
    #else
        @class UIColor;
        @class UIImage;
        typedef UIColor   PlatformColor;
        typedef UIImage   PlatformImage;
    #endif
#endif

#endif /* nii_platform_h */

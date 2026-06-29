//
//  NIIMetalRenderer.mm
//  MRIcroX
//
//  Metal implementation of the unified renderer. This file is the Metal
//  counterpart of the OpenGL code in nii_render.m. It is built for both the
//  macOS and iPad targets.
//
//  Scope status (Metal/iPad port):
//   - [x] device/library/pipeline setup
//   - [x] 3D intensity volume upload (replaces bindSubGL / glTexImage3D)
//   - [x] cube geometry + CPU-built MVP (replaces loadCube + the GL matrix stack)
//   - [x] default ray-cast frame (replaces drawBox / redrawRender, default path)
//   - [x] overlay/gradient textures, advanced MR/CT, Sobel compute
//   - [x] 2D slice / line / colored-quad / text pipelines
//   - [x] framebuffer readback (offscreen RGBA8 for screenshots / mosaic)
//
//  Matrix math is reconstructed from nii_render.m: resize2() (projection) and
//  drawBox() (modelview + rayDir). GL uses column-vector post-multiply
//  semantics (Current = Current * M), so the modelview is the product of the
//  glTranslatef/glRotatef/glScalef calls in call order, applied as M*v. simd is
//  also column-major with M*v, so the call order maps directly to left-to-right
//  matrix products here. The one real difference vs GL is clip-space depth:
//  Metal NDC z is [0,1], GL is [-1,1] — orthoMetal() below bakes in [0,1].
//

#import "NIIMetalRenderer.h"
#import "NIIMetalText.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>

// kDefaultDistance mirrors nii_render.m (renderDistance baseline used by resize2).
static const float kDefaultDistance = 2.25f;
static const float kMaxDistance     = 40.0f;

#pragma mark - matrix helpers (column-major simd, M*v)

static simd_float4x4 mtxIdentity(void) { return matrix_identity_float4x4; }

static simd_float4x4 mtxTranslate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (simd_float4){x, y, z, 1.0f};
    return m;
}

static simd_float4x4 mtxScale(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x; m.columns[1].y = y; m.columns[2].z = z;
    return m;
}

// Rotation by `deg` degrees about a normalized axis, matching glRotatef.
static simd_float4x4 mtxRotate(float deg, float ax, float ay, float az) {
    float r = deg * (float)M_PI / 180.0f;
    float c = cosf(r), s = sinf(r), t = 1.0f - c;
    simd_float3 a = simd_normalize((simd_float3){ax, ay, az});
    float x = a.x, y = a.y, z = a.z;
    simd_float4x4 m = matrix_identity_float4x4;
    // Column-major: columns[col].row
    m.columns[0] = (simd_float4){ t*x*x + c,    t*x*y + s*z,  t*x*z - s*y,  0 };
    m.columns[1] = (simd_float4){ t*x*y - s*z,  t*y*y + c,    t*y*z + s*x,  0 };
    m.columns[2] = (simd_float4){ t*x*z + s*y,  t*y*z - s*x,  t*z*z + c,    0 };
    m.columns[3] = (simd_float4){ 0,            0,            0,            1 };
    return m;
}

// CPU mirrors of the 2D MSL uniform structs (keep in sync with Shaders.metal).
typedef struct { simd_float4x4 mvp; int smooth; } Slice2DUniformsCPU;
typedef struct { simd_float4x4 mvp; simd_float4 color; } LineUniformsCPU;

// Pixel-space ortho for 2D slices/lines: x:[0,W]->[-1,1], y:[0,H]->[-1,1], z->0.5.
// Matches glOrtho(0,W,0,H,...) with identity modelview (enter2D in nii_img.mm).
static simd_float4x4 ortho2D(float W, float H) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = 2.0f / W;
    m.columns[1].y = 2.0f / H;
    m.columns[2].z = 0.0f;
    m.columns[3] = (simd_float4){-1.0f, -1.0f, 0.5f, 1.0f};
    return m;
}

// Orthographic projection with Metal [0,1] depth (vs glOrtho's [-1,1]).
static simd_float4x4 orthoMetal(float l, float r, float b, float t, float n, float f) {
    // Right-handed eye space (camera looks down -z) -> Metal NDC z in [0,1]:
    // z_eye=-n maps to 0, z_eye=-f maps to 1, i.e. z_clip = -(z_eye+n)/(f-n).
    simd_float4x4 m = (simd_float4x4){{
        { 2.0f/(r-l),        0,                 0,            0 },
        { 0,                 2.0f/(t-b),         0,            0 },
        { 0,                 0,                -1.0f/(f-n),    0 },
        { -(r+l)/(r-l),     -(t+b)/(t-b),      -n/(f-n),      1 },
    }};
    return m;
}

// The rotation*scale matrix `m` from drawBox(), used for rayDir and NormalMatrix.
// GL builds it with nifti's ROW-major mat44 ops (RotateX/RotateZ post-multiply
// row-major), so the column-major simd translation is the TRANSPOSE of a direct
// glRotatef translation — hence the elevation/azimuth angles are negated here
// relative to mvpForPrefs. Verified empirically: this orientation renders the
// volume correctly; the naive same-sign-as-MVP version does not.
static simd_float4x4 volumeRotScale(const NII_PREFS *p) {
    // MUST use the SAME rotation as mvpForPrefs' modelview linear part, else the
    // ray direction is inconsistent with how the cube is drawn and the volume
    // content shifts/skews inside the (correctly-placed) cube.
    simd_float4x4 m = mtxIdentity();
    m = simd_mul(m, mtxRotate(90.0f - p->renderElevation, -1, 0, 0));
    m = simd_mul(m, mtxRotate(p->renderAzimuth, 0, 0, 1));
    m = simd_mul(m, mtxScale(p->TexScale[1], p->TexScale[2], p->TexScale[3]));
    return m;
}

// Spherical (azimuth, elevation) -> Cartesian, matching sph2cartDeg90x in
// nii_render.m (used for the clip plane and light direction).
static void sph2cartDeg90x(float azimuthDeg, float elevationDeg,
                           float *x, float *y, float *z) {
    float theta = (azimuthDeg - 90.0f) * (float)M_PI / 180.0f;
    float E = elevationDeg;
    if (E > 360 || E < -360) E -= truncf(E / 360.0f) * 360.0f;
    if ((E > 89 && E < 91) || (E < -269 && E > -271)) E = 90;
    if ((E > 269 && E < 271) || (E < -89 && E > -91)) E = -90;
    float phi = E * (float)M_PI / 180.0f;
    *x = cosf(phi) * cosf(theta);
    *y = cosf(phi) * sinf(theta);
    *z = sinf(phi);
}

static simd_float3x3 upper3x3(simd_float4x4 m) {
    simd_float3 c0 = {m.columns[0].x, m.columns[0].y, m.columns[0].z};
    simd_float3 c1 = {m.columns[1].x, m.columns[1].y, m.columns[1].z};
    simd_float3 c2 = {m.columns[2].x, m.columns[2].y, m.columns[2].z};
    return simd_matrix(c0, c1, c2);
}

// (0,0,-1) ray direction transformed into volume space, matching drawBox().
static simd_float3 computeRayDir(const NII_PREFS *prefs) {
    simd_float4x4 inv = simd_inverse(volumeRotScale(prefs));
    simd_float4 dir = simd_mul(inv, (simd_float4){0, 0, -1, 0});
    simd_float3 d = (simd_float3){dir.x, dir.y, dir.z};
    d = simd_normalize(d);
    // addFuzz: avoid exact zeros (division in the shader's GetBackPosition).
    const float kEPS = 0.0001f;
    if (fabsf(d.x) < kEPS) d.x = kEPS;
    if (fabsf(d.y) < kEPS) d.y = kEPS;
    if (fabsf(d.z) < kEPS) d.z = kEPS;
    return d;
}

// View-centered light direction, an exact port of nii_render.m's lightUniforms:
//   1. base light = sph2cartDeg90x(azimuth 90, elevation 20)  -> (cos20,0,sin20)
//   2. reorder components to (lY, lZ, lX)  (the GL lA/lB/lC swap)
//   3. multiply by transpose(upper3x3(modelview)) — GL fetched the TRANSPOSE
//      modelview and dotted the light against its columns. volumeRotScale is the
//      modelview's linear part (rotation*TexScale), so this matches exactly.
//   4. defuzz near-zero components, then normalize.
static simd_float3 computeLightDir(const NII_PREFS *p) {
    float lx, ly, lz;
    sph2cartDeg90x(90.0f, 20.0f, &lx, &ly, &lz);
    simd_float3 base = (simd_float3){ly, lz, lx}; // GL reorder: (lA,lB,lC)=(lY,lZ,lX)
    simd_float3 l = simd_mul(simd_transpose(upper3x3(volumeRotScale(p))), base);
    const float kEPS = 1e-6f; // defuzz() in GL zeroes near-zero components
    if (fabsf(l.x) < kEPS) l.x = 0;
    if (fabsf(l.y) < kEPS) l.y = 0;
    if (fabsf(l.z) < kEPS) l.z = 0;
    float n = simd_length(l);
    return (n > 1e-6f) ? (l / n) : (simd_float3){0, 0, 1};
}

#pragma mark - renderer

@implementation NIIMetalRenderer {
    id<MTLDevice>               _device;
    id<MTLCommandQueue>         _queue;
    id<MTLRenderPipelineState>  _volumePipelineDefault;
    id<MTLRenderPipelineState>  _volumePipelineAdvMR; // advanced MR (matcap)
    id<MTLRenderPipelineState>  _volumePipelineAdvCT; // advanced CT (Phong)
    id<MTLRenderPipelineState>  _slicePipeline;   // 2D textured slice quads
    id<MTLRenderPipelineState>  _linePipeline;    // solid-color crosshairs/vectors
    id<MTLRenderPipelineState>  _coloredPipeline; // orientation cube / colorbar / histogram
    id<MTLRenderPipelineState>  _textPipeline;    // GLString replacement (textured glyphs)
    id<MTLComputePipelineState> _blurKernel;    // gradient pass 1
    id<MTLComputePipelineState> _sobelKernel;   // gradient pass 2
    id<MTLBuffer>               _cubeVerts;   // 8 * float3
    id<MTLBuffer>               _cubeIndices; // 14 * uint16 (triangle strip)
    NSUInteger                  _cubeIndexCount;
    id<MTLTexture>              _intensityVolume;
    id<MTLTexture>              _overlayVolume;
    id<MTLTexture>              _gradientVolume;  // Sobel gradient of intensity
    id<MTLTexture>              _gradientOverlay; // Sobel gradient of overlay
    id<MTLTexture>              _tempBlur;        // scratch for blur pass
    id<MTLTexture>              _matcap;          // 2D matcap for advanced MR
    void                      *_lastReadback; // owned, freed on dealloc
    // Open-frame state for overlay composition (begin/draw/end driven by nii_img)
    id<MTLCommandBuffer>        _frameCB;
    id<MTLRenderCommandEncoder> _frameEnc;
    id<CAMetalDrawable>         _frameDrawable;
    id<MTLTexture>             _offscreenTarget; // for screenshot begin/end
    simd_float4x4               _frameMVP;   // pixel-space ortho for overlays
}

- (nullable instancetype)initWithMTKView:(MTKView *)view {
    id<MTLDevice> device = view.device ?: MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    view.device = device;
    self = [self initWithDevice:device
               colorPixelFormat:view.colorPixelFormat
                     libraryURL:nil];
    return self;
}

+ (nullable instancetype)offscreenRendererWithDevice:(id<MTLDevice>)device
                                          libraryURL:(nullable NSURL *)libraryURL {
    if (!device) return nil;
    return [[self alloc] initWithDevice:device
                       colorPixelFormat:MTLPixelFormatRGBA8Unorm
                             libraryURL:libraryURL];
}

// Designated initializer: builds queue, the default ray-cast pipeline (matching
// the render target's pixel format), and the cube geometry.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                       colorPixelFormat:(MTLPixelFormat)pixelFormat
                             libraryURL:(nullable NSURL *)libraryURL {
    self = [super init];
    if (!self) return nil;
    _device = device;
    if (!_device) return nil;
    _queue = [_device newCommandQueue];

    NSError *libErr = nil;
    id<MTLLibrary> lib = libraryURL
        ? [_device newLibraryWithURL:libraryURL error:&libErr]
        : [_device newDefaultLibrary];
    if (!lib) { NSLog(@"NIIMetalRenderer: library load failed: %@", libErr); return nil; }
    id<MTLFunction> vfn = [lib newFunctionWithName:@"volumeVertex"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"volumeFragmentDefault"];
    if (!vfn || !ffn) return nil;

    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = vfn;
    pd.fragmentFunction = ffn;
    pd.colorAttachments[0].pixelFormat = pixelFormat;
    // Premultiplied-over blending matching the GL path
    // (glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA); shader premultiplies rgb by a).
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    // Vertex layout: a single float3 position attribute at buffer(0).
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(float) * 3;
    pd.vertexDescriptor = vd;

    NSError *err = nil;
    _volumePipelineDefault = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_volumePipelineDefault) {
        NSLog(@"NIIMetalRenderer: volume pipeline failed: %@", err);
        return nil;
    }

    // 2D slice pipeline: standard (non-premultiplied) alpha blend.
    {
        MTLRenderPipelineDescriptor *sp = [[MTLRenderPipelineDescriptor alloc] init];
        sp.vertexFunction = [lib newFunctionWithName:@"sliceVertex"];
        sp.fragmentFunction = [lib newFunctionWithName:@"sliceFragment"];
        sp.colorAttachments[0].pixelFormat = pixelFormat;
        // 2D slices are opaque (GL disables blend for them); the fragment
        // discards background voxels (alpha <= 0.01) instead.
        sp.colorAttachments[0].blendingEnabled = NO;
        MTLVertexDescriptor *svd = [[MTLVertexDescriptor alloc] init];
        svd.attributes[0].format = MTLVertexFormatFloat2; // position
        svd.attributes[0].offset = 0;
        svd.attributes[0].bufferIndex = 0;
        svd.attributes[1].format = MTLVertexFormatFloat3; // 3D texcoord
        svd.attributes[1].offset = sizeof(float) * 2;
        svd.attributes[1].bufferIndex = 0;
        svd.layouts[0].stride = sizeof(float) * 5;
        sp.vertexDescriptor = svd;
        _slicePipeline = [_device newRenderPipelineStateWithDescriptor:sp error:&err];
        if (!_slicePipeline) { NSLog(@"NIIMetalRenderer: slice pipeline failed: %@", err); return nil; }
    }

    // Line pipeline: solid color, vertices pulled manually from buffer(0).
    {
        MTLRenderPipelineDescriptor *lp = [[MTLRenderPipelineDescriptor alloc] init];
        lp.vertexFunction = [lib newFunctionWithName:@"lineVertex"];
        lp.fragmentFunction = [lib newFunctionWithName:@"lineFragment"];
        lp.colorAttachments[0].pixelFormat = pixelFormat;
        lp.colorAttachments[0].blendingEnabled = NO;
        _linePipeline = [_device newRenderPipelineStateWithDescriptor:lp error:&err];
        if (!_linePipeline) { NSLog(@"NIIMetalRenderer: line pipeline failed: %@", err); return nil; }
    }

    // Colored geometry pipeline (orientation cube / colorbar / histogram).
    {
        MTLRenderPipelineDescriptor *cp = [[MTLRenderPipelineDescriptor alloc] init];
        cp.vertexFunction = [lib newFunctionWithName:@"coloredVertex"];
        cp.fragmentFunction = [lib newFunctionWithName:@"coloredFragment"];
        cp.colorAttachments[0].pixelFormat = pixelFormat;
        cp.colorAttachments[0].blendingEnabled = YES;
        cp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        cp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        cp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        cp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        MTLVertexDescriptor *cvd = [[MTLVertexDescriptor alloc] init];
        cvd.attributes[0].format = MTLVertexFormatFloat3; // position
        cvd.attributes[0].offset = 0; cvd.attributes[0].bufferIndex = 0;
        cvd.attributes[1].format = MTLVertexFormatFloat4; // color
        cvd.attributes[1].offset = sizeof(float) * 3; cvd.attributes[1].bufferIndex = 0;
        cvd.layouts[0].stride = sizeof(float) * 7;
        cp.vertexDescriptor = cvd;
        _coloredPipeline = [_device newRenderPipelineStateWithDescriptor:cp error:&err];
        if (!_coloredPipeline) { NSLog(@"NIIMetalRenderer: colored pipeline failed: %@", err); return nil; }
    }

    // Text pipeline (premultiplied glyph blend, matching GLString).
    {
        MTLRenderPipelineDescriptor *tp = [[MTLRenderPipelineDescriptor alloc] init];
        tp.vertexFunction = [lib newFunctionWithName:@"textVertex"];
        tp.fragmentFunction = [lib newFunctionWithName:@"textFragment"];
        tp.colorAttachments[0].pixelFormat = pixelFormat;
        tp.colorAttachments[0].blendingEnabled = YES;
        tp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        tp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        tp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        tp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        MTLVertexDescriptor *tvd = [[MTLVertexDescriptor alloc] init];
        tvd.attributes[0].format = MTLVertexFormatFloat2; // position
        tvd.attributes[0].offset = 0; tvd.attributes[0].bufferIndex = 0;
        tvd.attributes[1].format = MTLVertexFormatFloat2; // texcoord
        tvd.attributes[1].offset = sizeof(float) * 2; tvd.attributes[1].bufferIndex = 0;
        tvd.layouts[0].stride = sizeof(float) * 4;
        tp.vertexDescriptor = tvd;
        _textPipeline = [_device newRenderPipelineStateWithDescriptor:tp error:&err];
        if (!_textPipeline) { NSLog(@"NIIMetalRenderer: text pipeline failed: %@", err); return nil; }
    }

    // Advanced render pipelines reuse pd's vertex stage, vertex descriptor, and blend.
    pd.fragmentFunction = [lib newFunctionWithName:@"volumeFragmentAdvancedMR"];
    _volumePipelineAdvMR = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_volumePipelineAdvMR) { NSLog(@"NIIMetalRenderer: adv MR pipeline failed: %@", err); return nil; }
    pd.fragmentFunction = [lib newFunctionWithName:@"volumeFragmentAdvancedCT"];
    _volumePipelineAdvCT = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_volumePipelineAdvCT) { NSLog(@"NIIMetalRenderer: adv CT pipeline failed: %@", err); return nil; }

    // Gradient compute pipelines.
    id<MTLFunction> blurFn  = [lib newFunctionWithName:@"gradientBlur"];
    id<MTLFunction> sobelFn = [lib newFunctionWithName:@"gradientSobel"];
    if (!blurFn || !sobelFn) return nil;
    _blurKernel  = [_device newComputePipelineStateWithFunction:blurFn error:&err];
    if (!_blurKernel) { NSLog(@"NIIMetalRenderer: blur kernel failed: %@", err); return nil; }
    _sobelKernel = [_device newComputePipelineStateWithFunction:sobelFn error:&err];
    if (!_sobelKernel) { NSLog(@"NIIMetalRenderer: sobel kernel failed: %@", err); return nil; }

    [self buildCube];
    [self buildDefaultMatcap];
    return self;
}

- (void)dealloc {
    if (_lastReadback) free(_lastReadback);
}

// Unit-cube geometry from loadCube() in nii_render.m: 8 corners, a 14-index
// triangle strip with reversed winding so back-face culling keeps the far faces.
- (void)buildCube {
    static const float vtx[8 * 3] = {
        0,0,0,  0,1,0,  1,1,0,  1,0,0,
        0,0,1,  0,1,1,  1,1,1,  1,0,1,
    };
    static const uint16_t idx[14] = {0,1,3,2,6,1,5,4, 6,7,3, 4, 0, 1};
    _cubeVerts   = [_device newBufferWithBytes:vtx length:sizeof(vtx) options:MTLResourceStorageModeShared];
    _cubeIndices = [_device newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
    _cubeIndexCount = 14;
}

#pragma mark - volume upload

- (id<MTLTexture>)makeVolumeTextureFrom:(const void *)data dims:(const int[4])d {
    if (data == NULL || d[1] < 1 || d[2] < 1 || d[3] < 1) return nil;
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width  = d[1];
    td.height = d[2];
    td.depth  = d[3];
    td.usage  = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    // Managed: separate CPU/GPU copies on Intel Macs; fine on Apple Silicon too.
    td.storageMode = MTLStorageModeManaged;
#else
    // iOS/iPadOS has unified memory — Shared, and Managed is unavailable.
    td.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
    MTLRegion region = MTLRegionMake3D(0, 0, 0, d[1], d[2], d[3]);
    [tex replaceRegion:region
           mipmapLevel:0
                 slice:0
             withBytes:data
           bytesPerRow:(NSUInteger)d[1] * 4
         bytesPerImage:(NSUInteger)d[1] * d[2] * 4];
    return tex;
}

- (void)uploadIntensityVolume:(const void *)data dims:(const int[4])voxelDim {
    _intensityVolume = [self makeVolumeTextureFrom:data dims:voxelDim];
}

- (void)uploadOverlayVolume:(const void *)data dims:(const int[4])voxelDim {
    _overlayVolume = (data == NULL) ? nil : [self makeVolumeTextureFrom:data dims:voxelDim];
}

- (id<MTLTexture>)makeWritable3D:(NSUInteger)w h:(NSUInteger)h d:(NSUInteger)d {
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = w; td.height = h; td.depth = d;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    td.storageMode = MTLStorageModePrivate; // GPU-only (compute writes, shader reads)
    return [_device newTextureWithDescriptor:td];
}

// Dispatch blur then Sobel over `src` -> `dstGradient`, using `tmp` as scratch.
- (void)computeGradientFrom:(id<MTLTexture>)src into:(id<MTLTexture>)dstGradient tmp:(id<MTLTexture>)tmp {
    MTLSize grid = MTLSizeMake(src.width, src.height, src.depth);
    MTLSize tg = MTLSizeMake(8, 8, 4);
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:_blurKernel];
    [ce setTexture:src atIndex:0];
    [ce setTexture:tmp atIndex:1];
    [ce dispatchThreads:grid threadsPerThreadgroup:tg];
    [ce memoryBarrierWithScope:MTLBarrierScopeTextures]; // blur must finish before Sobel reads tmp
    [ce setComputePipelineState:_sobelKernel];
    [ce setTexture:tmp atIndex:0];
    [ce setTexture:dstGradient atIndex:1];
    [ce dispatchThreads:grid threadsPerThreadgroup:tg];
    [ce endEncoding];
    [cb commit];
}

- (BOOL)hasGradients { return _gradientVolume != nil; }

- (void)recomputeGradients {
    if (!_intensityVolume) return;
    NSUInteger w = _intensityVolume.width, h = _intensityVolume.height, d = _intensityVolume.depth;
    if (!_tempBlur || _tempBlur.width != w || _tempBlur.height != h || _tempBlur.depth != d)
        _tempBlur = [self makeWritable3D:w h:h d:d];
    if (!_gradientVolume || _gradientVolume.width != w || _gradientVolume.height != h || _gradientVolume.depth != d)
        _gradientVolume = [self makeWritable3D:w h:h d:d];
    [self computeGradientFrom:_intensityVolume into:_gradientVolume tmp:_tempBlur];
    if (_overlayVolume) {
        if (!_gradientOverlay || _gradientOverlay.width != w || _gradientOverlay.height != h || _gradientOverlay.depth != d)
            _gradientOverlay = [self makeWritable3D:w h:h d:d];
        [self computeGradientFrom:_overlayVolume into:_gradientOverlay tmp:_tempBlur];
    }
}

- (void)uploadMatcapRGBA:(const void *)data width:(int)w height:(int)h {
    if (!data || w < 1 || h < 1) return;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0
             withBytes:data bytesPerRow:(NSUInteger)w * 4];
    _matcap = tex;
}

// 1x1 white fallback so the advanced-MR pipeline's matcap binding is always
// satisfied before the app uploads the real matcap (00ShinyWhite.jpg).
- (void)buildDefaultMatcap {
    uint32_t white = 0xFFFFFFFF;
    [self uploadMatcapRGBA:&white width:1 height:1];
}

- (void)loadMatcapFromBundle {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"00ShinyWhite" ofType:@"jpg"];
    if (!path) return;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return;
    int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
    uint8_t *rgba = (uint8_t *)calloc((size_t)w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = rgba ? CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        [self uploadMatcapRGBA:rgba width:w height:h];
        CGContextRelease(ctx);
    }
    free(rgba); CGColorSpaceRelease(cs); CGImageRelease(img);
}

#pragma mark - frame

#pragma mark - Open-frame overlay composition

- (BOOL)beginFrameInView:(MTKView *)view prefs:(NII_PREFS *)prefs {
    if (!_intensityVolume) return NO;
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    _frameDrawable = view.currentDrawable;
    if (!rpd || !_frameDrawable) return NO;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(
        prefs->backColor[0], prefs->backColor[1], prefs->backColor[2], 1.0);

    BOOL is2D = (prefs->displayModeGL == GL_2D_ONLY) || (prefs->displayModeGL == GL_2D_AXIAL)
             || (prefs->displayModeGL == GL_2D_CORONAL) || (prefs->displayModeGL == GL_2D_SAGITTAL);

    double dw = view.drawableSize.width, dh = view.drawableSize.height;
    _frameCB = [_queue commandBuffer];
    _frameEnc = [_frameCB renderCommandEncoderWithDescriptor:rpd];
    if (!is2D && prefs->renderWid > 0 && prefs->renderHt > 0) {
        double vy = (double)(prefs->scrnHt - (prefs->scrnOffsetY + prefs->renderBottom) - prefs->renderHt);
        // Clamp to the drawable — an out-of-bounds viewport aborts Metal validation.
        MTLViewport vp = (MTLViewport){
            (double)(prefs->scrnOffsetX + prefs->renderLeft), vy,
            (double)prefs->renderWid, (double)prefs->renderHt, 0.0, 1.0};
        if (vp.originX < 0) { vp.width += vp.originX; vp.originX = 0; }
        if (vp.originY < 0) { vp.height += vp.originY; vp.originY = 0; }
        if (vp.originX + vp.width > dw)  vp.width  = dw - vp.originX;
        if (vp.originY + vp.height > dh) vp.height = dh - vp.originY;
        if (vp.width > 0 && vp.height > 0)
            [self encode3DInto:_frameEnc prefs:prefs viewport:vp];
    }
    if (is2D || prefs->displayModeGL == GL_2D_AND_3D)
        [self encode2DInto:_frameEnc prefs:prefs];

    // Leave the encoder in full-window pixel space for overlays.
    float W = prefs->scrnWid > 0 ? prefs->scrnWid : 1, H = prefs->scrnHt > 0 ? prefs->scrnHt : 1;
    _frameMVP = ortho2D(W, H);
    [_frameEnc setViewport:(MTLViewport){(double)prefs->scrnOffsetX, (double)prefs->scrnOffsetY,
                                         (double)W, (double)H, 0.0, 1.0}];
    return YES;
}

- (void)drawGlyphTexture:(id<MTLTexture>)tex width:(int)w height:(int)h
                     atX:(float)x y:(float)y tint:(simd_float4)tint {
    if (!_frameEnc || !tex) return;
    // quad: pos(float2)+texcoord(float2), bottom-left at (x,y), texture upright
    // (texcoord y flipped because the glyph bitmap is top-left origin).
    float q[6 * 4] = {
        x,     y,     0, 1,   x + w, y,     1, 1,   x + w, y + h, 1, 0,
        x,     y,     0, 1,   x + w, y + h, 1, 0,   x,     y + h, 0, 0,
    };
    typedef struct { simd_float4x4 mvp; simd_float4 tint; } TextU;
    TextU u; u.mvp = _frameMVP; u.tint = tint;
    [_frameEnc setRenderPipelineState:_textPipeline];
    [_frameEnc setVertexBytes:q length:sizeof(q) atIndex:0];
    [_frameEnc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [_frameEnc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [_frameEnc setFragmentTexture:tex atIndex:0];
    [_frameEnc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Draw independent line segments (`verts` = `count` points, consecutive pairs
// forming segments) as filled quads of pixel width `w` — Metal line primitives
// ignore width, so GL's glLineWidth(2)/(5) crosshairs/DTI are rendered as
// perpendicular-expanded rectangles. Uses the line pipeline (positions @0) with
// triangles, the given pixel-space `mvp` and `color`.
- (void)encodeSegments:(const simd_float2 *)verts count:(int)count
                   mvp:(simd_float4x4)mvp color:(simd_float4)color
                 width:(float)w into:(id<MTLRenderCommandEncoder>)enc {
    int nseg = count / 2;
    if (!enc || nseg < 1) return;
    int outN = nseg * 6;
    simd_float2 *q = (simd_float2 *)malloc(sizeof(simd_float2) * (size_t)outN);
    if (!q) return;
    float h = w * 0.5f;
    int o = 0;
    for (int i = 0; i + 1 < count; i += 2) {
        simd_float2 a = verts[i], b = verts[i + 1];
        simd_float2 d = b - a;
        float len = simd_length(d);
        simd_float2 n = (len > 1e-5f) ? (simd_float2){ -d.y / len * h, d.x / len * h }
                                      : (simd_float2){ h, 0 };
        simd_float2 a0 = a - n, a1 = a + n, b0 = b - n, b1 = b + n;
        q[o++] = a0; q[o++] = b0; q[o++] = b1; // triangle 1
        q[o++] = a0; q[o++] = b1; q[o++] = a1; // triangle 2
    }
    LineUniformsCPU lu; lu.mvp = mvp; lu.color = color;
    [enc setRenderPipelineState:_linePipeline];
    [enc setVertexBytes:q length:sizeof(simd_float2) * (NSUInteger)outN atIndex:0];
    [enc setVertexBytes:&lu length:sizeof(lu) atIndex:1];
    [enc setFragmentBytes:&lu length:sizeof(lu) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)outN];
    free(q);
}

- (void)drawLines:(const float *)xy count:(int)count color:(simd_float4)color width:(float)widthPx {
    if (!_frameEnc || count < 2) return;
    [self encodeSegments:(const simd_float2 *)xy count:count
                     mvp:_frameMVP color:color width:widthPx into:_frameEnc];
}

- (void)drawColoredVerts:(const float *)verts count:(int)count {
    if (!_frameEnc || count < 3) return;
    id<MTLBuffer> buf = [_device newBufferWithBytes:verts
                                             length:(NSUInteger)count * 7 * sizeof(float)
                                            options:MTLResourceStorageModeShared];
    typedef struct { simd_float4x4 mvp; } ColoredU;
    ColoredU u; u.mvp = _frameMVP;
    [_frameEnc setRenderPipelineState:_coloredPipeline];
    [_frameEnc setVertexBuffer:buf offset:0 atIndex:0];
    [_frameEnc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [_frameEnc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
}

- (void)drawOrientCubeForPrefs:(NII_PREFS *)p {
    if (!_frameEnc || !p->showCube) return;
    float mx = p->renderWid * 0.04f;
    if (mx < 4) return;
    float ox = p->renderLeft + 1.8f * mx, oy = 1.8f * mx;
    // Same rotation as the modelview (glRotatef(90-elev,-1,0,0)*glRotatef(az,0,0,1));
    // ortho is 1:1 pixels, so the transformed x,y are screen pixels.
    simd_float4x4 mv = mtxTranslate(ox, oy, 0);
    mv = simd_mul(mv, mtxRotate(90.0f - p->renderElevation, -1, 0, 0));
    mv = simd_mul(mv, mtxRotate(p->renderAzimuth, 0, 0, 1));
    NSString *lr  = p->viewRadiological ? @"L" : @"R";
    NSString *rl  = p->viewRadiological ? @"R" : @"L";
    struct { simd_float3 pos; NSString *lab; } faces[6] = {
        {{ mx, 0, 0}, lr}, {{-mx, 0, 0}, rl},
        {{ 0, mx, 0}, @"A"}, {{ 0,-mx, 0}, @"P"},
        {{ 0, 0, mx}, @"S"}, {{ 0, 0,-mx}, @"I"},
    };
    CGFloat fs = mx * 0.9; if (fs < 8) fs = 8;
    for (int i = 0; i < 6; i++) {
        simd_float4 v = simd_mul(mv, (simd_float4){faces[i].pos.x, faces[i].pos.y, faces[i].pos.z, 1});
        NIIMetalText *t = [[NIIMetalText alloc] initWithString:faces[i].lab pointSize:fs device:_device];
        if (t.texture)
            [self drawGlyphTexture:t.texture width:t.pixelWidth height:t.pixelHeight
                               atX:(v.x - t.pixelWidth/2.0f) y:(v.y - t.pixelHeight/2.0f)
                              tint:(simd_float4){1.0f, 1.0f, 0.4f, 1.0f}];
    }
}

- (void)endFrameInView:(MTKView *)view {
    if (!_frameEnc) return;
    [_frameEnc endEncoding];
    [_frameCB presentDrawable:_frameDrawable];
    [_frameCB commit];
    _frameEnc = nil; _frameCB = nil; _frameDrawable = nil;
}

// Offscreen begin/end so screenshots include the overlays (same composition as
// the live frame). Pair beginOffscreenFrame with endOffscreenReadback.
- (BOOL)beginOffscreenFrameWidth:(int)w height:(int)h prefs:(NII_PREFS *)prefs {
    if (!_intensityVolume || w < 1 || h < 1) return NO;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    _offscreenTarget = [_device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = _offscreenTarget;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(prefs->backColor[0], prefs->backColor[1], prefs->backColor[2], 1.0);

    BOOL is2D = (prefs->displayModeGL == GL_2D_ONLY) || (prefs->displayModeGL == GL_2D_AXIAL)
             || (prefs->displayModeGL == GL_2D_CORONAL) || (prefs->displayModeGL == GL_2D_SAGITTAL);
    _frameCB = [_queue commandBuffer];
    _frameEnc = [_frameCB renderCommandEncoderWithDescriptor:rpd];
    if (!is2D && prefs->renderWid > 0 && prefs->renderHt > 0) {
        double vy = (double)(prefs->scrnHt - (prefs->scrnOffsetY + prefs->renderBottom) - prefs->renderHt);
        MTLViewport vp = (MTLViewport){(double)(prefs->scrnOffsetX + prefs->renderLeft), vy,
                                       (double)prefs->renderWid, (double)prefs->renderHt, 0.0, 1.0};
        if (vp.originX < 0) { vp.width += vp.originX; vp.originX = 0; }
        if (vp.originY < 0) { vp.height += vp.originY; vp.originY = 0; }
        if (vp.originX + vp.width > w)  vp.width  = w - vp.originX;
        if (vp.originY + vp.height > h) vp.height = h - vp.originY;
        if (vp.width > 0 && vp.height > 0)
            [self encode3DInto:_frameEnc prefs:prefs viewport:vp];
    }
    if (is2D || prefs->displayModeGL == GL_2D_AND_3D)
        [self encode2DInto:_frameEnc prefs:prefs];
    float W = prefs->scrnWid > 0 ? prefs->scrnWid : 1, H = prefs->scrnHt > 0 ? prefs->scrnHt : 1;
    _frameMVP = ortho2D(W, H);
    [_frameEnc setViewport:(MTLViewport){(double)prefs->scrnOffsetX, (double)prefs->scrnOffsetY,
                                         (double)W, (double)H, 0.0, 1.0}];
    return YES;
}

- (nullable void *)endOffscreenReadback {
    if (!_frameEnc) return NULL;
    [_frameEnc endEncoding];
#if TARGET_OS_OSX
    id<MTLBlitCommandEncoder> blit = [_frameCB blitCommandEncoder];
    [blit synchronizeResource:_offscreenTarget]; [blit endEncoding];
#endif
    [_frameCB commit]; [_frameCB waitUntilCompleted];
    int w = (int)_offscreenTarget.width, h = (int)_offscreenTarget.height;
    void *rgba = malloc((size_t)w * h * 4);
    if (rgba) [_offscreenTarget getBytes:rgba bytesPerRow:(NSUInteger)w * 4
                              fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    _frameEnc = nil; _frameCB = nil; _offscreenTarget = nil;
    return rgba;
}

// Begin a blank offscreen mosaic frame (bg-cleared, no scene). Pixel space is
// ortho2D(w,h) with viewport (0,0,w,h) — same bottom-left convention as the
// 2D slice path, so cell positions match the GL drawAx/Coro/Sag montage.
- (BOOL)beginMosaicFrameWidth:(int)w height:(int)h prefs:(NII_PREFS *)prefs {
    if (!_intensityVolume || w < 1 || h < 1) return NO;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    _offscreenTarget = [_device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = _offscreenTarget;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(prefs->backColor[0], prefs->backColor[1], prefs->backColor[2], 1.0);
    _frameCB = [_queue commandBuffer];
    _frameEnc = [_frameCB renderCommandEncoderWithDescriptor:rpd];
    _frameMVP = ortho2D((float)w, (float)h);
    [_frameEnc setViewport:(MTLViewport){0.0, 0.0, (double)w, (double)h, 0.0, 1.0}];
    return YES;
}

// Draw one mosaic cell quad (no crosshairs). orient uses the mosaic convention
// (1=axial 2=coronal 3=sagittal 4=sag-mirror); only sliceFrac[component] is read.
- (void)drawMosaicSliceOrient:(int)orient x:(float)x y:(float)y w:(float)w h:(float)h
                    sliceFrac:(const double[4])sliceFrac prefs:(NII_PREFS *)prefs {
    if (!_frameEnc) return;
    float flip = prefs->viewRadiological ? 1.0f : 0.0f;
    float quad[6*5];
    if (orient == 1)        // axial: honors radiological flip
        buildSliceQuad(quad, GL_2D_AXIAL, sliceFrac, flip, x, y, w, h);
    else if (orient == 2)   // coronal: honors radiological flip
        buildSliceQuad(quad, GL_2D_CORONAL, sliceFrac, flip, x, y, w, h);
    else {                  // sagittal (3) or sagittal-mirror (4)
        buildSliceQuad(quad, GL_2D_SAGITTAL, sliceFrac, 0.0f, x, y, w, h);
        if (orient == 4)    // mirror: flip the in-plane horizontal (tex.y)
            for (int i = 0; i < 6; i++) quad[i*5+3] = 1.0f - quad[i*5+3];
    }
    Slice2DUniformsCPU su; su.mvp = _frameMVP; su.smooth = prefs->isSmooth2D ? 1 : 0;
    [_frameEnc setRenderPipelineState:_slicePipeline];
    [_frameEnc setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [_frameEnc setVertexBytes:&su length:sizeof(su) atIndex:1];
    [_frameEnc setFragmentBytes:&su length:sizeof(su) atIndex:1];
    [_frameEnc setFragmentTexture:_intensityVolume atIndex:0];
    [_frameEnc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Build the MVP equivalent to resize2() projection * drawBox() modelview.
- (simd_float4x4)mvpForPrefs:(const NII_PREFS *)p {
    float w = p->renderWid  > 0 ? (float)p->renderWid  : 1.0f;
    float h = p->renderHt   > 0 ? (float)p->renderHt   : 1.0f;
    float scale = (p->renderDistance == 0)
        ? 1.0f
        : 1.0f / fabsf(kDefaultDistance / (p->renderDistance + 1.0f));
    float whratio = w / h;
    simd_float4x4 proj = orthoMetal(whratio * -0.5f * scale, whratio * 0.5f * scale,
                                    -0.5f * scale, 0.5f * scale, 0.01f, kMaxDistance);

    // Modelview: post-multiplied GL calls in call order (applied as M*v).
    simd_float4x4 mv = mtxIdentity();
    mv = simd_mul(mv, mtxTranslate(0, 0, -p->renderDistance * 2.0f));
    mv = simd_mul(mv, mtxTranslate(0, 0, 1.75f));
    mv = simd_mul(mv, mtxRotate(90.0f - p->renderElevation, -1, 0, 0));
    mv = simd_mul(mv, mtxRotate(p->renderAzimuth, 0, 0, 1));
    mv = simd_mul(mv, mtxTranslate(-p->TexScale[1] * 0.5f, -p->TexScale[2] * 0.5f, -p->TexScale[3] * 0.5f));
    mv = simd_mul(mv, mtxScale(p->TexScale[1], p->TexScale[2], p->TexScale[3]));

    return simd_mul(proj, mv);
}

- (NIIVolumeUniforms)uniformsForPrefs:(const NII_PREFS *)p {
    NIIVolumeUniforms u;
    memset(&u, 0, sizeof(u));
    u.mvp          = [self mvpForPrefs:p];
    u.normalMatrix = upper3x3(simd_inverse(volumeRotScale(p))); // == GL NormalMatrix
    u.rayDir       = computeRayDir(p);
    u.lightPosition = computeLightDir(p);
    float slices   = (float)(p->renderSlices > 0 ? p->renderSlices : 256);
    u.sliceSize    = 1.0f / slices; // smallest voxel edge, for opacity correction
    // Ray-march step from rayCastQuality1to4 (port of computeStepSize): quality 1
    // marches ~0.4x the slices (fast/coarse), quality 4 marches the full count.
    float q = fminf(fmaxf((float)p->rayCastQuality1to4 - 1.0f, 0.0f), 4.0f);
    float f = (slices * 0.4f) + (slices - slices * 0.4f) * (q / 4.0f); // lerp
    if (f < 10.0f) f = 10.0f;
    u.stepSize     = 1.0f / f;
    // Clip plane (pinch-to-cut-into-volume): matches clipUniforms in
    // nii_render.m. clipDepth<1 -> w=2.0 (disabled); else cut deeper.
    float clX, clY, clZ;
    sph2cartDeg90x(p->clipAzimuth, p->clipElevation, &clX, &clY, &clZ);
    float clD = (p->clipDepth < 1) ? 2.0f : (0.5f - p->clipDepth / 1000.0f);
    u.clipPlane    = (simd_float4){-clX, -clY, -clZ, clD};
    u.textureSz    = (simd_float3){(float)p->voxelDim[1], (float)p->voxelDim[2], (float)p->voxelDim[3]};
    u.clipThick    = 2.0f;
    u.overlayClip  = 0.0f;
    u.overlayFuzzy = 0.5f;
    u.overlayDepth = 0.3f;
    // advanced MR defaults (advanced_MR_shader.frag)
    u.brighten     = 1.5f;
    u.surfaceColor = 1.0f;
    u.backAlpha    = 0.95f;
    // advanced CT defaults (advanced_CT_shader.frag)
    u.ambient      = 0.8f;
    u.diffuse      = 0.3f;
    u.specular     = 0.1f;
    u.shininess    = 20.0f;
    u.surfaceHardness = 0.75f;
    u.overlays     = p->numOverlay;
    return u;
}

// Shared draw: encode the cube ray-cast for the 3D path into a render pass.
// `viewport` is the pixel rect to draw into within the attachment.
// Encode the 3D ray-cast cube into an existing encoder at the given viewport.
- (void)encode3DInto:(id<MTLRenderCommandEncoder>)enc
               prefs:(const NII_PREFS *)prefs
            viewport:(MTLViewport)viewport {
    NIIVolumeUniforms u = [self uniformsForPrefs:prefs];
    // Pick pipeline: advanced (gradient-lit) needs gradients computed; colorScheme
    // >= 20 selects the CT variant, else MR (matching drawBox).
    BOOL advanced = prefs->advancedRender && (_gradientVolume != nil);
    id<MTLRenderPipelineState> pipeline = _volumePipelineDefault;
    if (advanced)
        pipeline = (prefs->colorScheme >= 20) ? _volumePipelineAdvCT : _volumePipelineAdvMR;

    [enc setViewport:viewport];
    [enc setRenderPipelineState:pipeline];
    // Match GL_CCW front + cull back. Metal's DEFAULT front winding is CW.
    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
    [enc setCullMode:MTLCullModeBack];
    [enc setVertexBuffer:_cubeVerts offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentTexture:_intensityVolume atIndex:0];
    [enc setFragmentTexture:(_overlayVolume ?: _intensityVolume) atIndex:1];
    if (advanced) {
        [enc setFragmentTexture:_gradientVolume atIndex:2];
        [enc setFragmentTexture:(_gradientOverlay ?: _gradientVolume) atIndex:3];
        [enc setFragmentTexture:_matcap atIndex:4]; // MR samples it; CT ignores
    }
    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                    indexCount:_cubeIndexCount
                     indexType:MTLIndexTypeUInt16
                   indexBuffer:_cubeIndices
             indexBufferOffset:0];
}

// 3D-only convenience (used by the live window / standalone 3D view).
- (void)renderFrameWithPrefs:(NII_PREFS *)prefs inView:(MTKView *)view {
    if (!_intensityVolume || prefs->renderHt < 1 || prefs->renderWid < 1) return;
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [self encode3DInto:enc prefs:prefs viewport:(MTLViewport){
        (double)(prefs->scrnOffsetX + prefs->renderLeft),
        (double)(prefs->scrnOffsetY + prefs->renderBottom),
        (double)prefs->renderWid, (double)prefs->renderHt, 0.0, 1.0}];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

// Full frame: 3D ray-cast (unless 2D-only) + 2D slice composition, matching
// doRedraw's redrawRender + redraw2D. This is the path the in-place view swap
// (nii_GLView -> MTKView) and the live window use.
- (void)renderFullFrameWithPrefs:(NII_PREFS *)prefs inView:(MTKView *)view {
    if (!_intensityVolume) return;
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(
        prefs->backColor[0], prefs->backColor[1], prefs->backColor[2], 1.0);

    BOOL is2D = (prefs->displayModeGL == GL_2D_ONLY) || (prefs->displayModeGL == GL_2D_AXIAL)
             || (prefs->displayModeGL == GL_2D_CORONAL) || (prefs->displayModeGL == GL_2D_SAGITTAL);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (!is2D && prefs->renderWid > 0 && prefs->renderHt > 0) {
        // Flip GL bottom-origin renderBottom to Metal's top-left viewport origin.
        double vy = (double)(prefs->scrnHt - (prefs->scrnOffsetY + prefs->renderBottom) - prefs->renderHt);
        [self encode3DInto:enc prefs:prefs viewport:(MTLViewport){
            (double)(prefs->scrnOffsetX + prefs->renderLeft), vy,
            (double)prefs->renderWid, (double)prefs->renderHt, 0.0, 1.0}];
    }
    if (is2D || prefs->displayModeGL == GL_2D_AND_3D)
        [self encode2DInto:enc prefs:prefs];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

// Build the 6 vertices (two triangles) of a slice quad for one orientation,
// matching the corner->texcoord mapping in drawAx/drawCoro/drawSag. Each vertex
// is {posX, posY, texX, texY, texZ}. Screen rect is (x,y,w,h); `flip` is the
// radiological L/R flip; sf = prefs->sliceFrac.
static void buildSliceQuad(float *out, int orient, const double sf[4],
                           float flip, float x, float y, float w, float h) {
    simd_float3 tTL, tBL, tBR, tTR;
    if (orient == GL_2D_SAGITTAL) {
        float s = (float)sf[1];
        tTL=(simd_float3){s,0,1}; tBL=(simd_float3){s,0,0};
        tBR=(simd_float3){s,1,0}; tTR=(simd_float3){s,1,1};
    } else if (orient == GL_2D_CORONAL) {
        float s = (float)sf[2];
        tTL=(simd_float3){flip,s,1};   tBL=(simd_float3){flip,s,0};
        tBR=(simd_float3){1-flip,s,0}; tTR=(simd_float3){1-flip,s,1};
    } else { // GL_2D_AXIAL
        float s = (float)sf[3];
        tTL=(simd_float3){flip,1,s};   tBL=(simd_float3){flip,0,s};
        tBR=(simd_float3){1-flip,0,s}; tTR=(simd_float3){1-flip,1,s};
    }
    simd_float2 pTL={x,y+h}, pBL={x,y}, pBR={x+w,y}, pTR={x+w,y+h};
    simd_float2 pos[6] = {pTL,pBL,pBR, pTL,pBR,pTR};
    simd_float3 tex[6] = {tTL,tBL,tBR, tTL,tBR,tTR};
    for (int i = 0; i < 6; i++) {
        out[i*5+0]=pos[i].x; out[i*5+1]=pos[i].y;
        out[i*5+2]=tex[i].x; out[i*5+3]=tex[i].y; out[i*5+4]=tex[i].z;
    }
}

- (nullable void *)renderSliceOffscreenRGBA:(NII_PREFS *)prefs
                                orientation:(int)orient
                                      width:(int)width
                                     height:(int)height
                                 background:(const float[4])bgRGBA {
    if (!_intensityVolume || width < 1 || height < 1) return NULL;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(bgRGBA[0],bgRGBA[1],bgRGBA[2],bgRGBA[3]);

    simd_float4x4 mvp = ortho2D((float)width, (float)height);
    float flip = prefs->viewRadiological ? 1.0f : 0.0f;
    float quad[6*5];
    buildSliceQuad(quad, orient, prefs->sliceFrac, flip, 0, 0, (float)width, (float)height);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0,0,(double)width,(double)height,0,1}];
    // slice quad
    Slice2DUniformsCPU su; su.mvp = mvp; su.smooth = prefs->isSmooth2D ? 1 : 0;
    [enc setRenderPipelineState:_slicePipeline];
    [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [enc setVertexBytes:&su length:sizeof(su) atIndex:1];
    [enc setFragmentBytes:&su length:sizeof(su) atIndex:1];
    [enc setFragmentTexture:_intensityVolume atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    // crosshairs: vertical + horizontal through the slice's in-plane fractions
    [self encodeCrosshairs:enc orient:orient prefs:prefs mvp:mvp
                      width:(float)width height:(float)height];
    [enc endEncoding];
#if TARGET_OS_OSX
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:target]; [blit endEncoding];
#endif
    [cb commit]; [cb waitUntilCompleted];

    void *rgba = malloc((size_t)width*height*4);
    if (!rgba) return NULL;
    [target getBytes:rgba bytesPerRow:(NSUInteger)width*4
          fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    return rgba;
}

// Crosshairs (port of drawXBar): two solid lines through the in-plane crosshair
// fractions for this orientation, leaving the configured center gap.
- (void)encodeCrosshairs:(id<MTLRenderCommandEncoder>)enc
                  orient:(int)orient
                   prefs:(const NII_PREFS *)prefs
                     mvp:(simd_float4x4)mvp
                   width:(float)W height:(float)H {
    if (prefs->xBarGap < 0) return;
    // In-plane fractions (horizontal, vertical) per orientation, per drawAx/Coro/Sag.
    float fx, fy;
    if (orient == GL_2D_SAGITTAL)      { fx = (float)prefs->sliceFrac[2]; fy = (float)prefs->sliceFrac[3]; }
    else if (orient == GL_2D_CORONAL)  { fx = (float)prefs->sliceFrac[1]; fy = (float)prefs->sliceFrac[3]; }
    else                               { fx = (float)prefs->sliceFrac[1]; fy = (float)prefs->sliceFrac[2]; }
    if (prefs->viewRadiological) fx = 1.0f - fx;
    float cx = fx * W, cy = fy * H, gap = (float)prefs->xBarGap;
    simd_float2 v[8] = {
        {cx, 0},      {cx, cy - gap},   // bottom vertical
        {0, cy},      {cx - gap, cy},   // left horizontal
        {cx, cy+gap}, {cx, H},          // top vertical
        {cx+gap, cy}, {W, cy},          // right horizontal
    };
    simd_float4 col = (simd_float4){(float)prefs->xBarColor[0],(float)prefs->xBarColor[1],
                                    (float)prefs->xBarColor[2],1.0f};
    [self encodeSegments:v count:8 mvp:mvp color:col width:2.0f into:enc]; // GL glLineWidth(2)
}

// Draw one slice quad + its crosshairs at a screen rect (x,y,w,h), into an
// existing 2D encoder using the given pixel-space mvp. Ports drawAx/Coro/Sag.
- (void)encodeSliceAt:(id<MTLRenderCommandEncoder>)enc
               orient:(int)orient x:(float)x y:(float)y w:(float)w h:(float)h
                prefs:(const NII_PREFS *)p mvp:(simd_float4x4)mvp {
    float flip = p->viewRadiological ? 1.0f : 0.0f;
    float quad[6*5];
    buildSliceQuad(quad, orient, p->sliceFrac, flip, x, y, w, h);
    Slice2DUniformsCPU su; su.mvp = mvp; su.smooth = p->isSmooth2D ? 1 : 0;
    [enc setRenderPipelineState:_slicePipeline];
    [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [enc setVertexBytes:&su length:sizeof(su) atIndex:1];
    [enc setFragmentBytes:&su length:sizeof(su) atIndex:1];
    [enc setFragmentTexture:_intensityVolume atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    // crosshairs within this rect
    if (p->xBarGap < 0) return;
    float fx, fy;
    if (orient == GL_2D_SAGITTAL)     { fx = (float)p->sliceFrac[2]; fy = (float)p->sliceFrac[3]; }
    else if (orient == GL_2D_CORONAL) { fx = (float)p->sliceFrac[1]; fy = (float)p->sliceFrac[3]; }
    else                              { fx = (float)p->sliceFrac[1]; fy = (float)p->sliceFrac[2]; }
    if (p->viewRadiological) fx = 1.0f - fx;
    float cx = x + fx * w, cy = y + fy * h, gap = (float)p->xBarGap;
    simd_float2 v[8] = {
        {cx, y},        {cx, cy - gap},
        {x, cy},        {cx - gap, cy},
        {cx, cy + gap}, {cx, y + h},
        {cx + gap, cy}, {x + w, cy},
    };
    simd_float4 col = (simd_float4){(float)p->xBarColor[0],(float)p->xBarColor[1],(float)p->xBarColor[2],1.0f};
    [self encodeSegments:v count:8 mvp:mvp color:col width:2.0f into:enc]; // GL glLineWidth(2)
}

// 2D slice composition (port of redraw2D's layout switch). Uses prefs->scrnDim
// (set by the existing scrnSize code) so it matches the OpenGL layout exactly.
- (void)encode2DInto:(id<MTLRenderCommandEncoder>)enc prefs:(const NII_PREFS *)p {
    float W = p->scrnWid > 0 ? p->scrnWid : 1, H = p->scrnHt > 0 ? p->scrnHt : 1;
    simd_float4x4 mvp = ortho2D(W, H);
    [enc setViewport:(MTLViewport){(double)p->scrnOffsetX, (double)p->scrnOffsetY,
                                   (double)W, (double)H, 0.0, 1.0}];
    int d1 = p->scrnDim[1], d2 = p->scrnDim[2], d3 = p->scrnDim[3];
    switch (p->displayModeGL) {
        case GL_2D_AXIAL:
            [self encodeSliceAt:enc orient:GL_2D_AXIAL    x:0 y:0 w:d1 h:d2 prefs:p mvp:mvp]; break;
        case GL_2D_CORONAL:
            [self encodeSliceAt:enc orient:GL_2D_CORONAL  x:0 y:0 w:d1 h:d3 prefs:p mvp:mvp]; break;
        case GL_2D_SAGITTAL:
            [self encodeSliceAt:enc orient:GL_2D_SAGITTAL x:0 y:0 w:d2 h:d3 prefs:p mvp:mvp]; break;
        default:
            if (p->scrnWideLayout) { // 3-up side by side
                [self encodeSliceAt:enc orient:GL_2D_AXIAL    x:0       y:0 w:d1 h:d2 prefs:p mvp:mvp];
                [self encodeSliceAt:enc orient:GL_2D_CORONAL  x:(float)d1 y:0 w:d1 h:d3 prefs:p mvp:mvp];
                [self encodeSliceAt:enc orient:GL_2D_SAGITTAL x:(float)(2*d1) y:0 w:d2 h:d3 prefs:p mvp:mvp];
            } else { // 2x2: coronal TL, sagittal TR, axial BL
                [self encodeSliceAt:enc orient:GL_2D_CORONAL  x:0         y:(float)d2 w:d1 h:d3 prefs:p mvp:mvp];
                [self encodeSliceAt:enc orient:GL_2D_SAGITTAL x:(float)d1 y:(float)d2 w:d2 h:d3 prefs:p mvp:mvp];
                [self encodeSliceAt:enc orient:GL_2D_AXIAL    x:0         y:0         w:d1 h:d2 prefs:p mvp:mvp];
            }
    }
}

- (nullable void *)renderFullFrameOffscreenRGBA:(NII_PREFS *)prefs
                                          width:(int)width
                                         height:(int)height
                                     background:(const float[4])bgRGBA {
    if (!_intensityVolume || width < 1 || height < 1) return NULL;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(bgRGBA[0],bgRGBA[1],bgRGBA[2],bgRGBA[3]);

    BOOL is2D = (prefs->displayModeGL == GL_2D_ONLY) || (prefs->displayModeGL == GL_2D_AXIAL)
             || (prefs->displayModeGL == GL_2D_CORONAL) || (prefs->displayModeGL == GL_2D_SAGITTAL);
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (!is2D && prefs->renderWid > 0 && prefs->renderHt > 0) {
        double vy = (double)(prefs->scrnHt - (prefs->scrnOffsetY + prefs->renderBottom) - prefs->renderHt);
        [self encode3DInto:enc prefs:prefs viewport:(MTLViewport){
            (double)(prefs->scrnOffsetX + prefs->renderLeft), vy,
            (double)prefs->renderWid, (double)prefs->renderHt, 0.0, 1.0}];
    }
    if (is2D || prefs->displayModeGL == GL_2D_AND_3D)
        [self encode2DInto:enc prefs:prefs];
    [enc endEncoding];
#if TARGET_OS_OSX
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:target]; [blit endEncoding];
#endif
    [cb commit]; [cb waitUntilCompleted];
    void *rgba = malloc((size_t)width*height*4);
    if (!rgba) return NULL;
    [target getBytes:rgba bytesPerRow:(NSUInteger)width*4
          fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    return rgba;
}

- (nullable void *)renderOffscreenRGBA:(NII_PREFS *)prefs
                                 width:(int)width
                                height:(int)height
                            background:(const float[4])bgRGBA {
    if (!_intensityVolume || width < 1 || height < 1) return NULL;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor =
        MTLClearColorMake(bgRGBA[0], bgRGBA[1], bgRGBA[2], bgRGBA[3]);

    // Render into the full offscreen image (override viewport-within-window math).
    NII_PREFS p = *prefs;
    p.scrnOffsetX = 0; p.scrnOffsetY = 0; p.renderLeft = 0; p.renderBottom = 0;
    p.renderWid = width; p.renderHt = height;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [self encode3DInto:enc prefs:&p
              viewport:(MTLViewport){0, 0, (double)width, (double)height, 0.0, 1.0}];
    [enc endEncoding];
#if TARGET_OS_OSX
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:target];
    [blit endEncoding];
#endif
    [cb commit];
    [cb waitUntilCompleted];

    void *rgba = malloc((size_t)width * height * 4);
    if (!rgba) return NULL;
    [target getBytes:rgba
        bytesPerRow:(NSUInteger)width * 4
         fromRegion:MTLRegionMake2D(0, 0, width, height)
        mipmapLevel:0];
    return rgba;
}

@end

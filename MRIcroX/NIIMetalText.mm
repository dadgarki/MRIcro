//
//  NIIMetalText.mm
//  MRIcroX
//

#import "NIIMetalText.h"
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>

@implementation NIIMetalText {
    id<MTLTexture> _texture;
    int _w, _h;
}

- (id<MTLTexture>)texture { return _texture; }
- (int)pixelWidth { return _w; }
- (int)pixelHeight { return _h; }

- (nullable instancetype)initWithString:(NSString *)string
                              pointSize:(CGFloat)pointSize
                                 device:(id<MTLDevice>)device {
    self = [super init];
    if (!self || !device || string.length == 0) return nil;

    // Build an attributed string with white glyphs (the shader tints them).
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), pointSize, NULL);
    CGFloat comps[4] = {1, 1, 1, 1};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGColorRef white = CGColorCreate(rgb, comps);
    CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    CFTypeRef vals[]   = { font, white };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, (__bridge CFStringRef)string, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);

    CGFloat ascent = 0, descent = 0, leading = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    const int pad = 2;
    _w = (int)ceil(width) + pad * 2;
    _h = (int)ceil(ascent + descent) + pad * 2;
    if (_w < 1) _w = 1;
    if (_h < 1) _h = 1;

    // Premultiplied RGBA bitmap; Core Text draws origin at the baseline.
    CGContextRef ctx = CGBitmapContextCreate(NULL, _w, _h, 8, _w * 4, rgb,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { // bitmap allocation failed — clean up and fail gracefully
        CFRelease(line); CFRelease(as); CFRelease(attrs);
        CGColorRelease(white); CGColorSpaceRelease(rgb); CFRelease(font);
        return nil;
    }
    CGContextSetTextPosition(ctx, pad, descent + pad);
    CTLineDraw(line, ctx);
    void *data = CGBitmapContextGetData(ctx);

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:_w height:_h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    td.storageMode = MTLStorageModeManaged;
#else
    td.storageMode = MTLStorageModeShared;
#endif
    _texture = [device newTextureWithDescriptor:td];
    [_texture replaceRegion:MTLRegionMake2D(0, 0, _w, _h) mipmapLevel:0
                  withBytes:data bytesPerRow:_w * 4];

    CGContextRelease(ctx);
    CFRelease(line);
    CFRelease(as);
    CFRelease(attrs);
    CGColorRelease(white);
    CGColorSpaceRelease(rgb);
    CFRelease(font);
    return (_texture != nil) ? self : nil;
}

- (nullable void *)copyRGBA {
    if (!_texture) return NULL;
    void *rgba = malloc((size_t)_w * _h * 4);
    if (!rgba) return NULL;
    [_texture getBytes:rgba bytesPerRow:_w * 4
            fromRegion:MTLRegionMake2D(0, 0, _w, _h) mipmapLevel:0];
    return rgba;
}

@end

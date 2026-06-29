//
//  NIIMetalText.h
//  MRIcroX
//
//  Replaces GLString: rasterizes a string into a premultiplied-alpha 2D Metal
//  texture for the text pipeline (textVertex/textFragment in Shaders.metal).
//
//  Implemented with Core Text + CoreGraphics only (no AppKit/UIKit), so it
//  compiles unchanged for macOS and iPadOS — the GLString original was AppKit
//  (NSImage/NSAttributedString) and macOS-only. Used for the volume label,
//  orientation labels, and colorbar text.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@protocol MTLDevice;
@protocol MTLTexture;

NS_ASSUME_NONNULL_BEGIN

@interface NIIMetalText : NSObject

/// Glyph texture (RGBA8, premultiplied alpha, white glyphs — tint at draw time).
@property (nonatomic, readonly, nullable) id<MTLTexture> texture;
@property (nonatomic, readonly) int pixelWidth;
@property (nonatomic, readonly) int pixelHeight;

/// Rasterize `string` at `pointSize` into a texture on `device`.
- (nullable instancetype)initWithString:(NSString *)string
                              pointSize:(CGFloat)pointSize
                                 device:(id<MTLDevice>)device;

/// Copy the glyph texture back to host RGBA8 bytes (width*height*4). Caller
/// frees. For validation/screenshots.
- (nullable void *)copyRGBA;

@end

NS_ASSUME_NONNULL_END

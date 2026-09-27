#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <cmath>
#include <string>
#include "FvmNativeSupport.h"

// The caller supplies only pixels read from its own GameMaker surface. This
// codec does not inspect windows, displays, files, or other processes. Base64
// keeps the classic extension ABI independent of raw-pointer string formats.
FVM_EXPORT const char *EncodeGameFrame(const char *pixels, double width, double height) {
  static thread_local std::string result;
  result.clear();
  @autoreleasepool {
    @try {
      if (!pixels || !std::isfinite(width) || !std::isfinite(height) ||
          width < 1 || width > 960 || height < 1 || height > 540 ||
          width != std::floor(width) || height != std::floor(height)) return result.c_str();
      const size_t w = static_cast<size_t>(width), h = static_cast<size_t>(height);
      NSString *text = [NSString stringWithUTF8String:pixels];
      if (!text || text.length != ((w * h * 4 + 2) / 3) * 4) return result.c_str();
      NSData *rgba = [[NSData alloc] initWithBase64EncodedString:text options:0];
      if (rgba.length != w * h * 4) return result.c_str();
      CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
      CGColorSpaceRef colour = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, colour,
        kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big, provider, nullptr, false,
        kCGRenderingIntentDefault);
      if (image) {
        NSMutableData *jpeg = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(
          (__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr);
        if (destination) {
          CGImageDestinationAddImage(destination, image,
            (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:@0.72});
          if (CGImageDestinationFinalize(destination) && jpeg.length <= 525 * 1024) {
            result = [[jpeg base64EncodedStringWithOptions:0] UTF8String];
          }
          CFRelease(destination);
        }
        CGImageRelease(image);
      }
      CGColorSpaceRelease(colour);
      CGDataProviderRelease(provider);
    } @catch (NSException *) { result.clear(); }
  }
  return result.c_str();
}

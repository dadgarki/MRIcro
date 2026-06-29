//
//  NIIAppDelegate.h
//  MRIcroX (iOS / iPadOS)
//
//  Minimal window-based app entry (no storyboard, no scene manifest) hosting a
//  single NIIViewController. The macOS app keeps its own AppKit MRIcroAppDelegate.
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import <UIKit/UIKit.h>

@interface NIIAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

#endif

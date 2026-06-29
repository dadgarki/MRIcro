//
//  NIIAppDelegate.m
//  MRIcroX (iOS / iPadOS)
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import "NIIAppDelegate.h"
#import "NIIViewController.h"

@implementation NIIAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[NIIViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

// Open a file handed to the app (Files / share sheet / document picker).
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    NIIViewController *vc = (NIIViewController *)self.window.rootViewController;
    if (![vc isKindOfClass:[NIIViewController class]]) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [vc loadImageAtPath:url.path];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return YES;
}

@end

#endif

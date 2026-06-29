#import "nii_GLView.h"
#include "nifti1.h"
#include <stdio.h>
#import "nii_render.h"
#import "nii_img.h"
#import "nii_reslice.h"
#import <QuartzCore/QuartzCore.h>


#ifdef __APPLE__
#define _MACOSX
#endif

@interface nii_GLView (InternalMethods)
- (CVReturn)getFrameForTime:(const CVTimeStamp *)outputTime;
- (void)drawFrame;
//@property (nonatomic) NSPoint startPoint;
//@property (nonatomic, strong) CAShapeLayer *shapeLayer;


@end




@implementation nii_GLView
@synthesize twoFingersTouches;




-(void) ShowAlert: (NSString *)theMessage Title: (NSString *) theTitle
{
    NSBeginAlertSheet(theTitle, @"OK",NULL,NULL,[[NSApplication sharedApplication] keyWindow], self,
                      NULL, NULL, NULL,
                      @"%@"
                      , theMessage);
}

-(void) makeMosaicGL:(NSString *)mosStr
{
    [gNiiImg makeMosaic: mosStr];
   //RetinaXXX setScreenWidHtOffset
}

-(bool) isTimelineUpdateNeededGL
{
    return [gNiiImg isTimelineUpdateNeeded];
}

-(void)skipNumberOfVolumesGL: (int) skip {
    int nVol = [gNiiImg getNumberOfVolumes];
    
    if (nVol < 2) return;
    int vol = [gNiiImg getVolume];
    vol = vol + skip;
    if (vol < 1) vol = nVol;
    if (vol > nVol) vol = 1;
    [gNiiImg setVolume: vol];
    //printf("vol %d skip %d\n",vol,skip);
    [self drawFrame];
}

-(int) getNumberOfVolumesGL
{
    return [gNiiImg getNumberOfVolumes];
}

-(GraphStruct) getTimelineGL
{
    return [gNiiImg getTimeline] ;
}

-(void) updatePrefs
{
    NII_PREFS *prefs =[gNiiImg getPREFS];
    //prefs->retinaResolution = [[NSUserDefaults standardUserDefaults] boolForKey:@"retinaResolution"];
    prefs->scrnOffsetX = 0;
    prefs->scrnOffsetY = 0;
    prefs->showCube = [[NSUserDefaults standardUserDefaults] boolForKey:@"showCube"];
    prefs->xBarGap = 3*[[NSUserDefaults standardUserDefaults] boolForKey:@"xBarGap"];
    prefs->showInfo = [[NSUserDefaults standardUserDefaults] boolForKey:@"showInfo"];
    prefs->showOrient = [[NSUserDefaults standardUserDefaults] boolForKey:@"showOrient"];
    //NSLog(@"%d zzzz %d", prefs->showOrient, prefs->showInfo);
    prefs->orthoOrient = [[NSUserDefaults standardUserDefaults] boolForKey:@"orthoOrient"];
    prefs->loadFewVolumes = [[NSUserDefaults standardUserDefaults] boolForKey:@"loadFewVolumes"];
    prefs->viewRadiological  = [[NSUserDefaults standardUserDefaults] boolForKey:@"viewRadiological"];
    prefs->isSmooth2D = [[NSUserDefaults standardUserDefaults] boolForKey:@"isSmooth2D"];
    bool prev = prefs->advancedRender;
    prefs->advancedRender = [[NSUserDefaults standardUserDefaults] boolForKey:@"advancedRender"];
    prefs->dicomWarn = [[NSUserDefaults standardUserDefaults] boolForKey:@"dicomWarn"];
    //prefs->retinaResolution = [[NSUserDefaults standardUserDefaults] boolForKey:@"retinaResolution"];
    
    //NSLog(@"%d ---", prefs->dicomWarn);
    NSColor * aColor =nil;
    NSData *theData=[[NSUserDefaults standardUserDefaults] dataForKey:@"xBarColor"];
    if (theData != nil) {
        aColor =(NSColor *)[NSUnarchiver unarchiveObjectWithData:theData];
        //next line required if user uses grayscale sliders to create NSCalibratedWhiteColorSpace which does not have a redComponent!
        aColor = [aColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        prefs->xBarColor[0] = aColor.redComponent;
        prefs->xBarColor[1] = aColor.greenComponent;
        prefs->xBarColor[2] = aColor.blueComponent;
        //prefs->xBarColor[3] = 0;
        prefs->colorBarBorderColor[0] = aColor.redComponent;
        prefs->colorBarBorderColor[1] = aColor.greenComponent;
        prefs->colorBarBorderColor[2] = aColor.blueComponent;
        //convert RGB->Y http://en.wikipedia.org/wiki/YUV
        //prefs->backColor
        [gNiiImg updateFont: aColor] ;
    }
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"blackBackground"]) {
        if ((prefs->backColor[0] + prefs->backColor[1] + prefs->backColor[2]) > 0.0001)
            [self setBackgroundColor: 0 Green: 0 Blue: 0];
    } else {
        if ((prefs->backColor[0] + prefs->backColor[1] + prefs->backColor[2]) < 2.9999)
            [self setBackgroundColor: 1 Green: 1 Blue: 1];
    }
    theData=[[NSUserDefaults standardUserDefaults] dataForKey:@"colorBarTextColor"];
    if (theData != nil) {
        aColor =(NSColor *)[NSUnarchiver unarchiveObjectWithData:theData];
        prefs->colorBarTextColor[0] = aColor.redComponent;
        prefs->colorBarTextColor[1] = aColor.greenComponent;
        prefs->colorBarTextColor[2] = aColor.blueComponent;
    }
    if (prev != prefs->advancedRender) {
        prefs->force_recalcGL = true;
    }
    prefs->force_refreshGL = true;
    [self drawFrame];
}

-(LayerValues) getLayerValues: (int) index;
{
    LayerValues ret;
    NII_PREFS *prefs =[gNiiImg getPREFS];
    if (index == 0) {
        ret.colorScheme = prefs->colorScheme;
        ret.viewMin = prefs->viewMin;
        ret.viewMax = prefs->viewMax;
    } else { //-1 since background is layer 0, so overlay 0 at index 1
        ret.colorScheme = prefs->overlays[index-1].colorScheme;
        ret.viewMin = prefs->overlays[index-1].viewMin;
        ret.viewMax = prefs->overlays[index-1].viewMax;        
    }
    for (int i = 0; i < MAX_OVERLAY; i++) {
        ret.activeOverlay[i] = (prefs->overlays[i].datatype != DT_NONE);
    }
    return ret;
}

-(void) setFontScale: (float) scale;
{
    [gNiiImg updateFontScale: scale];
}
-(void) setViewGamma: (float) gamma;
{
    NII_PREFS *prefs =[gNiiImg getPREFS];
    prefs->lut_bias = gamma;
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    [self drawFrame];
}

/*-(void) forceRecalc; //flicker test
{
    NII_PREFS *prefs =[gNiiImg getPREFS];
    prefs->force_refreshGL = true;
    prefs->force_recalcGL = true;
    [self drawFrame];
}*/

-(void) setViewMinMaxForLayer: (double) min Max: (double) max Layer: (int) layer;
{
    [gNiiImg setViewMinMaxForLayer: min Max: max Layer: layer];
    [self drawFrame];
}

- (void) setContrast:(NSPoint)value
{
    NII_PREFS *prefs =[gNiiImg getPREFS];
    double fullWidth = prefs->nearMax - prefs->nearMin;
    double Center = (((100-value.y)/50) * (fullWidth/2.0)) + prefs->nearMin;
    double Width = ((100-value.x)/50) * fullWidth;
    [gNiiImg setViewMinMax: Center-(Width/2.0) Max: Center+(Width/2.0)];
    [self drawFrame];
}

-(IBAction) openDiffusionGL: (id) sender
{
    NSOpenPanel *openPanel  = [NSOpenPanel openPanel];
    NSArray *fileTypes = [NSArray arrayWithObjects:@"gz", nil];
    [openPanel setTitle:@"Choose _FA image"];
    [openPanel setAllowedFileTypes:fileTypes];
    NSInteger result    = [openPanel runModal];
    if(result!= NSOKButton) return;
    //if (![self checkSandAccess: [[openPanel URL] path]]) return;
    NSString *inName = [[openPanel URL] path];
    NSString *v1Name = [inName stringByReplacingOccurrencesOfString:@"_FA" withString:@"_V1"];
    if ( (![inName isEqualToString: v1Name]) && ([[NSFileManager defaultManager] fileExistsAtPath:v1Name])) {
        [gNiiImg setLoadDTI:inName V1name: v1Name];
    } else {
        NSString *faName = [inName stringByReplacingOccurrencesOfString:@"_V1" withString:@"_FA"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:faName]) {
            [gNiiImg setLoadDTI: faName V1name: inName];
        } else {
            [self ShowAlert: @"Please select a *_FA.nii.gz image in the same folder as a *_V1.nii.gz image" Title:@"Load DTI error" ];
            //ShowAlert(@"Please select a *_FA.nii.gz image in the same folder as a *_V1.nii.gz image",@"Load DTI error");
        }
    } //if v1Name else
    [self drawFrame];
}

-(IBAction) closeOverlaysGL: (id) sender
{
    [gNiiImg closeAllOverlays];
    [self drawFrame];
}

NSArray * niiFileTypes () {
    NSArray *fileTypes = [NSArray arrayWithObjects:
                          @"dcm", @"nii", @"MAT",@"NII",@"hdr", @"HDR",  @"GZ", @"gz",@"voi", @"MGH", @"mgh",  @"MGZ", @"mgz", @"MHA", @"mha",  @"MHD", @"mhd",@"HEAD", @"head", @"nrrd", @"nhdr", nil];
    fileTypes = [fileTypes arrayByAddingObjectsFromArray:[NSImage imageFileTypes]];
    return fileTypes;
}


-(IBAction) addOverlayGL: (id) sender
{
    if ([gNiiImg isBackgroundRGB]) {
        [self ShowAlert:@"You can not load overlays on top of color images (open a grayscale background image)" Title:@"Error"];
        //ShowAlert( @"You can not load overlays on top of color images (open a grayscale background image).", @"Error");
        return;        
    }
    if ([gNiiImg nextOverlaySlot] < 0) { //-1 means no free slots
        [self ShowAlert:@"Unable to add overlays. Please make sure a background image is loaded and you have not loaded too many overlays" Title:@"Error"];
        
        //ShowAlert( @"Unable to add overlays. Please make sure a background image is loaded and you have not loaded too many overlays.", @"Error");
        return;
    }
    NSOpenPanel *openPanel  = [NSOpenPanel openPanel];
    openPanel.title = @"Choose an overlay image";
    
    /*NSArray *fileTypes = [NSArray arrayWithObjects:
                          @"dcm", @"nii", @"MAT",@"NII",@"hdr", @"HDR",  @"GZ", @"gz",@"voi", @"MGH", @"mgh",  @"MGZ", @"mgz", @"MHA", @"mha",  @"MHD", @"mhd",@"HEAD", @"head", @"nrrd", @"nhdr", nil];
    [openPanel setAllowedFileTypes:fileTypes];*/
    [openPanel setAllowedFileTypes:niiFileTypes()];
    
    NSInteger result    = [openPanel runModal];
    if(result != NSOKButton) return;
    //if (![self checkSandAccess: [[openPanel URL] path]]) return;
    [self openOverlayFromFileNameGL:[[openPanel URL] path]];
    [self drawFrame];
}

- (BOOL) openOverlayFromFileNameGL: (NSString *)file_name
{
    //NSLog(@"nii_GLView openOverlayFromFileNameGL %@", file_name);
    int overlaySlot = [gNiiImg addOverlay: file_name];
    if (overlaySlot < 0) return FALSE;
    [self drawFrame];
    return TRUE;
}

/*
-(IBAction) openDocumentGL: (id) sender
{
    NSOpenPanel *openPanel  = [NSOpenPanel openPanel];
    openPanel.title = @"Choose a background image";
    [openPanel setAllowedFileTypes:niiFileTypes()];
    openPanel.allowsMultipleSelection = TRUE;
    
    //[openPanel allowsMultipleSelection: TRUE];
    //[openPanel setAllowedFileTypes:[NSImage imageFileTypes]];
    NSInteger result    = [openPanel runModal];
    if(result != NSOKButton) return;
    //if (![self checkSandAccess: [[openPanel URL] path]]) return;
        
    [self openDocumentFromFileNameGL: [[openPanel URL] path]] ;
    [self drawFrame];
    
    //https://stackoverflow.com/questions/7693896/nsopenpanel-everything-deprecated

}*/



- (void)saveScreenshotFromFileName:(NSString *) file_name //save PNG screenshot, or capture to clipboard
{
    // Get the size of the image in a retina safe way
    
    NSRect backRect = [self convertRectToBacking: [self bounds]];
    int w = NSWidth(backRect) / screenShotScaleFactor;
    int h = NSHeight(backRect) / screenShotScaleFactor;
    //[gNiiImg updateFontScale: 1];
    int zoom = 1;
    int wz = zoom * w;
    NII_PREFS *prefs =[gNiiImg getPREFS];
    int q =prefs->rayCastQuality1to4;
    prefs->rayCastQuality1to4 = 4;
    int hz = zoom * h;
    // Create image. Note no alpha channel. I don't copy that.
    NSBitmapImageRep *repz = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
     pixelsWide: wz pixelsHigh: hz bitsPerSample: 8 samplesPerPixel: 4 hasAlpha: YES
       isPlanar: NO colorSpaceName: NSCalibratedRGBColorSpace bytesPerRow: 4*wz bitsPerPixel: 0];
   // [gNiiImg updateFontScale: zoom]; //2021
   for (int tile = 0; tile < (zoom * zoom); tile++){
        int tilex = (tile % zoom) * w;
        int tiley = (tile / zoom) * h;
       //NSLog(@"%d %d %d",tile, tilex, tiley);
        //[gNiiImg setScreenWidHt: wz Height: hz];
       [gNiiImg setScreenWidHtOffset: wz Height: hz OffsetX: -tilex OffsetY: -tiley];
        [self drawFrame];
        // The following block does the actual reading of the image
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
            pixelsWide: w pixelsHigh: h bitsPerSample: 8 samplesPerPixel: 3 hasAlpha: NO
            isPlanar: NO colorSpaceName: NSCalibratedRGBColorSpace bytesPerRow: 3*w bitsPerPixel: 0];
        // Metal: synchronous offscreen render into the rep (already top-down).
        [gNiiImg metalScreenshotIntoRGB:[rep bitmapData] width:w height:h];
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep: repz];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext: context];
        [rep drawInRect: NSMakeRect(tilex, tiley, w, h)] ;
    }
    if ([file_name length] < 1) { //save to clipboard
        NSImage *imag = [[NSImage alloc] init];
        [imag addRepresentation:repz];
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        NSArray *copiedObjects = [NSArray arrayWithObject:imag];
        [pasteboard writeObjects:copiedObjects];
    } else {
        //http://stackoverflow.com/questions/34557563/null-passed-to-a-callee-that-requires-a-non-null-argument
        NSData *data = [repz representationUsingType: NSPNGFileType properties: @{}];
        //NSData *data = [repz representationUsingType: NSPNGFileType properties: nil];
        [data writeToFile: file_name atomically: NO];
    }
    //[gNiiImg setScreenWidHt: w Height: h]; //return to base resolution
    prefs->rayCastQuality1to4 = q;
    //[gNiiImg updateFontScale: screenShotScaleFactor];
    //[gNiiImg updateFontScale: retinaScaleFactor];
    [gNiiImg setScreenWidHtOffset: (w ) Height: (h ) OffsetX: 0 OffsetY: 0];
    [self reshape];
    [self drawFrame];
}

-(IBAction) saveDocumentAs: (id) sender //Request filename and save PNG screenshout
{
    NSSavePanel *savePanel = [NSSavePanel savePanel]; 
    [savePanel setTitle:@"Save as PNG bitmap"];
    NSArray *fileTypes = [NSArray arrayWithObjects:@"png",nil]; // Only export PNG
    [savePanel setAllowedFileTypes:fileTypes]; 
    [savePanel setTreatsFilePackagesAsDirectories:NO]; 
    [savePanel setAllowsOtherFileTypes:NO];
    //NSInteger user_choice =  [savePanel runModalForDirectory:NSHomeDirectory() file:@""]; // <- works, deprecated
    [savePanel setNameFieldStringValue:@""];
    [savePanel setDirectoryURL:[NSURL fileURLWithPath:NSHomeDirectory() ]];
    NSInteger user_choice =  [savePanel runModal];
    if(NSOKButton == user_choice)
        [self saveScreenshotFromFileName:[[savePanel URL] path]];
}

- (void)copy: (id) sender
{
    [self saveScreenshotFromFileName: @""];
}

- (BOOL) setLoadImageX:(NSString *) file_name newWindow: (bool) isNew {
    NSUInteger iflags = [NSEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask;
    bool specialKeys = (iflags == NSControlKeyMask);
    if ((specialKeys) && (!isNew))
        return [self openOverlayFromFileNameGL:  file_name];
    int err = [gNiiImg setLoadImage:file_name];
    return (err == 0);
}

- (BOOL)openDocumentFromFileNameGL:(NSString *) file_name
{
    BOOL OK = [self setLoadImageX: file_name newWindow: false];
    //[gNiiImg setLoadImage:file_name];
    //NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    //[prefs setObject:file_name forKey:@"defaultFilename"];
    //
    [[NSUserDefaults standardUserDefaults]setObject:file_name forKey:@"defaultFilename" ];
    //[[NSUserDefaults standardUserDefaults]synchronize ];
    [self drawFrame];
     [[NSNotificationCenter defaultCenter] postNotificationName:@"niiUpdate" object:self userInfo:nil]; //notify window if document drag-dropped directly on view
    return OK;
}

- (void) setDisplayMode:(NSInteger)mode
{
    [gNiiImg setDisplayModeX: int(mode)];
    [self drawFrame];
}

- (void) setColorScheme:(NSInteger)colorScheme
{
    [gNiiImg setColorScheme: int(colorScheme)];
    [self drawFrame];
}

-(void) setBackgroundColor: (double) red Green: (double) green Blue: (double) blue {
    [gNiiImg setBackgroundColor: red Green: green Blue: blue];
    [self drawFrame];
}
-(void)getBackgroundColor:(double*)red Green:(double*)green Blue:(double*)blue {
    [gNiiImg getBackgroundColor: red Green: green Blue: blue];
}

- (void) setColorSchemeForLayer:(NSInteger)colorScheme Layer: (int) layer;
{
    [gNiiImg setColorSchemeForLayer: int(colorScheme) Layer: layer];
    [self drawFrame];
}

-(void) refreshGL
{
    [self drawFrame];
}

-(void) setXYZmmGL: (float) x Y: (float) y Z: (float) z {
    if ([gNiiImg setXYZmm: x Y: y Z: z]) [self drawFrame];
    //[gNiiImg setXYZmm: x Y: y Z: z];
}

-(void) changeXYZvoxelGL: (int) x Y: (int) y Z: (int) z {
    if ([gNiiImg changeXYZvoxel: x Y: y Z: z]) [self drawFrame]; //ssss
    //[gNiiImg setAzimElevOrient: 1];
    
}

-(void) setAzimElevOrient: (int) orient; {
    NSLog(@"setAzimElevOrient %d", orient);
    //LRPAIS = 012345
    switch(orient) {
        case 1: [gNiiImg setAzimElev: 90 Elev: 0]; break;
        case 2: [gNiiImg setAzimElev: 270 Elev: 0]; break;
        case 3: [gNiiImg setAzimElev: 0 Elev: 0]; break;
        case 4: [gNiiImg setAzimElev: 180 Elev: 0]; break;
        case 5: [gNiiImg setAzimElev: -180 Elev: -90]; break;
        case 6: [gNiiImg setAzimElev: 0 Elev: 90]; break;
    }
    [self drawFrame];
}

- (NSPoint)convertPointX:(NSPoint)aPoint fromView:(NSView *)aView;
{
    //2021 convertPointToBacking convertPointFromBacking
    //NSPoint pt = [self convertPoint: aPoint fromView: aView];
    //NSPoint event_location = [theEvent locationInWindow];
    NSPoint pt = [self convertPoint:aPoint fromView:nil];
     
    //NSPoint pt = aPoint;
    //pt.y -= 10;
    
    pt = [self convertPointToBacking: pt];
    
    //NSPoint pt = [self convertPoint: aPoint fromView: aView];
    /*
    if (self->retinaScaleFactor > 1.0) {
        pt.x *= self->retinaScaleFactor;
        pt.y *= self->retinaScaleFactor;        
    }*/
    return pt;
}

- (NSPoint)convertPointXR:(NSPoint)aPoint fromView:(NSView *)aView {
    //This is in native screen space, not impacted by Retina mode
    return [self convertPoint: aPoint fromView: aView];
}

- (void)marchingAntsMouseDown:(NSEvent *)event {
    // create animation for the layer - invisible for retina?
    self->startPoint = [self convertPointXR:[event locationInWindow] fromView:nil];
    self->shapeLayer = [CAShapeLayer layer];
    self->shapeLayer.lineWidth = 2.0;
    //self->shapeLayer.strokeColor = [[NSColor blackColor] CGColor];
    //self->shapeLayer.strokeColor = [[NSColor purpleColor] CGColor];
    //self->shapeLayer.strokeColor = [[NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.75 alpha:0.8] CGColor]; //colorBarBorderColor
    self->shapeLayer.strokeColor = [[NSColor colorWithCalibratedRed:0.6 green:0.0 blue:0.6 alpha:0.8] CGColor]; //colorBarBorderColor
    //[NSColor colorWithCalibratedRed:0.227f green:0.251f blue:0.337 alpha:0.8];
    self->shapeLayer.fillColor = [[NSColor clearColor] CGColor];
    self->shapeLayer.lineDashPattern = @[@10, @5];
    //[self->layer addSublayer:self.shapeLayer];
    [self.layer addSublayer:self->shapeLayer];
    CABasicAnimation *dashAnimation;
    dashAnimation = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
    [dashAnimation setFromValue:@0.0f];
    [dashAnimation setToValue:@15.0f];
    [dashAnimation setDuration:0.75f];
    [dashAnimation setRepeatCount:HUGE_VALF];
    [self->shapeLayer addAnimation:dashAnimation forKey:@"linePhase"];
}


- (void)mouseDown:(NSEvent *)event {
    //NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
    
    NSPoint location = [self convertPointX:[event locationInWindow] fromView: nil]; //RetinaX 2016
    //NSLog(@"mouseDown %gx%g", location.x, location.y);
    [gNiiImg setMouseDown:location.x Y:location.y];
    [self drawFrame];
    
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    if  (flags & NSShiftKeyMask)
        [self marchingAntsMouseDown: event];
}

- (void)mouseDragged:(NSEvent *)event
{
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    if  (flags & NSShiftKeyMask){
        [self rightMouseDragged: event];
        return;
    }
    NSPoint location = [self convertPointX:[event locationInWindow] fromView:nil];
    [gNiiImg setMouseDrag: location.x Y: location.y];
    [self drawFrame];
}

- (void)mouseUp:(NSEvent *)event
{
    //[self.shapeLayer removeFromSuperlayer];
    //self.shapeLayer = nil;
    
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    if  (flags & NSShiftKeyMask){
        [self rightMouseUp: event];
        return;
    }
    
}

- (void)rightMouseDown:(NSEvent *)event
{
    [self mouseDown: event]; //  treat as left mouse button down event
    [self marchingAntsMouseDown: event];
        //http://stackoverflow.com/questions/20357960/drawing-selection-box-rubberbanding-marching-ants-in-cocoa-objectivec

    /*self.startPoint = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // create and configure shape layer
    */
    
 /*   // create animation for the layer
    self->startPoint = [self convertPoint:[event locationInWindow] fromView:nil];
    self->shapeLayer = [CAShapeLayer layer];
    self->shapeLayer.lineWidth = 1.0;
    self->shapeLayer.strokeColor = [[NSColor blackColor] CGColor];
    self->shapeLayer.fillColor = [[NSColor clearColor] CGColor];
    self->shapeLayer.lineDashPattern = @[@10, @5];
    //[self->layer addSublayer:self.shapeLayer];
    [self.layer addSublayer:self->shapeLayer];
    
    CABasicAnimation *dashAnimation;
    dashAnimation = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
    [dashAnimation setFromValue:@0.0f];
    [dashAnimation setToValue:@15.0f];
    [dashAnimation setDuration:0.75f];
    [dashAnimation setRepeatCount:HUGE_VALF];
    [self->shapeLayer addAnimation:dashAnimation forKey:@"linePhase"];*/
    
}

- (void)rightMouseDragged:(NSEvent *)event
{
    NSPoint point = [self convertPointXR:[event locationInWindow] fromView:nil];
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, self->startPoint.x, self->startPoint.y);
    CGPathAddLineToPoint(path, NULL, self->startPoint.x, point.y);
    CGPathAddLineToPoint(path, NULL, point.x, point.y);
    CGPathAddLineToPoint(path, NULL, point.x, self->startPoint.y);
    CGPathCloseSubpath(path);
    // set the shape layer's path
    self->shapeLayer.path = path;
    CGPathRelease(path);
    NSPoint location = [self convertPointX:[event locationInWindow] fromView:nil];
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    [gNiiImg setRightMouseDragXY: location.x Y: location.y isMag: (flags & NSControlKeyMask) isSwipe: (flags & NSCommandKeyMask)];
    
    /*if  (flags & NSControlKeyMask)
        [gNiiImg setRightMouseDragY: location.y isMag: true];
    else
        [gNiiImg setRightMouseDragY: location.y isMag: false];*/
    /*if  (!(flags & NSControlKeyMask))
        [gNiiImg setRightMouseDragX: location.x];
    if  (!(flags & NSCommandKeyMask))
        [gNiiImg setRightMouseDragY: location.y];*/
    //[gNiiImg setRightMouseDrag: location.x Y: location.y];
    [self drawFrame];
}

- (void)rightMouseUp:(NSEvent *)event
{
    //in future Marching Ants? http://stackoverflow.com/questions/20357960/drawing-selection-box-rubberbanding-marching-ants-in-cocoa-objectivec
    [self->shapeLayer removeFromSuperlayer];
    self->shapeLayer = nil;
    NSPoint location = [self convertPointX:[event locationInWindow] fromView:nil];
    if (![gNiiImg setRightMouseUp:location.x Y:location.y]) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"niiUpdate" object:self userInfo:nil];
}

- (void)scrollWheel:(NSEvent *)event
{
    //NSLog(@"Scroll Event: %@", event);
    //NSLog(@"%g %g", event.locationInWindow.x, event.locationInWindow.y);
    
    if ((event.deltaY == 0) && (event.deltaX == 0)) return;
    //NSLog(@"scroll %g %g", event.deltaX, event.deltaY);
    if ([gNiiImg setScrollWheel: event.deltaX Y: event.deltaY locX: event.locationInWindow.x locY: event.locationInWindow.y])
        [self drawFrame];
}

- (void) rotateWithEvent:(NSEvent *)event;
{
    if (fabs(event.rotation) < 0.5) return;
    //NSLog(@"rot %@", event);
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    if  (flags & NSControlKeyMask) return;
    //[gNiiImg changeClipDepth: 8*event.rotation];
    [gNiiImg setMagnify: event.rotation];
    [self drawFrame];
}

- (void) magnifyWithEvent:(NSEvent *)event;
{
    if (fabs(event.magnification) < 0.01) return;
    NSUInteger flags = [[NSApp currentEvent] modifierFlags];
    if  (flags & NSCommandKeyMask) return;
    if  (flags & NSControlKeyMask)
        [gNiiImg setMagnify: event.magnification];
    else
        [gNiiImg changeClipDepth: 200*event.magnification];
    [self drawFrame];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    //NSLog(@"swipe %g %g", event.deltaX, event.deltaY);
    [gNiiImg setSwipe: event.deltaX Y: event.deltaY];
    [self drawFrame];
}//older versions of OSX?*/

- (void) viewDidMoveToWindow
{
    // Listen to all mouse move events (not just dragging)
    [[self window] setAcceptsMouseMovedEvents:YES];
    // When view changes to this window then be sure that we start responding
    // to mouse events
    [[self window] makeFirstResponder:self];
}

- (void) drawFrame
{
    [self setNeedsDisplay:YES]; // request an MTKView redraw -> drawInMTKView:
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    [gNiiImg setScreenWidHt:(int)size.width Height:(int)size.height];
}

- (void)drawInMTKView:(MTKView *)view
{
    [gNiiImg redrawMetalInView:view]; // CPU data-prep + Metal render, no OpenGL
}

// MTKView has no -reshape (that's NSOpenGLView), but callers like
// handleScreenChanges still invoke it. Update the render size + redraw.
- (void) reshape
{
    CGSize ds = self.drawableSize;
    if (ds.width > 0 && ds.height > 0)
        [gNiiImg setScreenWidHt:(int)ds.width Height:(int)ds.height];
    [self setNeedsDisplay:YES];
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)becomeFirstResponder
{
    return  YES;
}

- (BOOL)resignFirstResponder
{
    return YES;
}

- (bool) sharpen {
    bool ret = [gNiiImg sharpen];
    if (ret == FALSE) {
        //[self ShowAlert:@"This function only works on 3D grayscale data" Title:@"Unable to remove haze"];
        [self ShowAlert:@"This function only works on grayscale data" Title:@"Unable to remove haze"]; //allow displayed volume of 4D
        return ret;
    }
    [self drawFrame];
    return ret;
}


- (bool) removeHaze {
     bool ret = [gNiiImg removeHaze];
    if (ret == FALSE) {
        //[self ShowAlert:@"This function only works on 3D grayscale data" Title:@"Unable to remove haze"];
        [self ShowAlert:@"This function only works on grayscale data" Title:@"Unable to remove haze"]; //allow displayed volume of 4D
        return ret;
    }
    [self drawFrame];    
    return ret;
}

- (void) resetClip
{
    int azim = 180;
    int elev = 0;
    int depth = 0;
    [gNiiImg setClip: azim Elev: elev Depth: depth];
    [self drawFrame];
}

-(NSString *)  matToText: (mat44)m
{
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    [nf setNumberStyle:NSNumberFormatterDecimalStyle];
    [nf setMaximumFractionDigits:3];
    [nf setRoundingMode:NSNumberFormatterRoundDown];
    NSString * ret;
    ret = [NSString stringWithFormat:@"[%@ %@ %@ %@; %@ %@ %@ %@; %@ %@ %@ %@]",
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[0][0]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[0][1]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[0][2]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[0][3]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[1][0]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[1][1]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[1][2]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[1][3]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[2][0]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[2][1]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[2][2]]],
           [nf stringFromNumber:[NSNumber numberWithFloat:m.m[2][3]]]];
    return ret;
}

/*-(NSString *)  matToText: (mat44)m
//this works, but gives hard to decipher scientific results for values near zero
 {
    NSString * ret;
    ret = [NSString stringWithFormat:@"[%g %g %g %g; %g %g %g %g; %g %g %g %g]",
           m.m[0][0],m.m[0][1],m.m[0][2],m.m[0][3],
           m.m[1][0],m.m[1][1],m.m[1][2],m.m[1][3],
           m.m[2][0],m.m[2][1],m.m[2][2],m.m[2][3] ];
    return ret;
}*/

-(NSString *) getHeaderFilename;
{
    NII_PREFS *prefs =[gNiiImg getPREFS];
    //return prefs->nii_prefs_fname;
    //NSLog(@"nii_GL fname = %s", prefs->nii_prefs_fname);
    return [NSString stringWithCString:prefs->nii_prefs_fname encoding:NSASCIIStringEncoding];
}

-(NSString *) getHeaderInfo
{
    FSLIO *f = [gNiiImg getFSLIO];
    NSString * ret;
    NSString *smat = [self matToText:f->niftiptr->sto_xyz];
    if (f->niftiptr->dim[0] == 3)
        ret = [NSString stringWithFormat:@"Dimensions: %dx%dx%d\nBytes per voxel: %d\nSpacing: %.3fx%.3fx%.3f\nMatrix %@",
               f->niftiptr->dim[1], f->niftiptr->dim[2], f->niftiptr->dim[3],
               f->niftiptr->nbyper,
               f->niftiptr->pixdim[1],f->niftiptr->pixdim[2],f->niftiptr->pixdim[3], smat ];
    else
        ret = [NSString stringWithFormat:@"Dimensions: %dx%dx%dx%d\nBytes per voxel: %d\nSpacing: %.3fx%.3fx%.3fx%.5f\nMatrix %@",
      f->niftiptr->dim[1], f->niftiptr->dim[2], f->niftiptr->dim[3],  f->niftiptr->dim[4],
            f->niftiptr->nbyper,
      f->niftiptr->pixdim[1],f->niftiptr->pixdim[2],f->niftiptr->pixdim[3], f->niftiptr->pixdim[4], smat  ];
    
    NSString *desc= [NSString stringWithUTF8String:f->niftiptr->descrip];
    desc = [desc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (desc.length > 0)
        ret = [ret stringByAppendingString:[@"\nDescription: " stringByAppendingString: desc]];
    NSString * slicecode;
    if (f->niftiptr->slice_code == NIFTI_SLICE_SEQ_INC)
        slicecode = @"\nAscending";
    else if (f->niftiptr->slice_code == NIFTI_SLICE_SEQ_DEC)
        slicecode = @"\nDescending";
    else if (f->niftiptr->slice_code == NIFTI_SLICE_ALT_INC)
        slicecode = @"\nInterleaved Ascending [1,3..2,4..]";
    else if (f->niftiptr->slice_code == NIFTI_SLICE_ALT_DEC)
        slicecode = @"\nInterleaved Descending [n,n-2..n-1,n-3..]";
    else if (f->niftiptr->slice_code == NIFTI_SLICE_ALT_INC2)
        slicecode = @"\n*Interleaved Ascending [2,4..1,3..]";
    else if (f->niftiptr->slice_code == NIFTI_SLICE_ALT_DEC2)
        slicecode = @"\n*Interleaved Descending [n-1,n-3,..n,n-2..]";
    else
        slicecode = @"";
    ret = [ret stringByAppendingString: slicecode];
    ret = [ret stringByAppendingString: [NSString stringWithFormat:@"\nIntensity Intercept; Slope: %g; %g", f->niftiptr->scl_inter, f->niftiptr->scl_slope] ];
    
    
   /* NSString * vx;
    vx = @"\nbeta!!!!!!\n";
    ret = [ret stringByAppendingString: vx];
     = @"Your String"
    NIFTI_SLICE_SEQ_INC  == sequential increasing
    NIFTI_SLICE_SEQ_DEC  == sequential decreasing
    NIFTI_SLICE_ALT_INC  == alternating increasing
    NIFTI_SLICE_ALT_DEC  == alternating decreasing
    NIFTI_SLICE_ALT_INC2 == alternating increasing #2
    NIFTI_SLICE_ALT_DEC2 == alternating decreasing #2
    f->niftiptr->slice_code*/
    //if (f->niftiptr->descrip)
    //    ret = [ret stringByAppendingString:@".png"];
    return ret;
}

- (void) awakeFromNib
{
    //[self setAcceptsTouchEvents: YES];


    gNiiImg = [nii_img alloc];
    gNiiImg = [gNiiImg init];
    // Metal-backed main view: draw on demand (mirrors the old GL drawFrame model).
    if (!self.device) self.device = MTLCreateSystemDefaultDevice();
    self.colorPixelFormat = MTLPixelFormatRGBA8Unorm; // match the renderer's pipeline
    self.framebufferOnly = NO;
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    self.delegate = self;
    [self updatePrefs];
    screenShotScaleFactor = 1.0f;
    //retinaScaleFactor = 1.0f;
    /*float supportRetina = 1.0;
    if ([[NSScreen mainScreen] respondsToSelector:@selector(backingScaleFactor)]) {
        NSArray *screens = [NSScreen screens];
        for (int i = 0; i < [screens count]; i++) {
            float s = [[screens objectAtIndex:i] backingScaleFactor];
            if (s > supportRetina)
                supportRetina = s;
        }
    }*/
    //NII_PREFS *prefs =[gNiiImg getPREFS]; //RetinaXX
    //[gNiiImg updateFontScale: retinaScaleFactor];
    screenShotScaleFactor = 1.0;
    /*
    [self setWantsBestResolutionOpenGLSurface:NO];//RetinaX 2016  - (void)
    if ((supportRetina > 1.0) && (prefs->retinaResolution)) {
        //[self setWantsBestResolutionOpenGLSurface:YES];//RetinaX 2016  - (void) prepareOpenGL
        //[self convertRectToBacking:[self bounds]];
        //NSRect backingBounds = self.;
        
        
        //NSRect backingBounds = [self convertRectToBacking:[self bounds]];
        //int wRetina = [self convertRectToBacking:[self bounds]].size.width;
        //int wBase = [self bounds].size.width;
        //if ((wRetina > wBase) && (wBase > 2))
        //    retinaScaleFactor = wRetina/wBase;
        retinaScaleFactor = [[NSScreen mainScreen] backingScaleFactor];
        [gNiiImg updateFontScale: retinaScaleFactor];
        //screenShotScaleFactor = retinaScaleFactor;
        //retinaScaleFactor = 2.0;
    } else if (supportRetina > 1.0) {
        screenShotScaleFactor = supportRetina;
        //[gNiiImg updateFontScale: screenShotScaleFactor];
        //retinaScaleFactor = 1;
        retinaScaleFactor = 1;
        [gNiiImg updateFontScale: retinaScaleFactor];
    }
     */
        //RetinaX 2016

    
    //NSRect hdRect = [self convertRectToBacking: [self bounds]];
    //NSRect sdRect = [self bounds];
    //NSLog(@"retinaScaleFactor %g %g", NSWidth(hdRect), NSWidth(sdRect));
    //[gNiiImg updateFont: aColor] ;
    //NSLog(@"retinaScaleFactor %g ", retinaScaleFactor);
    
    //self.acceptsTouchEvents = YES;
    //[[NSUserDefaults standardUserDefaults] setObject:@"/Users/cr/t1.nii" forKey:@"defaultFilename"];
    //for (int i = 0; i < 256; i++)  //test for leaks...
    //NSLog(@"BETA");
    [self setLoadImageX: [[NSUserDefaults standardUserDefaults] stringForKey:@"defaultFilename"] newWindow: true];
    //[gNiiImg setLoadImage:[[NSUserDefaults standardUserDefaults] stringForKey:@"defaultFilename"] ];
    [gNiiImg setScreenWidHt: [self bounds].size.width Height: [self bounds].size.height];
    
    /*
    NSString *over = [[[NSUserDefaults standardUserDefaults] stringForKey:@"defaultFilename"] stringByDeletingLastPathComponent];
    over = [over stringByAppendingString: @"/spmMotor.nii.gz"];
    NSLog(@"overlay loading>>%@", over);
    [self openOverlayFromFileNameGL:  over];
    */
}

- (void)deallocGL
{
    #if !__has_feature(objc_arc)
    [gNiiImg dealloc];
    #endif
}

- (void)dealloc
{
    //CVDisplayLinkRelease(displayLink);
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end

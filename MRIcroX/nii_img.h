//  writtem by Chris Rorden on 8/14/12 - distributed under BSD license

#import <Foundation/Foundation.h>
#include "nii_io.h"
#include "nii_definetypes.h"
#include "nii_platform.h"
#include "nii_graph.h" // GraphStruct (was nii_timelineView.h, which is AppKit/macOS-only)

@class MTKView;
@class NIIMetalRenderer;

@interface nii_img : NSObject
{
    NSMutableArray * labelArray;
    FSLIO *fslio;
    NII_PREFS *prefs;
    id _metalRenderer; // NIIMetalRenderer, one per window
}
// Metal render entry points (the renderer is the only backend now).
- (void) redrawMetalInView:(MTKView *)view; // CPU data-prep + Metal render
// Render the current frame offscreen (synchronous) into RGB (3 bytes/px, top-
// left origin) for screenshots. Returns NO if no renderer/volume.
- (BOOL) metalScreenshotIntoRGB:(unsigned char *)dest width:(int)w height:(int)h;
-(void) updateFont: (PlatformColor *) aColor;
- (void) updateFontScale: (float) scale;
-(bool) removeHaze;
-(bool) sharpen;
-(bool) setXYZmm: (float) x Y: (float) y Z: (float) z;
-(bool) changeXYZvoxel: (int) x Y: (int) y Z: (int) z;
-(int) getVolume; //returns displayed volume 1..getNumberOfVolumes
-(int) getNumberOfVolumes; //returns number of volumes: 1 for 3D images, else number of volumes in loaded 4D stack
-(void) setVolume: (int) volume; //set volume for display - clipped to 1..getNumberOfVolumes 
-(void) setBackgroundColor: (double) red Green: (double) green Blue: (double) blue;
-(void) setColorScheme: (int) clrIndex;
-(void) setColorSchemeForLayer: (int) index Layer: (int) layer;
-(void) setDisplayModeX: (int) mode;
-(int)  setLoadImage: (NSString *) file_name; //dummy loaded if filename blank or non-existent
-(int)  setLoadDTI: (NSString *) faname V1name: (NSString *) v1name; //dummy loaded if filename blank or non-existent
-(bool) isBackgroundRGB;
-(void) setMouseDown: (int) x Y: (int) y;
//-(bool) setScrollWheel: (int) delta;
//-(bool) setScrollWheel:  (float) x Y: (float) delta;
-(bool) setScrollWheel:  (float) x Y: (float) delta locX: (float) mouseX locY: (float) mouseY;
-(void) changeClipDepth: (float) x;
-(void) setMagnify: (float) delta;
-(bool) magnifyRender: (float) delta;
-(void) setSwipe: (float) x Y: (float) y;
-(void) makeMosaic:(NSString *)mosStr;
-(void) setMouseDrag: (int) x Y: (int) y;
-(void) setRightMouseDragXY: (int) x Y: (int) y isMag: (bool) mag isSwipe: (bool) swipe;
//-(void) setRightMouseDragX: (int) x;
//-(void) setRightMouseDragY: (int) y;
//-(void) setRightMouseDrag: (int) x Y: (int) y;
-(bool) setRightMouseUp: (int) x Y: (int) y;;
-(void) setScreenWidHt: (double) width Height: (double) height;
-(void) setScreenWidHtOffset: (double) width Height: (double) height OffsetX: (double) offsetX OffsetY: (double) offsetY;
-(void) setViewMinMax: (double) min Max: (double) max;
-(void) setViewMinMaxForLayer: (double) min Max: (double) max Layer: (int) layer; 
-(void) setAzimElev: (int) azim Elev: (int) elev;
-(void) setAzimElevInc: (int) azim Elev: (int) elev;
-(bool) doRedraw; //redraw screen - returns true if any changes were required
-(int)  nextOverlaySlot; //returns -1 if unable to load another overlay
-(int)  addOverlay: (NSString *) file_name;
-(GraphStruct) getTimeline;

-(bool) isTimelineUpdateNeeded;
-(void) closeAllOverlays;
-(void) getBackgroundColor:(double*)red Green:(double*)green Blue:(double*)blue;
-(void) getSuggestedViewMinMax: (double*) min Max: (double*) max;//suggested image range excluding outliers
-(void) getViewMinMax: (double*) min Max: (double*) max; //currently displayed values
-(void) getAzimElev: (int *) azim Elev: (int *) elev;
-(void) getClip: (int *) azim Elev: (int *) elev Depth: (int *) depth;
-(void) setClip: (int) azim Elev: (int) elev Depth: (int) depth;


-(FSLIO *) getFSLIO;
-(NII_PREFS *) getPREFS;
-(NSString *) getHeaderInfo; //human-readable summary of the loaded image header (dims, mm, datatype, range); empty string if none loaded
@end

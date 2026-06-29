//
//  nii_timelineView.h
//  PDF
//
//  Created by Chris Rorden on 9/24/12.
//  Copyright (c) 2012 Chris Rorden. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#include "nii_graph.h" // GraphStruct (platform-neutral; shared with the iOS target)

@interface nii_timelineView : NSImageView
/*{
    //NSColor *mybackground;
    //NSImage *myimage;
    NSImageView *myview;
}*/

- (void)savePDFFromFileName:(NSString *)fname;
- (void)savePDF;
//- (void)ensureShow;
- (void)saveTab;
- (void) pasteFromClipboard;
//-(void) changeData: (int) timepoints SelectedTimepoint: (int) selectedTimepoint Lines: (int) lines VerticalScale: (float) verticalScale Data: (float*) data;
-(void) updateData: (GraphStruct) graph;
-(void) enable: (bool) on;
//@property(retain) NSColor *mybackground;
//@property(retain) NSImage *myimage;
//@property(retain) NSImageView *myview;
@end

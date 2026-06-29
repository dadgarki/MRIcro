//
//  nii_graph.h
//  MRIcroX
//
//  Platform-neutral definition of GraphStruct (the 4D timeline data passed
//  across the nii_img seam). Extracted from nii_timelineView.h (which is AppKit
//  NSImageView and macOS-only) so the shared controller header nii_img.h can be
//  included from the iOS/iPadOS UIKit target without dragging in Cocoa.
//

#ifndef nii_graph_h
#define nii_graph_h

#include <stdbool.h>

typedef struct {
    int timepoints, lines, selectedTimepoint;
    float verticalScale;
    bool blackBackground, enabled;
    float * data;
} GraphStruct;

#endif /* nii_graph_h */

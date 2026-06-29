//
//  NIITimelineView.h
//  MRIcroPad (iOS / iPadOS)
//
//  4D time-series plot: the intensity at the current crosshair voxel across all
//  volumes (the UIKit counterpart of the AppKit nii_timelineView). Touch/drag
//  scrubs the displayed volume. Shown only for 4D data (>= 2 volumes).
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import <UIKit/UIKit.h>

@class NIITimelineView;
@protocol NIITimelineViewDelegate <NSObject>
- (void)timelineView:(NIITimelineView *)view didScrubToVolume:(int)volume; // 1-based
@end

@interface NIITimelineView : UIView
@property (nonatomic, weak) id<NIITimelineViewDelegate> delegate;
/// Copy `count` samples and the 1-based selected volume; pass count<2 to clear.
- (void)setSamples:(const float *)samples count:(int)count selected:(int)selected;
@end

#endif

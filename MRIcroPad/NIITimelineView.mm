//
//  NIITimelineView.mm
//  MRIcroPad (iOS / iPadOS)
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import "NIITimelineView.h"

@implementation NIITimelineView {
    NSMutableData *_samples; // float[_count]
    int _count;
    int _selected;           // 1-based
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        self.layer.cornerRadius = 8;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setSamples:(const float *)samples count:(int)count selected:(int)selected {
    if (samples && count > 1) {
        _samples = [NSMutableData dataWithBytes:samples length:(NSUInteger)count * sizeof(float)];
        _count = count;
    } else {
        _samples = nil; _count = 0;
    }
    _selected = selected;
    [self setNeedsDisplay];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    const CGFloat ml = 8, mr = 8, mt = 18, mb = 8; // margins (top leaves room for label)
    CGRect plot = CGRectMake(ml, mt, self.bounds.size.width - ml - mr,
                             self.bounds.size.height - mt - mb);
    if (_count < 2 || plot.size.width < 2 || plot.size.height < 2) return;
    const float *d = (const float *)_samples.bytes;

    float mn = d[0], mx = d[0];
    for (int i = 1; i < _count; i++) { mn = MIN(mn, d[i]); mx = MAX(mx, d[i]); }
    float span = (mx > mn) ? (mx - mn) : 1.0f;

    CGFloat (^px)(int) = ^CGFloat(int i){ return plot.origin.x + plot.size.width * (CGFloat)i / (_count - 1); };
    CGFloat (^py)(float) = ^CGFloat(float v){ return plot.origin.y + plot.size.height * (1.0f - (v - mn) / span); };

    // current-volume marker (vertical line)
    if (_selected >= 1 && _selected <= _count) {
        CGFloat mxp = px(_selected - 1);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.95 green:0.85 blue:0.2 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextMoveToPoint(ctx, mxp, plot.origin.y);
        CGContextAddLineToPoint(ctx, mxp, CGRectGetMaxY(plot));
        CGContextStrokePath(ctx);
    }
    // time-series polyline
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextMoveToPoint(ctx, px(0), py(d[0]));
    for (int i = 1; i < _count; i++) CGContextAddLineToPoint(ctx, px(i), py(d[i]));
    CGContextStrokePath(ctx);

    // label "Vol sel/N"
    NSString *label = [NSString stringWithFormat:@"Vol %d / %d", _selected, _count];
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium],
                             NSForegroundColorAttributeName: [UIColor whiteColor] };
    [label drawAtPoint:CGPointMake(ml, 2) withAttributes:attrs];
}

#pragma mark - Scrub (touch -> volume)

- (void)scrubToX:(CGFloat)x {
    if (_count < 2) return;
    const CGFloat ml = 8, mr = 8;
    CGFloat w = self.bounds.size.width - ml - mr;
    if (w < 1) return;
    float frac = (float)((x - ml) / w);
    int vol = 1 + (int)lroundf(frac * (_count - 1));
    vol = MAX(1, MIN(_count, vol));
    if (vol != _selected) {
        _selected = vol;
        [self setNeedsDisplay];
        [self.delegate timelineView:self didScrubToVolume:vol];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self scrubToX:[[touches anyObject] locationInView:self].x];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self scrubToX:[[touches anyObject] locationInView:self].x];
}

@end

#endif

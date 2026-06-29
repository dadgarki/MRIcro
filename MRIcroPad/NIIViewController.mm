//
//  NIIViewController.mm
//  MRIcroX (iOS / iPadOS)
//
//  UIKit host for the unified Metal renderer. Mirrors nii_GLView's event→seam
//  mapping for touch and adds a UIKit toolbar (open file, display mode, color
//  table, window/level) driving the shared nii_img control surface.
//
//  Touch map:
//    - tap            -> move crosshair / pick voxel
//    - 1-finger pan   -> rotate the volume   (Clip mode: rotate the clip plane)
//    - pinch          -> zoom                (Clip mode: clip plane depth)
//    - 2-finger pan   -> scroll slices (2D)
//  A toolbar "scissors" button toggles Clip mode.
//  Coordinates are converted from UIKit points (top-left origin) to renderer
//  pixel space (bottom-left origin, backing pixels) to match scrnWid/scrnHt.
//

#import <TargetConditionals.h>
#if !TARGET_OS_OSX

#import "NIIViewController.h"
#import "NIITimelineView.h"
#import "nii_img.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface NIIViewController () <UIDocumentPickerDelegate, NIITimelineViewDelegate>
{
    nii_img *_niiImg;
    MTKView *_mtkView;
    UIToolbar *_toolbar;
    UIView *_wlPanel;       // window/level slider panel (hidden by default)
    UISlider *_minSlider;
    UISlider *_maxSlider;
    UISlider *_gammaSlider;
    BOOL _advancedRender;   // gradient-lit (matcap) 3D rendering; on by default
    UIBarButtonItem *_effectsItem;
    UIBarButtonItem *_settingsItem;
    UIBarButtonItem *_shareItem;
    UIBarButtonItem *_openItem;     // anchor for the file-chooser popover
    UIBarButtonItem *_clipItem;     // Clip-mode toggle
    UIBarButtonItem *_colorItem;    // Color menu (per active layer)
    UIBarButtonItem *_layersItem;   // active-layer + opacity menu
    NIITimelineView *_timeline;     // 4D time-series plot (hidden for 3D data)
    UIButton *_volPrev, *_volNext;  // 4D volume stepper (shown with the timeline)
    int _activeLayer;       // 0 = background, 1.. = overlay slots (color/W-L target)
    BOOL _pickingOverlay;   // routes the next document pick to addOverlay vs load
    BOOL _clipMode;         // when on: 1-finger = clip angle, pinch = clip depth
}
@end

@implementation NIIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Metal view, draw-on-demand (matches the macOS nii_GLView setup).
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:MTLCreateSystemDefaultDevice()];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat = MTLPixelFormatRGBA8Unorm; // match the renderer pipeline
    _mtkView.framebufferOnly = NO;
    _mtkView.enableSetNeedsDisplay = YES;
    _mtkView.paused = YES;
    _mtkView.delegate = self;
    [self.view addSubview:_mtkView];

    _niiImg = [[nii_img alloc] init];
    _advancedRender = YES; // default to gradient-lit (matcap) rendering
    [self loadSavedPrefs]; // apply persisted display settings (may override _advancedRender)

    [self installGestureRecognizers];
    [self buildToolbar];
    [self buildWindowLevelPanel];
    [self buildTimeline];
    [self loadImageAtPath:nil]; // bundled sample volume until a file is opened
}

// 4D time-series plot, pinned just above the toolbar; shown only for 4D data.
- (void)buildTimeline {
    _timeline = [[NIITimelineView alloc] initWithFrame:CGRectZero];
    _timeline.translatesAutoresizingMaskIntoConstraints = NO;
    _timeline.delegate = self;
    _timeline.hidden = YES;
    [self.view addSubview:_timeline];

    // 4D volume stepper buttons flanking the timeline (prev | plot | next).
    _volPrev = [self makeStepperButton:@"chevron.left.circle.fill" action:@selector(stepVolumePrev)];
    _volNext = [self makeStepperButton:@"chevron.right.circle.fill" action:@selector(stepVolumeNext)];

    [NSLayoutConstraint activateConstraints:@[
        [_volPrev.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [_volPrev.centerYAnchor constraintEqualToAnchor:_timeline.centerYAnchor],
        [_volNext.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        [_volNext.centerYAnchor constraintEqualToAnchor:_timeline.centerYAnchor],
        [_timeline.leadingAnchor constraintEqualToAnchor:_volPrev.trailingAnchor constant:6],
        [_timeline.trailingAnchor constraintEqualToAnchor:_volNext.leadingAnchor constant:-6],
        [_timeline.bottomAnchor constraintEqualToAnchor:_toolbar.topAnchor constant:-8],
        [_timeline.heightAnchor constraintEqualToConstant:120],
    ]];
}

- (UIButton *)makeStepperButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:28];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.hidden = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (void)stepVolume:(int)delta {
    int n = [_niiImg getNumberOfVolumes];
    if (n < 2) return;
    int v = [_niiImg getVolume] + delta;
    if (v < 1) v = n; else if (v > n) v = 1; // wrap around
    [_niiImg setVolume:v];
    [self updateTimeline];
    [_mtkView setNeedsDisplay];
}
- (void)stepVolumePrev { [self stepVolume:-1]; }
- (void)stepVolumeNext { [self stepVolume:+1]; }

// Refresh the time-series at the current crosshair; hide it for 3D (1-volume) data.
- (void)updateTimeline {
    BOOL is4D = [_niiImg getNumberOfVolumes] >= 2;
    if (!is4D) { _timeline.hidden = YES; _volPrev.hidden = YES; _volNext.hidden = YES; return; }
    GraphStruct g = [_niiImg getTimeline];
    if (g.data && g.timepoints >= 2) {
        _timeline.hidden = NO; _volPrev.hidden = NO; _volNext.hidden = NO;
        [_timeline setSamples:g.data count:g.timepoints selected:g.selectedTimepoint];
    }
    if (g.data) free(g.data);
}

- (void)timelineView:(NIITimelineView *)view didScrubToVolume:(int)volume {
    [_niiImg setVolume:volume];
    [_mtkView setNeedsDisplay];
}

// Apply persisted display preferences (mirrors the macOS updatePrefs that reads
// NSUserDefaults) so settings survive relaunches. Registers sensible first-run
// defaults, then pushes each into NII_PREFS.
- (void)loadSavedPrefs {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d registerDefaults:@{ @"showCube":@YES, @"showInfo":@YES, @"showOrient":@YES,
                           @"crosshairs":@YES, @"viewRadiological":@NO,
                           @"blackBackground":@YES, @"advancedRender":@YES,
                           @"isSmooth2D":@YES }];
    NII_PREFS *p = [_niiImg getPREFS];
    if (!p) return;
    p->showCube         = [d boolForKey:@"showCube"];
    p->showInfo         = [d boolForKey:@"showInfo"];
    p->showOrient       = [d boolForKey:@"showOrient"];
    p->xBarGap          = [d boolForKey:@"crosshairs"] ? 3 : -1;
    p->isSmooth2D       = [d boolForKey:@"isSmooth2D"];
    p->viewRadiological = [d boolForKey:@"viewRadiological"];
    _advancedRender     = [d boolForKey:@"advancedRender"];
    if ([d boolForKey:@"blackBackground"]) [_niiImg setBackgroundColor:0 Green:0 Blue:0];
    else                                   [_niiImg setBackgroundColor:1 Green:1 Blue:1];
}

#pragma mark - Coordinate helpers

// UIKit point (top-left) -> renderer pixel (bottom-left, backing pixels).
- (CGPoint)pixelFromPoint:(CGPoint)p {
    CGFloat s = _mtkView.contentScaleFactor;
    CGFloat h = _mtkView.bounds.size.height;
    return CGPointMake(p.x * s, (h - p.y) * s);
}

#pragma mark - File load

- (void)loadImageAtPath:(NSString *)path {
    if (path.length < 1) // no file specified: load the bundled sample volume
        path = [self bundledSampleVolumePath];
    [_niiImg setLoadImage:(path ?: @"")];
    [self postLoadRefresh];
}

// Shared post-load refresh (used by image and DTI loads): apply render settings,
// resize, reset to the background layer, and refresh menus / W-L / timeline.
- (void)postLoadRefresh {
    [self applyAdvancedRender];
    CGSize ds = _mtkView.drawableSize;
    [_niiImg setScreenWidHt:ds.width Height:ds.height];
    _activeLayer = 0; // new volume: overlays cleared, back to background
    _layersItem.menu = [self layersMenu];
    _colorItem.menu = [self colorMenu];
    [self syncWindowLevelControls];
    [self updateTimeline];
    [_mtkView setNeedsDisplay];
}

// Load a DTI pair: pick either the *_FA or *_V1 image; the sibling (same folder,
// FA<->V1 name swap) is derived. FA is the background, V1 drives the DTI vectors.
- (void)loadDTIFrom:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fa = nil, *v1 = nil;
    if ([path rangeOfString:@"_FA"].location != NSNotFound) {
        fa = path; v1 = [path stringByReplacingOccurrencesOfString:@"_FA" withString:@"_V1"];
    } else if ([path rangeOfString:@"_V1"].location != NSNotFound) {
        v1 = path; fa = [path stringByReplacingOccurrencesOfString:@"_V1" withString:@"_FA"];
    }
    if (fa && v1 && [fm fileExistsAtPath:fa] && [fm fileExistsAtPath:v1]) {
        [_niiImg setLoadDTI:fa V1name:v1];
        [self postLoadRefresh];
    } else {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"DTI pair not found"
            message:@"Need a *_FA and matching *_V1 image in the same folder."
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    }
}

// Push _advancedRender into prefs and force a recalc so the Sobel gradient
// (needed by the matcap path) is (re)computed for the current volume.
- (void)applyAdvancedRender {
    NII_PREFS *prefs = [_niiImg getPREFS];
    if (!prefs) return;
    prefs->advancedRender = _advancedRender;
    prefs->rayCastQuality1to4 = 4; // crisp when idle (lowered during gestures)
    prefs->force_recalcGL = true;
    prefs->force_refreshGL = true;
}

// Adaptive ray-cast quality: coarse (fast) while a gesture is in progress, full
// quality (re-rendered) when it ends — keeps rotation/clip/zoom smooth on large
// volumes without sacrificing the static image.
- (void)setInteracting:(BOOL)on {
    NII_PREFS *p = [_niiImg getPREFS];
    if (!p) return;
    int q = on ? 2 : 4;
    if (p->rayCastQuality1to4 == q) return;
    p->rayCastQuality1to4 = q;
    if (!on) [_mtkView setNeedsDisplay]; // final crisp frame
}

// Path to the visiblehuman.nii.gz bundled in the app (nil if missing).
- (NSString *)bundledSampleVolumePath {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"visiblehuman.nii" ofType:@"gz"];
    if (!p) // fall back to a direct resourcePath join (compound extension safety)
        p = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"visiblehuman.nii.gz"];
    return [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_niiImg setScreenWidHt:(int)size.width Height:(int)size.height];
}

- (void)drawInMTKView:(MTKView *)view {
    [_niiImg redrawMetalInView:view]; // shared CPU prep + Metal render
}

#pragma mark - Toolbar

- (void)buildToolbar {
    _toolbar = [[UIToolbar alloc] init];
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    _openItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"folder"] menu:[self openMenu]];
    UIBarButtonItem *open = _openItem;

    UIBarButtonItem *view = [[UIBarButtonItem alloc]
        initWithTitle:@"View" menu:[self displayModeMenu]];

    _colorItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Color" menu:[self colorMenu]];
    UIBarButtonItem *color = _colorItem;

    _layersItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"square.stack.3d.up"] menu:[self layersMenu]];

    UIBarButtonItem *wl = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"slider.horizontal.below.rectangle"]
                style:UIBarButtonItemStylePlain target:self action:@selector(toggleWindowLevel)];

    _effectsItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"wand.and.stars"] menu:[self effectsMenu]];

    _settingsItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"gearshape"] menu:[self settingsMenu]];

    _clipItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"scissors"] style:UIBarButtonItemStylePlain
               target:self action:@selector(toggleClipMode)];

    _shareItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareCurrentView)];

    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    _toolbar.items = @[open, flex, view, flex, _layersItem, flex, color, flex, wl, flex,
                       _clipItem, flex, _effectsItem, flex, _settingsItem, flex, _shareItem];
}

// Clip mode: while on, one-finger drag aims the clip plane and pinch sets its
// depth (instead of rotate / zoom). Entering it with no active cut starts a
// shallow cut facing the current view, for immediate feedback.
- (void)toggleClipMode {
    _clipMode = !_clipMode;
    NII_PREFS *p = [_niiImg getPREFS];
    if (_clipMode && p && p->clipDepth < 1)
        [_niiImg setClip:(180 - p->renderAzimuth) Elev:p->renderElevation Depth:200];
    _clipItem.tintColor = _clipMode ? UIColor.systemBlueColor : nil; // highlight when active
    _clipItem.image = [UIImage systemImageNamed:(_clipMode ? @"scissors.circle.fill" : @"scissors")];
    [_mtkView setNeedsDisplay];
}

#pragma mark - File / Settings / Share menus

- (UIMenu *)openMenu {
    UIAction *open = [UIAction actionWithTitle:@"Open Image…"
        image:[UIImage systemImageNamed:@"doc"] identifier:nil
        handler:^(UIAction *a){ [self chooseLocalFileForOverlay:NO]; }];
    UIAction *over = [UIAction actionWithTitle:@"Add Overlay…"
        image:[UIImage systemImageNamed:@"square.stack.3d.up"] identifier:nil
        handler:^(UIAction *a){ [self chooseLocalFileForOverlay:YES]; }];
    UIAction *dti = [UIAction actionWithTitle:@"Open Diffusion (FA/V1)…"
        image:[UIImage systemImageNamed:@"arrow.up.and.down.and.arrow.left.and.right"] identifier:nil
        handler:^(UIAction *a){ [self chooseDTI]; }];
    UIAction *close = [UIAction actionWithTitle:@"Close Overlays"
        image:[UIImage systemImageNamed:@"xmark"] identifier:nil
        handler:^(UIAction *a){
            [_niiImg closeAllOverlays];
            NII_PREFS *p = [_niiImg getPREFS]; if (p) p->force_recalcGL = true;
            [self setActiveLayer:0]; // back to background (refreshes Layers/Color menus + W-L)
            [_mtkView setNeedsDisplay];
        }];
    return [UIMenu menuWithTitle:@"File" children:@[open, over, dti, close]];
}

// DTI chooser: list local *_FA / *_V1 images (both halves must be co-located, so
// only the in-app file list works — a single document-picker copy can't bring the
// sibling). Tapping one loads the pair via loadDTIFrom:.
- (void)chooseDTI {
    NSArray<NSURL *> *all = [self localVolumeFiles];
    NSMutableArray<NSURL *> *dti = [NSMutableArray array];
    for (NSURL *u in all) {
        NSString *n = u.lastPathComponent;
        if ([n rangeOfString:@"_FA"].location != NSNotFound ||
            [n rangeOfString:@"_V1"].location != NSNotFound) [dti addObject:u];
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Open Diffusion"
        message:(dti.count ? @"Pick the _FA or _V1 image"
                           : @"Add a *_FA and matching *_V1 image (same folder) to the app first.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSURL *u in dti)
        [ac addAction:[UIAlertAction actionWithTitle:u.lastPathComponent
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self loadDTIFrom:u.path]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = _openItem;
    [self presentViewController:ac animated:YES completion:nil];
}

// Volume files in the app's own Documents (where Files / drag-drop / "Open in"
// deposit them, incl. the Inbox subfolder). Reliable everywhere, unlike the
// system document picker (which can't select local files on the Simulator).
- (NSArray<NSURL *> *)localVolumeFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *docs = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSArray<NSURL *> *dirs = @[ docs, [docs URLByAppendingPathComponent:@"Inbox"] ];
    NSSet *exts = [NSSet setWithArray:@[ @"nii", @"gz", @"dcm", @"hdr", @"img",
                                         @"v16", @"mgz", @"mgh", @"nrrd", @"mha" ]];
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    for (NSURL *dir in dirs) {
        NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:dir
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *u in items)
            if ([exts containsObject:u.pathExtension.lowercaseString]) [out addObject:u];
    }
    [out sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b){
        return [a.lastPathComponent caseInsensitiveCompare:b.lastPathComponent]; }];
    return out;
}

- (void)chooseLocalFileForOverlay:(BOOL)overlay {
    NSArray<NSURL *> *files = [self localVolumeFiles];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(overlay ? @"Add Overlay" : @"Open Image")
        message:(files.count ? nil : @"No files yet — drop a NIfTI/DICOM onto the app, or use Browse Files.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSURL *u in files) {
        [ac addAction:[UIAlertAction actionWithTitle:u.lastPathComponent
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                [self openURLPath:u.path overlay:overlay]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Browse Files…"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [self presentPickerForOverlay:overlay]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = _openItem; // iPad anchor
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)openURLPath:(NSString *)path overlay:(BOOL)overlay {
    if (overlay) {
        [_niiImg addOverlay:path];
        NII_PREFS *p = [_niiImg getPREFS]; if (p) p->force_recalcGL = true;
        [self selectNewestOverlayLayer]; // make the new overlay the active layer
        [_mtkView setNeedsDisplay];
    } else {
        [self loadImageAtPath:path];
    }
}

- (UIMenu *)settingsMenu {
    NII_PREFS *p = [_niiImg getPREFS];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    // (title, NSUserDefaults key, current state, apply-block taking the new value)
    void (^add)(NSString *, NSString *, BOOL, void(^)(BOOL)) =
      ^(NSString *title, NSString *key, BOOL on, void (^apply)(BOOL)) {
        UIAction *act = [UIAction actionWithTitle:title image:nil identifier:nil
            handler:^(UIAction *a){
                BOOL nv = !on;
                apply(nv);
                [[NSUserDefaults standardUserDefaults] setBool:nv forKey:key];
                _settingsItem.menu = [self settingsMenu]; // refresh checkmarks
                [_mtkView setNeedsDisplay];
            }];
        act.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:act];
    };
    if (p) {
        add(@"Orientation Cube", @"showCube", p->showCube, ^(BOOL v){ [_niiImg getPREFS]->showCube = v; });
        add(@"Crosshairs", @"crosshairs", p->xBarGap >= 0, ^(BOOL v){ [_niiImg getPREFS]->xBarGap = v ? 3 : -1; });
        add(@"Image Info", @"showInfo", p->showInfo, ^(BOOL v){ [_niiImg getPREFS]->showInfo = v; });
        add(@"Orientation Labels", @"showOrient", p->showOrient, ^(BOOL v){ [_niiImg getPREFS]->showOrient = v; });
        add(@"Smooth 2D Slices", @"isSmooth2D", p->isSmooth2D, ^(BOOL v){ [_niiImg getPREFS]->isSmooth2D = v; });
        add(@"Radiological Orientation", @"viewRadiological", p->viewRadiological, ^(BOOL v){
            NII_PREFS *pp = [_niiImg getPREFS]; pp->viewRadiological = v; pp->force_recalcGL = true; });
        BOOL dark = (p->backColor[0] + p->backColor[1] + p->backColor[2]) < 1.5;
        add(@"Black Background", @"blackBackground", dark, ^(BOOL v){
            if (v) [_niiImg setBackgroundColor:0 Green:0 Blue:0];
            else   [_niiImg setBackgroundColor:1 Green:1 Blue:1]; });
    }
    // Header details (read-only) in its own section at the bottom of the menu.
    UIAction *info = [UIAction actionWithTitle:@"Image Information…"
        image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
        handler:^(UIAction *a){ [self showHeaderInfo]; }];
    UIMenu *infoSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
        options:UIMenuOptionsDisplayInline children:@[info]];
    return [UIMenu menuWithTitle:@"Settings" children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:items],
        infoSection ]];
}

// Present the loaded image's header as a read-only alert (dims, mm, datatype,
// display range, orientation, description). Built from the platform-neutral seam.
- (void)showHeaderInfo {
    NSString *body = [_niiImg getHeaderInfo];
    if (body.length == 0) body = @"No image loaded.";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Image Information"
        message:body preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    ac.popoverPresentationController.barButtonItem = _settingsItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)shareCurrentView {
    CGSize ds = _mtkView.drawableSize;
    int w = (int)ds.width, h = (int)ds.height;
    if (w < 1 || h < 1) return;
    unsigned char *rgb = (unsigned char *)malloc((size_t)w * h * 3);
    if (!rgb) return;
    if (![_niiImg metalScreenshotIntoRGB:rgb width:w height:h]) { free(rgb); return; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgb, w, h, 8, 3 * w, cs, kCGImageAlphaNone);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(rgb);
    if (!img) return;
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[img] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = _shareItem; // iPad popover anchor
    [self presentViewController:av animated:YES completion:nil];
}

- (UIMenu *)effectsMenu {
    UIAction *adv = [UIAction actionWithTitle:@"Advanced (matcap) Rendering" image:nil identifier:nil
                                      handler:^(UIAction *a){ [self toggleAdvancedRender]; }];
    adv.state = _advancedRender ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *haze = [UIAction actionWithTitle:@"Remove Haze"
                                         image:[UIImage systemImageNamed:@"sparkles"] identifier:nil
                                       handler:^(UIAction *a){ [self doRemoveHaze]; }];
    UIAction *sharp = [UIAction actionWithTitle:@"Sharpen"
                                          image:[UIImage systemImageNamed:@"camera.filters"] identifier:nil
                                        handler:^(UIAction *a){ [self doSharpen]; }];
    return [UIMenu menuWithTitle:@"Effects" children:@[adv, haze, sharp]];
}

- (void)toggleAdvancedRender {
    _advancedRender = !_advancedRender;
    [[NSUserDefaults standardUserDefaults] setBool:_advancedRender forKey:@"advancedRender"];
    [self applyAdvancedRender];
    _effectsItem.menu = [self effectsMenu]; // refresh the checkmark
    [_mtkView setNeedsDisplay];
}

- (void)doRemoveHaze {
    // removeHaze masks out background voxels and sets force_recalcGL itself.
    [_niiImg removeHaze];
    [_mtkView setNeedsDisplay];
}

- (void)doSharpen {
    [_niiImg sharpen];
    [_mtkView setNeedsDisplay];
}

- (UIMenu *)displayModeMenu {
    NSArray *modes = @[ @[@"3D Render", @(GL_3D_ONLY)],
                        @[@"2D + 3D",   @(GL_2D_AND_3D)],
                        @[@"Axial",     @(GL_2D_AXIAL)],
                        @[@"Coronal",   @(GL_2D_CORONAL)],
                        @[@"Sagittal",  @(GL_2D_SAGITTAL)],
                        @[@"Multi (2D)",@(GL_2D_ONLY)] ];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (NSArray *m in modes) {
        int mode = [m[1] intValue];
        UIAction *a = [UIAction actionWithTitle:m[0] image:nil identifier:nil
                                        handler:^(UIAction *act){ [self setDisplayMode:mode]; }];
        [actions addObject:a];
    }
    [actions addObject:[self orientationMenu]]; // 3D view-angle presets (inline submenu)
    return [UIMenu menuWithTitle:@"Display Mode" children:actions];
}

// Standard 3D view-angle presets (azimuth/elevation), mirroring the macOS
// setAzimElevOrient: mapping (LRPAIS). Inline submenu under the View button.
- (UIMenu *)orientationMenu {
    NSArray *presets = @[ @[@"Left",      @90,  @0],
                          @[@"Right",     @270, @0],
                          @[@"Posterior", @0,   @0],
                          @[@"Anterior",  @180, @0],
                          @[@"Inferior",  @(-180), @(-90)],
                          @[@"Superior",  @0,   @90] ];
    NSMutableArray<UIAction *> *acts = [NSMutableArray array];
    for (NSArray *p in presets) {
        int az = [p[1] intValue], el = [p[2] intValue];
        UIAction *a = [UIAction actionWithTitle:p[0] image:nil identifier:nil
            handler:^(UIAction *act){
                [_niiImg setAzimElev:az Elev:el];
                [_mtkView setNeedsDisplay];
            }];
        [acts addObject:a];
    }
    return [UIMenu menuWithTitle:@"View Angle"
                          image:[UIImage systemImageNamed:@"rotate.3d"]
                     identifier:nil options:0 children:acts];
}

- (UIMenu *)colorMenu {
    // Curated subset of createlutX's color schemes (index -> name).
    NSArray *luts = @[ @[@"Grayscale",@0], @[@"Hot",@1], @[@"Bone",@8], @[@"Gold",@9],
                       @[@"Hot Iron",@10], @[@"Surface",@11], @[@"Cividis",@15],
                       @[@"Inferno",@16], @[@"Plasma",@17], @[@"Viridis",@18],
                       @[@"CT Bone",@21], @[@"CT Soft Tissue",@24] ];
    int cur = [self activeLayerColorScheme];
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSArray *l in luts) {
        int idx = [l[1] intValue];
        UIAction *a = [UIAction actionWithTitle:l[0] image:nil identifier:nil
                                        handler:^(UIAction *act){ [self setColorScheme:idx]; }];
        a.state = (cur == idx) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    NSString *title = (_activeLayer == 0) ? @"Color: Background"
                                          : [NSString stringWithFormat:@"Color: Overlay %d", _activeLayer];
    return [UIMenu menuWithTitle:title children:actions];
}

// Color scheme currently set on the active layer (background or an overlay slot).
- (int)activeLayerColorScheme {
    NII_PREFS *p = [_niiImg getPREFS];
    if (!p) return 0;
    return (_activeLayer == 0) ? p->colorScheme : p->overlays[_activeLayer - 1].colorScheme;
}

// Layers menu: pick the active layer (Background + each loaded overlay) and set
// the overall overlay opacity. Color/W-L then act on the active layer.
- (UIMenu *)layersMenu {
    NII_PREFS *p = [_niiImg getPREFS];
    NSMutableArray<UIMenuElement *> *layers = [NSMutableArray array];
    UIAction *bg = [UIAction actionWithTitle:@"Background" image:nil identifier:nil
                                     handler:^(UIAction *a){ [self setActiveLayer:0]; }];
    bg.state = (_activeLayer == 0) ? UIMenuElementStateOn : UIMenuElementStateOff;
    [layers addObject:bg];
    if (p) for (int i = 0; i < MAX_OVERLAY; i++) {
        if (p->overlays[i].datatype == DT_NONE) continue;
        int layer = i + 1;
        UIAction *a = [UIAction actionWithTitle:[NSString stringWithFormat:@"Overlay %d", layer]
                                          image:nil identifier:nil
                                        handler:^(UIAction *ac){ [self setActiveLayer:layer]; }];
        a.state = (_activeLayer == layer) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layers addObject:a];
    }
    UIMenu *layerSel = [UIMenu menuWithTitle:@"Active Layer" image:nil identifier:nil
                                     options:UIMenuOptionsDisplayInline children:layers];

    float curFrac = p ? p->overlayFrac : 0.5f;
    NSMutableArray<UIMenuElement *> *ops = [NSMutableArray array];
    for (NSNumber *fn in @[ @0.25f, @0.5f, @0.75f, @1.0f ]) {
        float f = fn.floatValue;
        UIAction *o = [UIAction actionWithTitle:[NSString stringWithFormat:@"Overlay %d%%", (int)(f * 100)]
                                          image:nil identifier:nil
                                        handler:^(UIAction *a){ [self setOverlayOpacity:f]; }];
        o.state = (fabsf(curFrac - f) < 0.02f) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [ops addObject:o];
    }
    UIMenu *opSel = [UIMenu menuWithTitle:@"Overlay Opacity" image:nil identifier:nil
                                  options:UIMenuOptionsDisplayInline children:ops];
    return [UIMenu menuWithTitle:@"Layers" children:@[ layerSel, opSel ]];
}

- (void)setActiveLayer:(int)layer {
    _activeLayer = layer;
    _layersItem.menu = [self layersMenu];
    _colorItem.menu = [self colorMenu];   // checkmark + future picks target this layer
    [self syncWindowLevelControls];       // W-L sliders reflect this layer
}

- (void)setOverlayOpacity:(float)frac {
    NII_PREFS *p = [_niiImg getPREFS];
    if (p) { p->overlayFrac = frac; p->force_recalcGL = true; }
    _layersItem.menu = [self layersMenu];
    [_mtkView setNeedsDisplay];
}

// After loading an overlay, make the newest slot the active layer.
- (void)selectNewestOverlayLayer {
    NII_PREFS *p = [_niiImg getPREFS];
    if (!p) return;
    int last = 0;
    for (int i = 0; i < MAX_OVERLAY; i++)
        if (p->overlays[i].datatype != DT_NONE) last = i + 1;
    [self setActiveLayer:last];
}

- (void)setDisplayMode:(int)mode {
    [_niiImg setDisplayModeX:mode];
    [_mtkView setNeedsDisplay];
}

- (void)setColorScheme:(int)idx {
    [_niiImg setColorSchemeForLayer:idx Layer:_activeLayer]; // sets force_recalcGL itself
    _colorItem.menu = [self colorMenu]; // refresh checkmark
    [_mtkView setNeedsDisplay];
}

#pragma mark - Window / Level

- (void)buildWindowLevelPanel {
    _wlPanel = [[UIView alloc] init];
    _wlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _wlPanel.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.85];
    _wlPanel.layer.cornerRadius = 10;
    _wlPanel.hidden = YES;
    [self.view addSubview:_wlPanel];

    _minSlider = [[UISlider alloc] init];
    _maxSlider = [[UISlider alloc] init];
    for (UISlider *s in @[_minSlider, _maxSlider]) {
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [s addTarget:self action:@selector(windowLevelChanged) forControlEvents:UIControlEventValueChanged];
        [_wlPanel addSubview:s];
    }
    _gammaSlider = [[UISlider alloc] init];
    _gammaSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _gammaSlider.minimumValue = 0.05f; _gammaSlider.maximumValue = 0.95f; // 0.5 = linear
    [_gammaSlider addTarget:self action:@selector(gammaChanged) forControlEvents:UIControlEventValueChanged];
    [_wlPanel addSubview:_gammaSlider];

    UILabel *minL = [self wlLabel:@"Min"], *maxL = [self wlLabel:@"Max"], *gamL = [self wlLabel:@"Gamma"];
    [_wlPanel addSubview:minL]; [_wlPanel addSubview:maxL]; [_wlPanel addSubview:gamL];

    [NSLayoutConstraint activateConstraints:@[
        [_wlPanel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_wlPanel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_wlPanel.widthAnchor constraintEqualToConstant:360],
        [_wlPanel.heightAnchor constraintEqualToConstant:136],

        [minL.leadingAnchor constraintEqualToAnchor:_wlPanel.leadingAnchor constant:12],
        [minL.topAnchor constraintEqualToAnchor:_wlPanel.topAnchor constant:14],
        [_minSlider.leadingAnchor constraintEqualToAnchor:gamL.trailingAnchor constant:8],
        [_minSlider.trailingAnchor constraintEqualToAnchor:_wlPanel.trailingAnchor constant:-12],
        [_minSlider.centerYAnchor constraintEqualToAnchor:minL.centerYAnchor],

        [maxL.leadingAnchor constraintEqualToAnchor:_wlPanel.leadingAnchor constant:12],
        [maxL.centerYAnchor constraintEqualToAnchor:_wlPanel.centerYAnchor],
        [_maxSlider.leadingAnchor constraintEqualToAnchor:gamL.trailingAnchor constant:8],
        [_maxSlider.trailingAnchor constraintEqualToAnchor:_wlPanel.trailingAnchor constant:-12],
        [_maxSlider.centerYAnchor constraintEqualToAnchor:maxL.centerYAnchor],

        [gamL.leadingAnchor constraintEqualToAnchor:_wlPanel.leadingAnchor constant:12],
        [gamL.bottomAnchor constraintEqualToAnchor:_wlPanel.bottomAnchor constant:-14],
        [_gammaSlider.leadingAnchor constraintEqualToAnchor:gamL.trailingAnchor constant:8],
        [_gammaSlider.trailingAnchor constraintEqualToAnchor:_wlPanel.trailingAnchor constant:-12],
        [_gammaSlider.centerYAnchor constraintEqualToAnchor:gamL.centerYAnchor],
    ]];
}

- (UILabel *)wlLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text; l.font = [UIFont systemFontOfSize:13];
    return l;
}

- (void)toggleWindowLevel {
    _wlPanel.hidden = !_wlPanel.hidden;
    if (!_wlPanel.hidden) [self syncWindowLevelControls];
}

// Set the slider bounds from the volume's suggested range and the thumbs from
// the currently displayed window.
- (void)syncWindowLevelControls {
    NII_PREFS *p = [_niiImg getPREFS];
    double cMin, cMax, rLo, rHi;
    if (_activeLayer == 0 || !p) {
        double sMin = 0, sMax = 255;
        [_niiImg getSuggestedViewMinMax:&sMin Max:&sMax];
        [_niiImg getViewMinMax:&cMin Max:&cMax];
        double span = (sMax > sMin) ? (sMax - sMin) : 1.0;
        rLo = sMin - span; rHi = sMax + span;
    } else { // overlay layer: read its window from prefs (no per-layer suggested API)
        cMin = p->overlays[_activeLayer - 1].viewMin;
        cMax = p->overlays[_activeLayer - 1].viewMax;
        double span = (cMax > cMin) ? (cMax - cMin) : 1.0;
        rLo = cMin - span; rHi = cMax + span;
    }
    for (UISlider *s in @[_minSlider, _maxSlider]) { s.minimumValue = (float)rLo; s.maximumValue = (float)rHi; }
    _minSlider.value = (float)cMin;
    _maxSlider.value = (float)cMax;
    float bias = p ? (_activeLayer == 0 ? p->lut_bias : p->overlays[_activeLayer - 1].lut_bias) : 0.5f;
    _gammaSlider.value = (bias > 0.0f && bias < 1.0f) ? bias : 0.5f;
}

- (void)windowLevelChanged {
    double lo = _minSlider.value, hi = _maxSlider.value;
    if (lo > hi) { double t = lo; lo = hi; hi = t; }
    [_niiImg setViewMinMaxForLayer:lo Max:hi Layer:_activeLayer];
    [_mtkView setNeedsDisplay];
}

// Gamma (LUT bias) for the active layer; 0.5 = linear. Re-derives the LUT.
- (void)gammaChanged {
    NII_PREFS *p = [_niiImg getPREFS];
    if (!p) return;
    if (_activeLayer == 0) p->lut_bias = _gammaSlider.value;
    else                   p->overlays[_activeLayer - 1].lut_bias = _gammaSlider.value;
    p->force_recalcGL = true;
    p->force_refreshGL = true;
    [_mtkView setNeedsDisplay];
}

#pragma mark - Document picker (Browse Files… fallback for external locations)

- (void)presentPickerForOverlay:(BOOL)overlay {
    _pickingOverlay = overlay;
    [self presentDocumentPicker];
}

- (void)presentDocumentPicker {
    // Request our registered NIfTI document type (com.mricro.nifti, declared in
    // Info.plist as a public.data document owning .nii/.nii.gz) so tapping a .gz
    // in the picker opens it as our document instead of triggering iOS's archive
    // handling. public.data is kept as a fallback for DICOM/other inputs.
    // asCopy:YES copies the pick into our sandbox tmp — a plain readable path.
    UTType *nifti = [UTType typeWithIdentifier:@"com.mricro.nifti"];
    NSArray<UTType *> *types = nifti ? @[ nifti, UTTypeData ] : @[ UTTypeData ];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [self openURLPath:url.path overlay:_pickingOverlay]; // asCopy gives a readable sandbox path
}

#pragma mark - Gestures

- (void)installGestureRecognizers {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    [_mtkView addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    [_mtkView addGestureRecognizer:pan];

    UIPanGestureRecognizer *twoPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onTwoFingerPan:)];
    twoPan.minimumNumberOfTouches = 2;
    twoPan.maximumNumberOfTouches = 2;
    [_mtkView addGestureRecognizer:twoPan];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    [_mtkView addGestureRecognizer:pinch];
}

- (void)onTap:(UITapGestureRecognizer *)g {
    CGPoint px = [self pixelFromPoint:[g locationInView:_mtkView]];
    [_niiImg setMouseDown:(int)px.x Y:(int)px.y];
    [self updateTimeline]; // crosshair moved -> refresh the time-series
    [_mtkView setNeedsDisplay];
}

// One-finger drag: normally rotates the volume; in Clip mode it rotates the
// clip PLANE angle (horizontal = azimuth, vertical = elevation).
- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self setInteracting:YES];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setInteracting:NO]; return;
    }
    if (_clipMode) {
        NII_PREFS *p = [_niiImg getPREFS];
        if (p) {
            CGPoint t = [g translationInView:_mtkView];
            int az = p->clipAzimuth   + (int)lround(t.x * 0.25);
            int el = p->clipElevation - (int)lround(t.y * 0.25);
            [_niiImg setClip:az Elev:el Depth:p->clipDepth];
            [g setTranslation:CGPointZero inView:_mtkView];
        }
        [_mtkView setNeedsDisplay];
        return;
    }
    CGPoint px = [self pixelFromPoint:[g locationInView:_mtkView]];
    if (g.state == UIGestureRecognizerStateBegan)
        [_niiImg setMouseDown:(int)px.x Y:(int)px.y]; // anchor the drag
    else
        [_niiImg setMouseDrag:(int)px.x Y:(int)px.y]; // rotate volume (setAzimElevInc)
    [_mtkView setNeedsDisplay];
}

// Two-finger drag scrolls through slices (2D modes).
- (void)onTwoFingerPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_mtkView];
    CGPoint loc = [self pixelFromPoint:[g locationInView:_mtkView]];
    [_niiImg setScrollWheel:t.x Y:t.y locX:loc.x locY:loc.y];
    [g setTranslation:CGPointZero inView:_mtkView];
    [_mtkView setNeedsDisplay];
}

// Pinch: normally zooms; in Clip mode it sets the clip DEPTH (pinch out = cut
// deeper, pinch in = shallower; clamped 0..MAX_CLIPDEPTH).
- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { [self setInteracting:YES]; g.scale = 1.0; return; }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setInteracting:NO]; g.scale = 1.0; return;
    }
    if (g.state != UIGestureRecognizerStateChanged) { g.scale = 1.0; return; }
    if (_clipMode) {
        [_niiImg changeClipDepth:(float)((g.scale - 1.0) * 400.0f)];
    } else {
        [_niiImg setMagnify:(float)(g.scale - 1.0)]; // zoom
    }
    g.scale = 1.0;
    [_mtkView setNeedsDisplay];
}

@end

#endif

#include <gst/gst.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#include <math.h>

@interface LIVIClipView : NSView {
@public
  NSView* _gl;
  int _rank;
  double _cropL, _cropT, _visW, _visH, _tierW, _tierH;  // content region in tier px
@private
  BOOL _relayoutPending;
  BOOL _inLiveResize;
  BOOL _userHidden;
}
- (void)relayout;
- (void)setUserHidden:(BOOL)hidden;
@end

@implementation LIVIClipView
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (void)relayout {
  NSView* sv = [self superview];
  if (!sv) return;
  const double ww = sv.bounds.size.width;
  const double wh = sv.bounds.size.height;
  if (ww <= 0 || wh <= 0) return;

  if (_visW <= 0 || _visH <= 0 || _tierW <= 0 || _tierH <= 0) {
    [self setFrame:sv.bounds];
    [_gl setFrame:self.bounds];
    return;
  }

  const double scale = fmin(ww / _visW, wh / _visH);
  const double cdw = _visW * scale;
  const double cdh = _visH * scale;
  [self setFrame:NSMakeRect((ww - cdw) / 2.0, (wh - cdh) / 2.0, cdw, cdh)];

  [_gl setFrame:NSMakeRect(-_cropL * scale, -_cropT * scale, _tierW * scale, _tierH * scale)];
}

- (void)superviewResized:(NSNotification*)note {
  (void)note;
  if (_inLiveResize) return;
  if (_relayoutPending) return;
  _relayoutPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_relayoutPending = NO;
    [self relayout];
  });
}

- (void)setUserHidden:(BOOL)hidden {
  _userHidden = hidden;
  if (!_inLiveResize) [self setHidden:hidden];
}

- (void)windowWillStartLiveResize:(NSNotification*)note {
  (void)note;
  _inLiveResize = YES;
  [self setHidden:YES];
}

- (void)windowDidEndLiveResize:(NSNotification*)note {
  (void)note;
  _inLiveResize = NO;
  [self setHidden:_userHidden];
  [self relayout];
}
@end

// Under the UI's view: the whole window, or with an area (livi_set_video_area) its clip
// rectangle. The planes lay out in its content view: the host's bounds, or where the area puts
// the picture, which may reach past the clip.
@interface LIVIVideoHost : NSView {
@public
  NSView* _content;
}
@end

@implementation LIVIVideoHost
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
@end

static LIVIVideoHost* find_host(NSView* frame) {
  for (NSView* v in [frame subviews]) {
    if ([v isKindOfClass:[LIVIVideoHost class]]) return (LIVIVideoHost*)v;
  }
  return nil;
}

static NSView* video_host(NSView* ui) {
  NSView* frame = [ui superview];
  if (!frame) return ui;
  if (LIVIVideoHost* found = find_host(frame)) return found;
  LIVIVideoHost* host = [[LIVIVideoHost alloc] initWithFrame:[ui frame]];
  [host setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [host setWantsLayer:YES];
  host.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  host.layer.masksToBounds = YES;
  NSView* content = [[NSView alloc] initWithFrame:[host bounds]];
  [content setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [content setWantsLayer:YES];
  [host addSubview:content];
  host->_content = content;
  [frame addSubview:host positioned:NSWindowBelow relativeTo:ui];
  NSWindow* win = [ui window];
  [win setOpaque:YES];
  [win setBackgroundColor:[NSColor blackColor]];
  return host;
}

static NSView* video_content(NSView* ui) {
  NSView* host = video_host(ui);
  return [host isKindOfClass:[LIVIVideoHost class]] ? ((LIVIVideoHost*)host)->_content : host;
}

extern "C" void livi_prepare_window(guintptr ui) {
  if (!ui) return;
  video_host((NSView*)(void*)ui);
}

// `clip` and `content` are rectangles of the UI view in its backing pixels from the top left;
// `on` false gives the planes the whole view again. An empty clip hides them.
extern "C" void livi_set_video_area(guintptr ui, bool on, double cx, double cy, double cw,
    double ch, double kx, double ky, double kw, double kh) {
  if (!ui) return;
  NSView* u = (NSView*)(void*)ui;
  NSView* h = video_host(u);
  if (![h isKindOfClass:[LIVIVideoHost class]]) return;
  LIVIVideoHost* host = (LIVIVideoHost*)h;
  NSView* frame = [u superview];
  if (!on) {
    [host setHidden:NO];
    [host setFrame:[u frame]];
    [host setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [host->_content setFrame:[host bounds]];
    [host->_content setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    return;
  }
  if (cw <= 0 || ch <= 0) {
    [host setHidden:YES];
    return;
  }
  // Backing pixels from the top left to the view's points, then to the frame view's.
  auto in_frame = [&](double x, double y, double w, double hh) {
    NSRect r = [u convertRectFromBacking:NSMakeRect(x, y, w, hh)];
    if (![u isFlipped]) r.origin.y = u.bounds.size.height - r.origin.y - r.size.height;
    return [u convertRect:r toView:frame];
  };
  NSRect clip = in_frame(cx, cy, cw, ch);
  NSRect content = in_frame(kx, ky, kw, kh);
  [host setAutoresizingMask:NSViewNotSizable];
  [host setFrame:clip];
  [host->_content setAutoresizingMask:NSViewNotSizable];
  [host->_content setFrame:NSOffsetRect(content, -clip.origin.x, -clip.origin.y)];
  [host setHidden:NO];
}

static void insert_clip(NSView* p, LIVIClipView* clip) {
  NSView* above = nil;
  for (NSView* v in [p subviews]) {
    if ([v isKindOfClass:[LIVIClipView class]] && ((LIVIClipView*)v)->_rank <= clip->_rank) {
      above = v;
    }
  }
  if (above) {
    [p addSubview:clip positioned:NSWindowAbove relativeTo:above];
  } else {
    [p addSubview:clip positioned:NSWindowBelow relativeTo:nil];
  }
}

extern "C" guintptr livi_attach_view(guintptr parent, int rank, void** outView) {
  *outView = nullptr;
  if (!parent) return parent;
  NSView* p = video_content((NSView*)(void*)parent);

  LIVIClipView* clip = [[LIVIClipView alloc] initWithFrame:[p bounds]];
  clip->_gl = nullptr;
  clip->_rank = rank;
  clip->_cropL = clip->_cropT = clip->_visW = clip->_visH = clip->_tierW = clip->_tierH = 0;
  [clip setWantsLayer:YES];
  clip.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  clip.layer.masksToBounds = YES;
  insert_clip(p, clip);

  NSView* gl = [[NSView alloc] initWithFrame:[clip bounds]];
  [gl setWantsLayer:YES];
  [clip addSubview:gl];
  clip->_gl = gl;

  [p setPostsFrameChangedNotifications:YES];
  [[NSNotificationCenter defaultCenter] addObserver:clip
                                           selector:@selector(superviewResized:)
                                               name:NSViewFrameDidChangeNotification
                                             object:p];

  NSWindow* win = [p window];
  if (win) {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:clip
           selector:@selector(windowWillStartLiveResize:)
               name:NSWindowWillStartLiveResizeNotification
             object:win];
    [nc addObserver:clip
           selector:@selector(windowDidEndLiveResize:)
               name:NSWindowDidEndLiveResizeNotification
             object:win];
  }

  *outView = (void*)clip;
  return (guintptr)(void*)gl;   // the GL sink renders into the child
}

extern "C" void livi_set_content_region(void* view, void* sink, double cropL,
    double cropT, double visW, double visH, double tierW, double tierH) {
  (void)sink;
  if (!view) return;
  LIVIClipView* clip = (LIVIClipView*)view;
  clip->_cropL = cropL;
  clip->_cropT = cropT;
  clip->_visW = visW;
  clip->_visH = visH;
  clip->_tierW = tierW;
  clip->_tierH = tierH;
  [clip relayout];
}

extern "C" void livi_remove_view(void* view) {
  if (!view) return;
  NSView* v = (NSView*)view;
  [[NSNotificationCenter defaultCenter] removeObserver:v];
  [v removeFromSuperview];
}

extern "C" void livi_set_view_hidden(void* view, bool hidden) {
  if (!view) return;
  NSView* v = (NSView*)view;
  if ([v isKindOfClass:[LIVIClipView class]]) {
    [(LIVIClipView*)v setUserHidden:hidden];
    return;
  }
  [v setHidden:hidden];
}

extern "C" void livi_set_backdrop(guintptr parent, double r, double g, double b) {
  if (!parent) return;
  NSView* p = video_host((NSView*)(void*)parent);
  [p setWantsLayer:YES];
  if (!p.layer) return;
  NSColor* col = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
  p.layer.backgroundColor = col.CGColor;
}

// The planes arrive on threads of their own, views are touched on the main thread.
extern "C" void livi_run_on_main(void (*work)(void*), void* context) {
  if ([NSThread isMainThread]) {
    work(context);
    return;
  }
  dispatch_sync_f(dispatch_get_main_queue(), context, work);
}

extern "C" void livi_set_window_curves(guintptr ui, const float* rgb, int count) {
  if (!ui) return;
  NSView* frame = [(NSView*)(void*)ui superview];
  if (!frame) return;
  [frame setWantsLayer:YES];
  if (!rgb || count < 2) {
    frame.layer.filters = nil;
    return;
  }
  NSData* data = [NSData dataWithBytes:rgb length:(NSUInteger)count * 3 * sizeof(float)];
  CIFilter* curves = [CIFilter filterWithName:@"CIColorCurves"];
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  [curves setValue:data forKey:@"inputCurvesData"];
  [curves setValue:[CIVector vectorWithX:0 Y:1] forKey:@"inputCurvesDomain"];
  [curves setValue:(id)srgb forKey:@"inputColorSpace"];
  CGColorSpaceRelease(srgb);
  frame.layerUsesCoreImageFilters = YES;
  frame.layer.filters = @[ curves ];
}

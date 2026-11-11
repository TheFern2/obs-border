/*
 * obs-border: draws an on-screen border around the part of a display that
 * ends up in the OBS canvas, without the border itself being recorded.
 *
 * It is a pass-through video filter for macOS Screen Capture / Display Capture
 * sources. The border is drawn just *outside* the captured region on a
 * click-through overlay window that is also excluded from screen sharing, so
 * it never reaches the canvas.
 */

#import <Cocoa/Cocoa.h>
#include <obs-module.h>
#include <obs-frontend-api.h>
#include <graphics/matrix4.h>
#include <graphics/vec4.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-border", "en-US")

#define S_COLOR "color"
#define S_WIDTH "width"
#define S_DIM "dim_outside"
#define S_ONLY_ACTIVE "only_when_active"

#define T_(s) obs_module_text(s)

/* ------------------------------------------------------------------------- */
/* Overlay drawing                                                            */

@interface BorderView : NSView
@property (nonatomic) NSRect region; /* view coordinates, flipped */
@property (nonatomic, strong) NSColor *borderColor;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) CGFloat dimAlpha;
@end

@implementation BorderView

- (BOOL)isFlipped
{
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void) dirtyRect;
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationCopy);

    NSRect b = self.bounds;
    NSRect r = self.region;

    if (self.dimAlpha > 0) {
        [[NSColor colorWithCalibratedWhite:0 alpha:self.dimAlpha] setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(b), NSMinY(r)), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(0, NSMaxY(r), NSWidth(b), NSHeight(b) - NSMaxY(r)),
                                 NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(0, NSMinY(r), NSMinX(r), NSHeight(r)), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(NSMaxX(r), NSMinY(r), NSWidth(b) - NSMaxX(r), NSHeight(r)),
                                 NSCompositingOperationSourceOver);
    }

    /* Bars sit entirely outside the region so they can never be captured. */
    CGFloat w = self.borderWidth;
    [self.borderColor setFill];
    NSRectFillUsingOperation(NSMakeRect(NSMinX(r) - w, NSMinY(r) - w, NSWidth(r) + 2 * w, w),
                             NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(NSMinX(r) - w, NSMaxY(r), NSWidth(r) + 2 * w, w),
                             NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(NSMinX(r) - w, NSMinY(r), w, NSHeight(r)), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(NSMaxX(r), NSMinY(r), w, NSHeight(r)), NSCompositingOperationSourceOver);
}

@end

/* ------------------------------------------------------------------------- */
/* Per-filter controller, only touched on the main thread                     */

@interface BorderController : NSObject
@property (nonatomic, strong) NSColor *borderColor;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) CGFloat dimAlpha;
@property (nonatomic) BOOL onlyWhenActive;
- (instancetype)initWithFilter:(obs_source_t *)filter;
- (void)start;
- (void)stop;
- (void)redraw;
@end

@implementation BorderController {
    obs_weak_source_t *_weakFilter;
    dispatch_source_t _timer;
    NSWindow *_window;
    BorderView *_view;
    BOOL _stopped;
}

- (instancetype)initWithFilter:(obs_source_t *)filter
{
    if ((self = [super init])) {
        _weakFilter = obs_source_get_weak_source(filter);
        _borderColor = [NSColor redColor];
        _borderWidth = 4;
    }
    return self;
}

- (void)start
{
    if (_stopped || _timer)
        return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    __weak BorderController *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf tick];
    });
    dispatch_resume(_timer);
}

- (void)stop
{
    _stopped = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    [self hide];
    _window = nil;
    _view = nil;
    obs_weak_source_release(_weakFilter);
    _weakFilter = NULL;
}

- (void)redraw
{
    if (!_view)
        return;
    _view.borderColor = self.borderColor;
    _view.borderWidth = self.borderWidth;
    _view.dimAlpha = self.dimAlpha;
    [_view setNeedsDisplay:YES];
}

- (void)hide
{
    if (_window.visible)
        [_window orderOut:nil];
}

static NSScreen *screen_for_uuid(const char *uuid)
{
    if (!uuid || !*uuid)
        return [NSScreen mainScreen];

    NSString *want = [NSString stringWithUTF8String:uuid];
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
        CFUUIDRef ref = CGDisplayCreateUUIDFromDisplayID(num.unsignedIntValue);
        if (!ref)
            continue;
        NSString *str = (__bridge_transfer NSString *) CFUUIDCreateString(kCFAllocatorDefault, ref);
        CFRelease(ref);
        if ([str caseInsensitiveCompare:want] == NSOrderedSame)
            return screen;
    }
    return nil;
}

/* Returns the canvas -> item-local transform for the parent in the program
 * scene, or false if it is not shown there. */
static bool canvas_to_source_transform(obs_source_t *parent, struct matrix4 *out, struct obs_sceneitem_crop *crop)
{
    obs_source_t *scene_src = obs_frontend_get_current_scene();
    if (!scene_src)
        return false;

    bool ok = false;
    obs_scene_t *scene = obs_scene_from_source(scene_src);
    obs_sceneitem_t *item = scene ? obs_scene_find_source_recursive(scene, obs_source_get_name(parent)) : NULL;

    if (item && obs_sceneitem_visible(item)) {
        struct matrix4 xform;
        obs_sceneitem_get_draw_transform(item, &xform);

        obs_sceneitem_t *group = obs_sceneitem_get_group(scene, item);
        if (group) {
            struct matrix4 group_xform;
            obs_sceneitem_get_draw_transform(group, &group_xform);
            matrix4_mul(&xform, &xform, &group_xform);
        }

        if ((!group || obs_sceneitem_visible(group)) && matrix4_inv(out, &xform)) {
            obs_sceneitem_get_crop(item, crop);
            ok = true;
        }
    }

    obs_source_release(scene_src);
    return ok;
}

/* Computes which part of the captured display is inside the canvas, in
 * source pixels. */
static bool visible_source_rect(obs_source_t *parent, NSRect *out)
{
    uint32_t sw = obs_source_get_width(parent);
    uint32_t sh = obs_source_get_height(parent);
    if (!sw || !sh)
        return false;

    struct matrix4 inv;
    struct obs_sceneitem_crop crop;
    if (!canvas_to_source_transform(parent, &inv, &crop))
        return false;

    struct obs_video_info ovi;
    if (!obs_get_video_info(&ovi))
        return false;

    float cw = (float) ovi.base_width;
    float ch = (float) ovi.base_height;
    float corners[4][2] = {{0, 0}, {cw, 0}, {0, ch}, {cw, ch}};
    float min_x = INFINITY, min_y = INFINITY, max_x = -INFINITY, max_y = -INFINITY;

    for (int i = 0; i < 4; i++) {
        struct vec4 p;
        vec4_set(&p, corners[i][0], corners[i][1], 0.0f, 1.0f);
        vec4_transform(&p, &p, &inv);
        min_x = fminf(min_x, p.x);
        min_y = fminf(min_y, p.y);
        max_x = fmaxf(max_x, p.x);
        max_y = fmaxf(max_y, p.y);
    }

    /* Item-local coordinates start at the crop origin. The visible part is
     * also bounded by the cropped texture itself. */
    float vis_w = (float) sw - (float) (crop.left + crop.right);
    float vis_h = (float) sh - (float) (crop.top + crop.bottom);
    min_x = fmaxf(min_x, 0.0f) + (float) crop.left;
    min_y = fmaxf(min_y, 0.0f) + (float) crop.top;
    max_x = fminf(max_x, vis_w) + (float) crop.left;
    max_y = fminf(max_y, vis_h) + (float) crop.top;

    if (max_x <= min_x || max_y <= min_y)
        return false;

    *out = NSMakeRect(min_x, min_y, max_x - min_x, max_y - min_y);
    return true;
}

static bool is_display_capture(obs_source_t *parent, char **uuid)
{
    const char *id = obs_source_get_unversioned_id(parent);
    bool sck = strcmp(id, "screen_capture") == 0;
    if (!sck && strcmp(id, "display_capture") != 0)
        return false;

    obs_data_t *settings = obs_source_get_settings(parent);
    bool display = !sck || obs_data_get_int(settings, "type") == 0;
    if (display)
        *uuid = bstrdup(obs_data_get_string(settings, "display_uuid"));
    obs_data_release(settings);
    return display;
}

- (void)tick
{
    if (_stopped)
        return;

    obs_source_t *filter = obs_weak_source_get_source(_weakFilter);
    if (!filter) {
        [self hide];
        return;
    }

    NSRect src_rect = NSZeroRect;
    char *uuid = NULL;
    uint32_t sw = 0, sh = 0;
    bool show = obs_source_enabled(filter);

    if (show && self.onlyWhenActive)
        show = obs_frontend_recording_active() || obs_frontend_streaming_active();

    obs_source_t *parent = show ? obs_filter_get_parent(filter) : NULL;
    show = parent && is_display_capture(parent, &uuid) && visible_source_rect(parent, &src_rect);
    if (show) {
        sw = obs_source_get_width(parent);
        sh = obs_source_get_height(parent);
    }
    obs_source_release(filter);

    NSScreen *screen = show ? screen_for_uuid(uuid) : nil;
    bfree(uuid);
    if (!screen) {
        [self hide];
        return;
    }

    /* Source pixels -> screen points. Scaling by the ratio handles Retina. */
    NSRect frame = screen.frame;
    CGFloat sx = NSWidth(frame) / sw;
    CGFloat sy = NSHeight(frame) / sh;
    NSRect region = NSMakeRect(NSMinX(src_rect) * sx, NSMinY(src_rect) * sy, NSWidth(src_rect) * sx,
                               NSHeight(src_rect) * sy);

    [self showOnFrame:frame region:region];
}

- (void)showOnFrame:(NSRect)frame region:(NSRect)region
{
    if (!_window) {
        _window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
        _window.releasedWhenClosed = NO;
        _window.opaque = NO;
        _window.backgroundColor = [NSColor clearColor];
        _window.hasShadow = NO;
        _window.ignoresMouseEvents = YES;
        _window.level = NSStatusWindowLevel;
        _window.sharingType = NSWindowSharingNone;
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorIgnoresCycle;

        _view = [[BorderView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
        _window.contentView = _view;
        [self redraw];
    }

    if (!NSEqualRects(_window.frame, frame))
        [_window setFrame:frame display:NO];

    if (!NSEqualRects(_view.region, region)) {
        _view.region = region;
        [_view setNeedsDisplay:YES];
    }

    if (!_window.visible)
        [_window orderFrontRegardless];
}

@end

/* ------------------------------------------------------------------------- */
/* Filter                                                                     */

struct border_filter {
    obs_source_t *context;
    void *controller; /* BorderController, retained */
};

static const char *border_get_name(void *unused)
{
    (void) unused;
    return T_("RecordingAreaBorder");
}

static void border_update(void *data, obs_data_t *settings)
{
    struct border_filter *bf = data;
    uint32_t c = (uint32_t) obs_data_get_int(settings, S_COLOR);
    CGFloat width = (CGFloat) obs_data_get_int(settings, S_WIDTH);
    CGFloat dim = (CGFloat) obs_data_get_int(settings, S_DIM) / 100.0;
    BOOL only_active = obs_data_get_bool(settings, S_ONLY_ACTIVE);

    /* OBS stores colors as 0xAABBGGRR */
    NSColor *color = [NSColor colorWithSRGBRed:(c & 0xff) / 255.0
                                         green:((c >> 8) & 0xff) / 255.0
                                          blue:((c >> 16) & 0xff) / 255.0
                                         alpha:((c >> 24) & 0xff) / 255.0];

    BorderController *ctrl = (__bridge BorderController *) bf->controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        ctrl.borderColor = color;
        ctrl.borderWidth = width;
        ctrl.dimAlpha = dim;
        ctrl.onlyWhenActive = only_active;
        [ctrl redraw];
    });
}

static void *border_create(obs_data_t *settings, obs_source_t *context)
{
    struct border_filter *bf = bzalloc(sizeof(*bf));
    bf->context = context;

    BorderController *ctrl = [[BorderController alloc] initWithFilter:context];
    bf->controller = (__bridge_retained void *) ctrl;

    border_update(bf, settings);
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl start];
    });
    return bf;
}

static void border_destroy(void *data)
{
    struct border_filter *bf = data;
    BorderController *ctrl = (__bridge_transfer BorderController *) bf->controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl stop];
    });
    bfree(bf);
}

static void border_defaults(obs_data_t *settings)
{
    obs_data_set_default_int(settings, S_COLOR, 0xFF0000FF); /* opaque red */
    obs_data_set_default_int(settings, S_WIDTH, 4);
    obs_data_set_default_int(settings, S_DIM, 0);
    obs_data_set_default_bool(settings, S_ONLY_ACTIVE, false);
}

static obs_properties_t *border_properties(void *data)
{
    (void) data;
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_color_alpha(props, S_COLOR, T_("BorderColor"));
    obs_property_t *p = obs_properties_add_int_slider(props, S_WIDTH, T_("BorderWidth"), 1, 40, 1);
    obs_property_int_set_suffix(p, " pt");
    p = obs_properties_add_int_slider(props, S_DIM, T_("DimOutside"), 0, 90, 5);
    obs_property_int_set_suffix(p, "%");
    obs_properties_add_bool(props, S_ONLY_ACTIVE, T_("OnlyWhenActive"));
    obs_properties_add_text(props, "info", T_("Info"), OBS_TEXT_INFO);
    return props;
}

static void border_render(void *data, gs_effect_t *effect)
{
    (void) effect;
    struct border_filter *bf = data;
    obs_source_skip_video_filter(bf->context);
}

static struct obs_source_info border_filter_info = {
    .id = "recording_area_border_filter",
    .type = OBS_SOURCE_TYPE_FILTER,
    .output_flags = OBS_SOURCE_VIDEO,
    .get_name = border_get_name,
    .create = border_create,
    .destroy = border_destroy,
    .update = border_update,
    .get_defaults = border_defaults,
    .get_properties = border_properties,
    .video_render = border_render,
};

bool obs_module_load(void)
{
    obs_register_source(&border_filter_info);
    return true;
}

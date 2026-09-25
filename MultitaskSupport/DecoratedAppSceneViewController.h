#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIView *view;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);

/// YES while the stage watchdog is relaunching a jetsam'd guest into this slot. While set, the
/// guest exit callback neither removes the slot nor schedules a relaunch — the old card view is
/// kept (covered by the frozen frame) until the freshly launched guest replaces it.
@property(nonatomic) BOOL isRecoveringGuest;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;

/// Places this window into its stage slot. The guest app always renders at the phone's
/// original resolution and is scaled down by `ratio`, so it never relayouts.
/// `maximized` is the live fullscreen state owned by the stage; it has to be pushed in here
/// because the safe area differs between a split slot and fullscreen.
/// `isMainWindow` keeps the tap-to-promote gesture off the main slot, where the guest app
/// needs to receive its own touches.
- (void)applyStageFrame:(CGRect)frame scaleRatio:(CGFloat)ratio maximized:(BOOL)maximized isMainWindow:(BOOL)isMainWindow;
- (void)closeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;

/// Launch placeholder shown until the guest reports its first real frame
/// (icon + name + spinner over black), so a cold-starting heavy app reads as
/// "launching" instead of an empty black card.
- (void)configureLaunchPlaceholderWithIcon:(nullable UIImage *)icon appName:(NSString *)appName;

/// Recovery variant of the launch placeholder: icon + "recovering…" + spinner over the frozen
/// last frame while a killed guest is relaunched into the same slot.
- (void)showRecoveryCoverWithIcon:(nullable UIImage *)icon appName:(NSString *)appName;

/// Shows the guest's frozen last frame (JPEG path) over the recovering scene.
/// No-op when the file is missing or unreadable; the previous cover (if any) is kept.
- (void)showFrozenFrameAtPath:(NSString *)path;

/// Same as showFrozenFrameAtPath:, but ignores JPEGs whose modification date is older than
/// minModified (epoch seconds; pass 0 to disable the freshness gate). Used on the 100ms/500ms
/// re-cover after backgrounding: a JPEG from an earlier session must never replace the frame just
/// captured for THIS lock. Runs synchronously when called on the main thread so the cover is
/// already in place before the resign-away animation samples the hierarchy.
- (void)showFrozenFrameAtPath:(NSString *)path notOlderThan:(NSTimeInterval)minModified;

/// Fades (or instantly removes) every content cover — launch placeholder and
/// frozen frame alike. Idempotent: safe to call as a periodic backstop.
- (void)hideContentCoversAnimated:(BOOL)animated;

/// Lifts only the frozen last-frame cover, leaving a launch placeholder (cold start
/// still in progress) untouched. Used as the foreground-recovery backstop.
- (void)hideFrozenFrameAnimated:(BOOL)animated;
@end

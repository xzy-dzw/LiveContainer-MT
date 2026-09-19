#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIView *view;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
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
@end

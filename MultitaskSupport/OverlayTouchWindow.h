//
//  OverlayTouchWindow.h
//  LiveContainer
//
//  An invisible, highest-level UIWindow that routes touches for the multitask stage.
//  Side-window regions are intercepted (by subviews added directly to this window); the main-
//  window region is not intercepted and touches fall through to the hosted app.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OverlayTouchWindow : UIWindow

/// Initialise with the real app window. Touches that are not captured by a shield are
/// forwarded to this window so the main hosted app keeps receiving input normally.
- (instancetype)initWithFrame:(CGRect)frame hostWindow:(UIWindow *)hostWindow NS_DESIGNATED_INITIALIZER;

/// Allow Swift to create shield subviews directly on this window. Any subview tagged >= 100
/// is treated as a "touch shield": the overlay's hitTest returns it so the shield's own
/// gesture recognisers fire and promotions happen.
/// Routing toggles whether shields get priority. Set to NO when no shields are visible
/// (e.g. fullscreen, no windows open) so every touch goes straight to the host window.
@property(nonatomic, assign) BOOL routingEnabled;

@end

NS_ASSUME_NONNULL_END

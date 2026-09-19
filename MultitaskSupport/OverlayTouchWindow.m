//
//  OverlayTouchWindow.m
//  LiveContainer
//

#import "OverlayTouchWindow.h"

@implementation OverlayTouchWindow {
    UIWindow *_hostWindow;
}

- (instancetype)initWithFrame:(CGRect)frame hostWindow:(UIWindow *)hostWindow {
    self = [super initWithFrame:frame];
    if(self) {
        _hostWindow = hostWindow;
        self.windowLevel = UIWindowLevelAlert + 10000; // definitely above every other app window
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        self.routingEnabled = YES;
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    [NSException raise:@"OverlayTouchWindow"
                format:@"Use initWithFrame:hostWindow: instead."];
    return nil;
}

/// Touch routing is the whole reason this window exists. Subviews with tag >= 100 are "shields"
/// that route touches to promotion gesture recognisers; everything else falls straight through
/// to the real app window so the main hosted app keeps receiving input normally.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if(self.routingEnabled) {
        // Check shield subviews directly — we do NOT call super here because the window's own
        // hitTest would find its (otherwise empty) view hierarchy and return nil too early.
        for(UIView *sub in self.subviews) {
            if(sub.tag >= 100 && !sub.hidden && sub.userInteractionEnabled) {
                CGPoint local = [self convertPoint:point toView:sub];
                if([sub pointInside:local withEvent:event]) {
                    // Return the shield — its UITapGestureRecognizer fires the promotion.
                    return sub;
                }
            }
        }
    }
    // Not a shield hit (or routing disabled) → forward to the real app window as if we were
    // never there. Its own hitTest will route the touch correctly.
    CGPoint hostPoint = [_hostWindow convertPoint:point fromView:self];
    return [_hostWindow hitTest:hostPoint withEvent:event];
}

@end

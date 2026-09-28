//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

@implementation VirtualWindowsHostView
- (instancetype)init {
    // Resolve a key window bounds defensively: this view may be created before any UIWindowScene
    // exists (e.g. very early launch), and the previous cast to connectedScenes.anyObject crashed
    // when the first scene wasn't a UIWindowScene or when there were no scenes at all.
    CGRect frame = CGRectZero;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.keyWindow) {
                frame = windowScene.keyWindow.bounds;
                break;
            }
        }
    }
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The stage is its own page rather than an overlay on the app list, so it paints an opaque
    // neutral background and swallows touches that land on empty space.
    self.backgroundColor = UIColor.systemGray5Color;
    return self;
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    // Resolve the frontmost window at call time. The previous version gated this on a flag left
    // over from the last ordinary hit-test — status bar taps never run hitTest on this view, so
    // the flag was stale — and an empty stage read !nil.hidden as YES, reporting "handled" with
    // no window behind it, which swallowed the host's own status bar tap (e.g. scroll to top).
    UIView *frontmostView = self.subviews.lastObject;
    DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
    if (frontmostView.hidden || decoratedVC == nil) {
        return NO;
    }
    [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    return YES;
}
@end

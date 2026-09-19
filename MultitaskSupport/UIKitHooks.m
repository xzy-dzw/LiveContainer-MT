//
//  UIKitHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 25/6/26.
//
@import ObjectiveC;
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "LiveContainerSwiftUI-Swift.h"

static BOOL LCHasRemoteSheetProviderSelector;

UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIEdgeInsetsMake(insets.left, 0, insets.right, insets.bottom);
        case UIInterfaceOrientationLandscapeRight:
            return UIEdgeInsetsMake(insets.left, insets.bottom, insets.right, 0);
        default:
            return insets;
    }
}

// Fix _UIPrototypingMenuSlider not continually updating its value on iOS 17+
API_AVAILABLE(ios(17.0))
@implementation _UIFluidSliderInteraction(Hook)
- (NSInteger)_state {
    return 2;
}
@end

@interface FBScene(hooks)
- (void)hook__performUpdateWithoutActivation:(void (^)(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context))updateBlock;
@end

/// Hook to fix safe area scaling and orientation. We use superview's safeAreaInsets because self one tends to bug out with certain scaling, and also allows us to customize safe area while in PiP mode later on.
/// This hook applies across 18.0-27.0. 17.4+ is uncertain.
API_AVAILABLE(ios(17.0))
void hook_FBScene_performUpdateWithoutActivation(FBScene* self, SEL _cmd, void (^updateBlock)(UIMutableApplicationSceneSettings *, FBSSceneTransitionContext *)) {
    // We don't wanna mess up system extensions on iOS 26+
    if(LCHasRemoteSheetProviderSelector && self.ui_viewServiceComponent) {
        [self hook__performUpdateWithoutActivation:updateBlock];
        return;
    }
    
    _UISceneHostingController *controller = self.delegate;
    _UISceneHostingView *view = controller.sceneView;
    id wrappedBlock = ^(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context) {
        updateBlock(settings, context);
        CGAffineTransform transform = view.transform;
        UIEdgeInsets orig = view.superview.safeAreaInsets;
        if(LCHasRemoteSheetProviderSelector && UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
            // apps with glass has an extra top safe area space, so clear it (will it cause inconsistencies?)
            orig.top = 0;
        }
        UIEdgeInsets insets = UIEdgeInsetsMake(orig.top / transform.d, orig.left / transform.a, orig.bottom / transform.d, orig.right / transform.a);
        if(@available(iOS 19.0, *)) {
            settings.safeAreaEdgeInsets = insets;
            // fix orientation
            settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(insets, settings.interfaceOrientation);
        } else {
            settings.safeAreaInsetsPortrait = insets;
        }
    };
    [self hook__performUpdateWithoutActivation:wrappedBlock];
}

#pragma mark - Stage touch interception

// Touches destined for a hosted scene are delivered through a system-level channel that
// bypasses the regular UIKit hit-test chain, so no view placed above the scene view (neither
// in the hierarchy nor in a separate window) can reliably block them. sendEvent, however, is
// upstream of that channel: swallowing a touch there means the guest app never sees it. The
// hook asks the multitask stage whether a new touch began inside one of the side slots; if so
// the whole touch sequence is swallowed and the window is promoted to the main slot instead.
// NOTE: the hook selectors have no implementation of their own — they are registered with
// class_addMethod below and method_exchangeImplementations swaps them with the original
// sendEvent, so calling hook_xxx_sendEvent: from inside the hook dispatches to the original
// implementation (same pattern as the FBScene hook above).
static NSHashTable<UITouch *> *LCInterceptedTouches;

// window == nil means the UIApplication level: only touches already bound to a window are
// evaluated, each in its own window. Otherwise the given UIWindow is the one whose sendEvent
// is running and every touch of the event is evaluated in that window's coordinates.
// Returns YES when the whole event must be swallowed.
static BOOL LCProcessStageTouches(UIEvent *event, UIWindow *window) {
    NSSet<UITouch *> *touches = event.allTouches;
    if(touches.count == 0) {
        return NO;
    }
    if(@available(iOS 16.0, *)) {
        for(UITouch *touch in touches) {
            if(touch.phase != UITouchPhaseBegan) continue;
            if(window == nil) {
                if(touch.window == nil) continue; // not bound yet, the UIWindow hook gets it
                // Diagnostics: a began touch with a bound window passed the UIApplication hook.
                MultitaskDockManager.shared.diagBeganApp += 1;
                [MultitaskDockManager.shared refreshDiagnosticsLabel];
                CGPoint location = [touch locationInView:touch.window];
                if([MultitaskDockManager.shared interceptTouchAtLocation:location inWindow:touch.window]) {
                    if(!LCInterceptedTouches) {
                        LCInterceptedTouches = [NSHashTable weakObjectsHashTable];
                    }
                    [LCInterceptedTouches addObject:touch];
                }
            } else {
                if(touch.window != nil && touch.window != window) continue;
                // Diagnostics: a began touch reached the UIWindow hook of this window.
                MultitaskDockManager.shared.diagBeganWindow += 1;
                [MultitaskDockManager.shared refreshDiagnosticsLabel];
                CGPoint location = [touch locationInView:window];
                if([MultitaskDockManager.shared interceptTouchAtLocation:location inWindow:window]) {
                    if(!LCInterceptedTouches) {
                        LCInterceptedTouches = [NSHashTable weakObjectsHashTable];
                    }
                    [LCInterceptedTouches addObject:touch];
                }
            }
        }
        BOOL allTracked = YES;
        for(UITouch *touch in touches) {
            if(![LCInterceptedTouches containsObject:touch]) {
                allTracked = NO;
                break;
            }
        }
        if(allTracked) {
            // The whole event belongs to an intercepted sequence: drop it so the guest never
            // receives it. The table holds touches weakly, so entries evaporate on their own
            // once UIKit releases the ended touches.
            return YES;
        }
        // Mixed event (an intercepted sequence plus an unrelated touch): give up on the
        // interception and deliver everything, a half-swallowed sequence would be worse.
        [LCInterceptedTouches removeAllObjects];
    }
    return NO;
}

@interface UIApplication (LCSendEventHook)
- (void)hook_UIApplication_sendEvent:(UIEvent *)event;
@end

@interface UIWindow (LCSendEventHook)
- (void)hook_UIWindow_sendEvent:(UIEvent *)event;
@end

static void hook_UIApplication_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if(LCProcessStageTouches(event, nil)) {
        return;
    }
    [self hook_UIApplication_sendEvent:event];
}

static void hook_UIWindow_sendEvent(UIWindow *self, SEL _cmd, UIEvent *event) {
    if(LCProcessStageTouches(event, self)) {
        return;
    }
    [self hook_UIWindow_sendEvent:event];
}

void UIKitFixesInit(void) {
    if (@available(iOS 17.0, *)) {
        Class FBSceneClass = PrivClass(FBScene);
        LCHasRemoteSheetProviderSelector = [FBSceneClass instancesRespondToSelector:@selector(ui_viewServiceComponent)];
        class_addMethod(FBSceneClass, @selector(hook__performUpdateWithoutActivation:), (IMP)hook_FBScene_performUpdateWithoutActivation, "v@:@");
        swizzle(FBSceneClass, @selector(_performUpdateWithoutActivation:), @selector(hook__performUpdateWithoutActivation:));
    }
    if (@available(iOS 16.0, *)) {
        // UIApplication.sendEvent sees every event first; UIWindow.sendEvent is the second
        // chance for touches that had no window bound yet at the UIApplication level.
        class_addMethod(UIApplication.class, @selector(hook_UIApplication_sendEvent:), (IMP)hook_UIApplication_sendEvent, "v@:@");
        swizzle(UIApplication.class, @selector(sendEvent:), @selector(hook_UIApplication_sendEvent:));
        class_addMethod(UIWindow.class, @selector(hook_UIWindow_sendEvent:), (IMP)hook_UIWindow_sendEvent, "v@:@");
        swizzle(UIWindow.class, @selector(sendEvent:), @selector(hook_UIWindow_sendEvent:));
    }
}

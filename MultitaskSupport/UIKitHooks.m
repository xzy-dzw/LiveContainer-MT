//
//  UIKitHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 25/6/26.
//
@import ObjectiveC;
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "LCStageIPC.h"
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
//
// Interception state is tracked PER TOUCH SEQUENCE:
//   - only a UITouch whose BEGAN phase hit a side slot is ever quarantined;
//   - the old verdict is dropped at every began before re-evaluating, because UIKit can hand
//     the same UITouch instance to a later sequence — without this a recycled instance kept
//     stealing brand-new touches in the MAIN window (e.g. WeChat's press-and-hold-to-talk);
//   - ended/cancelled touches leave the table immediately;
//   - a mixed event releases only the sequences it contains instead of nuking the whole table.
//
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
        if(!LCInterceptedTouches) {
            LCInterceptedTouches = [NSHashTable weakObjectsHashTable];
        }

        for(UITouch *touch in touches) {
            // Sequences leave the table the moment they finish.
            if(touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                [LCInterceptedTouches removeObject:touch];
                continue;
            }
            if(touch.phase != UITouchPhaseBegan) {
                continue;
            }
            // A new sequence always starts untrusted: purge any verdict an earlier sequence left
            // on this (possibly recycled) UITouch instance before re-evaluating its location.
            [LCInterceptedTouches removeObject:touch];

            UIWindow *hitTestWindow = window ?: touch.window;
            if(hitTestWindow == nil) {
                continue; // not bound yet at the UIApplication level; the UIWindow hook gets it
            }
            if(window != nil && touch.window != nil && touch.window != window) {
                continue; // event bound to a different window than the one dispatching
            }
            CGPoint location = [touch locationInView:hitTestWindow];
            if([MultitaskDockManager.shared interceptTouchAtLocation:location inWindow:hitTestWindow]) {
                [LCInterceptedTouches addObject:touch];
                NSLog(@"[LCStage][触摸] 新触摸落在副窗区域，拦截本序列并提升该窗口");
            }
        }

        // Decide over EVERY touch of THIS event, including endings. A tracked sequence's own
        // ended was just removed from the table above (it must be delivered: the guest never got
        // its began); and an untracked ended/cancelled — e.g. the main-window finger lifting
        // while a quarantined side finger still moves — must veto the swallow, or that guest
        // never receives touchesEnded and its gesture/button hangs highlighted.
        BOOL allTracked = YES;
        BOOL anyTracked = NO;
        for(UITouch *touch in touches) {
            if([LCInterceptedTouches containsObject:touch]) {
                anyTracked = YES;
            } else {
                allTracked = NO;
            }
        }
        if(allTracked && anyTracked) {
            // Every live touch in the event belongs to a quarantined sequence: drop the event
            // so the side guest never sees it.
            return YES;
        }
        // Mixed event: this one is delivered, so release ONLY the side sequences that ride in
        // it (swallowing their later moved/ended after this delivery would split the gesture).
        // Sequences not present in this event keep their quarantine.
        if(anyTracked) {
            for(UITouch *touch in touches) {
                [LCInterceptedTouches removeObject:touch];
            }
        }
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

#pragma mark - Stage promotion requests from guests

// Side-window touches are quarantined inside the guest process (see
// LCStageIPC.h). The guest swallows the touch and asks the host to promote its
// window through a Darwin notification; the payload (which guest) travels in
// the App Group defaults. Promotions always run on the main thread.
static void LCStagePromoteRequestCallback(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    NSString *uuid = LCStageTakePendingPromoteUUID();
    if(uuid.length == 0) { return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        [MultitaskDockManager.shared promoteWindowForUUID:uuid];
    });
}

// A guest rendered real frames after cold start or a foreground return. The manager compares
// every staged window's frame-ready timestamp and reveals the matching card(s).
static void LCStageFrameReadyCallback(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object,
                                      CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(@available(iOS 16.0, *)) {
            [MultitaskDockManager.shared handleGuestFrameReady];
        }
    });
}

static void LCStageIPCHostInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LCStagePromoteRequestCallback,
                                        (__bridge CFStringRef)LCStagePromoteRequestNotificationName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LCStageFrameReadyCallback,
                                        (__bridge CFStringRef)LCStageFrameReadyNotificationName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

void UIKitFixesInit(void) {
    LCStageIPCHostInit();
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

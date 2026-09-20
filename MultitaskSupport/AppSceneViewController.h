//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "FoundationPrivate.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

API_AVAILABLE(ios(16.0))
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc;
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError*)error;
@optional
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc;
@end

API_AVAILABLE(ios(16.0))
@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic) NSString* bundleId;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic, weak) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic) UIView* contentView;
@property(nonatomic) _UIScenePresenter *presenter;
@property(nonatomic) _UISceneHostingController *hostingController API_AVAILABLE(ios(17.0));
/// Yes when the system touch region of this scene is currently parked off-screen (side-window
/// role). The stage reads it to decide which windows still need their region re-registered.
@property(nonatomic) BOOL touchRegionOffscreen;
- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString *)urlString;
- (void)handleStatusBarTapAction:(UIAction *)action;
/// Re-registers the hosted scene's system touch region after a stage geometry change, in two
/// halves: the foreground-off phase runs when the geometry animation starts (masked by the
/// motion), and the foreground-on phase once it has settled with the final geometry — the
/// only reliable trigger for that re-registration on iOS 26.
- (void)prepareHostedGeometryCommit;
- (void)finishHostedGeometryCommit;
/// Set foreground state on the hosted scene. Used to suspend side windows while the app is
/// backgrounded (so iOS does not kill them for memory pressure) and to wake them back up.
- (void)setHostedSceneForeground:(BOOL)foreground;
/// Plan C2 "register off-screen, display on-screen": runs a foreground NO→YES blip while the
/// hosting view is parked outside the display, so the system caches the touch region off-screen,
/// then puts the live content back into its slot. The completion fires once the view is restored.
- (void)registerTouchRegionOffscreenWithCompletion:(void (^_Nullable)(void))completion;
/// Drops the cached registration state after a lifecycle event (returning to the foreground)
/// made the system re-compute the touch region behind our back, so the next commit re-registers
/// this window.
- (void)invalidateTouchRegionRegistration;
- (BOOL)usesHostingControllerAPI;
@end


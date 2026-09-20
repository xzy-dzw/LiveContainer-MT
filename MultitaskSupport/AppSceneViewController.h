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
/// Plan C2 helper: relocate the hosted scene's system touch region to an off-screen CGRect
/// (targetFrame) via a frame push + NO→YES blip, then restore it into visibleSlotFrame for
/// rendering. The targetFrame is where the system touch region stays after registration, and
/// visibleSlotFrame is where the scene actually renders live content.
- (void)registerSceneTouchRegionAtFrame:(CGRect)targetFrame visibleSlotFrame:(CGRect)visibleSlotFrame;
- (BOOL)usesHostingControllerAPI;
@end


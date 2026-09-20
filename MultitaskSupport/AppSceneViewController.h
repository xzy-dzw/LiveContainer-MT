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
/// Plan C2 helper: relocate the hosted scene's system touch region to the target CGRect via a
/// frame push + NO→YES blip. The entire frame write lives in ObjC because SwiftUI's View.frame()
/// modifier collides with UIMutableApplicationSceneSettings.frame in Swift even with explicit
/// AnyObject casts. Swift-side MultitaskDockView calls this instead of touching settings.frame.
- (void)registerSceneTouchRegionAtFrame:(CGRect)targetFrame;
- (BOOL)usesHostingControllerAPI;
@end


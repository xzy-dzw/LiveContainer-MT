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
/// Derived live from the guest pid (getpgid); there is no stored value to set, so this is
/// intentionally readonly.
@property(nonatomic, readonly) BOOL isAppRunning;
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
/// Re-pushes the settled geometry of the hosted scene. BackBoard derives a hosted scene's touch
/// region from the hosting view's geometry, so a fullscreen toggle or a window promotion has to
/// end with this push or the main window stops being touchable at its new slot. The scene stays
/// foreground the whole time: the old foreground NO→YES blip froze the guest's video and cut its
/// audio for the length of the blip.
- (void)commitHostedGeometry;
/// Set foreground state on the hosted scene. Used to suspend side windows while the app is
/// backgrounded (so iOS does not kill them for memory pressure) and to wake them back up.
- (void)setHostedSceneForeground:(BOOL)foreground;
/// Set when the guest is deliberately terminated (red close button). Used to ignore the
/// cancellation error the extension reports on the way out.
@property(nonatomic, assign) BOOL terminationRequested;
- (BOOL)usesHostingControllerAPI;
@end


#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) bool isAppTerminationRequested;
@property(nonatomic) UITapGestureRecognizer* promoteGesture;
@end

@implementation DecoratedAppSceneViewController

- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];

    _dataUUID = dataUUID;
    _scaleRatio = 1.0;
    // The stage owns the fullscreen state; MultitaskDockManager pushes it through
    // applyStageFrame:scaleRatio:maximized:. Never read the launch setting here, or the two
    // sides disagree and the first layout flips between fullscreen and the split stage.
    _isMaximized = NO;
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];

    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];

    return self;
}

// The window itself carries no controls. The traffic lights live in the blank strip above the
// main window and are owned by MultitaskDockManager, so the guest app gets the whole slot.
- (void)setupDecoratedView {
    UIView* container = self.view;
    // The stage lays every window out itself, so the window must never auto-resize on its own.
    container.autoresizingMask = UIViewAutoresizingNone;
    container.backgroundColor = UIColor.blackColor;
    container.layer.cornerRadius = MultitaskStageLayout.cornerRadius;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.masksToBounds = YES;
    container.layer.borderColor = UIColor.separatorColor.CGColor;

    [self addChildViewController:_appSceneVC];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_appSceneVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [_appSceneVC.view.topAnchor constraintEqualToAnchor:container.topAnchor],
        [_appSceneVC.view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    // Tapping a side window promotes it to the main slot. The gesture is disabled on the main
    // window (and while fullscreen) so the guest app keeps receiving its own touches.
    _promoteGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPromoteWindow)];
    _promoteGesture.cancelsTouchesInView = YES;
    _promoteGesture.enabled = NO;
    [container addGestureRecognizer:_promoteGesture];
}

- (void)tapPromoteWindow {
    [MultitaskDockManager.shared promoteWindowForUUID:self.dataUUID];
}

#pragma mark - Stage layout

- (void)applyStageFrame:(CGRect)frame scaleRatio:(CGFloat)ratio maximized:(BOOL)maximized isMainWindow:(BOOL)isMainWindow {
    self.view.frame = frame;
    _scaleRatio = ratio > 0 ? ratio : 1.0;

    // The stage owns the fullscreen state, so mirror it here. Only re-push the whole settings
    // block when it actually flips, because split slots and fullscreen use different safe areas.
    BOOL maximizedChanged = (_isMaximized != maximized);
    _isMaximized = maximized;

    // Only a side window in split layout can be promoted by tapping it.
    _promoteGesture.enabled = !maximized && !isMainWindow;

    [self applyScaleRatio];
    [self.view layoutIfNeeded];

    if(maximizedChanged && self.appSceneVC.presenter) {
        [self appSceneVC:self.appSceneVC
    didUpdateFromSettings:self.appSceneVC.presenter.scene.settings.mutableCopy
       transitionContext:nil
     lifecycleActionType:0];
    } else {
        [self.appSceneVC updateFrameWithSettingsBlock:nil];
    }
}

- (void)applyScaleRatio {
    CGFloat ratio = _scaleRatio > 0 ? _scaleRatio : 1.0;
    self.appSceneVC.scaleRatio = ratio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(ratio, ratio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(ratio, ratio, 1.0);
    }
}

- (void)updateVerticalConstraints {
    [self applyScaleRatio];
    [self.appSceneVC updateFrameWithSettingsBlock:nil];
}

#pragma mark - Window actions

- (void)closeWindow {
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}

#pragma mark - AppSceneViewControllerDelegate

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        [[MultitaskDockManager shared] removeRunningApp:self.dataUUID];
        [self.view removeFromSuperview];
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];

        // The stage only has four slots, so a window whose app already exited must give its slot
        // back on its own. Otherwise it would keep blocking a slot and could never be relaunched.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if(!self) return;
            [[MultitaskDockManager shared] removeRunningApp:self.dataUUID];
            [self.view removeFromSuperview];
        });
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            [self applyScaleRatio];
            [self.appSceneVC updateFrameWithSettingsBlock:nil];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // Set up initial settings such as frame, safe area, etc
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
    [self applyScaleRatio];
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = baseSettings.userInterfaceStyle;
        settings.interfaceOrientation = baseSettings.interfaceOrientation;
        settings.deviceOrientation = baseSettings.deviceOrientation;
        settings.foreground = YES;

        if(self.isMaximized) {
            // Fullscreen shows the guest exactly like the original app does, safe area included.
            UIEdgeInsets insets = self.view.window.safeAreaInsets;
            settings.peripheryInsets = insets;
            settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(insets, baseSettings.interfaceOrientation);
        } else {
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }

        // The guest always renders at the phone's original resolution; the slot only scales it.
        CGRect frame = self.view.frame;
        CGFloat ratio = self.scaleRatio > 0 ? self.scaleRatio : 1.0;
        frame.size.width /= ratio;
        frame.size.height /= ratio;

        if(UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, frame.size.height, frame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
        }
    }];
}

@end

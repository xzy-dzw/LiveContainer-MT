//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "LCStageLog.h"
#include "../LiveContainer/utils.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic) AppSceneViewController* displayingVC;
@end


/// Static context pointer for the bounds KVO on pipVideoCallViewController.view.layer, used to
/// disambiguate from any other KVO registrations and to make add/remove pairing safe.
static int const LCPiPBoundsKVOContext = 0;

@implementation PiPManager
API_AVAILABLE(ios(16.0))
static PiPManager* sharedInstance = nil;

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    return (id)self.displayingVC.delegate;
}

- (BOOL)isPiP {
    return self.pipController.isPictureInPictureActive;
}

- (BOOL)isPiPWithVC:(AppSceneViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingVC == vc;
}

- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingDecoratedVC == vc;
}

- (instancetype)init {
    // Do NOT touch AVAudioSession here. PiP is used as a background keep-alive channel: the audio
    // session must only be activated while a PiP is actually running (see WillStart/DidStop below),
    // so merely touching the manager to read state never interrupts the user's own audio playback.
    return self;
}

- (void)startPiPWithVC:(AppSceneViewController*)vc {
    [self.pipController stopPictureInPicture];
    if(self.displayingVC) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:self.pipController];
    }
    // If a PiP is still tearing down, give it a moment to finish before starting the next one.
    NSTimeInterval delay = [self.pipController isPictureInPictureActive] ? 0.3 : 0.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.displayingVC = vc;
        self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];
        self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
        if(vc.usesHostingControllerAPI) {
            self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
            self.pipVideoCallContentView.layer.anchorPoint = CGPointMake(0, 0);
            self.pipVideoCallContentView.layer.position = CGPointMake(0, 0);
            [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
        } else {
            self.pipVideoCallContentView = vc.contentView;
        }
        AVPictureInPictureControllerContentSource* contentSource =  [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.pipController.delegate = self;
        [self.pipController setValue:@1 forKey:@"controlsStyle"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.pipController startPictureInPicture];
        });
    });

}

- (void)stopPiP {
    [self.pipController stopPictureInPicture];
}

// PIP delegate
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self.displayingDecoratedVC minimizeWindowPiP];
    if(self.displayingVC.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
        self.pipVideoCallViewController.additionalSafeAreaInsets = self.displayingVC.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:self.displayingVC.contentView];
    } else {
        self.displayingVC.contentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];

    // Activate the Playback audio session ONLY now that a PiP is actually starting: this is the
    // keep-alive channel that lets the host stay running in the background. It is torn down in
    // DidStop. Never touched while PiP is idle, so ordinary music playback is unaffected.
    NSError *activationError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&activationError];
    [[AVAudioSession sharedInstance] setActive:YES withOptions:1 error:&activationError];

    // Idempotent KVO pairing: remove any stale observer from a previous run before adding the
    // fresh one, so a second PiP never stacks observeValue callbacks. The layer may be brand new
    // (first PiP), so the remove is wrapped in @try.
    @try {
        [self.pipVideoCallViewController.view.layer removeObserver:self forKeyPath:@"bounds" context:&LCPiPBoundsKVOContext];
    } @catch (NSException * __unused exception) {}
    [self.pipVideoCallViewController.view.layer addObserver:self
                                forKeyPath:@"bounds"
                                   options:NSKeyValueObservingOptionNew
                                   context:&LCPiPBoundsKVOContext];
    self.pipVideoCallViewController.preferredContentSize = self.displayingVC.view.bounds.size;
    [self.displayingVC setBackgroundNotificationEnabled:false];
    self.displayingVC.shouldIgnoreSceneUpdates = YES;
}



- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // Always pair the bounds KVO registration, even if the layer changed between start and stop.
    @try {
        [self.pipVideoCallViewController.view.layer removeObserver:self forKeyPath:@"bounds" context:&LCPiPBoundsKVOContext];
    } @catch (NSException * __unused exception) {}

    // Release the keep-alive audio session now that PiP is no longer running.
    NSError *deactivationError = nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&deactivationError];

    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    os_log_error(LCStageLog(), "[LCStage][PiP] 启动失败: %{public}@", error.description);
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    CGRect rect = [change[@"new"] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / self.displayingVC.contentView.bounds.size.width/scale,rect.size.height /self.displayingVC.contentView.bounds.size.height/scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end

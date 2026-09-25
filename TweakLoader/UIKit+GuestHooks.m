@import UIKit;
@import AVFoundation;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import "../MultitaskSupport/LCStageIPC.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"

UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
BOOL launchURLProcessed = NO;

static void LCStageRolesChangedCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo);
static void LCStageHostBackgroundingCallback(CFNotificationCenterRef center, void *observer,
                                             CFStringRef name, const void *object,
                                             CFDictionaryRef userInfo);
static void LCStageHostForegroundingCallback(CFNotificationCenterRef center, void *observer,
                                             CFStringRef name, const void *object,
                                             CFDictionaryRef userInfo);

/// Resolved once in the constructor: the data container UUID this guest runs with. Drives the
/// heartbeat key and the side-window quarantine verdict.
static NSString *LCGuestDataUUID = nil;

/// The launch handoff key "selectedContainer" is NOT readable inside a guest: before this
/// dylib is dlopen'd, LCBootstrap calls NUDGuestHooksInit, which redirects
/// NSUserDefaults.standardUserDefaults to the guest app's own preferences domain. HOME is
/// already rewritten to the data container root at that point, and its last path component
/// is exactly the dataUUID the host registered this window with (AppSceneViewController
/// launches every window with container-folder-name = dataUUID).
static NSString *LCGuestResolveDataUUID(void) {
    const char *home = getenv("HOME");
    NSString *folder = home ? @(home).lastPathComponent : @"";
    if (folder.length && ![folder isEqualToString:@"Application"]) {
        return folder;
    }
    NSString *handoff = [NSUserDefaults.standardUserDefaults stringForKey:@"selectedContainer"];
    return handoff.length ? handoff : @"";
}

#pragma mark - Frozen frame + frame-ready signalling

#pragma mark - Guest keep-alive audio
//
// Each staged guest is its own LiveProcess.appex process. When the host is backgrounded or the
// screen locks, iOS suspends appexes that hold no media assertion — that suspension is what let
// jetsam kill the side windows. While the stage is active every guest therefore renders a
// near-silent looping PCM buffer through AVAudioEngine under .playback + .mixWithOthers: the
// process keeps a real playback assertion, stays runnable, makes no audible sound and never
// interrupts the user's music/calls. Classic single-app mode never publishes active roles, so
// the engine never runs there.

@interface LCGuestKeepAliveAudio : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioPlayerNode *player;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL wantsRunning;
@property(nonatomic, strong) id interruptionBeganObserver;
@property(nonatomic, strong) id interruptionEndedObserver;
@property(nonatomic, strong) id resetObserver;
+ (instancetype)shared;
/// Stage disappeared entirely: stop and release the session.
- (void)reconcile;
/// Host is about to background/lock: arm the engine (subject to the user toggle).
- (void)armForBackground;
/// Host returned to foreground: stop OUR engine but leave the session activated, so the guest
/// app's own audio (e.g. music that kept playing in the background) is never cut by us.
- (void)disarmForForeground;
@end

@implementation LCGuestKeepAliveAudio

+ (instancetype)shared {
    static LCGuestKeepAliveAudio *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [LCGuestKeepAliveAudio new]; });
    return instance;
}

- (BOOL)toggleEnabled {
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
    // v4.1.2+: this is a BACKUP channel and defaults OFF. Location + foreground pinning are the
    // primary keep-alive; enable this manually only for comparison testing if they fail.
    if ([defaults objectForKey:LCStageIPCKeepAliveAudioKey] == nil) { return NO; }
    return [defaults boolForKey:LCStageIPCKeepAliveAudioKey];
}

- (void)reconcile {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The engine only ever runs while the host is backgrounded (armed by
        // armForBackground). This callback's only job is tearing it down when the whole stage
        // goes away, so it never fights the guest app's own AVAudioSession configuration while
        // the stage is in the foreground.
        if (!LCStageGuestIsStageActive() && self.running) {
            [self stopLockedDeactivating:YES];
        }
    });
}

- (void)armForBackground {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.wantsRunning = [self toggleEnabled];
        if (self.wantsRunning && !self.running) {
            [self startLocked];
        }
    });
}

- (void)disarmForForeground {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.wantsRunning = NO;
        if (self.running) {
            [self stopLockedDeactivating:NO];
        }
    });
}

- (void)startLocked {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]
        || ![session setActive:YES error:&error]) {
        NSLog(@"[LCStage][保活] guest %@ 音频会话失败，2 秒后重试: %@", LCGuestDataUUID, error);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.wantsRunning) { [self startLocked]; }
        });
        return;
    }

    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioPlayerNode *player = [AVAudioPlayerNode new];
    [engine attachNode:player];
    double sampleRate = 44100.0;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:1];
    AVAudioFrameCount frameCount = (AVAudioFrameCount)sampleRate;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
    buffer.frameLength = frameCount;
    float *channel = buffer.floatChannelData[0];
    // ±1 LSB: provably rendering, completely inaudible.
    for (AVAudioFrameCount i = 0; i < frameCount; i++) {
        channel[i] = (i % 2 == 0) ? (1.0f / 32768.0f) : (-1.0f / 32768.0f);
    }
    [engine connect:player to:engine.mainMixerNode format:format];
    if (![engine startAndReturnError:&error]) {
        NSLog(@"[LCStage][保活] guest %@ 引擎启动失败，2 秒后重试: %@", LCGuestDataUUID, error);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.wantsRunning) { [self startLocked]; }
        });
        return;
    }
    [player scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [player play];
    self.engine = engine;
    self.player = player;
    self.running = YES;
    [self registerObservers];
    NSLog(@"[LCStage][保活] guest %@ 静音音轨已启动", LCGuestDataUUID);
}

- (void)stopLockedDeactivating:(BOOL)deactivate {
    [self unregisterObservers];
    [self.player stop];
    [self.engine stop];
    self.player = nil;
    self.engine = nil;
    self.running = NO;
    // On foreground return the session stays activated: the guest app may own playback of its
    // own (background music) and deactivating would cut it. Only the full stage teardown
    // releases the session back to the system.
    if (deactivate) {
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:nil];
    }
    NSLog(@"[LCStage][保活] guest %@ 静音音轨已停止（释放会话=%@）", LCGuestDataUUID,
          deactivate ? @"是" : @"否");
}

- (void)registerObservers {
    [self unregisterObservers];
    __weak typeof(self) weakSelf = self;
    self.interruptionBeganObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
        typeof(self) self = weakSelf;
        NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            NSLog(@"[LCStage][保活] guest %@ 被中断，结束后自动续播", LCGuestDataUUID);
        } else if (type == AVAudioSessionInterruptionTypeEnded) {
            // Tear the graph down and reconcile; startLocked re-activates the session and engine.
            [self hardRestart];
        }
    }];
    self.resetObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
        NSLog(@"[LCStage][保活] guest %@ 媒体服务重置，重建引擎", LCGuestDataUUID);
        [weakSelf hardRestart];
    }];
}

- (void)unregisterObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.interruptionBeganObserver) { [center removeObserver:self.interruptionBeganObserver]; }
    if (self.interruptionEndedObserver) { [center removeObserver:self.interruptionEndedObserver]; }
    if (self.resetObserver) { [center removeObserver:self.resetObserver]; }
    self.interruptionBeganObserver = nil;
    self.interruptionEndedObserver = nil;
    self.resetObserver = nil;
}

- (void)hardRestart {
    [self.player stop];
    [self.engine stop];
    self.player = nil;
    self.engine = nil;
    self.running = NO;
    if (self.wantsRunning) { [self startLocked]; }
}

@end

/// The foreground-active key window of this guest, regardless of whether the
/// app adopted UIScene already (old apps only have -[UIApplication keyWindow]).
static UIWindow *LCGuestKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive
            && windowScene.keyWindow) {
            return windowScene.keyWindow;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)scene).keyWindow) {
            return ((UIWindowScene *)scene).keyWindow;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

/// Renders a view into a tiny side x side 32bpp RGBA8 buffer and computes mean luminance plus
/// its standard deviation. A blank system buffer is ~(0,0); a dark video frame is black-ish but
/// noisy, so mean OR stddev crossing the thresholds is what separates "real content" from "black
/// nothing". Used both to verify frozen-frame captures and to verify post-unlock frames.
static BOOL LCGuestRenderLumaStats(UIView *view, CGFloat side, CGFloat *outMean, CGFloat *outStd) {
    CGSize size = view.bounds.size;
    if (size.width < 2 || size.height < 2) { return NO; }
    NSInteger w = (NSInteger)side;
    NSInteger h = (NSInteger)side;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, colorSpace,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) { return NO; }
    CGContextScaleCTM(ctx, (CGFloat)w / size.width, (CGFloat)h / size.height);
    [view.layer renderInContext:ctx];
    UInt8 *bytes = (UInt8 *)CGBitmapContextGetData(ctx);
    if (!bytes) { CGContextRelease(ctx); return NO; }
    double sum = 0, sumSq = 0;
    NSInteger count = w * h;
    for (NSInteger i = 0; i < count; i++) {
        double r = bytes[i * 4 + 0] / 255.0;
        double g = bytes[i * 4 + 1] / 255.0;
        double b = bytes[i * 4 + 2] / 255.0;
        double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        sum += luma;
        sumSq += luma * luma;
    }
    CGContextRelease(ctx);
    double mean = sum / count;
    double variance = MAX(0.0, sumSq / count - mean * mean);
    if (outMean) { *outMean = (CGFloat)mean; }
    if (outStd) { *outStd = (CGFloat)sqrt(variance); }
    return YES;
}

/// Snapshots the guest's last visible frame into the App Group. Runs on
/// willResignActive while the frame is still on screen; afterScreenUpdates:NO
/// keeps it synchronous and cheap. Logs JPEG size and pixel stats so a black/broken
/// capture is obvious from the logs instead of looking like a guest bug.
static void LCGuestCaptureFrozenFrame(NSString *dataUUID) {
    if (dataUUID.length == 0) { return; }
    UIWindow *window = LCGuestKeyWindow();
    CGRect bounds = window.bounds;
    if (bounds.size.width < 2 || bounds.size.height < 2) { return; }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:bounds];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
    }];
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.7);
    if (jpeg.length == 0) {
        NSLog(@"[LCStage][闪黑] 冻结帧拍照失败：JPEG 编码为空（uuid=%@）", dataUUID);
        return;
    }
    NSString *path = LCStageFrozenFramePath(dataUUID);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [jpeg writeToFile:path atomically:YES];
    CGFloat mean = 0, std = 0;
    LCGuestRenderLumaStats(window, 40, &mean, &std);
    NSLog(@"[LCStage][闪黑] 冻结帧已写入：%lu 字节，平均亮度=%.3f 标准差=%.3f",
          (unsigned long)jpeg.length, mean, std);
}

/// Pixel-verified frame-ready: every second display tick after arming, the key window is sampled
/// as a 40x40 thumbnail. Two CONSECUTIVE samples with mean luminance >0.02 OR stddev >0.01 count
/// as real content (a blank system buffer is ~(0,0); a dark video is black but noisy), and only
/// then is the host told to lift its cover. A 3s backstop always reports ready so a cover can
/// never get stuck on a genuinely dark app.
@interface LCFrameReadySignaler : NSObject
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, assign) NSInteger ticks;
@property(nonatomic, assign) NSInteger goodFrames;
@property(nonatomic, assign) CFAbsoluteTime armedAt;
@property(nonatomic, assign) BOOL done;
+ (instancetype)shared;
- (void)arm;
- (void)finishWithReason:(NSString *)reason;
@end

@implementation LCFrameReadySignaler

+ (instancetype)shared {
    static LCFrameReadySignaler *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [LCFrameReadySignaler new]; });
    return instance;
}

- (void)arm {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self arm]; });
        return;
    }
    [self.link invalidate];
    self.link = nil;
    self.ticks = 0;
    self.goodFrames = 0;
    self.done = NO;
    self.armedAt = CFAbsoluteTimeGetCurrent();
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)finishWithReason:(NSString *)reason {
    if (self.done) { return; }
    self.done = YES;
    [self.link invalidate];
    self.link = nil;
    NSLog(@"[LCStage][闪黑] 像素验真通过（%@，耗时 %.2fs，连续真实帧=%ld），上报 frame-ready",
          reason, CFAbsoluteTimeGetCurrent() - self.armedAt, (long)self.goodFrames);
    LCStageGuestMarkFrameReady(LCGuestDataUUID);
}

- (void)tick:(CADisplayLink *)link {
    if (self.done) { return; }
    self.ticks += 1;
    if (self.ticks % 2 != 0) { return; }  // sample every 2nd tick

    CGFloat mean = 0, std = 0;
    if (LCGuestRenderLumaStats(LCGuestKeyWindow(), 40, &mean, &std)) {
        if (mean > 0.02 || std > 0.01) {
            self.goodFrames += 1;
        } else {
            self.goodFrames = 0;
        }
        if (self.goodFrames >= 2) {
            [self finishWithReason:[NSString stringWithFormat:@"亮度=%.3f 噪点=%.3f", mean, std]];
            return;
        }
    }
    if (CFAbsoluteTimeGetCurrent() - self.armedAt > 3.0) {
        [self finishWithReason:[NSString stringWithFormat:@"3s 兜底（亮度=%.3f 噪点=%.3f）", mean, std]];
    }
}

@end

#pragma mark - Lifecycle broadcast masking (foreground pinning)
//
// Even with the host re-pinning every scene, iOS can still deliver UIScene lifecycle broadcasts
// into the guest during lock/background (willDeactivate / didActivate / willEnterForeground /
// didEnterBackground). Scene-based apps react to those by reloading their root feed (Instagram
// navigates back home from a deep profile page). While the stage is active and the user hasn't
// disabled pinning, TweakLoader therefore:
//   1. swallows those four broadcasts at NSNotificationCenter's post boundary, and
//   2. clamps -[UIScene activationState] / -[UIApplication applicationState] to active.
// Scene delegate methods are deliberately NOT swizzled. Classic single-app mode never publishes
// active roles, so zero behavior changes there.

static NSSet<NSString *> *LCStageMaskedLifecycleNames(void) {
    static NSSet *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            UISceneWillDeactivateNotification,
            UISceneDidActivateNotification,
            UISceneWillEnterForegroundNotification,
            UISceneDidEnterBackgroundNotification,
        ]];
    });
    return names;
}

/// Set to YES after THIS guest process has observed its first scene activation. Masking only arms
/// afterwards: a guest cold-starting into an already-active stage (first launch or watchdog
/// recovery relaunch) must receive its initial willEnterForeground/didActivate broadcasts or some
/// apps never finish bootstrapping their UI. The flag is process-local, so a relaunched guest
/// starts unmasked again.
static BOOL LCStageGuestHasActivatedOnce = NO;

static BOOL LCStageShouldMaskLifecycleName(NSString *name) {
    if (name.length == 0 || ![LCStageMaskedLifecycleNames() containsObject:name]) { return NO; }
    if (!LCStageGuestHasActivatedOnce) { return NO; }
    if (!LCStageGuestPinningEnabled()) { return NO; }
    return LCStageGuestIsStageActive();
}

@interface NSNotificationCenter (LCStageLifecycleMask)
- (void)hook_lc_postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)userInfo;
- (void)hook_lc_postNotification:(NSNotification *)notification;
@end

@implementation NSNotificationCenter (LCStageLifecycleMask)
- (void)hook_lc_postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)userInfo {
    if (LCStageShouldMaskLifecycleName(name)) { return; }
    [self hook_lc_postNotificationName:name object:object userInfo:userInfo];
}
- (void)hook_lc_postNotification:(NSNotification *)notification {
    if (LCStageShouldMaskLifecycleName(notification.name)) { return; }
    [self hook_lc_postNotification:notification];
}
@end

@interface UIScene (LCStageLifecycleMask)
- (UISceneActivationState)hook_lc_activationState;
@end

@implementation UIScene (LCStageLifecycleMask)
- (UISceneActivationState)hook_lc_activationState {
    if (LCStageGuestPinningEnabled() && LCStageGuestIsStageActive()) {
        return UISceneActivationStateForegroundActive;
    }
    return [self hook_lc_activationState];
}
@end

@interface UIApplication (LCStageLifecycleMask)
- (UIApplicationState)hook_lc_applicationState;
@end

@implementation UIApplication (LCStageLifecycleMask)
- (UIApplicationState)hook_lc_applicationState {
    if (LCStageGuestPinningEnabled() && LCStageGuestIsStageActive()) {
        return UIApplicationStateActive;
    }
    return [self hook_lc_applicationState];
}
@end

static void LCStageInstallLifecycleMasking(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        swizzle(NSNotificationCenter.class,
                @selector(postNotificationName:object:userInfo:),
                @selector(hook_lc_postNotificationName:object:userInfo:));
        swizzle(NSNotificationCenter.class,
                @selector(postNotification:),
                @selector(hook_lc_postNotification:));
        swizzle(UIScene.class,
                @selector(activationState),
                @selector(hook_lc_activationState));
        swizzle(UIApplication.class,
                @selector(applicationState),
                @selector(hook_lc_applicationState));
    });
}

__attribute__((constructor))
static void UIKitGuestHooksInit() {
    LCGuestDataUUID = LCGuestResolveDataUUID();
    if(!NSUserDefaults.lcGuestAppId) {
        return;
    }

    // Restart evidence for the host's [LCStage][场景] logs: one bump per process lifetime.
    LCGuestBumpLaunchCount(LCGuestDataUUID);
    NSLog(@"[LCStage][场景] guest 进程启动 uuid=%@ pid=%d launchCount=%ld",
          LCGuestDataUUID, NSProcessInfo.processInfo.processIdentifier,
          (long)LCStageHostGuestLaunchCount(LCGuestDataUUID));
    // Lifecycle masking hooks are installed unconditionally but only act while a stage is active
    // and the pinning toggle is on.
    LCStageInstallLifecycleMasking();
    // The first activation broadcast of THIS process must always reach the app (it finishes UI
    // bootstrapping); only arm lifecycle masking once it has landed. This observer fires before
    // masking could swallow anything because LCStageShouldMaskLifecycleName checks the flag.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                    object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        if (!LCStageGuestHasActivatedOnce) {
            LCStageGuestHasActivatedOnce = YES;
            NSLog(@"[LCStage][场景] guest 首次激活完成，生命周期屏蔽已武装（uuid=%@）", LCGuestDataUUID);
        }
    }];

    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
            swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }


    }


    // MARK: - Guest heartbeat for dead-window cleanup

    // Every guest process writes a timestamp to the shared App Group once per second. The
    // host MultitaskDockManager reads this in performLayout: any window whose heartbeat has
    // not moved for 10+ seconds is considered crashed/dead and gets removed from the stage
    // immediately, instead of lingering as a black screen until the user relaunches it.
    // This is the single most reliable cleanup signal — exit callbacks are asynchronous
    // and silently dropped when the system SIGKILLs the extension under memory pressure.
    NSString *dataUUID = LCGuestDataUUID;
    NSString *hbKey = [NSString stringWithFormat:@"LCGuestHeartbeat.%@", dataUUID.length ? dataUUID : @""];
    // Beat once right now, before the timer: loading this dylib is itself the proof that the
    // guest really launched the app (a guest that bailed out in LCBootstrap never gets here), and
    // the host's watchdog must not have to wait a whole timer period to see that liveness.
    NSUserDefaults *groupDefaults = [NSUserDefaults lcSharedDefaults];
    [groupDefaults setDouble:CFAbsoluteTimeGetCurrent() forKey:hbKey];
    [groupDefaults synchronize];
    __block NSTimer *heartbeatTimer = nil;
    // Use +weak reference so the timer block doesn't retain anything — if NSTimer ever holds
    // strong references to non-UI objects we don't care; we just want to fire every second.
    // timerWithTimeInterval: does NOT schedule itself on a runloop (unlike
    // scheduledTimerWithTimeInterval:), so there is exactly one add — below, in common modes.
    // This also stays correct if this constructor ever runs off the main thread.
    heartbeatTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        NSUserDefaults *group = [NSUserDefaults lcSharedDefaults];
        // CFAbsoluteTimeGetCurrent() is a CoreFoundation primitive — no extra framework link
        // required, unlike CACurrentMediaTime which lives in QuartzCore.
        [group setDouble:CFAbsoluteTimeGetCurrent() forKey:hbKey];
        [group synchronize];
    }];
    // The host allows 10s of silence before pruning, so the 1s cadence does not need to be exact:
    // tolerance lets the system coalesce this wake-up with other timers and save battery.
    heartbeatTimer.tolerance = 0.2;
    [[NSRunLoop mainRunLoop] addTimer:heartbeatTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[LCGuestHeartbeat] started for %@ (key=%@)", dataUUID, hbKey);

    // MARK: - Backdrop luminance for adaptive control glyphs
    //
    // The host cannot snapshot a hosted scene's cross-process content (it renders black), so the
    // MAIN guest measures its own rendered content and publishes a 0..1 mean luma. The host tints
    // the stage control glyphs white on dark video and dark on light apps. Side windows never
    // sample (their glyphs are hidden) and the cost is a single 40x40 software render at 2Hz.
    NSTimer *lumaTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        if (!LCStageGuestIsMainWindow(LCGuestDataUUID)) { return; }
        CGFloat mean = 0, std = 0;
        if (LCGuestRenderLumaStats(LCGuestKeyWindow(), 40, &mean, &std)) {
            LCStageGuestWriteBackdropLuma(LCGuestDataUUID, (double)mean);
        }
    }];
    lumaTimer.tolerance = 0.15;
    [[NSRunLoop mainRunLoop] addTimer:lumaTimer forMode:NSRunLoopCommonModes];

    // MARK: - First-frame report + frozen-frame capture
    //
    // A hosted scene shows a black card until the guest's first frame reaches
    // the host. The guest therefore (1) tells the host when real frames are on
    // screen after every activation, and (2) snapshots its last frame before
    // resigning active, so after unlock the host can cover the recovering
    // scene with a still of THIS app instead of a black flash.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        LCGuestCaptureFrozenFrame(LCGuestDataUUID);
    }];
    // Earliest in-process moment the scene is about to deactivate, captured independently of the
    // host's Darwin snapshot request. When lifecycle masking is ON this broadcast is swallowed at
    // the post boundary (so this observer does not run either — the host's Darwin request takes
    // the snapshot); when the user has turned masking OFF, this is the backup capture channel.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
                                                    object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        LCGuestCaptureFrozenFrame(LCGuestDataUUID);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        [LCFrameReadySignaler.shared arm];
    }];
    // Cold launch: the notification above usually fires right after this constructor,
    // arm once as well in case the app is already active when TweakLoader loads.
    [LCFrameReadySignaler.shared arm];

    // MARK: - Stage side-window touch quarantine
    //
    // When this guest is displayed as a non-main side window on the virtual window stage,
    // touches routed by BackBoard land directly in this process (the host can never see them).
    // Swallow them at UIApplication.sendEvent, upstream of every UIWindow/gesture, and ask the
    // host to promote this window to the main slot. The host publishes who the main window is
    // through LCStageIPC (App Group defaults + Darwin notifications).
    static dispatch_once_t stageOnce;
    dispatch_once(&stageOnce, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LCStageRolesChangedCallback,
                                        (__bridge CFStringRef)LCStageRolesChangedNotificationName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // Host is about to background/lock: our own willResignActive is stripped under hosting,
        // so snapshot NOW and make sure the keep-alive engine is armed before the suspension.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LCStageHostBackgroundingCallback,
                                        (__bridge CFStringRef)LCStageHostBackgroundingNotificationName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // Host returned to foreground: re-arm frame-ready reporting ourselves.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LCStageHostForegroundingCallback,
                                        (__bridge CFStringRef)LCStageHostForegroundingNotificationName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        swizzle(UIApplication.class, @selector(sendEvent:), @selector(hook_lcStage_sendEvent:));
    });
    // The stage may already be active by the time TweakLoader loads (guest launched straight
    // into a stage slot); reconcile once instead of waiting for the next roles change.
    [LCGuestKeepAliveAudio.shared reconcile];
}

// Cached side-window verdict. LCStageGuestIsSideWindow() hits App Group defaults on every
// call, and a fast scroll produces hundreds of touch events per second. Roles only change on
// a host publish, which always arrives with the Darwin notification above; so cache for 0.5s
// and invalidate the moment roles change. Both touch delivery and Darwin callbacks land on
// the main thread.
static BOOL lc_cachedIsSideWindow = NO;
static NSTimeInterval lc_sideWindowCacheValidUntil = 0;

static BOOL LCStageGuestCachedIsSideWindow(NSString *guestUUID) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now < lc_sideWindowCacheValidUntil) {
        return lc_cachedIsSideWindow;
    }
    lc_cachedIsSideWindow = LCStageGuestIsSideWindow(guestUUID);
    lc_sideWindowCacheValidUntil = now + 0.5;
    return lc_cachedIsSideWindow;
}

static void LCStageRolesChangedCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    // Pull the host's latest role state so the next sendEvent decision is fresh, and force
    // the cached verdict to be recomputed on the next event.
    [NSUserDefaults.lcSharedDefaults synchronize];
    lc_sideWindowCacheValidUntil = 0;
    // Stage active state is also the on/off switch for this guest's keep-alive audio.
    [LCGuestKeepAliveAudio.shared reconcile];
}

static void LCStageHostBackgroundingCallback(CFNotificationCenterRef center, void *observer,
                                             CFStringRef name, const void *object,
                                             CFDictionaryRef userInfo) {
    // Runs at host willResignActive. The guest's own lifecycle notifications are removed under
    // hosting (so YouTube-style apps keep playing), so the host tells us directly: freeze the
    // last frame and arm keep-alive BEFORE suspension begins.
    LCGuestCaptureFrozenFrame(LCGuestDataUUID);
    [LCGuestKeepAliveAudio.shared armForBackground];
}

static void LCStageHostForegroundingCallback(CFNotificationCenterRef center, void *observer,
                                             CFStringRef name, const void *object,
                                             CFDictionaryRef userInfo) {
    // The host is back; our own didBecomeActive never arrives under hosting. Stop our keep-alive
    // engine (without touching the guest app's own session) and re-arm the frame-ready signaler
    // so the cover lifts as soon as THIS guest's new frames are on screen.
    [LCGuestKeepAliveAudio.shared disarmForForeground];
    [[LCFrameReadySignaler shared] arm];
}

@interface UIApplication (LCStageTouchHook)
- (void)hook_lcStage_sendEvent:(UIEvent *)event;
@end

@implementation UIApplication (LCStageTouchHook)
- (void)hook_lcStage_sendEvent:(UIEvent *)event {
    // Cheap cached verdict first: allTouches enumeration runs only for guests currently staged
    // as a side window — on the main window, and when multitasking is never used, every single
    // touch event used to build and walk the touch set for nothing.
    if (event.type == UIEventTypeTouches && LCStageGuestCachedIsSideWindow(LCGuestDataUUID)) {
        // A fresh touch down in a side window is a promote request. Every
        // event of the sequence (began/moved/ended) is dropped so the app
        // inside never reacts to it.
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                LCStageRequestPromote(LCGuestDataUUID);
                break;
            }
        }
        return;
    }
    [self hook_lcStage_sendEvent:event];
}
@end

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcDocFolder = [[NSString stringWithUTF8String:getenv("LC_HOME_PATH")] stringByAppendingPathComponent:@"Documents"];
        
        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }
    
    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
        BOOL isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString: [NSString stringWithFormat: @"%@://", scheme]]];
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    
    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }
    
    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    
    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        
        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];
        
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    
    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };
    
    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }
    
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }
    
    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });
    
    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    

}

void LCOpenSideStoreURL(NSURL* sidestoreUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
        // Already launching: fall through used to build and show the confirmation alert as well,
        // and tapping OK there wrote the launch parameters a second time (double launch).
        return;
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            return;
        }
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }
        
        if(!bundle || ([lcAppInfo[@"isHidden"] boolValue] && [NSUserDefaults.lcSharedDefaults boolForKey:@"LCStrictHiding"])) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }
    
}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];
    
}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    // pass through sidestore urls
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        return LCControlAppURLHandlingPassThrough;
    }

    if([url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(url);
        return LCControlAppURLHandlingStop;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme]) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;
    
    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }
    
    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }
        
        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"LiveContainer", false);
            return LCControlAppURLHandlingStop;
        }
        
        NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches OR sidestore is running and we are launching builtinSideStore
        if (([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) ||
            (NSUserDefaults.isSideStore && [bundleName isEqualToString:@"builtinSideStore"])) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            if([bundleName isEqualToString:@"builtinSideStore"]) {
                LCShowSwitchAppConfirmation(url, @"SideStore", NO);
                return LCControlAppURLHandlingStop;
            }
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }
        
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;
        
    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme]) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }
    
    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }
        
        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
        context.payload = newDict;
        
        
        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }
        
        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];
        
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;
        
    } while(0);
    
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }
    
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    return canAppOpenItself(url) || shouldRedirectOpenURLToHost(url) || [self hook_canOpenURL:url];
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    // setDelegate: can run more than once; method swizzling is self-inverse, so re-swapping on
    // every call would silently restore the system implementations on even-numbered calls. Do it
    // at most once, decided by the first delegate that is installed.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
            // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
            swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
            swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
            swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
            // Fix apps that do not support UISceneDelegate getting 0 status bar frame
            swizzle(UIApplication.class, @selector(statusBarFrame), @selector(hook_statusBarFrame));
        }
    });
    [self hook_setDelegate:delegate];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame {
    UIStatusBarManager* manager = [(UIWindowScene*)(UIApplication.sharedApplication.connectedScenes.anyObject) statusBarManager];
    if(manager) {
        return manager.statusBarFrame;
    } else {
        return [self hook_statusBarFrame];
    }
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations {
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }

}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation {
    return YES;
}

@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}
- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    for(UIWindowScene *windowScene in UIApplication.sharedApplication.connectedScenes) {
        if(!self.windowScene && self.screen == windowScene.screen) {
            self.windowScene = windowScene;
            break;
        }
    }
}
@end

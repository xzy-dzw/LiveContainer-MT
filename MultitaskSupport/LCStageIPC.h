//
//  LCStageIPC.h
//  LiveContainer
//
//  Stage <-> guest inter-process communication for the virtual-window
//  multitask stage. This header is shared by the host app (MultitaskSupport)
//  and TweakLoader.dylib, which is injected into every guest process, so it
//  must stay Foundation-only and header-only (static inline).
//
//  Why this exists
//  ---------------
//  A hosted guest scene receives touches through BackBoard's per-scene touch
//  region, which on iOS 19+ is continuously derived from the hosting view's
//  geometry. Nothing placed in the host's UIKit hierarchy (shield views,
//  hitTest overrides, userInteractionEnabled=NO, off-screen region blips) can
//  stop a touch from being delivered to the guest process, and the host never
//  sees that event in UIApplication.sendEvent.
//
//  The reliable interception point is therefore *inside the guest process*:
//  TweakLoader swizzles the guest's UIApplication.sendEvent, asks the shared
//  role state published here whether it is a non-interactive side window,
//  swallows the whole touch sequence before the app sees it, and posts a
//  Darwin "promote me" request. The host promotes the window to the main slot.
//  Every scene stays foreground and rendering live; no snapshots are used.
//

#ifndef LCStageIPC_h
#define LCStageIPC_h

#import <Foundation/Foundation.h>
#import "../LiveContainer/utils.h"

NS_ASSUME_NONNULL_BEGIN

/// App Group defaults keys.
/// LCStageActive/LCStageMainUUID/LCStageRolesTimestamp are written by the host.
/// LCPendingPromoteUUID/LCPendingPromoteTimestamp are written by a guest.
static NSString * const LCStageIPCActiveKey = @"LCStageActive";
static NSString * const LCStageIPCMainUUIDKey = @"LCStageMainUUID";
static NSString * const LCStageIPCRolesTimestampKey = @"LCStageRolesTimestamp";
static NSString * const LCStageIPCPendingPromoteKey = @"LCPendingPromoteUUID";
static NSString * const LCStageIPCPendingPromoteTimestampKey = @"LCPendingPromoteTimestamp";

/// Darwin notification names. Darwin notifications carry no payload across
/// processes; the payload travels through the App Group defaults above.
static NSString * const LCStageRolesChangedNotificationName =
    @"com.kdt.livecontainer.stage.rolesChanged";
static NSString * const LCStagePromoteRequestNotificationName =
    @"com.kdt.livecontainer.stage.promoteRequest";
/// Posted by a guest after it rendered real frames following an activation
/// (cold start AND every foreground return). The host then fades its launch
/// placeholder / frozen-frame cover out. Payload: LCGuestFrameReady.<uuid>.
static NSString * const LCStageFrameReadyNotificationName =
    @"com.kdt.livecontainer.stage.frameReady";

/// Guest-written timestamp keys, one per data container.
static NSString * const LCStageIPCFrameReadyKeyPrefix = @"LCGuestFrameReady.";

/// Role state older than this many seconds is treated as missing. The host
/// republishes roughly once per second while the stage is on screen, so a
/// missed Darwin notification or a dead host can never lock a guest into
/// quarantined (touch-swallowing) state for long.
static const NSTimeInterval LCStageIPCRoleStaleness = 5.0;
/// Promotion requests older than this many seconds are ignored by the host.
static const NSTimeInterval LCStageIPCPromoteStaleness = 5.0;

static inline NSUserDefaults *LCStageSharedDefaults(void) {
    return [NSUserDefaults lcSharedDefaults] ?: NSUserDefaults.standardUserDefaults;
}

/// Host: publishes the current stage role state and wakes every guest.
/// active=NO releases all guests back to normal touch delivery.
static inline void LCStagePublishRoles(BOOL active, NSString *_Nullable mainUUID) {
    NSUserDefaults *defaults = LCStageSharedDefaults();
    [defaults setBool:active forKey:LCStageIPCActiveKey];
    if (active && mainUUID.length) {
        [defaults setObject:mainUUID forKey:LCStageIPCMainUUIDKey];
    } else if (!active) {
        [defaults removeObjectForKey:LCStageIPCMainUUIDKey];
    }
    [defaults setDouble:CFAbsoluteTimeGetCurrent() forKey:LCStageIPCRolesTimestampKey];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)LCStageRolesChangedNotificationName,
                                         NULL, NULL, TRUE);
}

/// Guest: asks the host to promote this guest's window to the main slot.
static inline void LCStageRequestPromote(NSString *guestUUID) {
    if (guestUUID.length == 0) { return; }
    NSUserDefaults *defaults = LCStageSharedDefaults();
    [defaults setObject:guestUUID forKey:LCStageIPCPendingPromoteKey];
    [defaults setDouble:CFAbsoluteTimeGetCurrent() forKey:LCStageIPCPendingPromoteTimestampKey];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)LCStagePromoteRequestNotificationName,
                                         NULL, NULL, TRUE);
}

/// Guest: YES when this guest is currently a non-interactive side window on
/// the stage and must not receive touches. Returns NO whenever the stage is
/// inactive, this guest is the main window, or the published state is stale.
static inline BOOL LCStageGuestIsSideWindow(NSString *guestUUID) {
    if (guestUUID.length == 0) { return NO; }
    NSUserDefaults *defaults = LCStageSharedDefaults();
    if (![defaults boolForKey:LCStageIPCActiveKey]) { return NO; }
    double timestamp = [defaults doubleForKey:LCStageIPCRolesTimestampKey];
    if (timestamp <= 0 || CFAbsoluteTimeGetCurrent() - timestamp > LCStageIPCRoleStaleness) {
        return NO;
    }
    NSString *mainUUID = [defaults stringForKey:LCStageIPCMainUUIDKey];
    if (mainUUID.length == 0) { return NO; }
    return ![mainUUID isEqualToString:guestUUID];
}

/// Host: reads and clears a pending promotion request. Returns nil when there
/// is no fresh request (a stale one left behind by a dead guest is dropped).
static inline NSString *_Nullable LCStageTakePendingPromoteUUID(void) {
    NSUserDefaults *defaults = LCStageSharedDefaults();
    // Refresh the cross-process cache BEFORE reading, otherwise the guest's
    // write may still be invisible to us even though the Darwin notification
    // already arrived.
    [defaults synchronize];
    NSString *uuid = [defaults stringForKey:LCStageIPCPendingPromoteKey];
    double timestamp = [defaults doubleForKey:LCStageIPCPendingPromoteTimestampKey];
    [defaults removeObjectForKey:LCStageIPCPendingPromoteKey];
    [defaults removeObjectForKey:LCStageIPCPendingPromoteTimestampKey];
    [defaults synchronize];
    if (uuid.length == 0 || timestamp <= 0 ||
        CFAbsoluteTimeGetCurrent() - timestamp > LCStageIPCPromoteStaleness) {
        return nil;
    }
    return uuid;
}

/// Guest: records that this guest has real frames on screen and wakes the
/// host so it can reveal the card.
static inline void LCStageGuestMarkFrameReady(NSString *guestUUID) {
    if (guestUUID.length == 0) { return; }
    NSUserDefaults *defaults = LCStageSharedDefaults();
    [defaults setDouble:CFAbsoluteTimeGetCurrent()
                 forKey:[LCStageIPCFrameReadyKeyPrefix stringByAppendingString:guestUUID]];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)LCStageFrameReadyNotificationName,
                                         NULL, NULL, TRUE);
}

/// Host: reads a guest's frame-ready timestamp (0 when never reported).
/// Callers synchronize first so the guest's write is visible.
static inline CFAbsoluteTime LCStageHostFrameReadyAt(NSString *guestUUID) {
    if (guestUUID.length == 0) { return 0; }
    NSUserDefaults *defaults = LCStageSharedDefaults();
    [defaults synchronize];
    return [defaults doubleForKey:[LCStageIPCFrameReadyKeyPrefix stringByAppendingString:guestUUID]];
}

/// Path of the frozen-frame JPEG one guest stores right before resigning
/// active, and the host shows while its hosted scene recovers after unlock.
static inline NSString *LCStageFrozenFramePath(NSString *guestUUID) {
    NSString *directory = [[[NSUserDefaults lcAppGroupPath]
                            stringByAppendingPathComponent:@"LiveContainer"]
                           stringByAppendingPathComponent:@"StageFrozenFrames"];
    return [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.jpg", guestUUID]];
}

NS_ASSUME_NONNULL_END

#endif /* LCStageIPC_h */

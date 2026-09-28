//
//  LCStageLog.h
//  LiveContainer
//
//  Unified logging for the multitask stage. Replaces synchronous NSLog (which opens a new ASL
//  connection and blocks the main thread on every touch interception / lifecycle event) with
//  os_log: asynchronous, low-overhead, filterable by subsystem in Console.app, and still visible
//  in Xcode 15+ debug console.
//

#ifndef LCStageLog_h
#define LCStageLog_h

#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared os_log_t for all multitask stage logging. Subsystem matches the app bundle; category
/// "stage" keeps stage logs filterable from guest/host noise.
static inline os_log_t LCStageLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.livecontainer.stage", "stage");
    });
    return log;
}

NS_ASSUME_NONNULL_END

#endif /* LCStageLog_h */

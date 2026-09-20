//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import Foundation
import Darwin

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    
    @objc class func registerMultitaskContainer(container: String) {
        usingMultitaskContainers.append(container)
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }
    
    @objc class func isUsing(container: String) -> Bool {
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        return usingMultitaskContainers.count > 0
    }

    /// Reaps a leftover guest process of *this* app that still holds `container`'s lock while no
    /// window of ours shows it. Returns YES when the lock was released.
    ///
    /// A guest whose window was dropped without terminating it stays alive as an orphan: it keeps
    /// playing audio and keeps the container registered in containerLock.plist, and LCBootstrap
    /// then makes every *later* guest of that container bail out with "another instance is
    /// running". The user sees a black window with audio from the orphan, and that window can
    /// never be switched to the main slot because its guest is an empty process. Called right
    /// before a launch, so the new guest finds the container free.
    @objc class func reapOrphanedGuest(holdingContainer container: String) -> Bool {
        guard !container.isEmpty,
              let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return false }
        let lockPath = (appGroupPath as NSString).appendingPathComponent("LiveContainer/containerLock.plist")
        guard let lock = NSMutableDictionary(contentsOfFile: lockPath),
              let entry = lock[container] as? [String: Any],
              let runningLC = entry["runningLC"] as? String,
              let token57 = (entry["auditToken57"] as? NSNumber)?.uint64Value else { return false }
        // Only an instance of a LiveProcess appex can be a window guest. Anything else (an app
        // running inside this app in classic mode, another LiveContainer install) keeps its lock.
        guard runningLC.hasSuffix("liveprocess") else { return false }
        // A window of ours owns the container legitimately, whenever it is on the stage.
        if #available(iOS 16.0, *),
           MultitaskDockManager.shared.apps.contains(where: { $0.appUUID == container }) {
            return false
        }

        // The lock stores the guest's own audit token; its pid is the upper half of val57.
        let pid = pid_t(truncatingIfNeeded: token57 >> 32)

        func releaseLock() {
            lock.removeObject(forKey: container)
            if let holder = lock[runningLC] as? NSNumber, holder.uint64Value == token57 {
                lock.removeObject(forKey: runningLC)
            }
            lock.write(toFile: lockPath, atomically: true)
        }

        guard let path = executablePath(pid: pid) else {
            // Nothing alive behind the entry any more (or its pid is unreadable): drop the entry
            // so the next launch is not redirected into a dead instance. Never kill on a guess.
            releaseLock()
            return true
        }

        // The pid may have been recycled since the lock was written, so only a path that is
        // unmistakably this app's LiveProcess appex may be killed.
        guard isLiveProcessExecutable(executablePath: path) else { return false }

        // SIGTERM first: the orphan is still a running app that should get the chance to flush
        // its data before the new guest takes over the very same container.
        if kill(pid, SIGTERM) == 0 {
            NSLog("[LCStage] reaping orphaned guest pid=%d holding container %@", pid, container)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard isLiveProcessExecutable(pid: pid) else { return }
                kill(pid, SIGKILL)
            }
        }
        releaseLock()
        return true
    }

    /// YES when the pid still points at a LiveProcess appex inside *this* app bundle. Guards the
    /// reaper against pid reuse and against guests of another LiveContainer install.
    private class func isLiveProcessExecutable(pid: pid_t) -> Bool {
        guard let path = executablePath(pid: pid) else { return false }
        return isLiveProcessExecutable(executablePath: path)
    }

    private class func isLiveProcessExecutable(executablePath: String) -> Bool {
        return executablePath.contains("/LiveProcess.appex/")
            && executablePath.hasPrefix(Bundle.main.bundlePath)
    }

    /// `proc_pidpath` lives in libproc, which the Darwin module does not re-export, so the symbol
    /// is resolved once at runtime instead of pulling a private header into the bridging header.
    /// If it cannot be resolved, nothing is ever killed (the lock is only released).
    private typealias ProcPidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
    private static let procPidPathFn: ProcPidPathFn? = {
        // RTLD_DEFAULT searches the images already loaded into this process; libproc is not linked
        // by the app, so if that misses, ask dyld for the library itself.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") {
            return unsafeBitCast(symbol, to: ProcPidPathFn.self)
        }
        guard let handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "proc_pidpath") else { return nil }
        return unsafeBitCast(symbol, to: ProcPidPathFn.self)
    }()

    /// Executable path of a process, or nil when it no longer exists.
    private class func executablePath(pid: pid_t) -> String? {
        guard pid > 0, let procPidPath = Self.procPidPathFn else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard procPidPath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

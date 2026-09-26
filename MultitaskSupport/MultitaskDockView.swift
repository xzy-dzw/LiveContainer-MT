//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine
import ObjectiveC.runtime
import AVFoundation
import AVKit
import CoreMedia
import CoreLocation

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)

    /// Coarse upper bound on each cache dictionary. Entries otherwise accumulate forever as
    /// apps are installed/removed. On overflow we drop the whole dictionary (it rebuilds
    /// lazily from disk on the next lookup) instead of maintaining a real LRU list.
    private static let maxCacheCount = 64

    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) {
                    if self.infoCacheByUUID[dataUUID] == nil && self.infoCacheByUUID.count >= Self.maxCacheCount {
                        self.infoCacheByUUID.removeAll()
                    }
                    self.infoCacheByUUID[dataUUID] = appInfo
                }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) {
                        if self.infoCacheByName[appName] == nil && self.infoCacheByName.count >= Self.maxCacheCount {
                            self.infoCacheByName.removeAll()
                        }
                        self.infoCacheByName[appName] = appInfo
                    }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        // Walk both model lists in place; `apps + hiddenApps` allocated a merged copy on every
        // window entry.
        let appLists = [DataManager.shared.model.apps, DataManager.shared.model.hiddenApps]
        for list in appLists {
            if let appInfo = list.first(where: {
                $0.appInfo.containers.contains { $0.folderName == dataUUID }
            })?.appInfo {
                return appInfo
            }
        }
        for list in appLists {
            if let appInfo = list.first(where: { $0.appInfo.displayName() == appName })?.appInfo {
                return appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - Running app model
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    /// The card view. `var` because an in-place recovery (guest killed by the system) swaps the
    /// freshly relaunched DecoratedVC's view in without changing the model's slot/order.
    var view: UIView?
    /// When this window entered the stage. The watchdog never judges a window that is still
    /// inside the guest-start grace window (see pruneDeadWindows(allowHeartbeatPrune:)): a
    /// freshly launched guest needs a moment before it writes its first heartbeat.
    /// Reset on recovery so the relaunched guest gets a fresh grace window.
    var addedAt = Date()
    /// YES while a jetsam'd/dead guest is being relaunched into this same slot. While set, the
    /// old card stays on screen showing the recovery cover, launch pre-checks allow the
    /// relaunch, and the old guest's exit callback must not remove the slot.
    var isRecovering = false
    /// Recovery attempts since the window was last healthy. Capped at 1 to avoid relaunch loops
    /// under sustained memory pressure; reset to 0 once the new guest reports a heartbeat.
    var recoveryAttempts = 0
    var recoveryBeganAt = Date.distantPast
    /// Pending lazy launch-cover show (0.3s after window entry). Cancelled the moment the guest
    /// reports a real frame, so fast launches never flash the spinner at all.
    var placeholderWorkItem: DispatchWorkItem?

    init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - Real keep-alive audio (host)

/// Holds a REAL playback assertion while the stage exists. Merely activating an AVAudioSession
/// without playing anything does NOT prevent suspension on modern iOS — mediaserverd only grants
/// the background assertion while audio is actually rendering. We therefore run an AVAudioEngine
/// with a looping near-silent PCM buffer under `.playback + mixWithOthers` (it never interrupts
/// the user's music/calls and is inaudible). Interruptions and media-server resets re-arm it.
@available(iOS 16.0, *)
private final class StageAudioKeepAlive {
    static let shared = StageAudioKeepAlive()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var retryWorkItem: DispatchWorkItem?

    private init() {}

    func start() {
        guard !isRunning else { return }
        retryWorkItem?.cancel()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let sampleRate = 44100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw NSError(domain: "LCStageKeepAlive", code: 1)
            }
            let frameCount = AVAudioFrameCount(sampleRate) // 1 second
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw NSError(domain: "LCStageKeepAlive", code: 2)
            }
            buffer.frameLength = frameCount
            // Non-zero ±1 LSB samples: a mathematically silent graph can be optimised away by
            // the stack; this level is completely inaudible but unambiguously "rendering".
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<Int(frameCount) {
                    channel[i] = (i % 2 == 0) ? (1.0 / 32768.0) : (-1.0 / 32768.0)
                }
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1.0
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            self.engine = engine
            self.player = player
            self.isRunning = true
            registerObservers()
            NSLog("[LCStage][保活] 宿主静音音轨已启动（playback/mixWithOthers）")
        } catch {
            NSLog("[LCStage][保活] 宿主静音音轨启动失败，2 秒后重试: \(error)")
            scheduleRetry()
        }
    }

    func stop() {
        retryWorkItem?.cancel()
        unregisterObservers()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        if isRunning {
            isRunning = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            NSLog("[LCStage][保活] 宿主静音音轨已停止")
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func registerObservers() {
        unregisterObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let typeValue = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if typeValue == .began {
                NSLog("[LCStage][保活] 音频会话被中断（来电/Siri 等），等待结束后续播")
                self.player?.pause()
            } else if typeValue == .ended {
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0.uintValue) } ?? []
                NSLog("[LCStage][保活] 中断结束，恢复静音音轨（shouldResume=\(options.contains(.shouldResume))）")
                // Restart unconditionally: our own audio must resume regardless of the option.
                self.hardRestart()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[LCStage][保活] 系统媒体服务重置，重建静音音轨")
            self?.hardRestart()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            if reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                || reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                || reason == AVAudioSession.RouteChangeReason.wakeFromSleep.rawValue {
                NSLog("[LCStage][保活] 音频路由变化（reason=\(reason)），确认音轨仍在播放")
                if self.engine?.isRunning != true { self.hardRestart() }
            }
        })
    }

    private func unregisterObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func hardRestart() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isRunning = false
        start()
    }
}

// MARK: - Real keep-alive location (host, primary channel)

/// STRONGEST of the three host-side background assertions: an app that is continuously using
/// location is treated by the system like a navigation app and is the last process jetsam reaps
/// under memory pressure. It is independent of AVAudioSession, so a native app (WeChat voice
/// message, phone call) that interrupts or suspends our playback cannot touch this assertion.
///
/// Battery is kept minimal: desiredAccuracy is Best (which also makes iOS treat the session as
/// navigation-level, showing the status-bar arrow less), while distanceFilter is essentially
/// infinite so the GPS radio is not actually woken up to fix positions. We never read the
/// coordinates; the session itself is the point.
@available(iOS 16.0, *)
private final class StageLocationKeepAlive: NSObject {
    static let shared = StageLocationKeepAlive()

    private let manager = CLLocationManager()
    private var isArmed = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func arm() {
        guard !isArmed else { return }
        isArmed = true
        guard CLLocationManager.locationServicesEnabled() else {
            NSLog("[LCStage][保活] 定位通道待命，但系统定位服务未开启（音轨+PiP 继续兜底）")
            return
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Effectively "never actually move": do not wake the GPS radio to fix positions, only keep
        // the continuous-location session alive.
        manager.distanceFilter = 999_999
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        switch manager.authorizationStatus {
        case .notDetermined:
            // First stage entry: ask for Always directly. iOS may grant WhenInUse first and
            // re-prompt for Always later; didChangeAuthorization starts updates for either.
            manager.requestAlwaysAuthorization()
            NSLog("[LCStage][保活] 定位通道请求「始终允许」权限")
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            NSLog("[LCStage][保活] 定位通道已启动（\(manager.authorizationStatus == .authorizedAlways ? "始终" : "使用期间")）")
        case .restricted, .denied:
            NSLog("[LCStage][保活] 定位权限被拒绝，定位通道不可用（音轨+PiP 继续兜底）")
        @unknown default:
            manager.requestAlwaysAuthorization()
        }
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        manager.stopUpdatingLocation()
        NSLog("[LCStage][保活] 定位通道已关闭")
    }

    // Coordinates are irrelevant — the delegate only exists to drive the session lifecycle.
    private func beginUpdatesIfPossible(_ status: CLAuthorizationStatus) {
        guard isArmed else { return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            // startUpdatingLocation is idempotent; this also covers the WhenInUse → Always upgrade.
            manager.startUpdatingLocation()
            NSLog("[LCStage][保活] 定位权限变为已授权，定位通道启动")
        case .denied, .restricted:
            NSLog("[LCStage][保活] 定位权限被关闭，定位通道失效（音轨+PiP 继续兜底）")
        default: break
        }
    }
}

@available(iOS 16.0, *)
extension StageLocationKeepAlive: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        beginUpdatesIfPossible(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient errors (no fix available etc.) must not stop the session; the manager keeps
        // trying and the background assertion stands.
        NSLog("[LCStage][保活] 定位回调错误（不影响保活会话）: \(error)")
    }
}

// MARK: - Real keep-alive PiP (host, second channel)

/// Second, INDEPENDENT background assertion: an always-playing 1pt black "video" makes the system
/// treat LiveContainer as a Picture-in-Picture app, so when the host leaves the foreground iOS
/// opens a PiP session automatically (canStartPictureInPictureAutomaticallyFromInline) and grants
/// the PiP background assertion. It runs in parallel with StageAudioKeepAlive: when a phone call
/// or another app kills the audio assertion the PiP assertion still stands, and when another app's
/// own PiP (e.g. a video call) pushes ours out, the audio assertion keeps the host runnable.
///
/// The feed is 1 frame/second: the assertion only requires a live session, and this feed goes into
/// a private 0.1pt AVSampleBufferDisplayLayer — it has nothing to do with the guest windows' render
/// pipeline, so it never caps their ProMotion 120Hz.
///
/// Invisibility trick: the PiP window's SHAPE follows the aspect ratio of the enqueued video
/// buffers. A 1×1 buffer produced a large 1:1 black square. We feed a 2048×2 (1024:1) buffer, so at
/// the system's minimum PiP width the window is a sub-point black hairline tucked in a screen
/// corner — effectively invisible. The user can still drag it to the edge to magnetize it.
@available(iOS 16.0, *)
private final class StagePiPKeepAlive: NSObject {
    static let shared = StagePiPKeepAlive()

    /// Ultra-wide, near-zero-height feed. The exact numbers only need to survive CVPixelBuffer
    /// creation and describe an extreme aspect ratio; content is pure black.
    private static let feedWidth = 2048
    private static let feedHeight = 2

    private var hostView: UIView?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var feedTimer: Timer?
    private var pixelBuffer: CVPixelBuffer?
    private var formatDescription: CMVideoFormatDescription?
    private var frameCount: Int64 = 0
    private var isArmed = false
    private var retryWorkItem: DispatchWorkItem?
    private var retriesLeft = 0

    private static let feedInterval: TimeInterval = 1.0
    private static let maxRetries = 6
    private static let retryInterval: TimeInterval = 5

    private override init() { super.init() }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isPiPActive: Bool { pipController?.isPictureInPictureActive ?? false }

    /// Turns the channel on. The invisible layer attaches on the next layout pass (attach(to:)).
    func arm() {
        guard isSupported, !isArmed else { return }
        isArmed = true
        NSLog("[LCStage][保活] PiP 第二通道已待命（黑帧 1fps，退后台自动开小窗）")
    }

    /// Mounts the 1pt black layer into the stage window. Idempotent across layout passes and
    /// key-window changes.
    func attach(to window: UIWindow) {
        guard isArmed else { return }
        if let hostView, hostView.window === window, pipController != nil { return }
        teardownViews()

        let view = UIView(frame: CGRect(x: 0.1, y: window.bounds.maxY - 0.2, width: 0.1, height: 0.1))
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        // Stay glued to the bottom-leading corner on rotation/resizes.
        view.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        layer.videoGravity = .resize
        view.layer.addSublayer(layer)
        window.addSubview(view)
        hostView = view
        displayLayer = layer

        setupBlackFrame()
        setupController(with: layer)
        startFeeding()
    }

    /// Turns the channel off and removes every trace: stops PiP, the feed and the 1pt view.
    func disarm() {
        guard isArmed else { return }
        isArmed = false
        retryWorkItem?.cancel()
        retriesLeft = 0
        pipController?.stopPictureInPicture()
        teardownViews()
        NSLog("[LCStage][保活] PiP 第二通道已关闭")
    }

    /// Called at host willResignActive: the automatic-from-inline mechanism normally opens PiP by
    /// itself; this is a belt-and-braces explicit nudge while a start is still possible.
    func nudgeStart() {
        guard isArmed, let pip = pipController else { return }
        if !pip.isPictureInPictureActive, pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    private func teardownViews() {
        feedTimer?.invalidate()
        feedTimer = nil
        pipController = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        hostView?.removeFromSuperview()
        hostView = nil
        pixelBuffer = nil
        formatDescription = nil
        frameCount = 0
    }

    private func setupBlackFrame() {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Self.feedWidth, Self.feedHeight,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let buffer = pb else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer)) // pure black
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        pixelBuffer = buffer
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(Self.feedWidth), height: Int32(Self.feedHeight),
                                       extensions: nil,
                                       formatDescriptionOut: &formatDescription)
    }

    private func setupController(with layer: AVSampleBufferDisplayLayer) {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        // The key entitlement: with this set, the system opens PiP ITSELF when the app goes
        // background, no user tap required.
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
    }

    private func startFeeding() {
        feedTimer?.invalidate()
        let timer = Timer(timeInterval: Self.feedInterval, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
        // .common keeps feeding while a window is being dragged; the layer must already be
        // "playing" in the foreground for automatic PiP to be permitted.
        RunLoop.main.add(timer, forMode: .common)
        feedTimer = timer
        timer.fire()
    }

    private func emitFrame() {
        guard let layer = displayLayer else { return }
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData,
              let pb = pixelBuffer, let fmt = formatDescription else { return }
        frameCount += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(value: frameCount, timescale: 1),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pb,
                                                 formatDescription: fmt,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        if let sample { layer.enqueue(sample) }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isArmed else { return }
            if let pip = self.pipController, !pip.isPictureInPictureActive {
                if pip.isPictureInPicturePossible {
                    NSLog("[LCStage][保活] PiP 被挤掉，尝试重拉（剩余 \(self.retriesLeft) 次）")
                    pip.startPictureInPicture()
                } else if self.retriesLeft > 0 {
                    // Transition still settling: consume one slot and try again later. Total
                    // attempts stay bounded (maxRetries × retryInterval); a long-lived foreign PiP
                    // (video call) simply leaves the audio channel covering us.
                    self.scheduleRetry()
                }
            }
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval, execute: work)
    }
}

@available(iOS 16.0, *)
extension StagePiPKeepAlive: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        retriesLeft = 0
        NSLog("[LCStage][保活] PiP 小窗已启动，第二通道断言生效")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        NSLog("[LCStage][保活] PiP 启动失败（音频通道仍在兜底）: \(error)")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        // Another app's PiP (video call etc.) can push ours out. Retry a few times; the audio
        // channel covers every gap, so this is best-effort only.
        guard isArmed, UIApplication.shared.applicationState != .active else { return }
        retriesLeft = Self.maxRetries
        scheduleRetry()
    }
}

@available(iOS 16.0, *)
extension StagePiPKeepAlive: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    // Xcode 26 SDK imports pictureInPictureControllerTimeRangeForPlayback: with no first
    // argument label (older SDKs imported it as timeRange(forPlayback:)).
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Infinite live range: the last black frame keeps the session alive without a constant feed.
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }
}

// MARK: - Stage manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()

    /// Running apps in stage order: index 0 is the main window, 1...3 are the side windows.
    @Published var apps: [DockAppModel] = []
    @Published var isFullscreen: Bool = false

    /// Thread-safe stage membership check for background callers (the orphan reaper runs on a
    /// background async context). Hopping to the main thread also guarantees the UI-heavy
    /// `shared` singleton is never first initialised off the main thread.
    @objc public static func isWindowOnStage(_ appUUID: String) -> Bool {
        let check = { shared.apps.contains { $0.appUUID == appUUID } }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    @objc public var windowHostingView = VirtualWindowsHostView()

    private var dockHost: UIHostingController<AnyView>?
    /// The four fixed glass controls, mounted directly on the key window:
    //  leading cluster — zoom, left/right swap, back-to-LiveContainer; trailing cluster — close.
    //  Their positions never follow the left/right mirror; only the window geometry mirrors.
    private lazy var zoomButton: MultitaskStageGlassButton = {
        let button = MultitaskStageGlassButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            pressedTint: nil
        )
        button.accessibilityLabel = "lc.multitask.zoomWindow".loc
        button.addTarget(self, action: #selector(stageControlsDidTapZoom), for: .touchUpInside)
        return button
    }()
    private lazy var swapButton: MultitaskStageGlassButton = {
        let button = MultitaskStageGlassButton(
            glyphImage: MultitaskStageSwapGlyph.makeImage(),
            pressedTint: nil
        )
        button.accessibilityLabel = "lc.multitask.toggleHandedness".loc
        button.addTarget(self, action: #selector(toggleLayoutHandedness), for: .touchUpInside)
        return button
    }()
    private lazy var homeButton: MultitaskStageGlassButton = {
        let button = MultitaskStageGlassButton(symbol: "house", pressedTint: nil)
        button.accessibilityLabel = "lc.multitask.backToLiveContainer".loc
        button.addTarget(self, action: #selector(returnToLauncher), for: .touchUpInside)
        return button
    }()
    private lazy var closeButton: MultitaskStageGlassButton = {
        let button = MultitaskStageGlassButton(
            symbol: "xmark",
            // Translucent red, not solid: the control reads as a red piece of glass rather than
            // a red sticker.
            pressedTint: UIColor.systemRed.withAlphaComponent(0.82)
        )
        button.accessibilityLabel = "lc.multitask.closeWindow".loc
        button.addTarget(self, action: #selector(stageControlsDidTapClose), for: .touchUpInside)
        return button
    }()
    /// The stage's frame-rate readout, in the strip's trailing corner beside the close button.
    private let fpsCounter = MultitaskStageFPSCounterView(frame: .zero)
    /// Every leading-cluster control in layout order, so mount/layout/visibility loops stay one line.
    private var leadingButtons: [MultitaskStageGlassButton] { [zoomButton, swapButton, homeButton] }
    /// All glass controls, for backdrop glyph-color forwarding and z-ordering.
    private var allChromeButtons: [MultitaskStageGlassButton] {
        [zoomButton, swapButton, homeButton, closeButton]
    }
    /// Reused impact generators: allocating one per tap puts Taptic engine setup on the hot path,
    /// which is exactly what a fast run of window switches does not need.
    private lazy var switchFeedback = UIImpactFeedbackGenerator(style: .light)
    private lazy var closeFeedback = UIImpactFeedbackGenerator(style: .rigid)

    /// Highest-level invisible window that routes touches for the stage. Side-window touches are
    /// captured in UIApplication.sendEvent (hooked in UIKitHooks.m), because the system-level
    /// hosted-view touch delivery bypasses the regular UIKit hit-test chain, while the main
    /// window's touches are forwarded straight through.

    /// The stage page's own surface: a light scrim over the launcher. The stage is a page, and the gap
    /// that opens between two cards while they trade places has to read as the desktop behind them —
    /// dimmed, never the launcher's own brightness.
    private let stageBackdrop = UIView()
    /// A single dark plate shaped exactly like the settled window block, one layer above the page
    /// backdrop and one layer below every shadow caster and card. Cards cover it completely at
    /// rest; it only exists to own the seam that opens between two cards trading sides during a
    /// left/right mirror swap (that seam used to flash the launcher-toned host surface).
    private let blockPlate = UIView()
    /// One shadow caster per window, all of them below every card.
    ///
    /// The stage used to have a single black plate behind the block, casting one shadow for all four
    /// windows. That plate painted the four tiled windows as one object instead of four cards, and the
    /// moment two of them started moving it was the plate — a black rectangle — that showed through
    /// the gap, which is exactly what stops the switch from reading as apps changing places. A caster
    /// per card puts the elevation where it belongs: the shadow follows its own window, the settled
    /// block still shows a single outer contour (each card covers the others' casters), and no caster
    /// can ever draw on a neighbour, because every one of them sits below every card.
    private var windowShadowCasters: [String: UIView] = [:]

    /// Whether the stage page (background, windows, controls, dock) is currently on screen.
    /// The stage is a page of its own, not a permanent overlay: it fades in when the first app
    /// launches and fades out together with the dock once the last window closes.
    private var isStagePresented = false
    /// Token of the layout animation currently in flight. Every animated layout pass bumps it and
    /// only the newest pass may settle. Replacing the running animation instead of dropping the new
    /// request is what makes a fast run of switches feel like one continuous motion; the token is
    /// what keeps that safe, because a replaced animation still reports its completion and a stale
    /// settle would re-run the whole layout pass behind the user's back.
    private var layoutToken: UInt = 0
    /// Stage state at the moment of the last settle, so the hosted scene's touch region is only
    /// re-registered when the main window actually changed (fullscreen toggle or promotion).
    private var lastSettledFullscreen: Bool?
    private var lastSettledMainUUID: String?
    /// True between arming a geometry commit and settling it. See armGeometryCommitIfNeeded().
    /// Replaced the old Bool flag with a generation counter: each relayout increments it, so
    /// a stale settle callback (from an animation that finished after a newer one was armed) can
    /// tell it's out of date and discard itself instead of clobbering the newer commit's state.
    private var pendingGeometryGeneration: UInt = 0
    /// The generation that settleAfterAnimation observed last time it ran. Used to detect
    /// double-fires from overlapping animators (beginFromCurrentState + a second arm).
    private var lastSettledGeneration: UInt = 0
    /// The role state the guests were last told about, and when. Repeated publishes of the same
    /// state inside one refresh interval are skipped: they cost a disk write each and wake every
    /// guest, and a fast run of switches asks for the same state three times per tap.
    private var lastPublishedRoles: (active: Bool, uuid: String?)?
    private var lastPublishedRolesAt = Date.distantPast
    private static let roleRepublishInterval: TimeInterval = 1.0
    /// Last frame-ready timestamp handled per window, so a re-delivered Darwin notification
    /// never re-runs the reveal animation.
    private var lastFrameReadyAt: [String: Double] = [:]
    /// Whether the stage currently keeps the screen on and the host alive in the background.
    private var isKeepAliveActive = false
    /// YES between host willResignActive and willEnterForeground while foreground pinning is on: the
    /// escalating re-pin scheduler is running.
    private var isPinningForeground = false
    private var foregroundPinningTimer: Timer?
    /// Set at foreground return when pinning handled the background stay; the main window's geometry commit
    /// is then deferred until the pixel-verified frame-ready reveal (or a 3s backstop) instead of
    /// racing the reconnecting surface and contributing its own black frame.
    private var pendingWakeGeometryCommit = false
    private var backgroundingBeganAt = Date.distantPast
    /// Per-control backdrop sampler state for adaptive glyph tinting. Each glass control maps
    /// its own on-screen centre into the main guest's published luma GRID, so a control tinted
    /// by the dark strip it actually floats over stays white even when the rest of the app is
    /// light. Keyed by button; value == "background behind this control is dark". Empty while
    /// unprobed.
    private var backdropProbeTimer: Timer?
    private var backdropButtonDark: [ObjectIdentifier: Bool] = [:]
    /// YES while the stage is visually collapsed to the LiveContainer app list (back-to-LiveContainer
    /// button). Guests, keep-alive and the watchdog all keep running; only the stage surfaces and
    /// chrome are hidden. Tapping a staged app in the list re-enters and clears this flag.
    private var isStageCollapsed = false
    /// Controllers of windows the user just dismissed from the chrome. The card and model are
    /// gone on the same frame as the tap; these stay retained only until the guest process has
    /// finished terminating (its 2.5s termination backstop timer lives on the controller).
    private var closingControllers: [DecoratedAppSceneViewController] = []
    /// Extra ~30s of foreground-style runtime bought at the moment we go to the background.
    /// The playback assertion is the long-term keeper; this task bridges the handoff so the
    /// freeze-frame IPC and guest engine arming always complete even on slow devices.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Last time the host entered (or was confirmed in) the foreground. Heartbeat pruning is
    /// suppressed for a grace window after that, because suspension freezes every guest timer
    /// and a fresh resume would otherwise look like all four guests died at once.
    private var lastHostWakeAt = Date()
    /// A dead guest is allowed this long to relaunch into its slot before the slot is dropped.
    private static let recoveryTimeout: TimeInterval = 25

    private static let layoutAnimationDuration: TimeInterval = 0.4

    override init() {
        super.init()
        migrateKeepAliveDefaultsOnce()
        if let rootView = keyWindow?.rootViewController?.view {
            // The windows live inside the app's own hierarchy; the controls and the dock sit on
            // the window itself so they are always drawn above every guest window.
            // The stage only becomes a page once a window exists, so it starts out hidden.
            windowHostingView.isHidden = true
            (rootView.subviews.first ?? rootView).addSubview(self.windowHostingView)
        }

        // The page surface is the bottom-most layer: cards, their shadow casters and the dock all sit
        // above it. It is a plain scrim rather than a material on purpose — a full-stage live blur
        // would be recomputed on every frame of every switch, and a static fill costs nothing.
        stageBackdrop.isUserInteractionEnabled = false
        stageBackdrop.isHidden = true
        stageBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        windowHostingView.addSubview(stageBackdrop)

        // The seam plate rides just above the page backdrop. Cards and their per-card shadow
        // casters are always inserted above it (see shadowCaster(for:)).
        blockPlate.isUserInteractionEnabled = false
        blockPlate.isHidden = true
        blockPlate.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        blockPlate.layer.cornerRadius = MultitaskStageLayout.cornerRadius
        blockPlate.layer.cornerCurve = .continuous
        windowHostingView.addSubview(blockPlate)

        // The buttons/fpsCounter are NOT attached here: the manager can be created before any
        // key window exists, in which case these would be orphaned forever. performLayout
        // mounts them idempotently once a window is available.
        allChromeButtons.forEach { $0.isHidden = true }
        fpsCounter.isHidden = true

        setupDockView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // One-second watchdog: (1) republishes the stage role state so guests
        // never lock themselves into touch quarantine on a missed Darwin
        // notification, and (2) removes dead/detached windows even when the
        // extension exit callback was lost, so the next window refills the main
        // slot instead of leaving a black card behind.
        let watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        watchdog.tolerance = 0.5
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func deviceOrientationDidChange() {
        // faceUp/faceDown fire this notification too, but the geometry does not change for them:
        // don't run a spring + settle layout pass when the user merely lays the phone flat.
        guard UIDevice.current.orientation.isValidInterfaceOrientation else { return }
        relayout(animated: true)
    }

    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))?.keyWindow
        ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    private func setupDockView() {
        DispatchQueue.main.async {
            let host = UIHostingController(rootView: AnyView(
                MultitaskStageDockSwiftView().environmentObject(self)
            ))
            host.view.backgroundColor = .clear
            host.view.isHidden = true
            // Attached by performLayout (idempotent mounting) — the key window can differ here.
            self.dockHost = host

            // The stage only becomes a page once a window exists, so it starts out hidden.
            self.windowHostingView.isHidden = true
            self.performLayout(animated: false)
        }
    }

    // MARK: - Stage layout

    @objc public func relayout(animated: Bool) {
        relayout(animated: animated, mirroring: false)
    }

    /// Mirroring relayout (left/right swap): only the cards fly; the chrome/dock/backdrop writes
    /// are frozen for the flight and corner masks swap after landing, so no seam or dock block
    /// flashes during the swap.
    func relayout(animated: Bool, mirroring: Bool) {
        DispatchQueue.main.async {
            self.performLayout(animated: animated, mirroring: mirroring)
        }
    }

    private func performLayout(animated: Bool, mirroring: Bool = false) {
        guard let window = keyWindow else { return }

        // Idempotent (re)mounting of the always-on-top views. The manager may have been born
        // before any window existed, or the key window may have changed since; attach only
        // when the view isn't already hosted by the current window.
        for button in allChromeButtons where button.superview !== window {
            button.removeFromSuperview()
            window.addSubview(button)
        }
        if fpsCounter.superview !== window {
            fpsCounter.removeFromSuperview()
            window.addSubview(fpsCounter)
        }
        // The invisible 1pt PiP layer must live in a real on-screen window while the PiP channel
        // is ARMED. v4.1.2 keeps PiP a backup channel: when the toggle is off no layer,
        // timer or video session is ever created (zero overhead).
        if keepAlivePiPEnabled {
            StagePiPKeepAlive.shared.attach(to: window)
        }
        if let dockView = dockHost?.view, dockView.superview !== window {
            dockView.removeFromSuperview()
            window.addSubview(dockView)
        }

        let bounds = window.bounds
        let safeArea = window.safeAreaInsets
        let count = apps.count

        // Whatever a previous teardown left in the hierarchy must never cover the windows that
        // are live right now — this also runs on the way out, when the last window closed.
        removeOrphanWindowViews()

        guard count > 0 else {
            // Last window closed: drop any shadow casters the update closure would otherwise
            // have no chance to clean (it doesn't run on this path).
            windowShadowCasters.values.forEach { $0.removeFromSuperview() }
            windowShadowCasters.removeAll()
            blockPlate.isHidden = true
            // Leave the stage page and go back to the launcher. The dock,
            // controls and stage background all leave together, so nothing is left floating on
            // top of LiveContainer's own UI.
            if isStagePresented {
                dismissStage()
            }
            // No guests on stage any more: release the screen-on lock and the background
            // audio session so the phone behaves normally again.
            updateStageKeepAlive(active: false)
            // Release every guest from side-window touch quarantine.
            publishStageRoles(active: false)
            return
        }

        // First window: the stage page enters as a whole on top of the launcher.
        let entering = !isStagePresented
        if entering {
            // Keep the screen on and the host (and therefore every guest process) alive in the
            // background while the stage exists: auto-lock is what suspended and killed guests
            // in the middle of a session.
            updateStageKeepAlive(active: true)
            // Control glyphs must track the guest content behind them (white on dark video,
            // dark on light apps): start the low-frequency backdrop sampler with the page.
            startBackdropProbe()
        }
        isStagePresented = true
        // While collapsed to the launcher every stage surface stays hidden; it is revealed
        // again by reenterStage(), not by a routine layout pass.
        windowHostingView.isHidden = isStageCollapsed
        stageBackdrop.isHidden = isStageCollapsed
        // The seam plate is only ever shown for the duration of a mirror flight; a routine
        // layout keeps it hidden so it can never show through the unfilled slots of a stage
        // that has fewer than four windows.
        blockPlate.isHidden = true
        dockHost?.view.isHidden = isStageCollapsed
        if entering {
            windowHostingView.alpha = 0
            dockHost?.view.alpha = 0
        }

        // The shadow paths ride along with whatever motion this pass uses — the stage's own spring, or
        // nothing at all. A path that has already reached its size while its window is still on the
        // way reads as a halo around the card, so the two travel together; the cross-dissolve pass
        // moves no geometry at all, so its paths snap with it.
        let shadowPathDuration: TimeInterval = (animated && !UIAccessibility.isReduceMotionEnabled)
            ? MultitaskDockManager.layoutAnimationDuration
            : 0
        // Corner masks swap sides on a mirror. During the spring flight they are deferred to the
        // settle pass (a mid-flight swap draws a contour line on the shared edge); the Reduce
        // Motion cross-dissolve has no flight — cards land instantly — so the mask must snap at
        // once there.
        let deferCornerMasks = mirroring && animated && !UIAccessibility.isReduceMotionEnabled

        let update = { [weak self] in
            guard let self else { return }
            // Drop crashed/detached windows before laying out, so the next app
            // slides into the main slot on this same layout pass.
            self.pruneDeadWindows()

            for (index, app) in self.apps.enumerated() {
                guard let view = app.view else { continue }
                let fullscreen = self.isFullscreen && index == 0
                let frame = fullscreen
                    ? MultitaskStageLayout.fullscreenFrame(bounds: bounds, safeArea: safeArea)
                    : MultitaskStageLayout.slotFrame(index, bounds: bounds, safeArea: safeArea)
                let ratio = fullscreen
                    ? 1.0
                    : MultitaskStageLayout.slotScaleRatio(index, bounds: bounds, safeArea: safeArea)

                (view._viewDelegate() as? DecoratedAppSceneViewController)?
                    .applyStageFrame(frame, scaleRatio: ratio, maximized: fullscreen, isMainWindow: index == 0)

                view.isHidden = false
                // Corner, border and frame all change in the same block so the layer animates
                // the radius instead of snapping it the moment fullscreen toggles.
                view.layer.cornerCurve = .continuous
                view.layer.borderColor = UIColor.separator.cgColor
                if fullscreen {
                    view.layer.cornerRadius = 0
                    view.layer.maskedCorners = MultitaskStageLayout.allCorners
                    view.layer.borderWidth = 0
                } else {
                    view.layer.cornerRadius = MultitaskStageLayout.cornerRadius
                    // While the cards trade sides, the corner mask has to swap sides too. Writing
                    // it at the START of a spring flight draws a hard contour line along the
                    // shared edge for the whole animation; keep the old mask in flight and let the
                    // settle pass snap the new one the moment the cards have arrived.
                    if !deferCornerMasks {
                        view.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
                    }
                    view.layer.borderWidth = MultitaskStageLayout.hairline
                }
            }

            // The main window has to end up frontmost, so front the slots back to front.
            for app in self.apps.reversed() {
                if let view = app.view {
                    self.windowHostingView.bringSubviewToFront(view)
                }
            }
            self.windowHostingView.sendSubviewToBack(self.stageBackdrop)
            // Keep the seam plate directly above the page backdrop and below every caster/card.
            self.windowHostingView.insertSubview(self.blockPlate, aboveSubview: self.stageBackdrop)

            // Page surface + seam plate. During a mirror swap these (and the chrome below) must
            // not animate inside the cards' spring: their values are identical, yet re-writing
            // them in the spring block made the backdrop layer and the hosting-backed dock flash
            // as a whole block for the length of the swap.
            let backdropUpdates = {
                self.stageBackdrop.frame = bounds
                // Fullscreen belongs to the guest app: the page surface leaves with the strip, so nothing
                // dims the app while it owns the screen.
                self.stageBackdrop.alpha = self.isFullscreen ? 0 : 1
                self.blockPlate.frame = MultitaskStageLayout.blockFrame(bounds: bounds, safeArea: safeArea)
                // Only a mirror flight needs the seam plate; the settle pass runs non-mirrored and
                // hides it again the moment the cards arrive.
                self.blockPlate.isHidden = !mirroring
            }
            if mirroring {
                UIView.performWithoutAnimation(backdropUpdates)
            } else {
                backdropUpdates()
            }

            // Every card carries its own shadow, laid out from the frames written just above so the
            // casters animate in the same block as the cards: the shadow of a window that is moving
            // stays welded to it, and the gap the two cards leave between them shows the page surface
            // with each card's own elevation on it — the way two apps changing places should look.
            for app in self.apps {
                guard let view = app.view else { continue }
                let caster = self.shadowCaster(
                    for: app.appUUID,
                    cardFrame: view.frame,
                    pathDuration: shadowPathDuration
                )
                // Fullscreen: the main card covers the screen, so its shadow would only cost frames.
                caster.alpha = self.isFullscreen ? 0 : 1
            }
            // A closed window takes its caster with it.
            let liveUUIDs = Set(self.apps.map { $0.appUUID })
            for staleUUID in self.windowShadowCasters.keys.filter({ !liveUUIDs.contains($0) }) {
                self.windowShadowCasters.removeValue(forKey: staleUUID)?.removeFromSuperview()
            }

            // Fixed chrome clusters. Zoom lives through fullscreen (it is the restore control
            // there); swap / home / close / FPS belong to the split stage only. While collapsed
            // to the launcher the whole strip is hidden.
            let chromeUpdates = {
                let stripVisible = !self.isFullscreen && !self.isStageCollapsed
                self.zoomButton.isHidden = self.isStageCollapsed
                self.zoomButton.frame = MultitaskStageLayout.leadingControlFrame(0, bounds: bounds, safeArea: safeArea)
                self.zoomButton.alpha = self.isStageCollapsed ? 0 : 1
                self.zoomButton.isUserInteractionEnabled = !self.isStageCollapsed
                self.zoomButton.setSymbol(self.isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                self.zoomButton.accessibilityLabel = (self.isFullscreen
                    ? "lc.multitask.restoreWindow"
                    : "lc.multitask.zoomWindow").loc

                for (ordinal, button) in self.leadingButtons.dropFirst().enumerated() {
                    button.isHidden = !stripVisible
                    button.frame = MultitaskStageLayout.leadingControlFrame(
                        ordinal + 1, bounds: bounds, safeArea: safeArea)
                    button.alpha = stripVisible ? 1 : 0
                    button.isUserInteractionEnabled = stripVisible
                }

                self.closeButton.isHidden = !stripVisible
                self.closeButton.frame = MultitaskStageLayout.closeButtonFrame(bounds: bounds, safeArea: safeArea)
                self.closeButton.alpha = stripVisible ? 1 : 0
                self.closeButton.isUserInteractionEnabled = stripVisible

                // The readout belongs to the split stage: fullscreen is the guest app's screen, so the
                // counter leaves with the strip — and stops sampling, instead of ticking away on a
                // number nobody can see.
                self.fpsCounter.isHidden = !stripVisible
                self.fpsCounter.frame = MultitaskStageLayout.fpsFrame(bounds: bounds, safeArea: safeArea)
                self.fpsCounter.alpha = stripVisible ? 1 : 0
                self.fpsCounter.isCounting = stripVisible

                if let dockView = self.dockHost?.view {
                    // Fullscreen means the guest app owns the whole screen, dock included.
                    dockView.isHidden = self.isStageCollapsed
                    dockView.alpha = self.isFullscreen ? 0 : 1
                    dockView.frame = MultitaskStageLayout.dockFrame(bounds: bounds, safeArea: safeArea)
                }
            }
            // The chrome never moves on a mirror swap (it is fixed to the screen edges). Writing
            // it inside the spring nevertheless re-ran the SwiftUI dock hosting layout and faded
            // the whole dock block for the flight; freeze it instead.
            if mirroring {
                UIView.performWithoutAnimation(chromeUpdates)
            } else {
                chromeUpdates()
            }
        }

        if animated && UIAccessibility.isReduceMotionEnabled {
            armGeometryCommitIfNeeded()
            layoutToken &+= 1
            let token = layoutToken
            UIView.transition(with: windowHostingView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
            UIView.animate(withDuration: 0.2) {
                self.dockHost?.view.alpha = self.isFullscreen ? 0 : 1
                self.fpsCounter.alpha = (self.isFullscreen || self.isStageCollapsed) ? 0 : 1
                for button in self.allChromeButtons {
                    button.alpha = button === self.zoomButton
                        ? (self.isStageCollapsed ? 0 : 1)
                        : (self.isFullscreen || self.isStageCollapsed ? 0 : 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.layoutToken == token else { return }
                self.settleAfterAnimation()
            }
        } else if animated {
            armGeometryCommitIfNeeded()
            layoutToken &+= 1
            let token = layoutToken
            // One spring, started from the values that are on screen at this instant. That is what
            // lets a switch arriving mid-flight take the motion over instead of being dropped: the
            // new pass re-targets the same cards from where they are, so a fast run of switches
            // reads as one continuous reflow — and the layout pass itself, which is the expensive
            // part, runs once per switch instead of once more when the animation settles.
            UIView.animate(
                withDuration: MultitaskDockManager.layoutAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: update
            ) { [weak self] _ in
                guard let self, self.layoutToken == token else { return }
                self.settleAfterAnimation()
            }
        } else {
            update()
        }

        if entering {
            // Cross-fade the whole page in, independently of the slot layout inside it. Reset
            // the alphas after `update` ran (it sets the settled alphas) so the fade always
            // starts from 0.
            let dockTargetAlpha: CGFloat = isFullscreen ? 0 : 1
            windowHostingView.alpha = 0
            dockHost?.view.alpha = 0
            fpsCounter.alpha = 0
            allChromeButtons.forEach { $0.alpha = 0 }
            UIView.animate(withDuration: 0.22, delay: 0, options: .allowUserInteraction) {
                self.windowHostingView.alpha = 1
                self.dockHost?.view.alpha = dockTargetAlpha
                self.fpsCounter.alpha = self.isFullscreen ? 0 : 1
                self.zoomButton.alpha = 1
                self.leadingButtons.dropFirst().forEach { $0.alpha = self.isFullscreen ? 0 : 1 }
                self.closeButton.alpha = self.isFullscreen ? 0 : 1
            }
        }

        allChromeButtons.forEach { window.bringSubviewToFront($0) }
        window.bringSubviewToFront(fpsCounter)
        if let dockView = dockHost?.view {
            window.bringSubviewToFront(dockView)
        }

        // Tell every guest who the main window is. Side windows quarantine
        // their own touches; the main window keeps full interactivity.
        publishStageRoles(active: true)
    }

    /// Creates or updates the shadow caster that follows one window, and returns it.
    ///
    /// A card cannot cast its own shadow: it clips its content to its corner radius, and clipping
    /// takes the shadow with it. So every window gets an invisible twin — same frame, same corner
    /// radius, nothing inside — that sits below every card and carries nothing but the elevation.
    ///
    /// The path is the part that has to keep up with the window. A shadowPath is a fixed shape, so
    /// if it were simply replaced while the window animates, the promoted card would wear its old
    /// shadow for the length of the switch: a soft halo the size the window used to be, hanging in
    /// the very gap the switch is opening. Instead the path animates from the shape the caster is
    /// showing at this instant (the presentation value, not the last target), which is also what
    /// keeps a fast run of switches seamless — an interrupted caster continues from where its
    /// shadow actually is. pathDuration 0 means this pass moves no geometry (a plain layout, or the
    /// cross-dissolve the Reduce Motion setting uses) and the path snaps along with everything else.
    private func shadowCaster(for appUUID: String, cardFrame: CGRect, pathDuration: TimeInterval) -> UIView {
        let caster: UIView
        if let existing = windowShadowCasters[appUUID] {
            caster = existing
        } else {
            caster = UIView(frame: cardFrame)
            caster.isUserInteractionEnabled = false
            caster.backgroundColor = .clear
            caster.layer.masksToBounds = false
            caster.layer.shadowColor = UIColor.black.cgColor
            caster.layer.shadowOpacity = 0.32
            caster.layer.shadowOffset = CGSize(width: 0, height: 6)
            caster.layer.shadowRadius = 16
            windowShadowCasters[appUUID] = caster
            windowHostingView.insertSubview(caster, aboveSubview: blockPlate)
        }

        // The path only needs work when the card it follows changed size. Position is the layer's
        // own business, so a window that only moved keeps the path it has.
        if caster.layer.shadowPath == nil || caster.frame.size != cardFrame.size {
            let path = CGPath(
                roundedRect: CGRect(origin: .zero, size: cardFrame.size),
                cornerWidth: MultitaskStageLayout.cornerRadius,
                cornerHeight: MultitaskStageLayout.cornerRadius,
                transform: nil
            )
            let fromPath = caster.layer.presentation()?.shadowPath
            // Write the model value without letting the transaction animate it on its own; the
            // animation below is the one that decides where the shadow starts from.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caster.layer.shadowPath = path
            CATransaction.commit()

            if pathDuration > 0, let fromPath {
                let pathAnimation = CABasicAnimation(keyPath: "shadowPath")
                pathAnimation.fromValue = fromPath
                pathAnimation.toValue = path
                pathAnimation.duration = pathDuration
                // A close stand-in for the stage's spring: both start and end at rest. The shadow
                // only has to stay the right size to the eye, and matching the size matters far more
                // than matching the curve.
                pathAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.2, 1)
                caster.layer.add(pathAnimation, forKey: "shadowPath")
            }
        }

        caster.frame = cardFrame
        return caster
    }

    /// Publishes the stage role state (active flag + main window UUID) that the
    /// guest processes read to decide whether to quarantine their touches.
    private func publishStageRoles(active: Bool) {
        guard isDockEnabled() else {
            publishRolesIfChanged(active: false, uuid: nil)
            return
        }
        publishRolesIfChanged(active: active, uuid: active ? apps.first?.appUUID : nil)
    }

    /// Writes the roles out only when they actually changed, or when the last write is old enough
    /// that the watchdog's refresh is due.
    ///
    /// Publishing is not free: it writes three keys into the shared defaults, synchronizes them to
    /// disk and wakes every guest with a Darwin notification. One switch used to publish up to three
    /// times for a single tap (the tap, the layout it starts and the settle), and at three keys plus
    /// a disk sync each that is the kind of work that heats a phone up when the user taps quickly.
    /// Skipping the identical ones is safe: the guest's staleness window is five seconds and the
    /// watchdog republishes once a second, so a role change is still seen immediately and a
    /// missed notification still heals well inside that window.
    private func publishRolesIfChanged(active: Bool, uuid: String?, force: Bool = false) {
        if !force,
           let last = lastPublishedRoles, last.active == active, last.uuid == uuid,
           Date().timeIntervalSince(lastPublishedRolesAt) < Self.roleRepublishInterval {
            return
        }
        lastPublishedRoles = (active, uuid)
        lastPublishedRolesAt = Date()
        LCStagePublishRoles(active, uuid)
    }

    /// A window whose guest never wrote a single heartbeat once it is older than this is not
    /// "still starting" any more: TweakLoader (the only writer of the heartbeat) loads as part
    /// of the guest's own dlopen, i.e. well before the app's main() runs. No heartbeat therefore
    /// means either the guest bailed out in LCBootstrap (another process still held its
    /// container) or it died on the way up — both leave a black window that only a teardown can
    /// clear, and an orphan process that still holds the container.
    private static let guestStartGrace: TimeInterval = 20

    /// A window whose launch placeholder is still up after this long loses the cover even
    /// without a frame-ready report — guests built without TweakLoader never send one.
    /// 8 seconds: long enough for a heavy cold start, short enough that a guest without
    /// TweakLoader does not sit behind the spinner for a quarter minute.
    private static let coverBackstopInterval: TimeInterval = 8

    /// Removes windows whose guest process is dead (heartbeat stale), whose guest never came up
    /// at all, or whose view was detached without a matching model removal (lost exit callback).
    ///
    /// Every removal goes through tearDownWindow(_:reason:): dropping the model alone used to
    /// leave a live guest behind, which then kept playing audio, kept its view in the hierarchy
    /// (a black card on top of the other windows) and kept the app's container lock — making the
    /// next launch of that app bail out into another black window.
    @discardableResult
    private func pruneDeadWindows(allowHeartbeatPrune: Bool = true) -> Bool {
        let now = Date()
        var deadUUIDs: Set<String> = []
        var recoverUUIDs: Set<String> = []
        if allowHeartbeatPrune {
            let absoluteNow = CFAbsoluteTimeGetCurrent()
            for app in apps {
                // A window that just entered the stage is never pruned: its guest still has to
                // boot, and the heartbeat key may hold a previous run's timestamp until the new
                // guest writes its own (write-addressed keys survive in the App Group).
                guard now.timeIntervalSince(app.addedAt) > Self.guestStartGrace else { continue }
                // A recovery is already in flight: recoveryTimeout is enforced in watchdogTick.
                if app.isRecovering { continue }

                // Every guest writes a heartbeat once per second (UIKit+GuestHooks.m).
                let hbKey = "LCGuestHeartbeat.\(app.appUUID)"
                // The heartbeat timer runs on the guest's MAIN run loop, so a stale timestamp
                // does not prove the process is dead: a heavy game blocking its main thread,
                // a debugger pause or the system throttling a side appex all freeze the timer
                // while the process is very much alive. SIGTERM-ing that process would destroy
                // unsaved user data. getpgid is the ground truth — only collect a window whose
                // pid is actually gone; alive-but-quiet windows stay on the stage.
                let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController
                let processAlive = decorated?.appSceneVC.isAppRunning ?? false
                let heartbeatFresh: Bool = {
                    guard let last = LCUtils.appGroupUserDefault.object(forKey: hbKey) as? Double else { return false }
                    return absoluteNow - last <= 10
                }()
                // After a successful recovery the attempts counter clears on the first fresh
                // heartbeat, so a window can be recovered again after it has truly come back once.
                if app.recoveryAttempts > 0, heartbeatFresh {
                    app.recoveryAttempts = 0
                    NSLog("[LCStage][恢复] 窗口 \(app.appUUID)（\(app.appName)）重启后心跳恢复，救援成功")
                }

                let definitelyDead: Bool
                if LCUtils.appGroupUserDefault.object(forKey: hbKey) != nil {
                    definitelyDead = !heartbeatFresh && !processAlive
                } else {
                    // No heartbeat at all after the grace window: either a guest built without
                    // TweakLoader (then processAlive is the only signal) or one that never ran.
                    definitelyDead = app.appInfo != nil && !processAlive
                }
                guard definitelyDead else { continue }
                if canRecoverInPlace(app) {
                    recoverUUIDs.insert(app.appUUID)
                } else {
                    deadUUIDs.insert(app.appUUID)
                }
            }
        }

        // A terminated window's view can be detached before its model left the
        // array (lost removal callback). Never for a recovering slot — its view is kept by design.
        for app in apps where app.view?.window == nil {
            if app.isRecovering { continue }
            deadUUIDs.insert(app.appUUID)
        }

        for uuid in recoverUUIDs {
            beginRecovery(uuid: uuid)
        }
        guard !deadUUIDs.isEmpty else { return !recoverUUIDs.isEmpty }
        NSLog("[LCStage] pruning \(deadUUIDs.count) window(s): \(deadUUIDs)")
        for uuid in deadUUIDs {
            tearDownWindow(uuid, reason: "unresponsive guest")
        }
        return true
    }

    /// Whether a dead window may be silently relaunched into its own slot instead of being torn
    /// down. Requires the toggle, an identifiable app (its data is kept by dataUUID) and no
    /// recovery already in flight; capped at one attempt per outage to avoid relaunch loops.
    private func canRecoverInPlace(_ app: DockAppModel) -> Bool {
        guard LCUtils.appGroupUserDefault.bool(forKey: "LCAutoRecoverGuest") else { return false }
        guard !app.isRecovering, app.recoveryAttempts < 1 else { return false }
        if let path = app.appInfo?.relativeBundlePath, !path.isEmpty { return true }
        return false
    }

    /// Jetsam-proofing is impossible (4 guest appexes share 6GB RAM) — the goal is that a kill
    /// becomes invisible: keep the slot, cover the frozen last frame, relaunch the same app with
    /// the SAME container UUID in place, and let the frame-ready signal reveal the new guest.
    private func beginRecovery(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }) else { return }
        guard let bundleId = app.appInfo?.relativeBundlePath, !bundleId.isEmpty else {
            tearDownWindow(uuid, reason: "recover: missing bundle id")
            return
        }
        app.isRecovering = true
        app.recoveryAttempts += 1
        app.recoveryBeganAt = Date()

        let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController
        // Freeze the visual: last frame first (best), recovery spinner on top of it either way.
        let framePath = LCStageFrozenFramePath(uuid)
        decorated?.showFrozenFrame(atPath: framePath)
        decorated?.showRecoveryCover(withIcon: app.appInfo?.iconIsDarkIcon(false), appName: app.appName)
        // Tear down the DEAD scene/extension remnants WITHOUT touching the card view. Must happen
        // while isRecoveringGuest is set, so the late exit callback never removes this slot.
        decorated?.isRecoveringGuest = true
        decorated?.appSceneVC.appTerminationCleanUp()

        NSLog("[LCStage][恢复] 窗口 \(uuid)（\(app.appName)）guest 已被系统回收，原位静默重启…")
        MultitaskRelaunchManager.recoverGuest(bundleId: bundleId, dataUUID: uuid)
    }

    /// Called when the in-place relaunch could not even be started. The slot is dropped so the
    /// stage stays consistent; the user can reopen the app from the dock.
    @objc func recoveryFailed(uuid: String, reason: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.recoveryFailed(uuid: uuid, reason: reason) }
            return
        }
        guard let app = apps.first(where: { $0.appUUID == uuid }), app.isRecovering else { return }
        NSLog("[LCStage][恢复] 窗口 \(uuid) 恢复失败（\(reason)），移除窗口")
        tearDownWindow(uuid, reason: "recovery failed: \(reason)")
    }

    /// Removes a window completely: terminates the guest process (which also destroys its hosted
    /// scene and clears the container lock), detaches its view from the stage and drops the
    /// model. The window removal callback is idempotent, so it is harmless when the extension
    /// reports the exit as well — and it is the only thing that runs when that callback is lost.
    private func tearDownWindow(_ appUUID: String, reason: String) {
        guard let index = apps.firstIndex(where: { $0.appUUID == appUUID }) else { return }
        let app = apps[index]
        NSLog("[LCStage] tearing down window \(appUUID) (\(reason))")
        apps.remove(at: index)
        if index == 0, !apps.isEmpty {
            isFullscreen = false
            // A side window is about to inherit the main slot. The next animated settle must
            // re-push its geometry, or BackBoard keeps the promoted scene's touch region at the
            // old side-slot rect and the main app looks "untouchable" until the next switch.
            pendingGeometryGeneration += 1
        }
        if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            // Terminate the guest process, then tear its scene down unconditionally: the
            // extension's cancellation/interruption callbacks are dropped by the system now and
            // then, and a guest that survives without a window is exactly the orphan that makes
            // every later launch of this app come up black.
            vc.closeWindow()
            vc.appSceneVC.appTerminationCleanUp()
        }
        app.view?.removeFromSuperview()
        // The guest is gone (or going): its heartbeat must not survive or the next window of the
        // same app would be pruned by a stale timestamp as soon as the grace window ends.
        clearStaleGuestState(appUUID)
    }

    /// Drops the previous run's heartbeat of a container, so a brand-new window can never be
    /// judged by an earlier process's timestamp. Also removes the frame-ready marker and the
    /// frozen-frame snapshot: each JPEG is 1-3 MB and they used to accumulate forever in the
    /// App Group, including after the container was deleted.
    private func clearStaleGuestState(_ appUUID: String) {
        guard !appUUID.isEmpty else { return }
        let defaults = LCUtils.appGroupUserDefault
        defaults.removeObject(forKey: "LCGuestHeartbeat.\(appUUID)")
        defaults.removeObject(forKey: "LCGuestFrameReady.\(appUUID)")
        defaults.synchronize()
        lastFrameReadyAt.removeValue(forKey: appUUID)
        if let baseURL = LCSharedUtils.appGroupPath() {
            let frozenURL = baseURL
                .appendingPathComponent("LiveContainer/StageFrozenFrames/\(appUUID).jpg")
            try? FileManager.default.removeItem(at: frozenURL)
        }
    }

    /// Window views that no longer belong to a running app are leftovers of a teardown that did
    /// not detach them (or of the probe builds' model-only pruning). Left in place they sit on
    /// top of the live windows as black cards, so they are dropped with every layout pass.
    private func removeOrphanWindowViews() {
        for subview in windowHostingView.subviews {
            guard subview._viewDelegate() != nil else { continue }
            if !apps.contains(where: { $0.view === subview }) {
                NSLog("[LCStage] dropping orphan window view \(type(of: subview))")
                subview.removeFromSuperview()
            }
        }
    }

    /// Runs once per second, independent of any layout trigger, so a lost exit
    /// callback can never leave a black main window on screen.
    @objc private func watchdogTick() {
        guard isDockEnabled(), isStagePresented, !apps.isEmpty else { return }
        // While suspended the shared defaults and every guest timer are frozen, so heartbeat
        // age is meaningless in the background and for a few seconds after a resume. 10 seconds
        // (was 5): on a 6GB device under heavy memory pressure resume itself can take several
        // seconds, and one false "dead" verdict here triggers an unnecessary relaunch.
        let inGrace = Date().timeIntervalSince(lastHostWakeAt) < 10
        let canPruneHeartbeats = UIApplication.shared.applicationState == .active && !inGrace
        if pruneDeadWindows(allowHeartbeatPrune: canPruneHeartbeats) {
            // Non-animated prune never reaches settleAfterAnimation, and a promoted side window
            // needs its geometry committed (tearDownWindow armed the generation when the old main
            // slot died). Layout first, then commit on the next runloop tick — same pattern as
            // appWillEnterForeground.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.performLayout(animated: false)
                self.lastSettledFullscreen = self.isFullscreen
                self.lastSettledMainUUID = self.apps.first?.appUUID
                self.lastSettledGeneration = self.pendingGeometryGeneration
                self.commitMainWindowGeometry()
            }
        } else {
            // Keep the role timestamp fresh even without layout changes.
            publishStageRoles(active: true)
        }
        // Recovery timeout: a relaunch that never produces a guest must not leave the slot
        // spinning behind a frozen frame forever.
        for app in apps where app.isRecovering
            && Date().timeIntervalSince(app.recoveryBeganAt) > Self.recoveryTimeout {
            recoveryFailed(uuid: app.appUUID, reason: "relaunch timeout")
        }
        // Frame-ready polling: a Darwin notification can be coalesced away while the host is
        // waking, so actively reconcile once per second in the foreground.
        if UIApplication.shared.applicationState == .active {
            handleGuestFrameReady()
        }
        // Cover backstop: a guest that does not inject TweakLoader never sends frame-ready,
        // so its launch placeholder would otherwise stay up forever. This deadline is beyond
        // any real cold start while still hiding the whole launch black gap.
        for app in apps where Date().timeIntervalSince(app.addedAt) > Self.coverBackstopInterval {
            (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
                .hideContentCovers(animated: true)
        }
    }

    /// Called when an animated relayout changes the main window (fullscreen toggle, promotion
    /// or refill after a close). BackBoard derives a hosted scene's touch region from the hosting
    /// view's geometry, so once the layout animation has landed the settled geometry is pushed
    /// into the scene again — see commitMainWindowGeometry().
    private func armGeometryCommitIfNeeded() {
        // Note: a left/right mirror is deliberately NOT an arming change. The main card's hosting
        // view moves halves natively and its geometry key (size/scale/fullscreen) is identical,
        // so re-pushing scene settings would only force a cross-process surface reconnect —
        // exactly the black flicker the mirror used to produce.
        let changed = lastSettledFullscreen != isFullscreen
            || lastSettledMainUUID != apps.first?.appUUID
        guard changed else { return }
        pendingGeometryGeneration += 1
    }

    /// Runs once when the geometry animation has landed: the settled layout is re-applied without
    /// animation and the main window's geometry is pushed into its hosted scene.
    private func settleAfterAnimation() {
        performLayout(animated: false)
        let currentGen = pendingGeometryGeneration
        // Guard 1: generation counter. If the arm happened twice for the same settle (two
        // overlapping animations arming before either settles), only the first settle runs the
        // commit. The second settle sees a different generation and discards itself.
        guard currentGen != lastSettledGeneration else { return }
        // Guard 2: no arm at all. Happens when relayout is called without a fullscreen/promotion
        // change (e.g. dock only relayouts, or device orientation while nothing moved). Skip.
        guard currentGen > 0 else { return }
        lastSettledGeneration = currentGen

        lastSettledFullscreen = isFullscreen
        lastSettledMainUUID = apps.first?.appUUID

        // The main window changed (fullscreen toggle, promotion, refill after a close), so its
        // touch region has to cover the slot it sits in now. Windows that slid into side slots
        // need no work: their touches are quarantined in the guest.
        commitMainWindowGeometry()

        // Second, delayed commit. On some iOS 19 builds the system's own post-animation layout
        // pass re-derives the hosting view geometry a beat AFTER our settle push, and the touch
        // region then describes a stale slot: controls in the split main window stay untappable
        // until the next foreground round trip (fullscreen always worked, because its frame
        // equals the screen and the race happens to be invisible). Re-commit once more shortly
        // after settling, but only if nothing else moved the stage in between.
        let gen = currentGen
        let settleToken = layoutToken
        let settledUUID = apps.first?.appUUID
        let settledFullscreen = isFullscreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.isStagePresented, !self.isStageCollapsed,
                  self.apps.first?.appUUID == settledUUID,
                  self.isFullscreen == settledFullscreen,
                  self.pendingGeometryGeneration == gen,
                  self.lastSettledGeneration == gen,
                  // A mirror swap (or any newer animated pass) bumps layoutToken without bumping
                  // the geometry generation; it must not be met by this push — re-committing the
                  // hosted scene mid-flight reconnects the render surface and brings the black
                  // flash the mirror pass exists to avoid.
                  self.layoutToken == settleToken else { return }
            self.commitMainWindowGeometry()
        }
    }

    /// Re-pushes the MAIN window's settled geometry into its hosted scene.
    ///
    /// This used to be a foreground NO→YES blip hidden behind a stage snapshot. Both halves of
    /// that dance were visible: the snapshot cannot capture a hosted scene's cross-process
    /// content, so the stage showed a blank card for the length of the blip, and backgrounding
    /// the guest froze its video and cut its audio for a moment on every resize or promotion.
    /// The settings push alone is what the region actually needs, and it leaves the scene live.
    ///
    /// Side windows do NOT need any of this: their region naturally covers their visible slot and
    /// their touches are quarantined inside the guest process (see LCStageIPC.h).
    private func commitMainWindowGeometry() {
        guard let mainVC = apps.first?.view?._viewDelegate() as? DecoratedAppSceneViewController else {
            return
        }
        mainVC.appSceneVC.commitHostedGeometry()
    }

    private func dismissStage() {
        isStagePresented = false
        isStageCollapsed = false
        isFullscreen = false
        allChromeButtons.forEach { $0.isHidden = true }
        // No stage on screen: the readout goes with it, and stops sampling frames nobody can see.
        fpsCounter.isCounting = false
        fpsCounter.isHidden = true
        stopBackdropProbe()
        // No stage on screen: every guest keeps its own touches again.
        publishStageRoles(active: false)
        notifyCollapsedStateChanged()
        UIView.animate(withDuration: 0.2, animations: {
            self.windowHostingView.alpha = 0
            self.dockHost?.view.alpha = 0
            self.allChromeButtons.forEach { $0.alpha = 0 }
            self.fpsCounter.alpha = 0
        }, completion: { _ in
            // A new app may have entered the stage while the fade-out was running; in that case
            // the entry path already showed everything again, so don't hide it here.
            guard !self.isStagePresented else { return }
            self.windowHostingView.isHidden = true
            self.dockHost?.view.isHidden = true
            // The page surface leaves with the page rather than lingering invisibly under the
            // launcher: the next entry clears the flag again on its way in.
            self.stageBackdrop.isHidden = true
        })
    }

    // MARK: - Stage keep-alive
    //
    // While the virtual-window stage exists we (1) disable the idle timer so the screen never
    // auto-locks in the middle of a session, and (2) keep a REAL inaudible audio buffer playing
    // (StageAudioKeepAlive). Merely activating an AVAudioSession does not grant a background
    // assertion on modern iOS — mediaserverd only does so while audio is actually rendering.
    // The app declares the `audio` background mode: the host (and every guest appex, which runs
    // its own copy of the buffer) therefore stays runnable while backgrounded/locked, which is
    // what keeps jetsam from collecting the side windows.

    /// User toggle from the multitask settings page (App Group so guests read the same key).
    /// v4.1.2: backup channel — a missing key defaults to OFF.
    private var keepAliveAudioEnabled: Bool {
        let defaults = LCUtils.appGroupUserDefault
        if defaults.object(forKey: LCStageIPCKeepAliveAudioKey) == nil { return false }
        return defaults.bool(forKey: LCStageIPCKeepAliveAudioKey)
    }

    /// PiP second-channel toggle (App Group). v4.1.2: backup channel — a missing key defaults to OFF.
    private var keepAlivePiPEnabled: Bool {
        let defaults = LCUtils.appGroupUserDefault
        if defaults.object(forKey: LCStageIPCPiPKeepAliveKey) == nil { return false }
        return defaults.bool(forKey: LCStageIPCPiPKeepAliveKey)
    }

    /// Continuous-location primary-channel toggle (App Group). Missing key defaults to ON. Location is the
    /// only channel on by default as of v4.1.2.
    private var keepAliveLocationEnabled: Bool {
        let defaults = LCUtils.appGroupUserDefault
        if defaults.object(forKey: LCStageIPCLocationKeepAliveKey) == nil { return true }
        return defaults.bool(forKey: LCStageIPCLocationKeepAliveKey)
    }

    /// Foreground pinning / lifecycle-masking master switch (host re-pin + guest broadcast masking
    /// both honor it). Missing key defaults to ON; the settings page lets users escape to legacy.
    private var scenePinningEnabled: Bool {
        let defaults = LCUtils.appGroupUserDefault
        if defaults.object(forKey: LCStageIPCPinningKey) == nil { return true }
        return defaults.bool(forKey: LCStageIPCPinningKey)
    }

    /// One-time v4.1.2 migration: existing users ran audio + PiP + location. Real-device testing
    /// proved location alone sufficient, so the first launch after upgrade explicitly turns the other two OFF
    /// (the code stays; a user can flip them right back on). A marker key makes this run once.
    private func migrateKeepAliveDefaultsOnce() {
        let defaults = LCUtils.appGroupUserDefault
        let markerKey = "LCStageKeepAliveMigratedV412"
        guard defaults.object(forKey: markerKey) == nil else { return }
        defaults.set(false, forKey: LCStageIPCKeepAliveAudioKey)
        defaults.set(false, forKey: LCStageIPCPiPKeepAliveKey)
        defaults.set(true, forKey: LCStageIPCLocationKeepAliveKey)
        defaults.set(true, forKey: markerKey)
        defaults.synchronize()
        NSLog("[LCStage][保活] v4.1.2 一次性迁移：仅保留定位通道，宿主音轨/PiP/副窗音轨默认关闭（代码保留可随时重新开启）")
    }

    /// Called by the settings toggles while a stage is live: start/stop each channel immediately
    /// instead of waiting for the next stage entry.
    @objc func applyKeepAliveSettings() {
        guard isKeepAliveActive else { return }
        if keepAliveAudioEnabled {
            StageAudioKeepAlive.shared.start()
        } else {
            StageAudioKeepAlive.shared.stop()
        }
        if keepAlivePiPEnabled {
            StagePiPKeepAlive.shared.arm()
            if let window = keyWindow { StagePiPKeepAlive.shared.attach(to: window) }
        } else {
            StagePiPKeepAlive.shared.disarm()
        }
        if keepAliveLocationEnabled {
            StageLocationKeepAlive.shared.arm()
        } else {
            StageLocationKeepAlive.shared.disarm()
        }
    }

    private func updateStageKeepAlive(active: Bool) {
        guard isKeepAliveActive != active else { return }
        isKeepAliveActive = active
        if active {
            UIApplication.shared.isIdleTimerDisabled = true
            // Layered lifecycle, weakest to strongest; each layer is independent, so any native
            // interruption can only knock out one at a time:
            //   1. silent audio  — playback assertion, mixes with other apps, auto-resumes
            //   2. hairline PiP  — video assertion, auto-opens in background
            //   3. location      — navigation-level assertion, survives audio/PiP eviction
            // Guests additionally arm their own silent track only while the host is backgrounded.
            if keepAliveAudioEnabled {
                StageAudioKeepAlive.shared.start()
            } else {
                StageAudioKeepAlive.shared.stop()
            }
            if keepAlivePiPEnabled {
                StagePiPKeepAlive.shared.arm()
            } else {
                StagePiPKeepAlive.shared.disarm()
            }
            if keepAliveLocationEnabled {
                StageLocationKeepAlive.shared.arm()
            } else {
                StageLocationKeepAlive.shared.disarm()
            }
            NSLog("[LCStage][保活] 舞台保活已激活（定位=\(keepAliveLocationEnabled)，音轨=\(keepAliveAudioEnabled)，PiP=\(keepAlivePiPEnabled)）")
        } else {
            UIApplication.shared.isIdleTimerDisabled = false
            StageAudioKeepAlive.shared.stop()
            StagePiPKeepAlive.shared.disarm()
            StageLocationKeepAlive.shared.disarm()
            endBackgroundTaskIfNeeded()
            NSLog("[LCStage][保活] 舞台保活已关闭")
        }
    }

    /// Buys ~30s of runtime at background entry so the freeze-frame IPC and the guests' engine
    /// arming always complete. The playback assertion is the long-term keeper; this is the bridge.
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LCStageBackground") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
        NSLog("[LCStage][保活] 已申请后台过渡时间")
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Darwin callback from a guest that just rendered real frames. Reveals every staged card
    /// whose guest reported a newer frame-ready timestamp.
    @objc func handleGuestFrameReady() {
        for app in apps {
            let readyAt = LCStageHostFrameReadyAt(app.appUUID)
            guard readyAt > (lastFrameReadyAt[app.appUUID] ?? 0) else { continue }
            lastFrameReadyAt[app.appUUID] = readyAt
            // A real frame beat the 0.3s lazy cover to it: cancel the pending cover so the
            // spinner is never shown for this launch.
            app.placeholderWorkItem?.cancel()
            app.placeholderWorkItem = nil
            let isMain = app.appUUID == apps.first?.appUUID
            (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
                .hideContentCovers(animated: true)
            // Only the main window's verified frame releases the geometry commit deferred at
            // foreground return; side-window geometry never needed re-committing.
            if isMain {
                settleWakeGeometryIfNeeded(trigger: "Darwin frame-ready")
            }
        }
    }

    // MARK: - Foreground recovery
    //
    // Scenes are deliberately NOT suspended when the host backgrounds (no foreground=NO pass):
    // with the keep-alive audio session the host stays runnable and the guests keep their
    // foreground state, so coming back is instant with no black flash. As a defence in depth
    // every guest snapshots its last frame on resign-active; on foreground return the host
    // covers each card with that still until the guest reports fresh frames, so even if the
    // system did reclaim a surface the user sees the app's real last picture, never black.

    @objc private func appWillResignActive() {
        guard isDockEnabled(), isStagePresented, !apps.isEmpty else { return }
        backgroundingBeganAt = Date()
        // 1) Tell every guest to snapshot its CURRENT frame right now. Under modern iOS hosting
        //    the guests' own willResignActive is stripped (AppSceneViewController.m), so without
        //    this explicit channel no frozen frame exists and the foreground return flashes black.
        LCStageNotifyHostBackgrounding()
        // 2) Locally cover every card with whatever frozen frame already exists (from the last
        //    round) immediately, so even the resign animation itself never shows a black gap.
        coverCardsWithFrozenFrames()
        // 3) Foreground pinning: re-assert foreground on every scene THIS SAME FRAME, before the
        //    system's deactivation lands, then keep re-pinning throughout the background. This is the
        //    root-cause fix for both "Instagram bounces to its feed" and the black flash: a scene
        //    that is never deactivated never rebuilds its cross-process render surface.
        if scenePinningEnabled {
            beginForegroundPinning()
        }
        // 4) Backup channels only: the PiP nudge runs solely when the user enabled PiP.
        if keepAlivePiPEnabled {
            StagePiPKeepAlive.shared.nudgeStart()
        }
        logGuestStates(context: "宿主即将后台/锁屏")
        NSLog("[LCStage][闪黑] 宿主即将后台/锁屏：已通知 \(apps.count) 个 guest 拍照并盖上冻结帧，前台钉住=\(scenePinningEnabled)")
    }

    @objc private func appDidEnterBackground() {
        guard isKeepAliveActive else { return }
        // Bridge time: the location assertion does the long-term keeping; this makes sure the
        // snapshot IPC and the 100ms/500ms re-covers finish during the handoff.
        beginBackgroundTaskIfNeeded()
        // Re-cover with the frames the guests captured during this very lock: the first Darwin round
        // trip crosses processes with a few milliseconds of lag, so an immediate cover can still be
        // the previous session's frame. Freshness gate keeps the older cover if the new JPEG isn't
        // there yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.coverCardsWithFrozenFrames(freshSince: self?.backgroundingBeganAt.timeIntervalSince1970 ?? 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.coverCardsWithFrozenFrames(freshSince: self?.backgroundingBeganAt.timeIntervalSince1970 ?? 0)
        }
    }

    /// Covers every staged card with its guest's frozen last frame (no-op when the JPEG is
    /// missing — showFrozenFrameAtPath returns early on unreadable files).
    /// - Parameter freshSince: when > 0, JPEGs older than this epoch timestamp are ignored so a stale
    ///   frame from an earlier session can never replace this lock's capture.
    private func coverCardsWithFrozenFrames(freshSince: TimeInterval = 0) {
        for app in apps {
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            vc.showFrozenFrame(atPath: LCStageFrozenFramePath(app.appUUID), notOlderThan: freshSince)
        }
    }

    /// Re-pins every staged guest scene and logs which scenes were not foremost anymore. Runs on the
    /// escalating background scheduler (immediate, 0.2s, 0.5s, 1s, then 1/s).
    @objc func pinAllStagedScenesForeground(reason: String) {
        for app in apps {
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            let scene = vc.appSceneVC
            let wasForemost = scene?.lcIsSceneForegroundActive() ?? false
            scene?.lcPinForeground()
            if !wasForemost {
                NSLog("[LCStage][场景] 重钉前台（\(reason)）：\(app.appName) 此前已失活，已补推 foreground=YES")
            }
        }
    }

    private func beginForegroundPinning() {
        guard !isPinningForeground else { return }
        isPinningForeground = true
        NSLog("[LCStage][场景] 前台钉住开始：对 \(apps.count) 个场景立即重钉")
        pinAllStagedScenesForeground(reason: "锁屏当帧")
        for delay in [0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isPinningForeground else { return }
                self.pinAllStagedScenesForeground(reason: "后台 \(delay)s")
            }
        }
        // Then once per second for as long as we stay out of the foreground app state. The
        // location assertion keeps us runnable, so this timer really fires in the background.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isPinningForeground,
                  UIApplication.shared.applicationState != .active else { return }
            self.pinAllStagedScenesForeground(reason: "后台周期 1s")
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        foregroundPinningTimer = timer
    }

    private func endForegroundPinning() {
        guard isPinningForeground else { return }
        isPinningForeground = false
        foregroundPinningTimer?.invalidate()
        foregroundPinningTimer = nil
        NSLog("[LCStage][场景] 前台钉住结束（宿主回前台）")
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTaskIfNeeded()
        endForegroundPinning()
        lastHostWakeAt = Date()
        // Guests' own didBecomeActive is stripped under hosting; tell them to re-arm frame-ready.
        LCStageNotifyHostForegrounding()
        // Cover with the snapshots taken at willResignActive first. Each cover is lifted only by
        // that guest's own pixel-verified frame-ready report (handleGuestFrameReady, also polled by
        // the watchdog) — never on a fixed frame counter alone. The freshness gate refuses frames
        // from an earlier session (the "wake shows an old frame" bug): only the JPEG written for
        // THIS backgrounding is accepted, with a 1s tolerance for filesystem timestamp granularity.
        let freshSince = backgroundingBeganAt == .distantPast
            ? 0
            : backgroundingBeganAt.addingTimeInterval(-1.0).timeIntervalSince1970
        coverCardsWithFrozenFrames(freshSince: freshSince)
        logGuestStates(context: "宿主回前台")

        if scenePinningEnabled {
            // The pinning scheduler held every scene foreground while we were away. Push ONLY the
            // scenes the system actually managed to deactivate anyway — a blanket re-push used to
            // manufacture the exact reactivation transition that bounces apps back to their feed.
            for app in apps {
                guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
                if vc.appSceneVC?.lcIsSceneForegroundActive() != true {
                    NSLog("[LCStage][场景] 回前台：\(app.appName) 钉住失败已失活，补推一次前台")
                    vc.appSceneVC?.setHostedSceneForeground(true)
                }
            }
            // The main window's geometry commit waits until the covers are lifted on pixel-verified real
            // frames; the geometry itself hasn't changed, so the touch region moving a few hundred ms late
            // is invisible.
            pendingWakeGeometryCommit = true
            scheduleWakeGeometryBackstop()
        } else {
            // Escape hatch: pre-v4.1.2 behavior for users who turned pinning off.
            for app in apps {
                guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
                vc.appSceneVC.setHostedSceneForeground(true)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.performLayout(animated: false)
                self.lastSettledFullscreen = self.isFullscreen
                self.lastSettledMainUUID = self.apps.first?.appUUID
                self.lastSettledGeneration = self.pendingGeometryGeneration
                self.commitMainWindowGeometry()
            }
        }
        // Backstop ONLY for guests that cannot report frame-ready (TweakLoader injection off):
        // they never took a snapshot either, but if a stale cover exists it must not stick
        // forever. TweakLoader guests are always revealed by their own frame-ready signal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            for app in self.apps where app.appInfo?.dontInjectTweakLoader == true {
                (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
                    .hideFrozenFrame(animated: true)
            }
        }
    }

    /// Runs the deferred post-wake geometry commit once the MAIN window's pixel-verified frame-ready
    /// report has lifted its cover. Side reports arriving earlier are ignored.
    private func settleWakeGeometryIfNeeded(trigger: String) {
        guard pendingWakeGeometryCommit else { return }
        pendingWakeGeometryCommit = false
        NSLog("[LCStage][闪黑] 主窗像素验真揭图完成（\(trigger)），补提交主窗几何")
        performLayout(animated: false)
        lastSettledFullscreen = isFullscreen
        lastSettledMainUUID = apps.first?.appUUID
        lastSettledGeneration = pendingGeometryGeneration
        commitMainWindowGeometry()
    }

    /// A cover must never outlast a broken frame-ready pipeline: after 3s, reveal everything and
    /// run the deferred geometry commit regardless of what the guests reported.
    private func scheduleWakeGeometryBackstop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.pendingWakeGeometryCommit else { return }
            NSLog("[LCStage][闪黑] 3 秒兜底：强制揭图并补提交主窗几何")
            self.pendingWakeGeometryCommit = false
            for app in self.apps {
                (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
                    .hideContentCovers(animated: true)
            }
            self.performLayout(animated: false)
            self.lastSettledFullscreen = self.isFullscreen
            self.lastSettledMainUUID = self.apps.first?.appUUID
            self.lastSettledGeneration = self.pendingGeometryGeneration
            self.commitMainWindowGeometry()
        }
    }

    /// Evidence log: one line per staged window with pid / launch count / foremost state, so a single
    /// lock/unlock cycle in the console proves whether a guest really restarted.
    private func logGuestStates(context: String) {
        for app in apps {
            let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController
            let pid = decorated?.appSceneVC.pid ?? -1
            let count = LCStageHostGuestLaunchCount(app.appUUID)
            let foremost = decorated?.appSceneVC.lcIsSceneForegroundActive() ?? false
            let alive = decorated?.appSceneVC.isAppRunning ?? false
            NSLog("[LCStage][场景] \(context)：\(app.appName) pid=\(pid) alive=\(alive) launchCount=\(count) foreground=\(foremost)")
        }
    }

    // MARK: - Running apps

    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }

    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        // Same container already on stage: either a duplicate launch (ignore, as before) or a
        // watchdog-triggered in-place recovery (swap the freshly launched guest into the slot).
        if let existing = apps.first(where: { $0.appUUID == appUUID }) {
            if existing.isRecovering {
                replaceRecoveredWindow(existing, appInfo: appInfo, newView: view)
            }
            return
        }
        // Single choke point for the maxWindows guard — every entry path flows through here.
        guard apps.count < MultitaskStageLayout.maxWindows else { return }

        let appName = appInfo?.displayName() ?? "lc.multitask.unknownApp".loc
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        // The model has to land in `apps` in the same runloop turn as the window view: the view is
        // already added to the hosting hierarchy by the time this is called
        // (DecoratedAppSceneViewController.init), and a layout pass racing in between would see a
        // window view without a model and drop it as an orphan. Callers are on the main thread,
        // so the insertion normally happens inline; the dispatch is only a fallback.
        let insertWindow = {
            // A window that enters the stage must never inherit the previous run's traces of the
            // same container: a leftover heartbeat timestamp used to prune the fresh window in
            // the very first watchdog tick, long before its guest could write its own.
            self.clearStaleGuestState(appUUID)
            // Lazy launch cover: give a fast guest 0.3s to paint its first frame. If it does,
            // handleGuestFrameReady cancels this item and the spinner is never shown at all; if
            // the app is still cold-starting, fade the icon/name/spinner cover in instead of
            // staring at a black card.
            let coverItem = DispatchWorkItem { [weak self, weak appModel] in
                guard let self, let appModel,
                      self.apps.contains(where: { $0 === appModel }) else { return }
                appModel.placeholderWorkItem = nil
                if let decorated = appModel.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    decorated.configureLaunchPlaceholder(
                        withIcon: appInfo?.iconIsDarkIcon(false),
                        appName: appModel.appName
                    )
                }
            }
            appModel.placeholderWorkItem = coverItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: coverItem)
            // New apps always enter the main slot (head of the array); any previous main window
            // slides down to a side slot. This matches the "open on the main slot" behaviour
            // users expect from a dock, instead of every new app landing as a side card.
            let first = self.apps.isEmpty
            self.apps.insert(appModel, at: 0)
            // When it is the very first window, honour the "launch maximized" user preference.
            // Otherwise a fresh open always starts split, so the user sees all four cards.
            if first, UserDefaults.standard.bool(forKey: "LCLaunchMultitaskMaximized") {
                self.isFullscreen = true
            }
            // applyStageFrame pushes all view frames synchronously, so by the time this layout
            // has landed every window already sits at its final slot.
            if self.isStageCollapsed {
                // Launched from the launcher while the stage was collapsed: reveal the stage
                // around the new guest instead of booting it behind hidden surfaces.
                self.reenterStage()
            } else {
                self.relayout(animated: false)
            }
            // The non-animated path never reaches settleAfterAnimation, so the commit bookkeeping
            // happens here (keeping the arm state in sync so a later animated relayout does not
            // re-commit for a change that already settled) and the main window's geometry is
            // pushed on the next runloop tick, after performLayout applied the new frames. The
            // main window is committed: its scene started before the stage laid it out, so its
            // touch region still reflects the pre-layout geometry. Side slots need no commit
            // (guest-side touch quarantine).
            self.lastSettledFullscreen = self.isFullscreen
            self.lastSettledMainUUID = self.apps.first?.appUUID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Reconcile after the relayout above actually ran: it may have pruned a dead
                // main window and armed a fresh generation.
                self.lastSettledGeneration = self.pendingGeometryGeneration
                self.commitMainWindowGeometry()
            }
        }
        if Thread.isMainThread {
            insertWindow()
        } else {
            DispatchQueue.main.async(execute: insertWindow)
        }
    }

    /// Swaps the freshly relaunched guest into a slot whose previous guest was jetsam'd. The
    /// DockAppModel stays (same slot, same order); only its view/decorated controller changes.
    private func replaceRecoveredWindow(_ model: DockAppModel, appInfo: LCAppInfo?, newView: UIView?) {
        let apply = {
            NSLog("[LCStage][恢复] 窗口 \(model.appUUID)（\(model.appName)）新 guest 已接入，原位替换卡片")
            model.placeholderWorkItem?.cancel()
            model.placeholderWorkItem = nil
            model.view?.removeFromSuperview()
            model.view = newView
            // Fresh grace window for the new guest (heartbeat/frame timing all restarts).
            model.addedAt = Date()
            model.isRecovering = false
            self.clearStaleGuestState(model.appUUID)
            // The slot must stay covered NOW: the new guest has not rendered a frame yet, and
            // unlike a cold start there is no 0.3s lazy delay — the recovery cover is already up.
            if let decorated = newView?._viewDelegate() as? DecoratedAppSceneViewController {
                decorated.configureLaunchPlaceholder(
                    withIcon: appInfo?.iconIsDarkIcon(false),
                    appName: model.appName
                )
            }
            self.relayout(animated: false)
            self.lastSettledFullscreen = self.isFullscreen
            self.lastSettledMainUUID = self.apps.first?.appUUID
            // The new guest has never received role state; force-publish immediately instead of
            // waiting up to a second for the watchdog's refresh.
            self.publishRolesIfChanged(active: self.isDockEnabled(), uuid: self.apps.first?.appUUID, force: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastSettledGeneration = self.pendingGeometryGeneration
                self.commitMainWindowGeometry()
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }

        DispatchQueue.main.async {
            if let index = self.apps.firstIndex(where: { $0.appUUID == appUUID }) {
                self.apps.remove(at: index)
                if index == 0 {
                    self.isFullscreen = false
                }
            }
            // Relayout even when the UUID was not found: performLayout self-heals detached
            // windows, so this pass is what lets the next app slide into the main slot.
            self.relayout(animated: true)
        }
    }

    // MARK: - Window actions

    /// Brings a running app to the main slot. Used by the app list as well.
    public func bringMultitaskViewToFront(uuid: String) -> Bool {
        guard isDockEnabled(), let index = apps.firstIndex(where: { $0.appUUID == uuid }) else {
            return false
        }
        promoteToMain(index: index)
        return true
    }

    /// Called when the user taps a side window, so it takes over the main slot.
    @objc public func promoteWindowForUUID(_ appUUID: String) {
        guard isDockEnabled(), let index = apps.firstIndex(where: { $0.appUUID == appUUID }) else {
            return
        }
        promoteToMain(index: index)
    }

    /// Called from the sendEvent hooks in UIKitHooks.m for every touch that begins inside the
    /// stage's window. Hosted scenes receive touches through a system-level channel that
    /// bypasses the regular UIKit hit-test chain, so view-level shields cannot stop a side
    /// window's app from getting the touch. sendEvent, however, is upstream of that channel:
    /// swallowing the touch there means the side app never sees it at all.
    /// Returns true when the location landed in a side slot and the window was promoted.
    /// The explicit ObjC name keeps the descriptive selector used by UIKitHooks.m — the
    /// implicit one for (at:in:) would be "interceptTouchAt:in:".
    @objc(interceptTouchAtLocation:inWindow:)
    public func interceptTouch(at location: CGPoint, in window: UIWindow) -> Bool {
        // Collapsed to the launcher: the stage is visually gone, so its hidden slot frames must
        // neither swallow launcher touches nor silently reorder the windows.
        guard !isStageCollapsed, !isFullscreen, apps.count > 1 else { return false }
        // Only the window that actually hosts the stage can match a side slot; a touch over
        // any other window (alert, sheet, ...) must never promote anything.
        guard let stageView = apps.first?.view, stageView.window === window else { return false }
        for index in 1..<apps.count {
            guard let view = apps[index].view else { continue }
            if view.convert(view.bounds, to: window).contains(location) {
                // promoteToMain takes over any layout animation already in flight, so a quick run
                // of taps keeps working; the touch is always swallowed so it can never leak into
                // the side app.
                promoteToMain(index: index)
                return true
            }
        }
        return false
    }

    /// Every window in the stage reflows at once — the card that leaves the main slot and the card
    /// that takes it are moved by the same spring, so the two halves of a switch read as one
    /// motion. A switch that lands while that spring is still running takes it over instead of
    /// being ignored (see performLayout), which is what makes tapping through the windows quickly
    /// feel like one continuous reflow as well as keep the work per tap small.
    func promoteToMain(index: Int) {
        guard index >= 0, index < apps.count else { return }
        // Already in the main slot: repeated taps must not re-run the whole relayout plus a
        // haptic and a role broadcast (used to make fast tapping visibly jitter).
        guard index > 0 else { return }
        let app = apps.remove(at: index)
        apps.insert(app, at: 0)
        // The new main window's content (and therefore its backdrop luma) is different; drop the
        // hysteresis state so its first published sample decides the glyph color immediately.
        backdropButtonDark.removeAll()
        // Flip touch ownership immediately: the old main starts quarantining
        // and the new main releases touches while the promotion animates.
        publishStageRoles(active: true)
        relayout(animated: true)
        switchFeedback.impactOccurred()
    }

    /// The close button tears the card down ON THIS FRAME and lets the next window inherit the
    /// main slot in the same layout spring. The old flow waited for the guest's SIGTERM →
    /// cancellation → exit callback chain (with a 2.5s backstop), so the killed main app left a
    /// black card on screen for seconds before the side window moved up.
    @objc func stageControlsDidTapClose() {
        guard let app = apps.first else { return }
        // Closing terminates the guest process, so acknowledge the destructive commit with the
        // hard-edged feedback that belongs to a destructive action.
        closeFeedback.impactOccurred()

        apps.removeFirst()
        let closingView = app.view
        let closingVC = closingView?._viewDelegate() as? DecoratedAppSceneViewController
        isFullscreen = false
        if !apps.isEmpty {
            // A side window inherits the main slot: arm its geometry commit so the spring that
            // promotes it ends with the correct touch region.
            pendingGeometryGeneration += 1
        }
        // The promoted window brings a different backdrop; re-probe its glyph colour immediately.
        backdropButtonDark.removeAll()

        // The layout pass removes the orphaned card (removeOrphanWindowViews) and springs the
        // remaining cards into place in one motion — there is never a frame of empty black page.
        closingView?.isUserInteractionEnabled = false
        relayout(animated: true)

        // Terminate the guest only after its card is gone from the hierarchy. Its late exit
        // callback (removeRunningApp) is a harmless no-op once the UUID has left `apps`.
        if let closingVC {
            closingControllers.append(closingVC)
            closingVC.closeWindow()
            // Release once the termination backstop (2.5s) has definitely run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak closingVC] in
                guard let self, let closingVC else { return }
                self.closingControllers.removeAll { $0 === closingVC }
            }
        }
        clearStaleGuestState(app.appUUID)
    }

    @objc func stageControlsDidTapZoom() {
        isFullscreen.toggle()
        relayout(animated: true)
        // Fires on the same frame the layout animation starts, so the tap and the motion read as
        // one event.
        switchFeedback.impactOccurred()
    }

    /// Flips the whole stage between left-hand (main left) and right-hand (main right) layouts.
    /// iPhone has no public API for detecting which hand holds the device, so this is an explicit
    /// toggle; the choice persists across launches via MultitaskStageLayout.isMirrored.
    @objc func toggleLayoutHandedness() {
        MultitaskStageLayout.isMirrored.toggle()
        switchFeedback.impactOccurred()
        // Mirror pass: cards fly through the spring, chrome/dock/plate stay frozen and corner
        // masks swap only after landing — no junction seam or dock-block flash mid-swap.
        relayout(animated: true, mirroring: true)
        // A half-turn on the glyph reads as the two halves physically swapping places.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let flip = CASpringAnimation(keyPath: "transform.rotation.y")
        flip.fromValue = 0
        flip.toValue = CGFloat.pi
        flip.damping = 12
        flip.stiffness = 180
        flip.duration = 0.4
        swapButton.layer.add(flip, forKey: "swapFlip")
    }

    /// Collapses the stage back to the LiveContainer app list. Nothing is terminated: guests keep
    /// running in the background with the stage keep-alive, so re-entering is instant.
    @objc func returnToLauncher() {
        guard isStagePresented, !isStageCollapsed else { return }
        switchFeedback.impactOccurred()
        isStageCollapsed = true
        isFullscreen = false
        // Kill interaction on the first frame of the fade-out: a tap landing during the 0.22s
        // animation must not toggle fullscreen, persist a mirror flip or close a hidden window.
        allChromeButtons.forEach { $0.isUserInteractionEnabled = false }
        UIView.animate(withDuration: 0.22, delay: 0, options: .allowUserInteraction, animations: {
            self.windowHostingView.alpha = 0
            self.dockHost?.view.alpha = 0
            self.fpsCounter.alpha = 0
            self.allChromeButtons.forEach { $0.alpha = 0 }
        }, completion: { _ in
            // Bail out if a re-entry already happened mid-animation.
            guard self.isStageCollapsed else { return }
            self.windowHostingView.isHidden = true
            self.stageBackdrop.isHidden = true
            self.blockPlate.isHidden = true
            self.dockHost?.view.isHidden = true
            self.fpsCounter.isHidden = true
            self.fpsCounter.isCounting = false
            self.allChromeButtons.forEach { $0.isHidden = true }
            self.stopBackdropProbe()
            self.notifyCollapsedStateChanged()
        })
    }

    /// Re-enters a collapsed stage (tapping a still-running app in the LiveContainer list) and
    /// brings that app's window to the main slot.
    func reenterStage(promote uuid: String? = nil) {
        guard isStagePresented, !apps.isEmpty else { return }
        if let uuid, let index = apps.firstIndex(where: { $0.appUUID == uuid }), index > 0 {
            let app = apps.remove(at: index)
            apps.insert(app, at: 0)
            backdropButtonDark.removeAll()
        }
        guard isStageCollapsed else {
            relayout(animated: true)
            return
        }
        isStageCollapsed = false
        startBackdropProbe()
        windowHostingView.isHidden = false
        stageBackdrop.isHidden = false
        blockPlate.isHidden = true
        dockHost?.view.isHidden = false
        // Start from 0; the layout pass's own spring eases every surface back to its settled alpha.
        windowHostingView.alpha = 0
        dockHost?.view.alpha = 0
        fpsCounter.alpha = 0
        allChromeButtons.forEach {
            $0.isHidden = false
            $0.alpha = 0
        }
        relayout(animated: true)
        // relayout only springs the chrome/dock alphas; the hosting surface's alpha is owned by
        // the entry/collapse fades, so it has to be brought back explicitly here.
        UIView.animate(withDuration: 0.22, delay: 0, options: .allowUserInteraction) {
            self.windowHostingView.alpha = 1
        }
        publishStageRoles(active: true)
        notifyCollapsedStateChanged()
    }

    // MARK: - Launcher re-entry

    /// Posted whenever the stage collapses to the launcher, re-enters, or is dismissed. The
    /// LiveContainer app list observes it to show/hide the "enter multitasking" toolbar button.
    public static let collapsedStateChangedNotification = Notification.Name("LCStageCollapsedStateChanged")

    /// YES while a live stage is folded away behind the LiveContainer app list: guests keep
    /// running and the user can jump straight back onto the stage.
    @objc public var hasCollapsedStage: Bool {
        isStagePresented && isStageCollapsed && !apps.isEmpty
    }

    /// Re-enters the folded stage from the LiveContainer app list without changing which guest
    /// owns the main slot.
    @objc public func reenterStageFromLauncher() {
        reenterStage(promote: nil)
    }

    private func notifyCollapsedStateChanged() {
        NotificationCenter.default.post(name: Self.collapsedStateChangedNotification, object: nil)
    }

    // MARK: - Adaptive control-glyph backdrop sampling
    //
    // A hosted scene's cross-process pixels render black in every host-side snapshot, so the host
    // cannot measure what is behind the controls. The MAIN guest instead publishes a coarse 16×12
    // luma grid of its own rendered content (TweakLoader, 2Hz). Every control maps its on-screen
    // centre into the main card's coordinate space, reads the single grid cell behind it and tints
    // itself white on dark content / near-black on light content, with a per-control hysteresis
    // band so mid-greys never make one glyph oscillate. Whole-screen mean used to mis-tint every
    // button of a mostly light app whose top strip was dark.

    /// Luma bytes (0...255) bounding the per-control hysteresis band.
    private static let backdropDarkByte: UInt8 = 107   // 0.42
    private static let backdropLightByte: UInt8 = 148  // 0.58
    private static let backdropMidByte: UInt8 = 128

    private func startBackdropProbe() {
        guard backdropProbeTimer == nil else { return }
        // Probe immediately so the first decision doesn't wait a full period.
        DispatchQueue.main.async { [weak self] in self?.sampleBackdropGrid() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sampleBackdropGrid()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        backdropProbeTimer = timer
    }

    private func stopBackdropProbe() {
        backdropProbeTimer?.invalidate()
        backdropProbeTimer = nil
        backdropButtonDark.removeAll()
    }

    private func sampleBackdropGrid() {
        guard isStagePresented,
              !isStageCollapsed,
              UIApplication.shared.applicationState == .active,
              let mainView = apps.first?.view,
              mainView.bounds.width > 1,
              mainView.bounds.height > 1,
              let mainUUID = apps.first?.appUUID,
              let grid = LCStageHostGuestBackdropGrid(mainUUID, 2.0) else { return }
        let bytes = [UInt8](grid)
        let cols = Int(LCStageBackdropGridCols)
        let rows = Int(LCStageBackdropGridRows)
        guard bytes.count == cols * rows else { return }

        for button in allChromeButtons where !button.isHidden && button.alpha > 0.1 {
            // Map the control centre into the main card's coordinate space. The card view hosts
            // the guest's full-screen content scaled to fit, so card-space normalized coordinates
            // are exactly the guest's normalized screen coordinates — which is how the guest
            // stretched its render into the same cols×rows grid.
            let centre = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
            let p = button.convert(centre, to: mainView)
            var nx = p.x / mainView.bounds.width
            var ny = p.y / mainView.bounds.height
            // The controls live in the blank strip ABOVE the block. Clamp to the top edge: the
            // patch nearest a floating control is the content row directly below it, not the
            // wrapped-around bottom row.
            nx = min(max(nx, 0), 0.999_999)
            ny = min(max(ny, 0), 0.999_999)
            let col = Int(nx * CGFloat(cols))
            let row = Int(ny * CGFloat(rows))
            let luma = bytes[row * cols + col]

            let key = ObjectIdentifier(button)
            let dark: Bool
            if let current = backdropButtonDark[key] {
                // Hysteresis: once dark, stay dark until luma crosses ABOVE the light threshold;
                // once light, stay light until it drops BELOW the dark threshold.
                dark = current ? (luma <= Self.backdropLightByte)
                               : (luma < Self.backdropDarkByte)
            } else {
                dark = luma < Self.backdropMidByte
            }
            guard backdropButtonDark[key] != dark else { continue }
            backdropButtonDark[key] = dark
            button.setGlyphOnDarkBackground(dark, animated: true)
        }
    }

    // MARK: - Dock taps

    func runningIndex(for app: LCAppModel) -> Int? {
        let folder = app.uiSelectedContainer?.folderName
        let name = app.appInfo.displayName()
        return apps.firstIndex { model in
            if let folder, model.appUUID == folder { return true }
            return model.appName == name
        }
    }

    func stageDockTapped(_ app: LCAppModel) {
        if let index = runningIndex(for: app) {
            // Also covers the collapsed-to-launcher state: the tap brings the whole stage back.
            if isStageCollapsed {
                reenterStage(promote: index > 0 ? apps[index].appUUID : nil)
            } else {
                promoteToMain(index: index)
            }
            return
        }

        guard apps.count < MultitaskStageLayout.maxWindows else {
            presentAlert(title: "lc.multitask.stageLimitTitle".loc, message: "lc.multitask.stageLimitMessage".loc)
            return
        }

        Task { @MainActor in
            do {
                try await app.runApp(multitask: true)
            } catch {
                self.presentAlert(title: "lc.common.error".loc, message: error.localizedDescription)
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard let window = self.keyWindow else { return }
            var presenter = window.rootViewController
            while let presented = presenter?.presentedViewController {
                presenter = presented
            }
            guard let presenter = presenter else { return }

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
            presenter.present(alert, animated: true)
        }
    }

    // MARK: - Pre-launch guarding

    /// Pre-check executed on the ObjC launch path BEFORE the guest process is spawned (the
    /// stage guard used to run only in `addRunningAppWithInfo`, i.e. after the extension
    /// request had already launched a guest that then held the container lock forever).
    /// - nil: launch allowed
    /// - empty string: the container already has a window on stage (it was just promoted to
    ///   the main slot); the caller aborts the launch silently
    /// - non-empty string: localized rejection message the caller surfaces as an error
    @objc(blockedReasonForNewStageWindowUUID:)
    public class func blockedReason(forNewStageWindow uuid: String) -> String? {
        let manager = shared
        let check: () -> String? = {
            guard manager.isDockEnabled() else { return nil }
            if let index = manager.apps.firstIndex(where: { $0.appUUID == uuid }) {
                // The watchdog's in-place recovery relaunches the SAME container on purpose;
                // the slot is waiting for this exact guest, so let it through.
                if manager.apps[index].isRecovering {
                    return nil
                }
                // The container is already on stage: if the stage was collapsed to the launcher,
                // bring it back; otherwise just promote the window to the main slot.
                if manager.isStageCollapsed {
                    manager.reenterStage(promote: uuid)
                } else {
                    manager.promoteToMain(index: index)
                }
                return ""
            }
            if manager.apps.count >= MultitaskStageLayout.maxWindows {
                return "lc.multitask.stageLimitMessage".loc
            }
            return nil
        }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
    }

    // MARK: - Multitask mode check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - Bottom dock
@available(iOS 16.0, *)
struct MultitaskStageDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    // The dock follows the LiveContainer app list's sort order (left → right) instead of the
    // raw insertion order, so reordering the management page reorders the stage dock too.
    @ObservedObject var sortManager = LCAppSortManager.shared
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(sortManager.sortedApps, id: \.self) { app in
                    MultitaskStageDockIcon(app: app, darkModeIcon: darkModeIcon) {
                        dockManager.stageDockTapped(app)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
        .modifier(MultitaskStageDockBackground())
    }
}

/// Matches the iOS dock: a full width translucent slab that sits above the home indicator.
/// On iOS 26 it uses the real Liquid Glass material; older systems fall back to a thinner
/// approximation that keeps the same silhouette and light-catching top edge.
@available(iOS 16.0, *)
struct MultitaskStageDockBackground: ViewModifier {
    /// The iOS 26 dock reads as a glass slab with a very large radius, not a small rounded card.
    /// Deriving it from the dock height keeps the proportions right if the dock is resized.
    private let cornerRadius: CGFloat = MultitaskStageLayout.dockHeight * 0.42

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .clipShape(shape)
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            // Glass catches light on the top edge and falls off toward the bottom.
                            shape.stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.34), .white.opacity(0.06)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                        }
                }
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskStageDockIcon: View {
    let app: LCAppModel
    let darkModeIcon: Bool
    let action: () -> Void

    @State private var icon: UIImage?

    /// Same edge length as a home-screen dock icon (60pt).
    private static let iconSize: CGFloat = 60
    /// The iOS 26 app-icon mask: a continuous-corner squircle whose radius is 26.67% of the
    /// icon edge (the ratio the rest of the app already uses for icon masks). Without it the
    /// raw artwork would show its own square corners, which reads as "not an iOS 26 icon".
    private static let iconShape = RoundedRectangle(cornerRadius: iconSize * 0.2667, style: .continuous)

    var body: some View {
        // A plain Button keeps SwiftUI's native gesture arbitration with the horizontal
        // ScrollView, so the dock can still be scrolled while a press still highlights.
        Button(action: action) {
            Group {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            .clipShape(Self.iconShape)
            .contentShape(Rectangle())
        }
        .buttonStyle(StagePressButtonStyle())
        .onAppear(perform: loadIcon)
    }

    private func loadIcon() {
        guard icon == nil else { return }
        let cacheKey = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "?"

        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            icon = cachedIcon
            return
        }

        let dark = darkModeIcon
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = app.appInfo.iconIsDarkIcon(dark)
            DispatchQueue.main.async {
                if let loaded {
                    self.icon = loaded
                    IconCacheManager.shared.setIcon(loaded, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press feedback
/// macOS dock style press feedback: the icon scales up instantly while held and springs back
/// with a slight overshoot on release.
@available(iOS 16.0, *)
struct StagePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.12 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    // NSCache is thread-safe on its own, evicts images under memory pressure, and caps how many
    // icons stay resident — the hand-rolled concurrent queue + unbounded dictionary did neither.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private init() {}

    func getIcon(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setIcon(_ icon: UIImage, for key: String) {
        cache.setObject(icon, forKey: key as NSString)
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}

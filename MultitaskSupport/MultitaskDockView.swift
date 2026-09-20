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

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
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
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
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
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
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
    let view: UIView?
    /// When this window entered the stage. The watchdog never judges a window that is still
    /// inside the guest-start grace window (see pruneDeadWindows(allowHeartbeatPrune:)): a
    /// freshly launched guest needs a moment before it writes its first heartbeat.
    let addedAt = Date()
    
    init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - Stage manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject, MultitaskStageControlsDelegate {
    @objc public static let shared = MultitaskDockManager()

    /// Running apps in stage order: index 0 is the main window, 1...3 are the side windows.
    @Published var apps: [DockAppModel] = []
    @Published var isFullscreen: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()

    private var dockHost: UIHostingController<AnyView>?
    private let controls = MultitaskStageControlsView(frame: .zero)

    /// Highest-level invisible window that routes touches for the stage. Side-window touches are
    /// captured in UIApplication.sendEvent (hooked in UIKitHooks.m), because the system-level
    /// hosted-view touch delivery bypasses the regular UIKit hit-test chain, while the main
    /// window's touches are forwarded straight through.

    /// The four slots tile into one rectangle, so a single shadow caster behind them lifts the
    /// whole block off the desktop without drawing overlapping shadows inside the shared edges.
    private let blockShadowView = UIView()

    /// Whether the stage page (background, windows, controls, dock) is currently on screen.
    /// The stage is a page of its own, not a permanent overlay: it fades in when the first app
    /// launches and fades out together with the dock once the last window closes.
    private var isStagePresented = false
    /// Re-entry guard while the stage geometry is animating, so quick repeated zoom/promote
    /// taps cannot stack two geometry animations on top of each other.
    private var isLayoutAnimating = false
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
    /// Last time the host entered (or was confirmed in) the foreground. Heartbeat pruning is
    /// suppressed for a grace window after that, because suspension freezes every guest timer
    /// and a fresh resume would otherwise look like all four guests died at once.
    private var lastHostWakeAt = Date()

    private static let layoutAnimationDuration: TimeInterval = 0.4

    override init() {
        super.init()
        if let rootView = keyWindow?.rootViewController?.view {
            // The windows live inside the app's own hierarchy; the controls and the dock sit on
            // the window itself so they are always drawn above every guest window.
            // The stage only becomes a page once a window exists, so it starts out hidden.
            windowHostingView.isHidden = true
            (rootView.subviews.first ?? rootView).addSubview(self.windowHostingView)
        }

        blockShadowView.isUserInteractionEnabled = false
        blockShadowView.isHidden = true
        blockShadowView.backgroundColor = .black
        blockShadowView.layer.cornerCurve = .continuous
        blockShadowView.layer.cornerRadius = MultitaskStageLayout.cornerRadius
        blockShadowView.layer.masksToBounds = false
        blockShadowView.layer.shadowColor = UIColor.black.cgColor
        blockShadowView.layer.shadowOpacity = 0.38
        blockShadowView.layer.shadowOffset = CGSize(width: 0, height: 8)
        blockShadowView.layer.shadowRadius = 22
        windowHostingView.addSubview(blockShadowView)

        controls.delegate = self
        controls.isHidden = true
        keyWindow?.addSubview(controls)

        setupDockView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        // Memory management while the device is locked: suspend side-window scenes so the
        // system does not kill them under background memory pressure. Restore on unlock.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
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
            self.keyWindow?.addSubview(host.view)
            self.dockHost = host

            // The stage only becomes a page once a window exists, so it starts out hidden.
            self.windowHostingView.isHidden = true
            self.performLayout(animated: false)
        }
    }

    // MARK: - Stage layout

    @objc public func relayout(animated: Bool) {
        DispatchQueue.main.async {
            self.performLayout(animated: animated)
        }
    }

    private func performLayout(animated: Bool) {
        guard let window = keyWindow else { return }
        let bounds = window.bounds
        let safeArea = window.safeAreaInsets
        let count = apps.count

        // Whatever a previous teardown left in the hierarchy must never cover the windows that
        // are live right now — this also runs on the way out, when the last window closed.
        removeOrphanWindowViews()

        guard count > 0 else {
            // Last window closed: leave the stage page and go back to the launcher. The dock,
            // controls and stage background all leave together, so nothing is left floating on
            // top of LiveContainer's own UI.
            if isStagePresented {
                dismissStage()
            }
            // Release every guest from side-window touch quarantine.
            publishStageRoles(active: false)
            return
        }

        // First window: the stage page enters as a whole on top of the launcher.
        let entering = !isStagePresented
        isStagePresented = true
        windowHostingView.isHidden = false
        dockHost?.view.isHidden = false
        if entering {
            windowHostingView.alpha = 0
            dockHost?.view.alpha = 0
        }

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
                    view.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
                    view.layer.borderWidth = MultitaskStageLayout.hairline
                }
            }

            // The main window has to end up frontmost, so front the slots back to front.
            for app in self.apps.reversed() {
                if let view = app.view {
                    self.windowHostingView.bringSubviewToFront(view)
                }
            }
            self.windowHostingView.sendSubviewToBack(self.blockShadowView)

            self.blockShadowView.frame = MultitaskStageLayout.blockFrame(bounds: bounds, safeArea: safeArea)
            self.blockShadowView.isHidden = self.isFullscreen

            self.controls.isHidden = false
            self.controls.isFullscreen = self.isFullscreen
            self.controls.frame = self.isFullscreen
                ? MultitaskStageLayout.fullscreenControlsFrame(bounds: bounds, safeArea: safeArea)
                : MultitaskStageLayout.controlsFrame(bounds: bounds, safeArea: safeArea)

            if let dockView = self.dockHost?.view {
                // Fullscreen means the guest app owns the whole screen, dock included.
                dockView.isHidden = false
                dockView.alpha = self.isFullscreen ? 0 : 1
                dockView.frame = MultitaskStageLayout.dockFrame(bounds: bounds, safeArea: safeArea)
            }
        }

        if animated && UIAccessibility.isReduceMotionEnabled {
            armGeometryCommitIfNeeded()
            isLayoutAnimating = true
            UIView.transition(with: windowHostingView, duration: 0.2, options: .transitionCrossDissolve, animations: update)
            UIView.animate(withDuration: 0.2) { self.dockHost?.view.alpha = self.isFullscreen ? 0 : 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.settleAfterAnimation()
            }
        } else if animated {
            armGeometryCommitIfNeeded()
            let animator = UIViewPropertyAnimator(
                duration: MultitaskDockManager.layoutAnimationDuration,
                timingParameters: UISpringTimingParameters(dampingRatio: 1.0)
            )
            isLayoutAnimating = true
            animator.addAnimations(update)
            animator.addCompletion { [weak self] _ in
                self?.settleAfterAnimation()
            }
            animator.startAnimation()
        } else {
            update()
        }

        if entering {
            // Cross-fade the whole page in, independently of the slot layout inside it. Reset
            // the alphas after `update` ran (it sets the dock's settled alpha) so the fade
            // always starts from 0.
            let dockTargetAlpha: CGFloat = isFullscreen ? 0 : 1
            windowHostingView.alpha = 0
            dockHost?.view.alpha = 0
            UIView.animate(withDuration: 0.22, delay: 0, options: .allowUserInteraction) {
                self.windowHostingView.alpha = 1
                self.dockHost?.view.alpha = dockTargetAlpha
            }
        }

        window.bringSubviewToFront(controls)
        if let dockView = dockHost?.view {
            window.bringSubviewToFront(dockView)
        }

        // Tell every guest who the main window is. Side windows quarantine
        // their own touches; the main window keeps full interactivity.
        publishStageRoles(active: true)
    }

    /// Publishes the stage role state (active flag + main window UUID) that the
    /// guest processes read to decide whether to quarantine their touches.
    private func publishStageRoles(active: Bool) {
        guard isDockEnabled() else {
            LCStagePublishRoles(false, nil)
            return
        }
        LCStagePublishRoles(active, active ? apps.first?.appUUID : nil)
    }

    /// A window whose guest never wrote a single heartbeat once it is older than this is not
    /// "still starting" any more: TweakLoader (the only writer of the heartbeat) loads as part
    /// of the guest's own dlopen, i.e. well before the app's main() runs. No heartbeat therefore
    /// means either the guest bailed out in LCBootstrap (another process still held its
    /// container) or it died on the way up — both leave a black window that only a teardown can
    /// clear, and an orphan process that still holds the container.
    private static let guestStartGrace: TimeInterval = 20

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
        if allowHeartbeatPrune {
            let absoluteNow = CFAbsoluteTimeGetCurrent()
            for app in apps {
                // A window that just entered the stage is never pruned: its guest still has to
                // boot, and the heartbeat key may hold a previous run's timestamp until the new
                // guest writes its own (write-addressed keys survive in the App Group).
                guard now.timeIntervalSince(app.addedAt) > Self.guestStartGrace else { continue }

                // Every guest writes a heartbeat once per second (UIKit+GuestHooks.m).
                let hbKey = "LCGuestHeartbeat.\(app.appUUID)"
                if let last = LCUtils.appGroupUserDefault.object(forKey: hbKey) as? Double {
                    // 10-second deadline: generous for scheduling delays, short
                    // enough to not linger as a black card after close/crash.
                    if absoluteNow - last > 10 {
                        deadUUIDs.insert(app.appUUID)
                    }
                } else if app.appInfo?.dontInjectTweakLoader != true {
                    // No heartbeat at all after the grace window: the guest never ran the app.
                    deadUUIDs.insert(app.appUUID)
                }
            }
        }

        // A terminated window's view can be detached before its model left the
        // array (lost removal callback).
        for app in apps where app.view?.window == nil {
            deadUUIDs.insert(app.appUUID)
        }

        guard !deadUUIDs.isEmpty else { return false }
        NSLog("[LCStage] pruning \(deadUUIDs.count) window(s): \(deadUUIDs)")
        for uuid in deadUUIDs {
            tearDownWindow(uuid, reason: "unresponsive guest")
        }
        return true
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
    /// judged by an earlier process's timestamp.
    private func clearStaleGuestState(_ appUUID: String) {
        guard !appUUID.isEmpty else { return }
        let defaults = LCUtils.appGroupUserDefault
        defaults.removeObject(forKey: "LCGuestHeartbeat.\(appUUID)")
        defaults.synchronize()
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
        // age is meaningless in the background and for a few seconds after a resume.
        let inGrace = Date().timeIntervalSince(lastHostWakeAt) < 5
        let canPruneHeartbeats = UIApplication.shared.applicationState == .active && !inGrace
        if pruneDeadWindows(allowHeartbeatPrune: canPruneHeartbeats) {
            relayout(animated: false)
        } else {
            // Keep the role timestamp fresh even without layout changes.
            publishStageRoles(active: true)
        }
    }

    /// Called when an animated relayout changes the main window (fullscreen toggle, promotion
    /// or refill after a close). BackBoard derives a hosted scene's touch region from the hosting
    /// view's geometry, so once the layout animation has landed the settled geometry is pushed
    /// into the scene again — see commitMainWindowGeometry().
    private func armGeometryCommitIfNeeded() {
        let changed = lastSettledFullscreen != isFullscreen
            || lastSettledMainUUID != apps.first?.appUUID
        guard changed else { return }
        pendingGeometryGeneration += 1
    }

    /// Runs once when the geometry animation has landed: the settled layout is re-applied without
    /// animation and the main window's geometry is pushed into its hosted scene.
    private func settleAfterAnimation() {
        isLayoutAnimating = false
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
        isFullscreen = false
        controls.isHidden = true
        blockShadowView.isHidden = true
        // No stage on screen: every guest keeps its own touches again.
        publishStageRoles(active: false)
        UIView.animate(withDuration: 0.2, animations: {
            self.windowHostingView.alpha = 0
            self.dockHost?.view.alpha = 0
        }, completion: { _ in
            // A new app may have entered the stage while the fade-out was running; in that case
            // the entry path already showed everything again, so don't hide it here.
            guard !self.isStagePresented else { return }
            self.windowHostingView.isHidden = true
            self.dockHost?.view.isHidden = true
        })
    }

    // MARK: - Background memory management
    // Four simultaneously-active hosted scenes put a lot of pressure on iOS memory when the
    // device is locked. Suspend the side windows' scenes (foreground = NO) while the app is
    // backgrounded so they don't get killed outright; wake them back up on foreground.

    @objc private func appDidEnterBackground() {
        for app in apps.dropFirst() { // skip index 0 = main window (still foregrounded by system)
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            _ = vc.appSceneVC.perform(NSSelectorFromString("setHostedSceneForeground:"), with: false)
        }
    }

    @objc private func appWillEnterForeground() {
        lastHostWakeAt = Date()
        // Wake every scene back up (the background handler suspended the side
        // windows). Side touches are quarantined in the guest process, so their
        // regions simply returning on-screen is harmless; the main window gets
        // its settled geometry pushed again so its region covers its slot.
        for app in apps {
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            _ = vc.appSceneVC.perform(NSSelectorFromString("setHostedSceneForeground:"), with: true)
        }
        commitMainWindowGeometry()
        // Re-layout so the stage and shields are restored to their proper positions.
        DispatchQueue.main.async {
            self.relayout(animated: false)
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
        guard !apps.contains(where: { $0.appUUID == appUUID }) else { return }
        // Single choke point for the maxWindows guard — every entry path flows through here.
        guard apps.count < MultitaskStageLayout.maxWindows else { return }

        let appName = appInfo?.displayName() ?? "Unknown App"
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
            // applyStageFrame pushes all view frames synchronously, so by the time this relayout
            // has landed every window already sits at its final slot.
            self.relayout(animated: false)
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
                self?.commitMainWindowGeometry()
            }
        }
        if Thread.isMainThread {
            insertWindow()
        } else {
            DispatchQueue.main.async(execute: insertWindow)
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
        guard !isFullscreen, apps.count > 1 else { return false }
        // Only the window that actually hosts the stage can match a side slot; a touch over
        // any other window (alert, sheet, ...) must never promote anything.
        guard let stageView = apps.first?.view, stageView.window === window else { return false }
        for index in 1..<apps.count {
            guard let view = apps[index].view else { continue }
            if view.convert(view.bounds, to: window).contains(location) {
                // promoteToMain no-ops while a layout animation is in flight, but the touch
                // is always swallowed so it can never leak into the side app.
                promoteToMain(index: index)
                return true
            }
        }
        return false
    }

    func promoteToMain(index: Int) {
        guard !isLayoutAnimating else { return }
        guard index >= 0, index < apps.count else { return }
        if index > 0 {
            let app = apps.remove(at: index)
            apps.insert(app, at: 0)
        }
        // Flip touch ownership immediately: the old main starts quarantining
        // and the new main releases touches while the promotion animates.
        publishStageRoles(active: true)
        relayout(animated: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc func stageControlsDidTapClose() {
        guard let vc = apps.first?.view?._viewDelegate() as? DecoratedAppSceneViewController else { return }
        // Closing terminates the guest process, so acknowledge the destructive commit with the
        // hard-edged feedback that belongs to a destructive action.
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        vc.closeWindow()
    }

    @objc func stageControlsDidTapZoom() {
        guard !isLayoutAnimating else { return }
        isFullscreen.toggle()
        relayout(animated: true)
        // Fires on the same frame the layout animation starts, so the tap and the motion read as
        // one event.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            promoteToMain(index: index)
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
    @ObservedObject var model = DataManager.shared.model
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.apps, id: \.self) { app in
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
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}

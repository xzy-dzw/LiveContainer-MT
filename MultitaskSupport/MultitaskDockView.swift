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
    /// Tiny build marker shown on the stage so the exact commit running on device is obvious.
    private let buildLabel = UILabel()

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
    /// Snapshot cover that hides the touch-region re-registration blip at settle.
    private var geometryCommitCover: UIView?
    /// True once we've kicked off a C2 offscreen re-registration for the side windows in the
    /// current settleAfterAnimation. Used to guard against double-blips when pendingGeometry
    /// gets re-armed mid-settle (the generation counter handles this too, but the flag catches
    /// the case where a single settle tries to flip side-window foreground twice).
    private var sideWindowRegistrationInFlight = false

    /// Runtime diagnostics shown in the build label: they prove on-device how far a side-window
    /// tap travels through the interception chain (seen by the UIApplication hook / the UIWindow
    /// hook / swallowed / promoted) and whether the close path fires (exit callback / removal).
    @objc public var diagBeganApp = 0
    @objc public var diagBeganWindow = 0
    @objc public var diagIntercepted = 0
    @objc public var diagPromoted = 0
    @objc public var diagExited = 0
    @objc public var diagRemoved = 0

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

            // Build marker: shows the stamped commit so the package on device is unmistakable,
            // plus the live diagnostic counters that trace the touch interception chain.
            self.buildLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            self.buildLabel.textColor = .label
            self.buildLabel.alpha = 0.55
            self.buildLabel.isHidden = true
            self.updateBuildLabel()
            self.keyWindow?.addSubview(self.buildLabel)
            // The stage only becomes a page once a window exists, so it starts out hidden.
            self.windowHostingView.isHidden = true
            self.performLayout(animated: false)
        }
    }

    /// Re-stamps the build label with the commit and the live diagnostic counters.
    private func updateBuildLabel() {
        let commit = Bundle.main.object(forInfoDictionaryKey: "LCBuildCommit") as? String ?? ""
        let build = commit.isEmpty ? "build ?" : "build " + commit
        // Read guest-side counters from the shared App Group. They are written by the
        // UIApplication.sendEvent hook installed in each LiveProcess extension. If guestBegan
        // stays 0 while tapping a side window, the touch never entered the guest process and
        // Plan D (intercept inside guest) will not work as-is — we'll need a different hook
        // point (UIWindow.sendEvent or scene-level API).
        let guestBegan = LCUtils.appGroupUserDefault.integer(forKey: "LCGuestTouchBegan")
        let guestDataUUID = LCUtils.appGroupUserDefault.string(forKey: "LCGuestTouchDataUUID") ?? ""
        buildLabel.text = "\(build)  e\(diagBeganApp) w\(diagBeganWindow) h\(diagIntercepted) p\(diagPromoted) x\(diagExited) r\(diagRemoved) | g\(guestBegan)[\(guestDataUUID.prefix(4))]"
    }

    /// Counters are bumped from the sendEvent hooks on whatever thread UIKit delivers events on,
    /// so the label refresh is marshalled onto the main queue.
    @objc public func refreshDiagnosticsLabel() {
        DispatchQueue.main.async { [weak self] in
            self?.updateBuildLabel()
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

        guard count > 0 else {
            // Last window closed: leave the stage page and go back to the launcher. The dock,
            // controls and stage background all leave together, so nothing is left floating on
            // top of LiveContainer's own UI.
            if isStagePresented {
                dismissStage()
            }
            return
        }

        // First window: the stage page enters as a whole on top of the launcher.
        let entering = !isStagePresented
        isStagePresented = true
        windowHostingView.isHidden = false
        dockHost?.view.isHidden = false
        buildLabel.isHidden = false
        if entering {
            windowHostingView.alpha = 0
            buildLabel.alpha = 0
            dockHost?.view.alpha = 0
        }

        let update = { [weak self] in
            guard let self else { return }
            // MARK: Dead-window cleanup via guest heartbeat

            // Every guest process writes a timestamp to the App Group once per second (see
            // UIKit+GuestHooks.m). If a window's heartbeat has not moved for 10+ seconds, the
            // guest process is dead — either it crashed, got SIGKILLed under memory pressure, or
            // never launched in the first place. Self-heal below only drops windows whose view
            // is detached from the window hierarchy; a dead guest still has a visible (black)
            // view, so the heartbeat check is the only signal that catches it reliably.
            let now = CFAbsoluteTimeGetCurrent()
            var deadUUIDs: Set<String> = []
            for app in self.apps {
                // Skip self-hosted (no separate guest process). Check heartbeat from App Group.
                let hbKey = "LCGuestHeartbeat.\(app.appUUID)"
                if let last = LCUtils.appGroupUserDefault.object(forKey: hbKey) as? Double {
                    // 10-second deadline — heartbeat fires every 1s so this is generous enough
                    // for transient scheduling delays but short enough to not linger as a black
                    // screen after the user closes or relaunches.
                    if now - last > 10 {
                        deadUUIDs.insert(app.appUUID)
                    }
                } else {
                    // No heartbeat at all: either a guest that hasn't started yet (safe to keep
                    // waiting) or a self-hosted window (not applicable). Leave it alone.
                }
            }
            if !deadUUIDs.isEmpty {
                self.apps.removeAll { deadUUIDs.contains($0.appUUID) }
                NSLog("[LCStage] heartbeat: removed \(deadUUIDs.count) dead window(s): \(deadUUIDs)")
            }

            // Self-heal: a terminated window's view can be detached from the stage before its
            // model left the array (lost removal callback). Dropping detached models here lets
            // the next app slide into the main slot on this very layout pass instead of leaving
            // an empty main slot behind.
            if self.apps.contains(where: { $0.view?.window == nil }) {
                self.apps.removeAll { $0.view?.window == nil }
            }
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

            self.buildLabel.frame = CGRect(
                x: safeArea.left + 10,
                y: bounds.height - safeArea.bottom - MultitaskStageLayout.dockHeight - 20,
                width: 300,
                height: 14
            )
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
            buildLabel.alpha = 0
            dockHost?.view.alpha = 0
            UIView.animate(withDuration: 0.22, delay: 0, options: .allowUserInteraction) {
                self.windowHostingView.alpha = 1
                self.buildLabel.alpha = 0.55
                self.dockHost?.view.alpha = dockTargetAlpha
            }
        }

        window.bringSubviewToFront(controls)
        if let dockView = dockHost?.view {
            window.bringSubviewToFront(dockView)
        }
        window.bringSubviewToFront(buildLabel)
    }

    /// Called when an animated relayout changes the main window (fullscreen toggle, promotion
    /// or refill after a close). The hosted scene's system touch region only re-registers on a
    /// foreground NO→YES transition, so settleAfterAnimation runs that blip once the final
    /// geometry is in place. The scene stays foreground for the whole animation: backgrounding it
    /// mid-gesture froze the content and the reactivation showed up as a flash.
    private func armGeometryCommitIfNeeded() {
        let changed = lastSettledFullscreen != isFullscreen
            || lastSettledMainUUID != apps.first?.appUUID
        guard changed else { return }
        pendingGeometryGeneration += 1
    }

    /// Runs once when the geometry animation has landed. The settled layout is re-applied without
    /// animation, then every window gets its system touch region pushed to the right spot:
    ///
    ///   - Main window → re-registered at its on-screen slot (so it stays interactive).
    ///   - Side windows → re-registered at an off-screen CGRect. The window content still
    ///     renders live in its side slot (the view frame is real), but the system touch region
    ///     lives at {x = screenWidth + 100} so taps land nowhere in the visible stage and
    ///     cascade down to the host process' normal hit-test chain where they are intercepted.
    ///
    /// This is Plan C2 — "register offscreen, display onscreen" — and it is the only known way
    /// to satisfy "4 windows all live + side windows tappable without touching the app inside"
    /// on iOS hosted scenes, since the system routes touches through a BackBoard region table
    /// that bypasses UIKit hit-testing entirely.
    ///
    /// C2 depends on a single fragile assumption: the region table is only recomputed on
    /// foreground transition, never on frame changes alone. If a future iOS changes this, the
    /// whole mechanism silently stops working. We guard against that by centralising it here —
    /// a fallback to Plan B (side windows backgrounded) is a one-line flip.
    private func settleAfterAnimation() {
        isLayoutAnimating = false
        performLayout(animated: false)
        let currentGen = pendingGeometryGeneration
        // Guard 1: generation counter. If the arm happened twice for the same settle (two
        // overlapping animations arming before either settles), only the first settle runs the
        // blip chain. The second settle sees a different generation and discards itself.
        guard currentGen != lastSettledGeneration else { return }
        // Guard 2: no arm at all. Happens when relayout is called without a fullscreen/promotion
        // change (e.g. dock only relayouts, or device orientation while nothing moved). Skip.
        guard currentGen > 0 else { return }
        lastSettledGeneration = currentGen

        lastSettledFullscreen = isFullscreen
        lastSettledMainUUID = apps.first?.appUUID
        sideWindowRegistrationInFlight = true

        // Cover the main window for the main-slot blip (snapshot swap, same as before).
        coverMainWindowForGeometryCommit()
        guard let main = apps.first?.view?._viewDelegate() as? DecoratedAppSceneViewController else { return }

        // Step 1: main window. Move its touch region to its actual on-screen frame, blip NO→YES.
        main.appSceneVC.prepareHostedGeometryCommit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            self.runMainWindowBlipCompletion(mainVC: main)
            // Step 2: side windows. AFTER the main blip finishes (so snapshots don't collide),
            // blip each side window's scene with its container moved off-screen for the duration
            // of the foreground transition. The window renders live at its slot frame; only the
            // system touch region moves.
            self.runSideWindowOffscreenRegistrations()
        }
    }

    /// Main window half of settleAfterAnimation — finish the blip, reveal the cover with fade.
    private func runMainWindowBlipCompletion(mainVC: DecoratedAppSceneViewController) {
        mainVC.appSceneVC.finishHostedGeometryCommit()
        guard let cover = geometryCommitCover else { return }
        geometryCommitCover = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            UIView.animate(withDuration: 0.15, animations: { cover.alpha = 0 }) { _ in
                cover.removeFromSuperview()
            }
        }
    }

    /// For every side window (index > 0), re-register its system touch region at an off-screen
    /// location. The view itself stays at its slot frame (live render keeps running), but the
    /// system touch region moves to {screenWidth + 100} so taps land nowhere in the visible
    /// stage and cascade into the host process where the sendEvent hook can intercept them.
    ///
    /// How: push scene frame to off-screen → foreground NO → wait → foreground YES → restore frame.
    /// Each side window's scene is independent, so blips are serialised (one at a time) to keep
    /// the total off-time short per app. A hard 100ms timeout on each flip prevents any side
    /// window from getting stuck in NO state if the system doesn't acknowledge the transition.
    private func runSideWindowOffscreenRegistrations() {
        // Only the real side windows (index 1+). Skip the main window — its touch region is
        // already correct after the main blip just above. Also skip fullscreen: there are no
        // side slots when the main window owns the whole screen.
        let sideApps = apps.dropFirst().enumerated().compactMap { (indexOffset, app) -> (String, DecoratedAppSceneViewController)? in
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { return nil }
            return (app.appUUID, vc)
        }
        guard !sideApps.isEmpty else {
            sideWindowRegistrationInFlight = false
            return
        }

        // Compute a safe off-screen frame (outside both x and y of the stage) — we use the
        // stage bounds so the area is cleanly outside the visible stage block.
        let screenBounds = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? UIScreen.main.bounds
        let offscreenFrame = CGRect(x: screenBounds.width + 100, y: 0, width: 0, height: 0)

        // Serialise blips — one per side window, each ~100ms. With at most 3 side windows this
        // takes ~300ms total, well below the 1s heartbeat timeout so no fake "dead" windows.
        var delay: TimeInterval = 0
        for (_, vc) in sideApps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                // Step A: move scene frame to off-screen, push NO.
                vc.appSceneVC.updateSettingsWithBlock { settings in
                    settings.frame = offscreenFrame
                    settings.peripheryInsets = UIEdgeInsets.zero
                    settings.safeAreaInsetsPortrait = UIEdgeInsets.zero
                    settings.foreground = false
                }
                // Step B: hard 100ms timeout — don't trust the foreground transition to finish
                // promptly. If it hangs we still flip back after the deadline.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    // Step C: push YES back, let the system re-register with the off-screen frame.
                    vc.appSceneVC.updateSettingsWithBlock { settings in
                        settings.foreground = true
                    }
                    // Step D: restore the scene frame — updateSettingsWithBlock:nil re-pushes the
                    // frame derived from view.frame (which is already at the correct side slot
                    // after performLayout). The touch region stays where it was registered (off),
                    // so we get "displayed on-screen, touched off-screen" = C2.
                    vc.appSceneVC.updateFrameWithSettingsBlock(nil)
                }
            }
            delay += 0.12
        }

        // Reset the guard flag once all serialised blips are scheduled.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
            self?.sideWindowRegistrationInFlight = false
        }
    }

    /// Snapshots the main window's current content and pins the snapshot above the live scene, so
    /// the foreground blip underneath is never visible. A failed capture yields a transparent
    /// view, which degrades gracefully to the uncovered behaviour.
    private func coverMainWindowForGeometryCommit() {
        geometryCommitCover?.removeFromSuperview()
        geometryCommitCover = nil
        guard let container = apps.first?.view,
              let cover = container.snapshotView(afterScreenUpdates: false) else { return }
        cover.frame = container.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(cover)
        geometryCommitCover = cover
    }

    private func dismissStage() {
        isStagePresented = false
        isFullscreen = false
        controls.isHidden = true
        blockShadowView.isHidden = true
        UIView.animate(withDuration: 0.2, animations: {
            self.windowHostingView.alpha = 0
            self.dockHost?.view.alpha = 0
            self.buildLabel.alpha = 0
        }, completion: { _ in
            // A new app may have entered the stage while the fade-out was running; in that case
            // the entry path already showed everything again, so don't hide it here.
            guard !self.isStagePresented else { return }
            self.windowHostingView.isHidden = true
            self.dockHost?.view.isHidden = true
            self.buildLabel.isHidden = true
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
        for app in apps {
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            _ = vc.appSceneVC.perform(NSSelectorFromString("setHostedSceneForeground:"), with: true)
        }
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

        DispatchQueue.main.async {
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
            self.relayout(animated: false)
        }
    }

    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        diagRemoved += 1
        refreshDiagnosticsLabel()

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
                diagIntercepted += 1
                refreshDiagnosticsLabel()
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
        diagPromoted += 1
        refreshDiagnosticsLabel()
        relayout(animated: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc func stageControlsDidTapClose() {
        guard let vc = apps.first?.view?._viewDelegate() as? DecoratedAppSceneViewController else { return }
        // Closing terminates the guest process, so acknowledge the destructive commit with a tap.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        vc.closeWindow()
    }

    @objc func stageControlsDidTapZoom() {
        guard !isLayoutAnimating else { return }
        isFullscreen.toggle()
        relayout(animated: true)
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 60, height: 60)
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

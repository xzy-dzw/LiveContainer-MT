//
//  MultitaskStage.swift
//  LiveContainer
//
//  1 main + 3 side window stage layout, the pair of glass window controls that live in the blank
//  strip above the main window, and the stage's FPS readout.
//

import Foundation
import SwiftUI
import UIKit
import CoreText

// MARK: - Geometry

@objc class MultitaskStageLayout: NSObject {
    /// Main window plus three side windows.
    @objc static let maxWindows = 4

    /// Blank strip above the window block that hosts the main window's controls. Tall enough for
    /// the HIG minimum hit target (44pt), so the controls never have to overlap a window.
    static let controlsHeight: CGFloat = 44
    /// Hit target of one window control, and the side of the glass circle it draws.
    static let controlSize: CGFloat = 44
    /// Gap between the two controls' hit targets: close enough that the pair reads as one piece of
    /// chrome, wide enough that a thumb never lands on both at once.
    static let controlSpacing: CGFloat = 6
    /// Combined width of the control pair.
    static var controlsWidth: CGFloat { controlSize * 2 + controlSpacing }
    /// Keeps the controls off the very edge of the screen, aligned with the main window's edge.
    static let controlLeadingInset: CGFloat = 12
    /// Trailing inset of the FPS readout, measured from the far edge of the strip.
    static let fpsTrailingInset: CGFloat = 12
    /// Gap between the FPS capsule and the handedness toggle beside it.
    static let chromeSpacing: CGFloat = 4
    /// Fixed size of the FPS readout: a glass capsule with a status dot, a square tabular
    /// value and a small superscript "FPS" unit; tightened around the smaller superscript unit.
    static let fpsWidth: CGFloat = 80
    static let fpsHeight: CGFloat = 30

    /// Persisted left/right handedness choice. NO (default): main window on the left for
    /// left-hand use; YES: mirrored, main window on the right. Stored in the App Group so the
    /// host and every guest agree on the geometry.
    private static let mirrorDefaultsKey = "LCStageLayoutMirrored"
    @objc static var isMirrored: Bool {
        get { LCUtils.appGroupUserDefault.bool(forKey: mirrorDefaultsKey) }
        set {
            LCUtils.appGroupUserDefault.set(newValue, forKey: mirrorDefaultsKey)
            LCUtils.appGroupUserDefault.synchronize()
        }
    }
    /// Bottom dock, sized like the iOS dock.
    static let dockHeight: CGFloat = 90
    static let dockSideInset: CGFloat = 10
    @objc static let cornerRadius: CGFloat = 12

    @objc static var hairline: CGFloat { 1.0 / UIScreen.main.scale }

    private struct Geometry {
        var unit: CGFloat = 0
        var sideHeight: CGFloat = 0
        var origin: CGPoint = .zero
    }

    /// Every slot keeps the phone's original aspect ratio: the main window is three units
    /// wide, each side window is one unit wide, and they tile with no gap in between.
    private static func geometry(_ bounds: CGRect, _ safeArea: UIEdgeInsets) -> Geometry {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return Geometry() }

        let available = height - safeArea.top - safeArea.bottom - controlsHeight - dockHeight
        var unit = width / CGFloat(maxWindows)
        var sideHeight = unit * height / width
        if available > 0, sideHeight * 3 > available {
            // Not enough vertical room for the natural size, shrink proportionally.
            sideHeight = available / 3
            unit = sideHeight * width / height
        }

        return Geometry(
            unit: unit,
            sideHeight: sideHeight,
            origin: CGPoint(
                x: (width - unit * CGFloat(maxWindows)) / 2,
                y: safeArea.top + controlsHeight + max(0, (available - sideHeight * 3) / 2)
            )
        )
    }

    /// Slot 0 is the main window, slots 1...3 are the stacked side windows. In right-handed
    /// (mirrored) layout the block flips horizontally: the side stack leads on the left and the
    /// main window trails on the right, while the side windows keep their top-to-bottom order.
    @objc static func slotFrame(_ index: Int, bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        let blockWidth = g.unit * CGFloat(maxWindows)
        if index <= 0 {
            let x = isMirrored ? g.origin.x + g.unit : g.origin.x
            return CGRect(x: x, y: g.origin.y, width: g.unit * 3, height: g.sideHeight * 3)
        }
        let sideX = isMirrored
            ? g.origin.x
            : g.origin.x + blockWidth - g.unit
        return CGRect(
            x: sideX,
            y: g.origin.y + g.sideHeight * CGFloat(index - 1),
            width: g.unit,
            height: g.sideHeight
        )
    }

    /// The guest app keeps its original resolution, so each slot scales the whole phone screen.
    @objc static func slotScaleRatio(_ index: Int, bounds: CGRect, safeArea: UIEdgeInsets) -> CGFloat {
        let g = geometry(bounds, safeArea)
        guard bounds.width > 0, g.unit > 0 else { return 1 }
        return (index <= 0 ? g.unit * 3 : g.unit) / bounds.width
    }

    /// The window controls live in the blank strip right above the MAIN window's outer edge: the
    /// leading edge in left-handed layout, the trailing edge in right-handed layout.
    ///
    /// Fullscreen shows ONLY the restore control (closing requires shrinking back to the split
    /// stage first), and the single control steps to the screen edge the main window now reaches.
    /// The width collapses with it, so the single circle keeps the same edge alignment.
    @objc static func controlsFrame(bounds: CGRect, safeArea: UIEdgeInsets, fullscreen: Bool) -> CGRect {
        let g = geometry(bounds, safeArea)
        let width = fullscreen ? controlSize : controlsWidth
        let edgeX: CGFloat
        if fullscreen {
            // The main window now reaches the screen boundary.
            edgeX = isMirrored
                ? bounds.width - controlLeadingInset - width
                : controlLeadingInset
        } else {
            // Split stage: hug the main window's outer side.
            edgeX = isMirrored
                ? g.origin.x + g.unit * 3 - controlLeadingInset - width
                : g.origin.x + controlLeadingInset
        }
        return CGRect(
            x: edgeX,
            y: safeArea.top + (controlsHeight - controlSize) / 2,
            width: width,
            height: controlSize
        )
    }

    /// The FPS readout hugs the screen edge OPPOSITE the controls (the side-window side), on the
    /// same line: right edge in left-handed layout, left edge in right-handed layout.
    @objc static func fpsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let x: CGFloat
        if isMirrored {
            x = fpsTrailingInset
        } else {
            x = max(0, bounds.width - fpsTrailingInset - fpsWidth)
        }
        return CGRect(
            x: x,
            y: safeArea.top + (controlsHeight - fpsHeight) / 2,
            width: fpsWidth,
            height: fpsHeight
        )
    }

    /// The handedness toggle sits immediately toward screen center from the FPS capsule (to the
    /// RIGHT of the FPS in mirrored layout, to its left otherwise), so the pair reads as one
    /// instrument cluster in either handedness.
    @objc static func handednessFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let fps = fpsFrame(bounds: bounds, safeArea: safeArea)
        let x = isMirrored
            ? fps.maxX + chromeSpacing
            : fps.minX - chromeSpacing - controlSize
        return CGRect(
            x: x,
            y: safeArea.top + (controlsHeight - controlSize) / 2,
            width: controlSize,
            height: controlSize
        )
    }

    @objc static func dockFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        return CGRect(
            x: dockSideInset,
            y: bounds.height - safeArea.bottom - dockHeight,
            width: max(0, bounds.width - dockSideInset * 2),
            height: dockHeight
        )
    }

    /// Fullscreen keeps the original resolution, so the scale ratio is 1.
    @objc static func fullscreenFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        return bounds
    }

    /// All four corners, used while fullscreen so the radius animates uniformly.
    static let allCorners: CACornerMask = [
        .layerMinXMinYCorner, .layerMaxXMinYCorner,
        .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
    ]

    /// Only the outer contour of the window block is rounded, shared edges stay flush. Mirrored
    /// layout swaps which side is the outer one: the main window rounds its right two corners and
    /// the side stack rounds its left two.
    static func maskedCorners(_ index: Int, count: Int) -> CACornerMask {
        if count <= 1 { return allCorners }
        if !isMirrored {
            if index <= 0 { return [.layerMinXMinYCorner, .layerMinXMaxYCorner] }
            var corners: CACornerMask = []
            if index == 1 { corners.insert(.layerMaxXMinYCorner) }
            if index == count - 1 { corners.insert(.layerMaxXMaxYCorner) }
            return corners
        }
        // Mirrored: main window on the right.
        if index <= 0 { return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] }
        var corners: CACornerMask = []
        if index == 1 { corners.insert(.layerMinXMinYCorner) }
        if index == count - 1 { corners.insert(.layerMinXMaxYCorner) }
        return corners
    }
}

// MARK: - Window controls

@objc protocol MultitaskStageControlsDelegate: AnyObject {
    func stageControlsDidTapClose()
    func stageControlsDidTapZoom()
}

/// One of the stage's two glass window controls.
///
/// The control answers on the way down instead of the way up: the glass takes its pressed look and
/// the whole control scales the moment the finger lands, so a tap can never feel dead. Releasing
/// springs back with the same critically damped feel the window layout uses, so the button and the
/// stage move as one material. The close control is the only one that takes a color while held —
/// red glass under the finger confirms the destructive intent before the release commits it, the
/// same way a destructive button stays neutral until it is actually pressed.
final class MultitaskStageGlassButton: UIButton {
    /// The glass this control takes on while pressed. nil keeps the neutral material and answers
    /// the press with scale alone.
    private let pressedTint: UIColor?

    /// The visible circle stays smaller than the 44pt hit target, so the strip reads as light
    /// chrome instead of two heavy discs.
    private static let circleSize: CGFloat = 34
    /// A 16pt semibold symbol inside a 34pt circle: the same glyph-to-circle proportion the system's
    /// own circular controls use, so the pair carries the weight of the two glass buttons without the
    /// symbols looking lost in them.
    private static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

    private let glass = UIVisualEffectView(effect: nil)
    private let tint = UIView()
    private let glyph = UIImageView()
    /// Whether the content behind the control is currently dark. Dark backdrops want a WHITE glyph
    /// (e.g. a black video in fullscreen); light backdrops want a dark glyph. Driven by the stage's
    /// backdrop-luma sampler. Starts dark: white is the safe choice before the first sample arrives.
    private var glyphOnDark = true
    private var isPressed = false

    init(symbol: String, pressedTint: UIColor?) {
        self.pressedTint = pressedTint
        super.init(frame: .zero)
        backgroundColor = .clear
        setupGlass()
        setupGlyph(symbol)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Swaps the glyph with the system's own symbol transition, so expand and restore morph into
    /// each other instead of blinking to the other arrow.
    func setSymbol(_ symbol: String) {
        guard let image = UIImage(systemName: symbol, withConfiguration: Self.glyphConfiguration) else { return }
        if #available(iOS 17.0, *) {
            glyph.setSymbolImage(image, contentTransition: .replace)
        } else {
            glyph.image = image
        }
    }

    /// Neutral material: the controls belong to the stage chrome, not to the guest app, so they must
    /// not borrow the app's accent color or compete with its content.
    private func setupGlass() {
        glass.isUserInteractionEnabled = false
        // The layer radius is what clips the fallback materials into a circle. Liquid Glass ignores
        // it and takes its shape from the corner configuration instead (see below).
        glass.layer.cornerRadius = Self.circleSize / 2
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true

        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            // The system's own Liquid Glass: what a control in a system toolbar is made of there.
            // The glass draws itself from the corner configuration rather than the layer, so the
            // circle has to be declared here as well — a square control asked for as a capsule is a
            // circle.
            glass.cornerConfiguration = .capsule()
            glass.effect = UIGlassEffect()
        } else if UIAccessibility.isReduceTransparencyEnabled {
            glass.effect = nil
            glass.backgroundColor = .secondarySystemFill
            addGlassBorder()
        } else {
            glass.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            addGlassBorder()
        }
        addSubview(glass)

        tint.backgroundColor = pressedTint
        tint.isUserInteractionEnabled = false
        tint.alpha = 0
        tint.clipsToBounds = true
        tint.layer.cornerCurve = .continuous
        addSubview(tint)
    }

    /// A hairline rim: without it the ultra thin material has no edge on a light backdrop. Real
    /// Liquid Glass draws its own rim, so it is only added to the fallback.
    private func addGlassBorder() {
        glass.layer.borderWidth = MultitaskStageLayout.hairline
        glass.layer.borderColor = UIColor.label.withAlphaComponent(0.12).cgColor
    }

    private func setupGlyph(_ symbol: String) {
        glyph.image = UIImage(systemName: symbol, withConfiguration: Self.glyphConfiguration)
        // White until the first backdrop sample: a dark glyph can vanish on a black video, a white
        // one always survives on the translucent glass.
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
    }

    /// Adaptive glyph color: dark backdrop → white glyph, light backdrop → near-black glyph.
    /// A destructive control (close) keeps white glyphs while its red press state is showing.
    func setGlyphOnDarkBackground(_ dark: Bool, animated: Bool) {
        guard dark != glyphOnDark else { return }
        glyphOnDark = dark
        let color = currentGlyphColor
        let apply = { self.glyph.tintColor = color }
        guard animated && !UIAccessibility.isReduceMotionEnabled else { apply(); return }
        // Cross-fade through a quick dissolve so the glyph never pops while a video cuts scenes.
        if let snapshot = glyph.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = glyph.frame
            addSubview(snapshot)
            glyph.tintColor = color
            glyph.alpha = 0
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: { self.glyph.alpha = 1 },
                           completion: { _ in snapshot.removeFromSuperview() })
        } else {
            UIView.transition(with: glyph, duration: 0.18,
                              options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
                              animations: apply)
        }
    }

    /// White under a finger on a tinted (destructive) button; otherwise white on dark backdrops,
    /// near-black on light backdrops.
    private var currentGlyphColor: UIColor {
        if isPressed && pressedTint != nil { return .white }
        return glyphOnDark ? .white : UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    }

    /// Press feedback. Reduce Motion keeps the color change — it is the feedback that says which
    /// control this is — and drops the scale, which the user has asked to stay still.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyPressedAppearance(isHighlighted)
        }
    }

    private func applyPressedAppearance(_ pressed: Bool) {
        isPressed = pressed
        let apply = {
            self.glyph.tintColor = self.currentGlyphColor
            self.tint.alpha = pressed ? 1 : 0
            self.transform = pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: pressed ? 0.12 : 0.34,
            delay: 0,
            usingSpringWithDamping: pressed ? 1.0 : 0.8,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: apply
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let circle = CGRect(
            x: (bounds.width - Self.circleSize) / 2,
            y: (bounds.height - Self.circleSize) / 2,
            width: Self.circleSize,
            height: Self.circleSize
        )
        glass.frame = circle
        tint.frame = circle
        tint.layer.cornerRadius = Self.circleSize / 2
        glyph.frame = bounds
    }
}

/// The stage's window chrome: two glass controls in the blank strip above the main window's leading
/// edge — close on the left, zoom/restore on the right, the order the hand already knows from a
/// window's title bar, with the destructive action where it is expected.
///
/// macOS puts three colored dots inside a window's title bar. On a phone that reads wrong — the dots
/// are small, they color the stage chrome in someone else's accent color, and a title bar would
/// steal a whole strip of the guest app's screen. So the stage keeps two HIG sized (44pt) controls,
/// and they never live inside a window: the pair sits in the blank strip above the main window's
/// leading edge and stays exactly there, in both layouts. The strip is the controls' home and the
/// window grows underneath it — chrome that slides while a window resizes reads as the button coming
/// apart under the finger, so the window is the only thing that moves.
@objc class MultitaskStageControlsView: UIView {
    @objc weak var delegate: MultitaskStageControlsDelegate?

    /// Fullscreen mode: the close control is retracted entirely. Closing now requires shrinking the
    /// window back to the split stage first — fullscreen is the guest app's screen, and a
    /// destructive button has no business floating over it.
    @objc var isFullscreen: Bool = false {
        didSet {
            guard isFullscreen != oldValue else { return }
            updateZoomControl()
            updateCloseVisibility(animated: true)
        }
    }

    private let closeButton = MultitaskStageGlassButton(
        symbol: "xmark",
        // Translucent red, not solid: the glass under it still shows through, so the control reads
        // as a red piece of glass rather than a red sticker.
        pressedTint: UIColor.systemRed.withAlphaComponent(0.82)
    )
    private let zoomButton = MultitaskStageGlassButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        pressedTint: nil
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        closeButton.accessibilityLabel = "lc.multitask.closeWindow".loc
        zoomButton.accessibilityLabel = "lc.multitask.zoomWindow".loc
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        zoomButton.addTarget(self, action: #selector(zoomTapped), for: .touchUpInside)
        addSubview(closeButton)
        addSubview(zoomButton)
        updateZoomControl()
        updateCloseVisibility(animated: false)
    }

    @objc private func closeTapped() {
        delegate?.stageControlsDidTapClose()
    }

    @objc private func zoomTapped() {
        delegate?.stageControlsDidTapZoom()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Expand while the stage shows the split layout, restore while the main window is fullscreen.
    /// The glyph morphs between the two arrows, so the control shows where the window is going
    /// rather than only what it is now.
    private func updateZoomControl() {
        zoomButton.setSymbol(isFullscreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right")
        zoomButton.accessibilityLabel = (isFullscreen ? "lc.multitask.restoreWindow" : "lc.multitask.zoomWindow").loc
    }

    /// Fades and shrinks the close control out of the strip in fullscreen; the restore control
    /// slides to its edge-aligned slot. The layout's own width collapses with the animation
    /// (the host's controlsFrame hands us the single-button width).
    private func updateCloseVisibility(animated: Bool) {
        let collapsed = isFullscreen
        let changes = {
            self.closeButton.alpha = collapsed ? 0 : 1
            self.closeButton.transform = collapsed
                ? CGAffineTransform(scaleX: 0.4, y: 0.4)
                : .identity
            // The restore button hugs the outer edge in both layouts: the left edge of the pair in
            // split mode, and the only slot in fullscreen.
            self.layoutButtons()
        }
        closeButton.isUserInteractionEnabled = !collapsed
        guard animated && !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(withDuration: 0.32, delay: 0,
                       usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: changes)
    }

    /// Forwards the backdrop-derived glyph color to both buttons (the hidden close one included, so
    /// it is already the right color the instant it returns in split mode).
    @objc func applyBackdropDark(_ dark: Bool, animated: Bool) {
        closeButton.setGlyphOnDarkBackground(dark, animated: animated)
        zoomButton.setGlyphOnDarkBackground(dark, animated: animated)
    }

    private func layoutButtons() {
        let size = MultitaskStageLayout.controlSize
        let top = (bounds.height - size) / 2
        if MultitaskStageLayout.isMirrored {
            // The view's frame hugs the screen's trailing edge: that edge is the OUTER side, so the
            // restore control goes last (x = width - size) and close sits toward screen center.
            zoomButton.frame = CGRect(x: bounds.width - size, y: top, width: size, height: size)
            closeButton.frame = CGRect(x: 0, y: top, width: size, height: size)
        } else {
            // Leading edge of the screen is outer: restore leads, close trails toward center.
            zoomButton.frame = CGRect(x: 0, y: top, width: size, height: size)
            closeButton.frame = CGRect(
                x: size + MultitaskStageLayout.controlSpacing,
                y: top,
                width: size,
                height: size
            )
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutButtons()
    }

    /// Only the two buttons are tappable; the strip itself stays invisible to touches, so nothing on
    /// the stage is ever covered by this view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - FPS readout

/// The stage's frame rate readout at the far end of the blank strip above the windows.
///
/// Design language: the same Liquid Glass capsule as the window controls, but the NUMBER is the
/// hero — SF Rounded bold with tabular monospaced digits (soft, friendly glyphs that still never
/// shift width), large enough to glance at, tinted by the health colour (green/amber/red). Every
/// time the integer changes it does a quick spring "heartbeat" pop, so a locked 120 reads as a
/// calm steady pulse and a struggling stage visibly stutters. A 7pt status dot carries the same
/// meaning for peripheral vision. The capsule hides entirely in fullscreen.
@objc class MultitaskStageFPSCounterView: UIView {
    private let glass = UIVisualEffectView(effect: nil)
    private let statusDot = UIView()
    private let label = UILabel()
    private var link: CADisplayLink?
    private var framesInWindow = 0
    private var windowStart: CFTimeInterval = 0
    private var lastShownValue: Int?

    /// Longer than a frame, short enough to show a stutter as it happens.
    private static let sampleInterval: CFTimeInterval = 0.5
    private static let valueFontSize: CGFloat = 15
    private static let unitFontSize: CGFloat = 9
    /// How far the superscript "FPS" rides above the digits' baseline: roughly the cap-height gap
    /// between the small unit and the hero number.
    private static let unitBaselineOffset: CGFloat = 5

    private enum FPSState {
        case idle, smooth, strained, dropping

        /// Semantic system colours with a touch of saturation softening for text — calm, not a
        /// gaming-OSD neon.
        var color: UIColor {
            switch self {
            case .idle: return .secondaryLabel
            case .smooth: return UIColor.systemGreen.withAlphaComponent(0.95)
            case .strained: return UIColor.systemYellow.withAlphaComponent(0.95)
            case .dropping: return UIColor.systemRed.withAlphaComponent(0.95)
            }
        }
    }
    private var state: FPSState = .idle

    /// Whether the readout should tick. Driven by the stage: on while the split layout is on
    /// screen, off in fullscreen and once the stage is gone.
    @objc var isCounting: Bool = false {
        didSet {
            guard isCounting != oldValue else { return }
            if isCounting {
                startCounting()
            } else {
                stopCounting()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupMaterial()
        setupStatusDot()
        setupLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupMaterial() {
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        glass.layer.cornerCurve = .continuous

        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            glass.cornerConfiguration = .capsule()
            glass.effect = UIGlassEffect()
        } else if UIAccessibility.isReduceTransparencyEnabled {
            glass.effect = nil
            glass.backgroundColor = .secondarySystemFill
            addRim()
        } else {
            glass.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            addRim()
        }
        addSubview(glass)
    }

    /// Hairline rim on the fallback material; real Liquid Glass draws its own edge.
    private func addRim() {
        glass.layer.borderWidth = MultitaskStageLayout.hairline
        glass.layer.borderColor = UIColor.label.withAlphaComponent(0.10).cgColor
    }

    private func setupStatusDot() {
        statusDot.isUserInteractionEnabled = false
        statusDot.backgroundColor = state.color
        statusDot.layer.cornerRadius = 3.5
        statusDot.layer.cornerCurve = .continuous
        glass.contentView.addSubview(statusDot)
    }

    private func setupLabel() {
        label.textAlignment = .left
        label.attributedText = readoutText(value: nil, color: state.color)
        glass.contentView.addSubview(label)
    }

    /// The default SF Pro design (square, straight-sided — deliberately NOT SF Rounded) with the
    /// monospaced-numbers feature: an instrument readout should read technical and stay put as the
    /// digits change ("120" → "119" never jiggles the capsule).
    private func squareTabularFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let feature: [UIFontDescriptor.FeatureKey: Any] = [
            .featureIdentifier: kNumberSpacingType,
            .typeIdentifier: kMonospacedNumbersSelector
        ]
        let styled = base.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return UIFont(descriptor: styled, size: size)
    }

    private func readoutText(value: Int?, color: UIColor) -> NSAttributedString {
        let digits = value.map(String.init) ?? "--"
        let result = NSMutableAttributedString(string: digits, attributes: [
            .font: squareTabularFont(size: Self.valueFontSize, weight: .heavy),
            .kern: 0.3,
            .foregroundColor: color,
        ])
        // Uppercase "FPS" as a true superscript: small caps-height glyphs riding the top of the
        // digits (positive baseline offset), one tone quieter — the notation of a measurement unit.
        let unit = NSAttributedString(string: " FPS", attributes: [
            .font: squareTabularFont(size: Self.unitFontSize, weight: .bold),
            .kern: 0.4,
            .foregroundColor: UIColor.secondaryLabel,
            .baselineOffset: Self.unitBaselineOffset,
        ])
        result.append(unit)
        return result
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            // cornerConfiguration owns the capsule shape; no layer radius is needed.
        } else {
            glass.layer.cornerRadius = bounds.height / 2
        }
        let dotSize: CGFloat = 7
        let dotX: CGFloat = 11
        statusDot.frame = CGRect(
            x: dotX,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        label.sizeToFit()
        label.frame = CGRect(
            x: dotX + dotSize + 6,
            y: (bounds.height - label.bounds.height) / 2,
            width: label.bounds.width,
            height: label.bounds.height
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // A detached readout must never leave a display link behind.
            stopCounting()
        } else if isCounting && link == nil {
            // Reattached to a new key window while still expected to tick.
            startCounting()
        }
    }

    private func startCounting() {
        guard link == nil, window != nil else { return }
        framesInWindow = 0
        windowStart = 0
        lastShownValue = nil
        let link = CADisplayLink(target: self, selector: #selector(sampleTick))
        // Ask for the display's whole range instead of the default 60Hz ceiling. On a ProMotion
        // phone this is what lets the stage run at up to 120Hz; the 60 floor is for the stage's
        // lifetime only, so an idle launcher isn't pinned to a high refresh rate.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        // .common so the readout keeps sampling while the dock is scrolled or a window dragged.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopCounting() {
        link?.invalidate()
        link = nil
        framesInWindow = 0
        windowStart = 0
        lastShownValue = nil
        label.layer.removeAllAnimations()
        label.transform = .identity
        label.attributedText = readoutText(value: nil, color: FPSState.idle.color)
        transition(to: .idle)
    }

    /// One increment and one compare per presented frame — the counter must never be the reason the
    /// number it shows is low.
    @objc private func sampleTick(_ link: CADisplayLink) {
        guard windowStart > 0 else {
            windowStart = link.timestamp
            framesInWindow = 0
            return
        }
        framesInWindow += 1
        let elapsed = link.timestamp - windowStart
        guard elapsed >= Self.sampleInterval else { return }
        let rate = Int((Double(framesInWindow) / elapsed).rounded())
        if rate != lastShownValue {
            label.attributedText = readoutText(value: rate, color: state.color)
            setNeedsLayout()
            layoutIfNeeded()
            pulse()
            lastShownValue = rate
        }
        // Absolute thresholds: 50+ is smooth on both 60Hz and ProMotion panels, 30–49 is visibly
        // strained, below 30 the stage is dropping frames.
        if rate >= 50 {
            transition(to: .smooth)
        } else if rate >= 30 {
            transition(to: .strained)
        } else {
            transition(to: .dropping)
        }
        windowStart = link.timestamp
        framesInWindow = 0
    }

    /// The "alive" feeling: one quick overshoot-and-settle heartbeat on every new integer, tiny
    /// enough to feel like a ticking instrument rather than a pulsing badge.
    private func pulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        label.layer.removeAllAnimations()
        label.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
        UIView.animate(withDuration: 0.42,
                       delay: 0,
                       usingSpringWithDamping: 0.45,
                       initialSpringVelocity: 0.25,
                       options: [.allowUserInteraction, .curveEaseOut]) {
            self.label.transform = .identity
        }
    }

    /// State changes recolour both the dot (cross-dissolve) and, immediately, the number.
    private func transition(to newState: FPSState) {
        guard newState != state else { return }
        state = newState
        statusDot.backgroundColor = newState.color
        if let value = lastShownValue {
            label.attributedText = readoutText(value: value, color: newState.color)
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        UIView.transition(with: statusDot, duration: 0.3,
                          options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            self.statusDot.backgroundColor = newState.color
        }
    }
}
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
    /// Fixed size of the FPS readout: a 120fps readout in SF Mono 11pt plus the chip padding
    /// never reflows as the count changes.
    static let fpsWidth: CGFloat = 58
    static let fpsHeight: CGFloat = 22
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

    /// Slot 0 is the main window, slots 1...3 are the stacked side windows.
    @objc static func slotFrame(_ index: Int, bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        if index <= 0 {
            return CGRect(x: g.origin.x, y: g.origin.y, width: g.unit * 3, height: g.sideHeight * 3)
        }
        return CGRect(
            x: g.origin.x + g.unit * 3,
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

    /// The two window controls live in the blank strip right above the window block, leading-aligned
    /// with the main window's edge.
    ///
    /// The frame is deliberately the same in both modes: fullscreen and the split stage differ in what
    /// is behind the controls, never in where they are. The pair used to step six points down and left
    /// as the main window grew, and a control that slides while its glyph stays put inside the circle
    /// reads as the button coming apart — the window is what should move, not the chrome on top of it.
    @objc static func controlsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        return CGRect(
            x: g.origin.x + controlLeadingInset,
            y: safeArea.top + (controlsHeight - controlSize) / 2,
            width: controlsWidth,
            height: controlSize
        )
    }

    /// The FPS readout sits at the far end of the strip, on the same line as the controls.
    @objc static func fpsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        return CGRect(
            x: max(0, bounds.width - fpsTrailingInset - fpsWidth),
            y: safeArea.top + (controlsHeight - fpsHeight) / 2,
            width: fpsWidth,
            height: fpsHeight
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

    /// Only the outer contour of the window block is rounded, shared edges stay flush.
    static func maskedCorners(_ index: Int, count: Int) -> CACornerMask {
        if count <= 1 { return allCorners }
        if index <= 0 { return [.layerMinXMinYCorner, .layerMinXMaxYCorner] }

        var corners: CACornerMask = []
        if index == 1 { corners.insert(.layerMaxXMinYCorner) }
        if index == count - 1 { corners.insert(.layerMaxXMaxYCorner) }
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
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
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
        let pressedTint = self.pressedTint
        glyph.tintColor = (pressed && pressedTint != nil) ? .white : .label
        let apply = {
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

    /// Only the zoom control changes with the mode: it grows the main window and restores it.
    @objc var isFullscreen: Bool = false {
        didSet {
            guard isFullscreen != oldValue else { return }
            updateZoomControl()
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = MultitaskStageLayout.controlSize
        let top = (bounds.height - size) / 2
        closeButton.frame = CGRect(x: 0, y: top, width: size, height: size)
        zoomButton.frame = CGRect(
            x: size + MultitaskStageLayout.controlSpacing,
            y: top,
            width: size,
            height: size
        )
    }

    /// Only the two buttons are tappable; the strip itself stays invisible to touches, so nothing on
    /// the stage is ever covered by this view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - FPS readout

/// The stage's frame rate: how many frames the stage actually presented per second, drawn at the far
/// end of the blank strip above the windows.
///
/// It exists to make performance visible while the user switches between windows, so it only ticks
/// while the multitask stage is on screen — fullscreen belongs to the guest app, and the readout
/// leaves with the strip. The look is the gaming OSD players already know from GPU overlays:
/// SF Mono bold tabular digits with wide tracking, a phosphor-green glow, inside a dark glass
/// chip. SF Mono is the system monospaced face — the digits never twitch as the number changes,
/// and no custom font has to ship with the app.
@objc class MultitaskStageFPSCounterView: UIView {
    private let label = UILabel()
    private var link: CADisplayLink?
    private var framesInWindow = 0
    private var windowStart: CFTimeInterval = 0

    /// Longer than a frame, short enough to show a stutter as it happens.
    private static let sampleInterval: CFTimeInterval = 0.5
    /// Phosphor green of the in-game performance overlays players compare against.
    private static let counterGreen = UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)

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
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        // No masksToBounds: the label's green glow would be clipped at the chip edge.
        layer.borderWidth = MultitaskStageLayout.hairline
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = Self.counterGreen
        label.textAlignment = .center
        // A soft green halo is what makes the digits read as an OSD readout rather than plain
        // text stamped on the strip.
        label.layer.shadowColor = Self.counterGreen.cgColor
        label.layer.shadowOpacity = 0.45
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.attributedText = readoutText("-- FPS")
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Wide letter spacing (positive tracking is correct at small sizes) keeps the chip reading
    /// as instrument typography instead of a sentence.
    private func readoutText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .kern: 0.6,
            .foregroundColor: Self.counterGreen,
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // A detached readout must never leave a display link behind.
            stopCounting()
        } else if isCounting && link == nil {
            // Reattached to a new key window while still expected to tick. Detach invalidated the
            // link, and isCounting's didSet would not re-fire because its value never changed —
            // without this the readout froze on the last number forever.
            startCounting()
        }
    }

    private func startCounting() {
        guard link == nil, window != nil else { return }
        framesInWindow = 0
        windowStart = 0
        let link = CADisplayLink(target: self, selector: #selector(sampleTick))
        // Ask for the display's whole range instead of the default 60Hz ceiling. On a ProMotion phone
        // this is what lets the stage — and the window animations the readout is measuring — run at up
        // to 120Hz; without it the system keeps the process at 60 even though the app declares
        // CADisableMinimumFrameDurationOnPhone. The 60 floor is for the stage's lifetime only, so an
        // idle launcher is not pinned to a high refresh rate by a readout nobody is looking at.
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
        // Frames in the window over the time the window actually took, so a dropped frame pulls the
        // number down instead of being averaged away.
        let rate = Double(framesInWindow) / elapsed
        label.attributedText = readoutText("\(Int(rate.rounded())) FPS")
        windowStart = link.timestamp
        framesInWindow = 0
    }
}
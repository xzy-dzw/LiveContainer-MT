//
//  MultitaskStage.swift
//  LiveContainer
//
//  1 main + 3 side window stage layout, and the single glass window control that
//  lives in the blank strip above the main window, identical in fullscreen.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Geometry

@objc class MultitaskStageLayout: NSObject {
    /// Main window plus three side windows.
    @objc static let maxWindows = 4

    /// Blank strip above the window block that hosts the main window's control. Tall enough for
    /// the HIG minimum hit target (44pt), so the control never has to overlap a window.
    static let controlsHeight: CGFloat = 44
    /// Hit target of the window control, and the side of the glass circle it draws.
    static let controlSize: CGFloat = 44
    /// Keeps the control off the very edge of the screen, aligned with the main window's edge.
    static let controlLeadingInset: CGFloat = 12
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

    /// The main window's control lives in the blank strip right above the window, aligned with
    /// its leading edge. It is the control's own frame, not the strip: the control is a single
    /// object that only moves, so it can never cross-fade or jump between two shapes.
    @objc static func controlsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        return CGRect(
            x: g.origin.x + controlLeadingInset,
            y: safeArea.top + (controlsHeight - controlSize) / 2,
            width: controlSize,
            height: controlSize
        )
    }

    /// The four slots tile into one rectangle, so the whole block casts a single shadow
    /// that follows the shared outer contour instead of four overlapping ones.
    @objc static func blockFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        return CGRect(
            x: g.origin.x,
            y: g.origin.y,
            width: g.unit * CGFloat(maxWindows),
            height: g.sideHeight * 3
        )
    }

    /// The same control, floating over the top leading corner while the main window is
    /// fullscreen. The two positions are one short move apart, so the control travels with the
    /// window instead of being replaced by a different looking one.
    @objc static func fullscreenControlsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        return CGRect(x: safeArea.left + 6, y: safeArea.top + 6, width: controlSize, height: controlSize)
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

/// The main window's window control: one neutral glass button that opens the window menu.
///
/// macOS puts three colored dots inside a window's title bar. On a phone that reads wrong — the
/// dots are small, they color the stage chrome in someone else's accent color, and a title bar
/// would steal a whole strip of the guest app's screen. So the stage keeps one HIG sized (44pt)
/// control with a single `ellipsis` glyph, and it never lives inside a window: in split layout it
/// sits in the blank strip above the main window's leading edge, and while the main window is
/// fullscreen the very same control floats over the top leading corner of the screen. Both
/// positions are one short move apart, so the control travels with the window and the hand never
/// has to re-learn where it is.
@objc class MultitaskStageControlsView: UIView {
    @objc weak var delegate: MultitaskStageControlsDelegate?

    /// The control is one object in both modes; only the menu's first item changes.
    @objc var isFullscreen: Bool = false {
        didSet {
            guard isFullscreen != oldValue else { return }
            rebuildMenu()
        }
    }

    /// The visible glass circle stays smaller than the hit target, so the control reads as a
    /// light piece of chrome instead of a heavy disc.
    private static let circleSize: CGFloat = 34

    private let button = UIButton(type: .custom)
    private let glassBackground = UIVisualEffectView(effect: nil)
    private let icon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupButton()
        rebuildMenu()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupButton() {
        // Neutral material: the control belongs to the stage chrome, not to the guest app, so it
        // must not borrow the app's accent color or compete with its content.
        if UIAccessibility.isReduceTransparencyEnabled {
            glassBackground.effect = nil
            glassBackground.backgroundColor = UIColor.secondarySystemFill
        } else {
            glassBackground.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        glassBackground.isUserInteractionEnabled = false
        glassBackground.clipsToBounds = true
        glassBackground.layer.cornerCurve = .continuous
        glassBackground.layer.borderWidth = MultitaskStageLayout.hairline
        glassBackground.layer.borderColor = UIColor.label.withAlphaComponent(0.12).cgColor
        button.addSubview(glassBackground)

        icon.image = UIImage(
            systemName: "ellipsis",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        icon.tintColor = .label
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        button.addSubview(icon)

        button.accessibilityLabel = "lc.multitask.windowMenu".loc
        // Respond on the press, not on the release: waiting for the menu to open is what made the
        // old dots feel dead.
        button.addTarget(self, action: #selector(pressChanged), for: [.touchDown, .touchDragEnter])
        button.addTarget(
            self,
            action: #selector(releaseChanged),
            for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel]
        )
        addSubview(button)
    }

    /// One control, two items: maximize/restore the main window, or close it. The destructive
    /// item keeps the system's own red treatment instead of a permanently red button.
    private func rebuildMenu() {
        let zoomTitle = (isFullscreen ? "lc.multitask.restoreWindow" : "lc.multitask.zoomWindow").loc
        let zoomSymbol = isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let zoom = UIAction(title: zoomTitle, image: UIImage(systemName: zoomSymbol)) { [weak self] _ in
            self?.delegate?.stageControlsDidTapZoom()
        }
        let close = UIAction(
            title: "lc.multitask.closeWindow".loc,
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.delegate?.stageControlsDidTapClose()
        }

        button.menu = UIMenu(children: [zoom, close])
        button.showsMenuAsPrimaryAction = true
    }

    @objc private func pressChanged() {
        setPressed(true)
    }

    @objc private func releaseChanged() {
        setPressed(false)
    }

    /// The press scales the whole control and the release springs back, with the same critically
    /// damped feel the window layout uses, so the button and the stage move as one material.
    private func setPressed(_ pressed: Bool) {
        let scale: CGFloat = pressed ? 0.94 : 1.0
        let apply = { self.button.transform = CGAffineTransform(scaleX: scale, y: scale) }
        guard !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: pressed ? 0.12 : 0.32,
            delay: 0,
            usingSpringWithDamping: pressed ? 1.0 : 0.82,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: apply
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        glassBackground.frame = CGRect(
            x: (bounds.width - Self.circleSize) / 2,
            y: (bounds.height - Self.circleSize) / 2,
            width: Self.circleSize,
            height: Self.circleSize
        )
        glassBackground.layer.cornerRadius = Self.circleSize / 2
        icon.frame = bounds
    }

    /// Only the button itself is tappable; nothing else on the stage is covered by this view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

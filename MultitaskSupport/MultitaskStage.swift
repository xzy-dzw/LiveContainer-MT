//
//  MultitaskStage.swift
//  LiveContainer
//
//  1 main + 3 side window stage layout, macOS style window controls that live
//  outside of the windows, and the floating shrink capsule used in fullscreen.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Geometry

@objc class MultitaskStageLayout: NSObject {
    /// Main window plus three side windows.
    @objc static let maxWindows = 4

    /// Blank strip above the window block that hosts the macOS style control dots.
    static let controlsHeight: CGFloat = 30
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

    /// Control dots sit in the blank strip right above the main window, left aligned.
    @objc static func controlsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let g = geometry(bounds, safeArea)
        return CGRect(
            x: g.origin.x,
            y: safeArea.top,
            width: g.unit * 3,
            height: controlsHeight
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

    /// Floating capsule shown while the main window is fullscreen.
    @objc static func fullscreenControlsFrame(bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        return CGRect(x: safeArea.left + 6, y: safeArea.top + 4, width: 88, height: 34)
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

/// macOS style traffic lights for the main window. They are never placed inside a window:
/// in split layout they sit in the blank strip above the main window, and while the main
/// window is fullscreen they collapse into a small floating capsule that only shrinks.
@objc class MultitaskStageControlsView: UIView {
    @objc weak var delegate: MultitaskStageControlsDelegate?

    @objc var isFullscreen: Bool = false {
        didSet {
            guard isFullscreen != oldValue else { return }
            applyMode()
            setNeedsLayout()
        }
    }

    private let closeButton = UIButton(type: .custom)
    private let zoomButton = UIButton(type: .custom)
    private let capsuleButton = UIButton(type: .custom)
    private let capsuleBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let capsuleDot = UIView()
    private let capsuleIcon = UIImageView()

    private let dotSize: CGFloat = 13
    private let dotSpacing: CGFloat = 9
    /// Keeps the traffic lights off the very edge of the main window, like macOS does.
    private let dotLeftInset: CGFloat = 8
    private let capsuleSize = CGSize(width: 88, height: 34)
    private let capsuleDotSize: CGFloat = 12

    private static let closeColor = UIColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1.00)
    private static let zoomColor = UIColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1.00)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupTrafficLight(closeButton, color: MultitaskStageControlsView.closeColor, action: #selector(tapClose))
        setupTrafficLight(zoomButton, color: MultitaskStageControlsView.zoomColor, action: #selector(tapZoom))
        setupCapsule()
        applyMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTrafficLight(_ button: UIButton, color: UIColor, action: Selector) {
        button.backgroundColor = color
        button.layer.cornerRadius = dotSize / 2
        button.layer.borderWidth = MultitaskStageLayout.hairline
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.12).cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func setupCapsule() {
        capsuleBackground.layer.cornerRadius = capsuleSize.height / 2
        capsuleBackground.layer.cornerCurve = .continuous
        capsuleBackground.clipsToBounds = true
        capsuleBackground.isUserInteractionEnabled = false
        if UIAccessibility.isReduceTransparencyEnabled {
            capsuleBackground.effect = nil
            capsuleBackground.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        }
        addSubview(capsuleBackground)

        capsuleDot.backgroundColor = MultitaskStageControlsView.zoomColor
        capsuleDot.layer.cornerRadius = capsuleDotSize / 2
        capsuleBackground.contentView.addSubview(capsuleDot)

        capsuleIcon.image = UIImage(
            systemName: "arrow.down.right.and.arrow.up.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        capsuleIcon.tintColor = .white
        capsuleIcon.contentMode = .scaleAspectFit
        capsuleBackground.contentView.addSubview(capsuleIcon)

        capsuleButton.layer.cornerRadius = capsuleSize.height / 2
        capsuleButton.addTarget(self, action: #selector(tapZoom), for: .touchUpInside)
        addSubview(capsuleButton)
    }

    /// Cross-fades between the two modes so the dots do not snap out of existence while the main
    /// window is still resizing. `.beginFromCurrentState` keeps a fast double tap from jumping.
    private func applyMode() {
        let showDots = !isFullscreen
        closeButton.isUserInteractionEnabled = showDots
        zoomButton.isUserInteractionEnabled = showDots
        capsuleButton.isUserInteractionEnabled = !showDots
        capsuleBackground.isUserInteractionEnabled = false
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.closeButton.alpha = showDots ? 1 : 0
            self.zoomButton.alpha = showDots ? 1 : 0
            self.capsuleBackground.alpha = showDots ? 0 : 1
            self.capsuleButton.alpha = showDots ? 0 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isFullscreen {
            capsuleBackground.frame = CGRect(origin: .zero, size: capsuleSize)
            capsuleButton.frame = capsuleBackground.frame
            capsuleDot.frame = CGRect(
                x: 12,
                y: (capsuleSize.height - capsuleDotSize) / 2,
                width: capsuleDotSize,
                height: capsuleDotSize
            )
            capsuleIcon.frame = CGRect(x: 34, y: (capsuleSize.height - 16) / 2, width: 42, height: 16)
        } else {
            let y = (bounds.height - dotSize) / 2
            closeButton.frame = CGRect(x: dotLeftInset, y: y, width: dotSize, height: dotSize)
            zoomButton.frame = CGRect(
                x: dotLeftInset + dotSize + dotSpacing,
                y: y,
                width: dotSize,
                height: dotSize
            )
        }
    }

    @objc private func tapClose() {
        delegate?.stageControlsDidTapClose()
    }

    @objc private func tapZoom() {
        delegate?.stageControlsDidTapZoom()
    }

    /// Only the dots themselves are tappable, the strip they live in stays pass-through.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

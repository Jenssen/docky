//
//  DockBadgeView.swift
//  Docky
//
//  The red notification badge drawn over a running app's tile, mirroring the
//  system Dock's badge. Sizes itself relative to the tile so it scales with
//  the dock.
//

import SwiftUI

struct DockBadgeView: View {
    let text: String
    /// Multiplier on the badge's icon-relative size. Defaults to 1 (the
    /// system-Dock-matching size used on regular tiles); the app-folder grid
    /// preview bumps this so the badge stays legible on its tiny icons.
    var scale: CGFloat = 1
    /// Vertical offset from the icon's top-trailing corner, as a fraction of
    /// badge height. Positive nudges down into the icon (default); negative
    /// lets the badge poke above the icon's top edge.
    var verticalOffsetFactor: CGFloat = 0.30

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // Anchor to the centered icon square, not the tile: the tile also
            // holds the vertical tile padding, which does not grow with
            // magnification.
            badge(forTileSide: side)
                .frame(width: side, height: side, alignment: .topTrailing)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func badge(forTileSide side: CGFloat) -> some View {
        // Close to the macOS 26 Dock badge, a bit smaller.
        let height = max(8, side * 0.36 * scale)
        let fontSize = height * 0.58
        // Up to two characters fit in a circle. Longer labels get a capsule
        // with room around the text.
        let horizontalPadding = height * (displayText.count > 2 ? 0.28 : 0.15)

        Text(displayText)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: height, minHeight: height)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red)
                    .shadow(color: .black.opacity(0.3), radius: max(1, height * 0.08), y: max(0.5, height * 0.03))
            )
            // Center on the corner of the visible icon, like the system Dock.
            // A macOS app icon leaves a transparent margin of 100 px on each
            // side of its 1024 px canvas.
            .offset(
                x: height * 0.3 - side * 100 / 1024,
                y: side * 100 / 1024 + height * (verticalOffsetFactor - 0.6)
            )
    }

    /// Clamp absurdly long status strings so a badge can't blow out the
    /// tile. The Dock itself shows "99+" past two digits for most apps;
    /// non-numeric labels (rare) are passed through but capped.
    private var displayText: String {
        if text.count <= 4 { return text }
        if let value = Int(text), value > 999 { return "999+" }
        return String(text.prefix(4))
    }
}

/// A countless variant of `DockBadgeView`: a plain red dot in the icon's
/// top-trailing corner. Used on the tiny app-folder preview icons where a
/// numeric badge would be illegible — it answers "which app" without the count.
/// Geometry mirrors `DockBadgeView` so the two read as the same badge family.
struct DockBadgeDotView: View {
    /// See `DockBadgeView.scale`.
    var scale: CGFloat = 1
    /// See `DockBadgeView.verticalOffsetFactor`.
    var verticalOffsetFactor: CGFloat = 0.30

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            dot(forTileSide: side)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dot(forTileSide side: CGFloat) -> some View {
        let diameter = max(6, side * 0.285 * scale)

        Circle()
            .fill(Color.red)
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.3), radius: max(1, diameter * 0.08), y: max(0.5, diameter * 0.03))
            .offset(x: diameter * 0.05, y: diameter * verticalOffsetFactor)
    }
}

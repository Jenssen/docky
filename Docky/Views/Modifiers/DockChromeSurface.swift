//
//  DockChromeSurface.swift
//  Docky
//
//  The dock chrome's background for the surfaces that open from the dock:
//  window previews, the window switcher and the Start menu. It reads the
//  same settings as `MainWindowView.chromeBackground`, so a tint, glass or
//  border change in Appearance or in a theme reaches every surface.
//

import SwiftUI

struct DockChromeSurface: View {
    let cornerRadius: CGFloat
    /// The dock shows icons, which stay readable over any wallpaper. These
    /// surfaces show text, so they blur more than the dock's window blur.
    var blurRadius = 30

    private let preferences = DockyPreferences.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if usesLiquidGlass, #available(macOS 26.0, *) {
                LiquidGlassChromeView(variant: 11, cornerRadius: cornerRadius)
            } else {
                // The same SkyLight blur as the dock window. A system
                // material would also shift the colors toward light or dark.
                SkyLightHostBlurInstaller(blurRadius: blurRadius)
            }
            shape.fill(Color(nsColor: preferences.effectiveWindowTintColor))
                .opacity(preferences.effectiveWindowTintOpacity)
        }
        .clipShape(shape)
        .overlay { border(shape) }
    }

    private var usesLiquidGlass: Bool {
        !preferences.effectiveDisablesGlassLook && FeatureGate.shared.isAvailable(.liquidGlass)
    }

    /// The theme border wins over the glass outline, as on the dock.
    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if let color = preferences.effectiveWindowBorderColor {
            let width = max(0, preferences.effectiveWindowBorderWidth)
            if width > 0 {
                shape.inset(by: width / 2).strokeBorder(Color(nsColor: color), lineWidth: width)
            }
        } else if !preferences.effectiveDisablesGlassLook {
            shape.inset(by: 0.5).strokeBorder(dockyGlassBorderGradient, lineWidth: 1)
        }
    }

    /// The dock's corner style at the size of a surface: a dock with square
    /// corners gives square surfaces, and a round dock gives `maximum`.
    static func cornerRadius(maximum: CGFloat) -> CGFloat {
        let preferences = DockyPreferences.shared
        return preferences.effectiveWindowClipShape.resolvedCornerRadius(
            base: preferences.effectiveWindowCornerRadius,
            maximum: maximum
        )
    }
}

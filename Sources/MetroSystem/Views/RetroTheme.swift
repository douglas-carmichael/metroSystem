import SwiftUI

/// The two display skins. `retro` is the VT320 amber/green phosphor console;
/// `iso101` is a muted "high-performance HMI" palette after ISA-101 / the
/// GEDIS guide — a neutral-grey canvas with dark text where colour is spent
/// only on abnormal / alarm conditions. Switched live from
/// `AppLanguage.themeKind`.
enum ThemeKind {
    case retro
    case iso101
}

enum RetroTheme {
    /// The active skin. Kept in step with `AppLanguage.themeKind` (an
    /// @Published) so flipping it re-renders every localized view — they all
    /// observe `AppLanguage` already — and the accessors below then return
    /// the other palette. Window roots additionally carry `.id(themeKind)`
    /// so the whole subtree is rebuilt cleanly on a switch.
    static var kind: ThemeKind = .retro

    // MARK: - Palette
    //
    // The ISA-101 column deliberately desaturates the nominal "green" toward
    // grey so healthy status recedes into the canvas, while `red` stays
    // saturated and becomes the most salient thing on screen — the core
    // high-performance-HMI idea, obtained without changing any call site
    // (a view asking for `RetroTheme.green` for a healthy state just gets a
    // quiet grey-green under ISA-101).

    static var bg: Color {
        switch kind {
        case .retro:  return Color(red: 0.04, green: 0.04, blue: 0.05)
        case .iso101: return Color(red: 0.80, green: 0.80, blue: 0.78)   // neutral grey canvas
        }
    }
    static var bgPanel: Color {
        switch kind {
        case .retro:  return Color(red: 0.06, green: 0.06, blue: 0.07)
        case .iso101: return Color(red: 0.87, green: 0.87, blue: 0.85)   // lighter panel fill
        }
    }
    /// Primary label / structural colour (phosphor amber → dark slate text).
    static var amber: Color {
        switch kind {
        case .retro:  return Color(red: 1.00, green: 0.72, blue: 0.20)
        case .iso101: return Color(red: 0.18, green: 0.18, blue: 0.20)
        }
    }
    /// Secondary / dimmed text.
    static var amberDim: Color {
        switch kind {
        case .retro:  return Color(red: 0.62, green: 0.45, blue: 0.12)
        case .iso101: return Color(red: 0.44, green: 0.44, blue: 0.46)
        }
    }
    /// Emphasised values (bright phosphor → near-black).
    static var amberBright: Color {
        switch kind {
        case .retro:  return Color(red: 1.00, green: 0.86, blue: 0.45)
        case .iso101: return Color(red: 0.07, green: 0.07, blue: 0.09)
        }
    }
    /// Nominal / healthy. Bright in retro; quiet grey-green under ISA-101.
    static var green: Color {
        switch kind {
        case .retro:  return Color(red: 0.36, green: 1.00, blue: 0.42)
        case .iso101: return Color(red: 0.28, green: 0.40, blue: 0.30)
        }
    }
    static var greenDim: Color {
        switch kind {
        case .retro:  return Color(red: 0.20, green: 0.55, blue: 0.22)
        case .iso101: return Color(red: 0.60, green: 0.62, blue: 0.58)
        }
    }
    /// Abnormal / alarm — stays saturated in both skins.
    static var red: Color {
        switch kind {
        case .retro:  return Color(red: 1.00, green: 0.30, blue: 0.28)
        case .iso101: return Color(red: 0.78, green: 0.11, blue: 0.11)
        }
    }
    /// Information / setpoint accent.
    static var cyan: Color {
        switch kind {
        case .retro:  return Color(red: 0.45, green: 0.95, blue: 1.00)
        case .iso101: return Color(red: 0.11, green: 0.33, blue: 0.60)
        }
    }

    // MARK: - Type
    //
    // Retro uses the VT323 bitmap phosphor face. ISA-101 keeps a monospaced
    // *design* (so the column-aligned synoptics still line up) but drops the
    // bitmap font for the system monospace, at slightly smaller nominal sizes
    // to match VT323's compact bitmap metrics.

    static let retroFontName = "VT323"

    static var mono: Font {
        switch kind {
        case .retro:  return Font.custom(retroFontName, size: 16, relativeTo: .body)
        case .iso101: return Font.system(size: 12.5, design: .monospaced)
        }
    }
    static var monoSm: Font {
        switch kind {
        case .retro:  return Font.custom(retroFontName, size: 13, relativeTo: .footnote)
        case .iso101: return Font.system(size: 10.5, design: .monospaced)
        }
    }
    static var monoLg: Font {
        switch kind {
        case .retro:  return Font.custom(retroFontName, size: 22, relativeTo: .title3)
        case .iso101: return Font.system(size: 17, weight: .semibold, design: .monospaced)
        }
    }
    static var monoXl: Font {
        switch kind {
        case .retro:  return Font.custom(retroFontName, size: 30, relativeTo: .title)
        case .iso101: return Font.system(size: 23, weight: .semibold, design: .monospaced)
        }
    }

    static let glow = Color(red: 1.00, green: 0.72, blue: 0.20).opacity(0.45)
}

extension View {
    /// Phosphor bloom under the retro skin; a no-op under ISA-101 (decorative
    /// glow runs contrary to the high-performance-HMI style).
    @ViewBuilder
    func retroGlow() -> some View {
        if RetroTheme.kind == .retro {
            self.shadow(color: RetroTheme.glow, radius: 2.5, x: 0, y: 0)
        } else {
            self
        }
    }
}

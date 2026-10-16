import AppKit
import CoreText
import CVterm
import AmuxLib

/// Optional local appearance settings, independent of terminal input behavior.
struct TerminalAppearance: Decodable {
    struct Colors: Decodable {
        var foreground: [Double]
        var background: [Double]
        var cursor: [Double]
        var ansi: [[Double]]
    }
    var fontName: String
    var fontSize: Double
    var horizontalSpacing: Double
    var verticalSpacing: Double
    var antialias: Bool
    var brightBold: Bool
    var light: Colors
    var dark: Colors

    static func load() -> TerminalAppearance? {
        let home = ProcessInfo.processInfo.environment["AMUX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".amux").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("appearance.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.fontSize.isFinite, (6...48).contains(value.fontSize),
              (0.5...2).contains(value.horizontalSpacing), (0.5...2).contains(value.verticalSpacing),
              [value.light, value.dark].allSatisfy({ c in
                  c.ansi.count == 16 && ([c.foreground, c.background, c.cursor] + c.ansi).allSatisfy {
                      $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) }
                  }
              }) else { return nil }
        return value
    }

    var colors: Colors {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    static func cgColor(_ rgb: [Double], alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: rgb.map { CGFloat($0) } + [alpha])!
    }

    func apply(to terminal: VTerminal) {
        func color(_ rgb: [Double]) -> VTermColor {
            var result = VTermColor()
            vterm_color_rgb(&result, UInt8((rgb[0] * 255).rounded()), UInt8((rgb[1] * 255).rounded()), UInt8((rgb[2] * 255).rounded()))
            return result
        }
        let state = vterm_obtain_state(terminal.vt)
        var fg = color(colors.foreground), bg = color(colors.background)
        vterm_screen_set_default_colors(terminal.screen, &fg, &bg)
        for (index, rgb) in colors.ansi.enumerated() {
            var entry = color(rgb)
            vterm_state_set_palette_color(state, Int32(index), &entry)
        }
        vterm_state_set_bold_highbright(state, brightBold ? 1 : 0)
    }
}

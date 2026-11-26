import AppKit

/// What the cat is doing. Each mood maps to a MacPorts state.
enum CatMood: String, CaseIterable {
    case sleeping   // everything up to date
    case running    // busy: checking, syncing, upgrading
    case waving     // outdated ports are waiting
    case sad        // MacPorts missing, or a problem was found
    case happy      // an upgrade just finished

    /// Animation speed in frames per second.
    var fps: Double {
        switch self {
        case .sleeping: return 2.5
        case .running:  return 8
        case .waving:   return 4
        case .sad:      return 2
        case .happy:    return 5
        }
    }
}

enum CatArt {
    private static let outline = NSColor(srgbRed: 0.25, green: 0.16, blue: 0.19, alpha: 1)
    private static let palette: [Character: NSColor] = [
        "o": outline,
        "#": NSColor(srgbRed: 1, green: 0.92, blue: 0.81, alpha: 1),
        "t": NSColor(srgbRed: 0.92, green: 0.56, blue: 0.33, alpha: 1),
        "x": outline,
        "+": NSColor(srgbRed: 1, green: 0.53, blue: 0.62, alpha: 1),
        "~": .systemTeal,
        "*": .systemOrange,
    ]

    /// Renders one pixel-art grid into an image.
    /// - Parameters:
    ///   - pixel: size of one art pixel in points.
    ///   - template: menu-bar style image that follows light/dark mode.
    static func image(_ grid: [String], pixel: CGFloat, template: Bool) -> NSImage {
        let rows = grid.map { Array($0) }
        let height = rows.count
        let width = rows.map(\.count).max() ?? 0
        let size = NSSize(width: CGFloat(width) * pixel, height: CGFloat(height) * pixel)

        let image = NSImage(size: size, flipped: true) { _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    guard let color = template ? templateColor(for: ch) : palette[ch] else { continue }
                    color.setFill()
                    NSRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func templateColor(for cell: Character) -> NSColor? {
        switch cell {
        case "x": return nil   // face cutouts stay visible after macOS tints the image
        case "+", "~", "*": return .black.withAlphaComponent(0.65)
        default: return .black
        }
    }

    static func frames(for mood: CatMood, pixel: CGFloat, template: Bool) -> [NSImage] {
        (grids[mood] ?? []).map { image($0, pixel: pixel, template: template) }
    }
}

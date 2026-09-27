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
        case .sleeping: return 1.2
        case .running:  return 9
        case .waving:   return 2.5
        case .sad:      return 1.5
        case .happy:    return 5
        }
    }
}

enum CatArt {
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
                    let color: NSColor
                    if template {
                        color = ch == "+" ? NSColor.black.withAlphaComponent(0.55) : .black
                    } else {
                        color = ch == "+" ? .systemPink : .labelColor
                    }
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

    static func frames(for mood: CatMood, pixel: CGFloat, template: Bool) -> [NSImage] {
        (grids[mood] ?? []).map { image($0, pixel: pixel, template: template) }
    }
}

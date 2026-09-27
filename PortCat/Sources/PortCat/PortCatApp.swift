import AppKit
import SwiftUI

@main
struct PortCatMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}

/// Owns the menu bar item: the animated cat plus a small outdated-count badge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = PortManager()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var menuFrames: [CatMood: [NSImage]] = [:]
    private var animationTimer: Timer?
    private var currentMood: CatMood?
    private var frameIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        for mood in CatMood.allCases {
            menuFrames[mood] = CatArt.frames(for: mood, pixel: 1, template: true)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "PortCat"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(manager: manager))

        manager.onChange = { [weak self] in self?.stateChanged() }
        stateChanged()
        manager.start()
    }

    // MARK: Cat animation

    private func stateChanged() {
        updateBadge()
        let mood = manager.mood
        guard mood != currentMood else { return }
        currentMood = mood
        frameIndex = 0
        animationTimer?.invalidate()
        showFrame()
        let timer = Timer(timeInterval: 1.0 / mood.fps, target: self,
                          selector: #selector(nextFrame), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)   // keeps animating while menus are open
        animationTimer = timer
    }

    @objc private func nextFrame() {
        frameIndex += 1
        showFrame()
    }

    private func showFrame() {
        guard let mood = currentMood, let frames = menuFrames[mood], !frames.isEmpty else { return }
        statusItem.button?.image = frames[frameIndex % frames.count]
    }

    private func updateBadge() {
        let count = manager.outdated.count
        guard let button = statusItem?.button else { return }
        if count > 0 && !manager.isBusy {
            button.attributedTitle = NSAttributedString(
                string: "\(count)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if !manager.isBusy { Task { await manager.refresh() } }
        }
    }
}

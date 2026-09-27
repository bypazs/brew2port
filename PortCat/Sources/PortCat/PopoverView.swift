import SwiftUI

/// The big animated cat at the top of the popover.
struct CatView: View {
    let mood: CatMood
    private static let frames: [CatMood: [NSImage]] = Dictionary(
        uniqueKeysWithValues: CatMood.allCases.map { ($0, CatArt.frames(for: $0, pixel: 4, template: false)) })

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / mood.fps)) { context in
            let frames = Self.frames[mood] ?? []
            if !frames.isEmpty {
                let index = Int(context.date.timeIntervalSinceReferenceDate * mood.fps) % frames.count
                Image(nsImage: frames[index])
                    .interpolation(.none)
            }
        }
        .frame(width: 88, height: 64)
        .accessibilityLabel(Text("PortCat is \(mood.rawValue)"))
    }
}

struct PopoverView: View {
    @ObservedObject var manager: PortManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if manager.isBusy {
                ProgressView().progressViewStyle(.linear)
            }

            if !manager.isInstalled {
                notInstalled
            } else {
                if let problem = manager.problem { problemBox(problem) }
                if let notice = manager.notice { noticeBox(notice) }
                if !manager.outdated.isEmpty { outdatedSection }
                staleIndexHint
                homebrewLeftover
                installedSection
                actions
                logSection
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            CatView(mood: manager.mood)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                if let checked = manager.lastChecked {
                    Text("Checked \(checked, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch manager.mood {
        case .running:  return manager.busyMessage ?? "Working…"
        case .happy:    return "All done!"
        case .sad:      return manager.isInstalled ? "Something needs a look" : "MacPorts not found"
        case .waving:   return "\(manager.outdated.count) update\(manager.outdated.count == 1 ? "" : "s") available"
        case .sleeping: return "All up to date"
        }
    }

    private var subtitle: String {
        switch manager.mood {
        case .running:  return "Hang on, I'm on it! ε=ε=(ﾉ≧∀≦)ﾉ"
        case .happy:    return "Otsukaresama~ (๑•̀ㅂ•́)و✧"
        case .sad:      return manager.isInstalled ? "See below (´・ω・`)" : "I need MacPorts to work (´；ω；`)"
        case .waving:   return "Psst! Some ports want upgrading"
        case .sleeping: return "Nothing to do… zzz (－ω－)"
        }
    }

    // MARK: Sections

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = manager.problem { problemBox(problem) }
            if let notice = manager.notice { noticeBox(notice) }

            Text("MacPorts isn't installed yet. I can set it up for you:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await manager.installMacPorts() }
            } label: {
                Label("Install MacPorts", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isBusy)
            Text("Downloads the official installer for your macOS, checks its SHA256 and Apple signature, then asks for your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if manager.hasHomebrew {
                Button {
                    manager.openMigration()
                } label: {
                    Label("Move my Homebrew packages…", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }
                .disabled(manager.isBusy)
                Text("Opens Terminal and runs brew2port. It installs MacPorts too, shows you the plan, and asks before changing anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link("Or install MacPorts yourself", destination: URL(string: "https://www.macports.org/install.php")!)
                .font(.caption)

            logSection
        }
    }

    private var homebrewLeftover: some View {
        VStack(alignment: .leading, spacing: 8) {
            homebrewFormulae
            homebrewOrphans
        }
    }

    @ViewBuilder
    private var homebrewOrphans: some View {
        let orphans = manager.homebrewOrphans
        if !orphans.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("Homebrew has \(orphans.count) leftover dependenc\(orphans.count == 1 ? "y" : "ies") nothing uses anymore: \(orphans.prefix(6).joined(separator: ", "))\(orphans.count > 6 ? "…" : "")")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button("Clean up Homebrew") { Task { await manager.cleanHomebrew() } }
                    .controlSize(.small)
                    .disabled(manager.isBusy)
                    .help("Runs brew autoremove and brew cleanup. Only removes packages that were installed as dependencies and are no longer needed.")
            }
        }
    }

    @ViewBuilder
    private var homebrewFormulae: some View {
        if let names = manager.homebrewLeftNames, !names.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text("Still in Homebrew: \(names.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: ", "))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Move them…") { manager.openMigration() }
                        .help("Install MacPorts versions of what's still in Homebrew")
                    Button("Remove old copies…") { manager.openRemoval() }
                        .help("Remove Homebrew copies that already have a MacPorts version")
                    Button("Keep in Homebrew") { manager.keepInHomebrew(names) }
                        .help("Some tools have no MacPorts port. Keep them in Homebrew and stop reminding me.")
                }
                .controlSize(.small)
                .disabled(manager.isBusy)
            }
        } else if !manager.keptInHomebrew.isEmpty {
            HStack {
                Text("Kept in Homebrew: \(manager.keptInHomebrew.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Undo") { manager.forgetKept() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
    }

    private func problemBox(_ text: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Dismiss") { manager.dismissProblem() }
                }
                .controlSize(.small)
            }
        } label: {
            Label("Problem", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func noticeBox(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { manager.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
    }

    private var outdatedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Outdated").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Upgrade all") { Task { await manager.upgradeAll() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(manager.isBusy)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(manager.outdated) { port in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(port.name).font(.callout.weight(.medium))
                                Text("\(port.current) → \(port.latest)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Upgrade") { Task { await manager.upgrade(port) } }
                                .controlSize(.small)
                                .disabled(manager.isBusy)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(manager.outdated.count) * 36, 150))
        }
    }

    @ViewBuilder
    private var staleIndexHint: some View {
        if manager.lastSync == nil || (manager.indexAgeDays ?? 0) >= 3 {
            Text(manager.lastSync == nil
                 ? "Tip: press “Check for updates” so I know about the newest versions."
                 : "Package list is \(manager.indexAgeDays ?? 0) days old. Press “Check for updates”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installedSection: some View {
        DisclosureGroup("Installed (\(manager.requested.count))") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(manager.requested, id: \.self) { name in
                        Text(name).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: min(CGFloat(manager.requested.count) * 18 + 4, 120))
        }
        .font(.subheadline)
    }

    private var actions: some View {
        HStack {
            Button("Check for updates") { Task { await manager.syncAndCheck() } }
                .help("Sync the MacPorts package list (asks for your password), then look for updates")
            Button("Diagnose") { Task { await manager.diagnose() } }
                .help("Run port diagnose")
            Button("Clean up") { Task { await manager.reclaim() } }
                .help("MacPorts: remove old versions, unused downloads and unneeded dependencies (port reclaim)")
        }
        .controlSize(.small)
        .disabled(manager.isBusy)
    }

    @ViewBuilder
    private var logSection: some View {
        if !manager.log.isEmpty {
            DisclosureGroup("Log") {
                ScrollView {
                    Text(manager.log)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            .font(.subheadline)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(
                get: { manager.launchAtLogin },
                set: { manager.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Link("☕ Buy me a coffee", destination: URL(string: "https://buymeacoffee.com/bypazs")!)
                .font(.caption)
                .help("Support PortCat and brew2port")
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipsCopy {
    static func clearHistoryMessage(boardClipCount: Int) -> String {
        switch boardClipCount {
        case 0: "This removes every clip from Aster. It can’t be undone."
        case 1: "This removes every clip except the 1 saved to a board. It can’t be undone."
        default: "This removes every clip except the \(boardClipCount) saved to boards. It can’t be undone."
        }
    }
}

/// A small, cached preview of a saved clipboard image.
struct ClipImageThumbnail: View {
    let url: URL
    var maxPixel = 640
    var fills = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = CanvasThumbnailCache.cachedImage(for: url, maxPixel: maxPixel)
            if image == nil {
                image = await CanvasThumbnailCache.image(forImageAt: url, maxPixel: maxPixel)
            }
        }
    }
}

/// Clips settings, shown from the Clips page and in the Settings window.
struct ClipsOptionsView: View {
    @Environment(ClipboardManager.self) private var clipboard
    @State private var pasteAccessGranted = ClipsPasteAction.isAllowed

    var body: some View {
        @Bindable var clipboard = clipboard
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("History").font(.headline)
                HStack {
                    Text("Keep up to")
                    Spacer()
                    Picker("Keep up to", selection: $clipboard.historyLimit) {
                        ForEach(ClipboardManager.historyLimitChoices, id: \.self) { limit in
                            Text("\(limit) clips").tag(limit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Text("Remove clips after")
                    Spacer()
                    Picker("Remove clips after", selection: $clipboard.retention) {
                        ForEach(ClipboardManager.Retention.allCases) { retention in
                            Text(retention == .forever ? "Never" : retention.label).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Clips saved to a board are always kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Paste after choosing a clip")
                    Spacer()
                    Toggle("Paste after choosing a clip", isOn: Binding(
                        get: { clipboard.pastesAfterCopy },
                        set: { newValue in
                            clipboard.pastesAfterCopy = newValue
                            if newValue {
                                pasteAccessGranted = ClipsPasteAction.requestAccess()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Text("Choosing a clip in the Clips panel pastes it straight into the app you were using.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if clipboard.pastesAfterCopy && !pasteAccessGranted {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aster needs Accessibility access to paste for you. Until then, clips are only copied.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Accessibility Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ignored apps").font(.headline)
                    Spacer()
                    Button("Add App…", action: chooseApplication)
                }
                Text("Aster never records what you copy in these apps. Password managers and Keychain are always ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if clipboard.excludedApps.isEmpty {
                    Text("No apps added")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(clipboard.excludedApps) { app in
                            HStack(spacing: 8) {
                                Image(nsImage: icon(for: app))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Button { clipboard.removeExcludedApp(app) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop ignoring \(app.name)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pasteAccessGranted = ClipsPasteAction.isAllowed
        }
    }

    private func icon(for app: ClipboardManager.ExcludedApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { clipboard.excludeApplication(at: url) }
    }
}

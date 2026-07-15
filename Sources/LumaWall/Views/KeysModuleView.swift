import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeysModuleView: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(MacShortcutRemapper.self) private var shortcutRemapper
    @Environment(AppHotkeyController.self) private var appHotkeyController
    @State private var section: KeysSection = .mac
    @State private var searchText = ""
    @State private var editingTarget: EditingTarget?
    @State private var recordingRequest = 0
    @State private var editError: String?

    private enum KeysSection: String, CaseIterable, Identifiable {
        case mac = "Mac shortcuts"
        case aster = "Aster shortcuts"
        case apps = "App hotkeys"

        var id: String { rawValue }
    }

    private enum EditingTarget: Equatable {
        case mac(String)
        case aster(AsterShortcutAction)
        case app(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .keys) {
                HStack(spacing: 12) {
                    Picker("Shortcut collection", selection: $section) {
                        ForEach(KeysSection.allCases) { item in
                            Text(item.rawValue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 420)
                    if section == .apps {
                        Button(action: chooseApplication) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Add App")
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .buttonStyle(KeysActionButtonStyle())
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    introduction
                    searchField

                    if section == .mac {
                        macShortcutList
                    } else if section == .aster {
                        asterShortcutList
                    } else {
                        appHotkeyList
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(22)
            }
            .scrollIndicators(.hidden)
        }
        .background(alignment: .topLeading) {
            ShortcutCaptureView(
                isActive: editingTarget != nil,
                focusRequest: recordingRequest,
                onCapture: apply,
                onCancel: { editingTarget = nil }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .alert("Couldn’t Change Shortcut", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "Try a different shortcut.")
        }
        .onChange(of: section) { _, _ in editingTarget = nil }
        .onDisappear { editingTarget = nil }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: sectionIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.asterPurple)
                .frame(width: 38, height: 38)
                .background(Color.asterPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                Text(sectionTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(sectionDetail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if section == .mac {
                if shortcutRemapper.needsAccessibilityPermission {
                    Button("Enable instant changes") {
                        shortcutRemapper.requestAccessibilityPermission()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.asterPurple)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(Color.asterPurple.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                } else if shortcutRemapper.isActive {
                    Label("Live", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            } else if section == .apps, appHotkeyController.isActive {
                Label("Global & live", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.thinMaterial.opacity(0.38), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.asterPurple.opacity(0.16), lineWidth: 0.7)
        }
    }

    private var sectionIcon: String {
        switch section {
        case .mac: "macbook"
        case .aster: "asterisk"
        case .apps: "app.badge"
        }
    }

    private var sectionTitle: String {
        switch section {
        case .mac: "Your Mac shortcut cheat sheet"
        case .aster: "Shortcuts that control Aster"
        case .apps: "Jump directly to any app"
        }
    }

    private var sectionDetail: String {
        switch section {
        case .mac:
            "Custom combinations are remapped instantly while Aster runs. The original combination is disabled until you restore it or close Aster."
        case .aster:
            "Changes in this section take effect in Aster immediately. The global Clips shortcut works even when another app is active."
        case .apps:
            "Choose an app and assign a global hotkey. If it’s running, Aster brings it to the front; if it isn’t, Aster opens it."
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search shortcuts and actions…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private var macShortcutList: some View {
        let matches = ShortcutStore.macShortcuts.filter(matchesSearch)
        if matches.isEmpty {
            emptySearchResult
        } else {
            ForEach(categories(in: matches), id: \.self) { category in
                ShortcutGroup(title: category) {
                    ForEach(matches.filter { $0.category == category }) { shortcut in
                        let isDisabled = shortcuts.isDisabled(shortcut)
                        ShortcutRow(
                            title: shortcut.title,
                            detail: shortcut.detail,
                            warning: nil,
                            binding: shortcuts.binding(for: shortcut),
                            isGlobal: false,
                            isRecording: editingTarget == .mac(shortcut.id),
                            isCustomized: shortcuts.isCustomized(shortcut),
                            isDisabled: isDisabled,
                            edit: { beginEditing(.mac(shortcut.id)) },
                            toggleDisabled: {
                                shortcuts.setDisabled(!isDisabled, for: shortcut)
                                if editingTarget == .mac(shortcut.id) { editingTarget = nil }
                            },
                            restore: {
                                shortcuts.restore(shortcut)
                                if editingTarget == .mac(shortcut.id) { editingTarget = nil }
                            }
                        )
                        if shortcut.id != matches.filter({ $0.category == category }).last?.id {
                            Divider().overlay(.white.opacity(0.055))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var asterShortcutList: some View {
        let matches = AsterShortcutAction.allCases.filter(matchesSearch)
        if matches.isEmpty {
            emptySearchResult
        } else {
            ForEach(categories(in: matches), id: \.self) { category in
                ShortcutGroup(title: category) {
                    ForEach(matches.filter { $0.category == category }) { action in
                        let isDisabled = shortcuts.isDisabled(action)
                        ShortcutRow(
                            title: action.title,
                            detail: action.detail,
                            warning: action == .showClipsGlobally && !isDisabled
                                ? shortcuts.globalShortcutRegistrationError
                                : nil,
                            binding: shortcuts.binding(for: action),
                            isGlobal: action.isGlobal,
                            isRecording: editingTarget == .aster(action),
                            isCustomized: shortcuts.isCustomized(action),
                            isDisabled: isDisabled,
                            edit: { beginEditing(.aster(action)) },
                            toggleDisabled: {
                                shortcuts.setDisabled(!isDisabled, for: action)
                                if editingTarget == .aster(action) { editingTarget = nil }
                            },
                            restore: {
                                shortcuts.restore(action)
                                if editingTarget == .aster(action) { editingTarget = nil }
                            }
                        )
                        if action.id != matches.filter({ $0.category == category }).last?.id {
                            Divider().overlay(.white.opacity(0.055))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var appHotkeyList: some View {
        let matches = shortcuts.appHotkeys.filter(matchesSearch)
        if shortcuts.appHotkeys.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: "app.badge")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.asterPurple)
                Text("No app hotkeys yet")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add any application, then press the hotkey you want to use from anywhere on your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: chooseApplication) {
                    Label("Add App", systemImage: "plus")
                }
                .buttonStyle(KeysActionButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
            .background(.thinMaterial.opacity(0.28), in: RoundedRectangle(cornerRadius: 17))
        } else if matches.isEmpty {
            emptySearchResult
        } else {
            ShortcutGroup(title: "Applications") {
                ForEach(matches) { hotkey in
                    AppHotkeyRow(
                        hotkey: hotkey,
                        registrationError: shortcuts.appHotkeyRegistrationErrors[hotkey.id],
                        isRecording: editingTarget == .app(hotkey.id),
                        isCustomized: shortcuts.isAppHotkeyCustomized(hotkey),
                        edit: { beginEditing(.app(hotkey.id)) },
                        toggleDisabled: {
                            shortcuts.setAppHotkeyDisabled(!hotkey.isDisabled, id: hotkey.id)
                            if editingTarget == .app(hotkey.id) { editingTarget = nil }
                        },
                        restore: {
                            shortcuts.restoreAppHotkey(hotkey.id)
                            if editingTarget == .app(hotkey.id) { editingTarget = nil }
                        },
                        remove: {
                            shortcuts.removeAppHotkey(hotkey.id)
                            if editingTarget == .app(hotkey.id) { editingTarget = nil }
                        }
                    )
                    if hotkey.id != matches.last?.id {
                        Divider().overlay(.white.opacity(0.055))
                    }
                }
            }
        }
    }

    private var emptySearchResult: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
    }

    private func matchesSearch(_ shortcut: MacShortcutDefinition) -> Bool {
        matchesSearch(title: shortcut.title, detail: shortcut.detail, category: shortcut.category)
    }

    private func matchesSearch(_ action: AsterShortcutAction) -> Bool {
        matchesSearch(title: action.title, detail: action.detail, category: action.category)
    }

    private func matchesSearch(_ hotkey: AppHotkeyDefinition) -> Bool {
        matchesSearch(
            title: hotkey.name,
            detail: hotkey.applicationURL.deletingLastPathComponent().path,
            category: "Applications"
        )
    }

    private func matchesSearch(title: String, detail: String, category: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
            || category.localizedCaseInsensitiveContains(query)
    }

    private func categories(in shortcuts: [MacShortcutDefinition]) -> [String] {
        shortcuts.map(\.category).reduce(into: []) { result, category in
            if !result.contains(category) { result.append(category) }
        }
    }

    private func categories(in actions: [AsterShortcutAction]) -> [String] {
        actions.map(\.category).reduce(into: []) { result, category in
            if !result.contains(category) { result.append(category) }
        }
    }

    private func apply(_ binding: ShortcutBinding) {
        guard let editingTarget else { return }
        do {
            switch editingTarget {
            case .mac(let id):
                guard let shortcut = ShortcutStore.macShortcuts.first(where: { $0.id == id }) else { return }
                try shortcuts.update(shortcut, to: binding)
            case .aster(let action):
                try shortcuts.update(action, to: binding)
            case .app(let id):
                try shortcuts.updateAppHotkey(id, to: binding)
            }
            self.editingTarget = nil
        } catch {
            editError = error.localizedDescription
            self.editingTarget = nil
        }
    }

    private func beginEditing(_ target: EditingTarget) {
        editingTarget = target
        recordingRequest += 1
    }

    private func chooseApplication() {
        let picker = NSOpenPanel()
        picker.title = "Add an App Hotkey"
        picker.message = "Choose an application, then assign the hotkey that will open or focus it."
        picker.prompt = "Add App"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.begin { response in
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor in
                do {
                    let id = try shortcuts.addApplication(at: url)
                    searchText = ""
                    beginEditing(.app(id))
                } catch {
                    editError = error.localizedDescription
                }
            }
        }
    }
}

private struct AppHotkeyRow: View {
    let hotkey: AppHotkeyDefinition
    let registrationError: String?
    let isRecording: Bool
    let isCustomized: Bool
    let edit: () -> Void
    let toggleDisabled: () -> Void
    let restore: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hotkey.applicationPath))
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(hotkey.name)
                        .font(.system(size: 13.5, weight: .medium))
                    Text("GLOBAL")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Color.asterPurple)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.asterPurple.opacity(0.11), in: Capsule())
                    if hotkey.isDisabled {
                        Text("DISABLED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.orange.opacity(0.11), in: Capsule())
                    }
                }
                Text(rowDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(registrationError == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button(action: edit) {
                Text(isRecording ? "Press hotkey…" : hotkey.binding?.display ?? "Set hotkey")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isRecording ? Color.asterPurple : .primary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 90, minHeight: 30)
                    .background(.white.opacity(isRecording ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isRecording ? Color.asterPurple.opacity(0.7) : .white.opacity(0.08), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(hotkey.isDisabled)
            .opacity(hotkey.isDisabled ? 0.48 : 1)

            Button(action: toggleDisabled) {
                Image(systemName: hotkey.isDisabled ? "checkmark.circle" : "nosign")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hotkey.isDisabled ? Color.green : Color.orange)
            .disabled(hotkey.binding == nil)
            .help(hotkey.isDisabled ? "Enable this app hotkey" : "Disable this app hotkey")

            Button(action: restore) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle((isCustomized || hotkey.isDisabled) ? Color.asterPurple : Color.secondary.opacity(0.4))
            .disabled((!isCustomized && !hotkey.isDisabled) || hotkey.defaultBinding == nil)
            .help("Restore the first hotkey assigned to this app")

            Button(action: remove) {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red.opacity(0.8))
            .help("Remove this app hotkey")
        }
        .frame(minHeight: 62)
    }

    private var rowDetail: String {
        if hotkey.isDisabled { return "This app hotkey is disabled." }
        if let registrationError { return registrationError }
        if hotkey.binding == nil { return "Click Set hotkey, then press a shortcut." }
        return "Open or focus \(hotkey.name) from any app."
    }
}

private struct KeysActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11)
            .frame(minWidth: 82, alignment: .center)
            .frame(height: 32, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(Color.asterPurple.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.white.opacity(0.09), lineWidth: 0.7)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct ShortcutGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 9)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16)
                .background(.thinMaterial.opacity(0.34), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 0.7)
                }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let detail: String
    let warning: String?
    let binding: ShortcutBinding
    let isGlobal: Bool
    let isRecording: Bool
    let isCustomized: Bool
    let isDisabled: Bool
    let edit: () -> Void
    let toggleDisabled: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                    if isGlobal {
                        Text("GLOBAL")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(Color.asterPurple)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.asterPurple.opacity(0.11), in: Capsule())
                    }
                    if isDisabled {
                        Text("DISABLED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.orange.opacity(0.11), in: Capsule())
                    }
                }
                Text(isDisabled ? "This shortcut will not respond until you enable or restore it." : warning ?? detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle((warning == nil && !isDisabled) ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: edit) {
                Text(isRecording ? "Press shortcut…" : binding.display)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isRecording ? Color.asterPurple : .primary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 78, minHeight: 30)
                    .background(.white.opacity(isRecording ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isRecording ? Color.asterPurple.opacity(0.7) : .white.opacity(0.08), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.48 : 1)
            .help("Click, then press a new shortcut")

            Button(action: toggleDisabled) {
                Label(
                    isDisabled ? "Enable" : "Disable",
                    systemImage: isDisabled ? "checkmark.circle" : "nosign"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDisabled ? Color.green : Color.orange)
            .help(isDisabled ? "Enable this shortcut" : "Disable this shortcut")

            Button(action: restore) {
                Label("Restore", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle((isCustomized || isDisabled) ? Color.asterPurple : Color.secondary.opacity(0.45))
            .disabled(!isCustomized && !isDisabled)
            .help("Restore this shortcut to its default")
            .accessibilityLabel("Restore \(title) shortcut")
        }
        .frame(minHeight: 58)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let focusRequest: Int
    let onCapture: (ShortcutBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.setActive(isActive, focusRequest: focusRequest)
    }
}

@MainActor
private final class ShortcutRecorderNSView: NSView {
    var onCapture: ((ShortcutBinding) -> Void)?
    var onCancel: (() -> Void)?
    private var isActive = false
    private var lastFocusRequest = -1

    override var acceptsFirstResponder: Bool { true }

    func setActive(_ active: Bool, focusRequest: Int) {
        let shouldFocus = active && (!isActive || focusRequest != lastFocusRequest)
        isActive = active
        lastFocusRequest = focusRequest
        if shouldFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.window?.makeFirstResponder(self)
            }
        } else if !active, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard let binding = Self.binding(from: event) else {
            NSSound.beep()
            return
        }
        onCapture?(binding)
    }

    private static func binding(from event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let key: String
        switch event.keyCode {
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 49: key = "space"
        case 51, 117: key = "delete"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageup"
        case 121: key = "pagedown"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  characters.count == 1,
                  let character = characters.first,
                  !character.isWhitespace,
                  !character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            key = String(character)
        }
        return ShortcutBinding(key, keyCode: event.keyCode, modifiers: modifiers)
    }
}

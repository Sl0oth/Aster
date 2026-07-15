import AppKit
import Observation
import SwiftUI

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if contains(.control) { value.insert(.control) }
        if contains(.option) { value.insert(.option) }
        if contains(.shift) { value.insert(.shift) }
        if contains(.command) { value.insert(.command) }
        return value
    }

    var display: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    let key: String
    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    init(_ key: String, keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.key = key.lowercased()
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var display: String { modifiers.display + displayKey }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": .space
        case "return": .return
        case "delete": .delete
        case "escape": .escape
        case "tab": .tab
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        case "home": .home
        case "end": .end
        case "pageup": .pageUp
        case "pagedown": .pageDown
        default: KeyEquivalent(Character(key))
        }
    }

    private var displayKey: String {
        switch key {
        case "space": "Space"
        case "return": "↩"
        case "delete": "⌫"
        case "escape": "Esc"
        case "tab": "⇥"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }
}

struct AppHotkeyDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let bundleIdentifier: String?
    let applicationPath: String
    var binding: ShortcutBinding?
    var defaultBinding: ShortcutBinding?
    var isDisabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String?,
        applicationPath: String,
        binding: ShortcutBinding? = nil,
        defaultBinding: ShortcutBinding? = nil,
        isDisabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.binding = binding
        self.defaultBinding = defaultBinding
        self.isDisabled = isDisabled
    }

    var applicationURL: URL { URL(fileURLWithPath: applicationPath) }
}

enum AsterShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case openHome
    case openCanvas
    case openClips
    case openShelf
    case openBar
    case openSwitch
    case openKeys
    case importCanvas
    case showClipsGlobally

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openHome: "Open Home"
        case .openCanvas: "Open Canvas"
        case .openClips: "Open Clips"
        case .openShelf: "Open Shelf"
        case .openBar: "Open Bar"
        case .openSwitch: "Open Switch"
        case .openKeys: "Open Keys"
        case .importCanvas: "Import into Canvas"
        case .showClipsGlobally: "Open Clips globally"
        }
    }

    var detail: String {
        switch self {
        case .openHome: "Show Aster’s home page."
        case .openCanvas: "Open wallpaper controls."
        case .openClips: "Open clipboard history in Aster."
        case .openShelf: "Open Shelf settings."
        case .openBar: "Open menu bar controls."
        case .openSwitch: "Open Mac controls."
        case .openKeys: "Open this shortcut cheat sheet."
        case .importCanvas: "Choose images or videos for Canvas."
        case .showClipsGlobally: "Show the Clips panel from any app."
        }
    }

    var category: String {
        switch self {
        case .openHome, .openCanvas, .openClips, .openShelf, .openBar, .openSwitch, .openKeys:
            "Navigation"
        case .importCanvas:
            "Canvas"
        case .showClipsGlobally:
            "Clips"
        }
    }

    var isGlobal: Bool { self == .showClipsGlobally }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .openHome: ShortcutBinding("1", keyCode: 18, modifiers: .command)
        case .openCanvas: ShortcutBinding("2", keyCode: 19, modifiers: .command)
        case .openClips: ShortcutBinding("3", keyCode: 20, modifiers: .command)
        case .openShelf: ShortcutBinding("4", keyCode: 21, modifiers: .command)
        case .openBar: ShortcutBinding("5", keyCode: 23, modifiers: .command)
        case .openSwitch: ShortcutBinding("6", keyCode: 22, modifiers: .command)
        case .openKeys: ShortcutBinding("7", keyCode: 26, modifiers: .command)
        case .importCanvas: ShortcutBinding("o", keyCode: 31, modifiers: .command)
        case .showClipsGlobally: ShortcutBinding("v", keyCode: 9, modifiers: [.shift, .command])
        }
    }
}

struct MacShortcutDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let defaultBinding: ShortcutBinding

    init(
        _ id: String,
        category: String,
        title: String,
        detail: String,
        key: String,
        keyCode: UInt16,
        modifiers: ShortcutModifiers
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.defaultBinding = ShortcutBinding(key, keyCode: keyCode, modifiers: modifiers)
    }
}

enum ShortcutEditError: LocalizedError {
    case missingModifier
    case duplicate(String)
    case duplicateApp(String)
    case invalidApplication

    var errorDescription: String? {
        switch self {
        case .missingModifier:
            "Add Command, Option, or Control to keep the shortcut from firing while you type."
        case .duplicate(let title):
            "That shortcut is already assigned to \(title)."
        case .duplicateApp(let title):
            "\(title) already has an app hotkey."
        case .invalidApplication:
            "Choose a macOS application."
        }
    }
}

@MainActor
@Observable
final class ShortcutStore {
    private enum Keys {
        static let aster = "Aster.Keys.asterOverrides"
        static let mac = "Aster.Keys.macOverrides"
        static let disabledAster = "Aster.Keys.disabledAster"
        static let disabledMac = "Aster.Keys.disabledMac"
        static let appHotkeys = "Aster.Keys.appHotkeys"
    }

    private let defaults: UserDefaults
    private(set) var asterOverrides: [String: ShortcutBinding]
    private(set) var macOverrides: [String: ShortcutBinding]
    private(set) var disabledAsterShortcuts: Set<String>
    private(set) var disabledMacShortcuts: Set<String>
    private(set) var appHotkeys: [AppHotkeyDefinition]
    private(set) var globalShortcutRegistrationError: String?
    private(set) var appHotkeyRegistrationErrors: [UUID: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asterOverrides = Self.load(key: Keys.aster, from: defaults)
        macOverrides = Self.load(key: Keys.mac, from: defaults)
        disabledAsterShortcuts = Set(defaults.stringArray(forKey: Keys.disabledAster) ?? [])
        disabledMacShortcuts = Set(defaults.stringArray(forKey: Keys.disabledMac) ?? [])
        appHotkeys = Self.loadAppHotkeys(from: defaults)
        globalShortcutRegistrationError = nil
        appHotkeyRegistrationErrors = [:]
    }

    func binding(for action: AsterShortcutAction) -> ShortcutBinding {
        asterOverrides[action.rawValue] ?? action.defaultBinding
    }

    func binding(for shortcut: MacShortcutDefinition) -> ShortcutBinding {
        macOverrides[shortcut.id] ?? shortcut.defaultBinding
    }

    func isCustomized(_ action: AsterShortcutAction) -> Bool {
        binding(for: action) != action.defaultBinding
    }

    func isCustomized(_ shortcut: MacShortcutDefinition) -> Bool {
        binding(for: shortcut) != shortcut.defaultBinding
    }

    func isDisabled(_ action: AsterShortcutAction) -> Bool {
        disabledAsterShortcuts.contains(action.rawValue)
    }

    func isDisabled(_ shortcut: MacShortcutDefinition) -> Bool {
        disabledMacShortcuts.contains(shortcut.id)
    }

    func addApplication(at url: URL) throws -> UUID {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: standardizedURL) else {
            throw ShortcutEditError.invalidApplication
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        return try addApplication(
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            applicationPath: standardizedURL.path
        )
    }

    @discardableResult
    func addApplication(
        name: String,
        bundleIdentifier: String?,
        applicationPath: String
    ) throws -> UUID {
        if let existing = appHotkeys.first(where: {
            if let bundleIdentifier, let existingBundleID = $0.bundleIdentifier {
                return existingBundleID == bundleIdentifier
            }
            return $0.applicationPath == applicationPath
        }) {
            throw ShortcutEditError.duplicateApp(existing.name)
        }
        let hotkey = AppHotkeyDefinition(
            name: name,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationPath
        )
        appHotkeys.append(hotkey)
        saveAppHotkeys()
        return hotkey.id
    }

    func updateAppHotkey(_ id: UUID, to binding: ShortcutBinding) throws {
        guard binding.modifiers.contains(.command)
                || binding.modifiers.contains(.option)
                || binding.modifiers.contains(.control) else {
            throw ShortcutEditError.missingModifier
        }
        if let duplicate = appHotkeys.first(where: {
            $0.id != id
                && $0.binding.map { Self.sameKeyCombination($0, binding) } == true
        }) {
            throw ShortcutEditError.duplicate(duplicate.name)
        }
        if let duplicate = AsterShortcutAction.allCases.first(where: {
            Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        if let duplicate = Self.macShortcuts.first(where: {
            Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        guard let index = appHotkeys.firstIndex(where: { $0.id == id }) else { return }
        appHotkeys[index].binding = binding
        if appHotkeys[index].defaultBinding == nil {
            appHotkeys[index].defaultBinding = binding
        }
        appHotkeys[index].isDisabled = false
        saveAppHotkeys()
    }

    func setAppHotkeyDisabled(_ disabled: Bool, id: UUID) {
        guard let index = appHotkeys.firstIndex(where: { $0.id == id }) else { return }
        appHotkeys[index].isDisabled = disabled
        saveAppHotkeys()
    }

    func restoreAppHotkey(_ id: UUID) {
        guard let index = appHotkeys.firstIndex(where: { $0.id == id }) else { return }
        appHotkeys[index].binding = appHotkeys[index].defaultBinding
        appHotkeys[index].isDisabled = false
        saveAppHotkeys()
    }

    func removeAppHotkey(_ id: UUID) {
        appHotkeys.removeAll { $0.id == id }
        appHotkeyRegistrationErrors.removeValue(forKey: id)
        saveAppHotkeys()
    }

    func isAppHotkeyCustomized(_ hotkey: AppHotkeyDefinition) -> Bool {
        hotkey.binding != hotkey.defaultBinding
    }

    func update(_ action: AsterShortcutAction, to binding: ShortcutBinding) throws {
        guard binding.modifiers.contains(.command)
                || binding.modifiers.contains(.option)
                || binding.modifiers.contains(.control) else {
            throw ShortcutEditError.missingModifier
        }
        if Self.sameKeyCombination(binding, action.defaultBinding) {
            restore(action)
            return
        }
        if let duplicate = Self.macShortcuts.first(where: {
            Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        if let duplicate = AsterShortcutAction.allCases.first(where: {
            guard $0 != action else { return false }
            return Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        if let duplicate = appHotkeys.first(where: {
            $0.binding.map { Self.sameKeyCombination($0, binding) } == true
        }) {
            throw ShortcutEditError.duplicate(duplicate.name)
        }
        asterOverrides[action.rawValue] = binding
        saveAsterChanges()
    }

    func update(_ shortcut: MacShortcutDefinition, to binding: ShortcutBinding) throws {
        if Self.sameKeyCombination(binding, shortcut.defaultBinding) {
            restore(shortcut)
            return
        }
        guard binding.modifiers.contains(.command)
                || binding.modifiers.contains(.option)
                || binding.modifiers.contains(.control) else {
            throw ShortcutEditError.missingModifier
        }
        if let duplicate = Self.macShortcuts.first(where: {
            $0.id != shortcut.id
                && Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        if let duplicate = AsterShortcutAction.allCases.first(where: {
            Self.sameKeyCombination(self.binding(for: $0), binding)
        }) {
            throw ShortcutEditError.duplicate(duplicate.title)
        }
        if let duplicate = appHotkeys.first(where: {
            $0.binding.map { Self.sameKeyCombination($0, binding) } == true
        }) {
            throw ShortcutEditError.duplicate(duplicate.name)
        }
        macOverrides[shortcut.id] = binding
        Self.save(macOverrides, key: Keys.mac, to: defaults)
        NotificationCenter.default.post(name: .asterMacShortcutsChanged, object: nil)
    }

    func restore(_ action: AsterShortcutAction) {
        asterOverrides.removeValue(forKey: action.rawValue)
        disabledAsterShortcuts.remove(action.rawValue)
        saveDisabledAsterShortcuts()
        saveAsterChanges()
    }

    func restore(_ shortcut: MacShortcutDefinition) {
        macOverrides.removeValue(forKey: shortcut.id)
        disabledMacShortcuts.remove(shortcut.id)
        Self.save(macOverrides, key: Keys.mac, to: defaults)
        saveDisabledMacShortcuts()
        NotificationCenter.default.post(name: .asterMacShortcutsChanged, object: nil)
    }

    func setDisabled(_ disabled: Bool, for action: AsterShortcutAction) {
        if disabled {
            disabledAsterShortcuts.insert(action.rawValue)
        } else {
            disabledAsterShortcuts.remove(action.rawValue)
        }
        saveDisabledAsterShortcuts()
        NotificationCenter.default.post(name: .asterShortcutsChanged, object: nil)
    }

    func setDisabled(_ disabled: Bool, for shortcut: MacShortcutDefinition) {
        if disabled {
            disabledMacShortcuts.insert(shortcut.id)
        } else {
            disabledMacShortcuts.remove(shortcut.id)
        }
        saveDisabledMacShortcuts()
        NotificationCenter.default.post(name: .asterMacShortcutsChanged, object: nil)
    }

    func reportGlobalShortcutRegistration(error: String?) {
        globalShortcutRegistrationError = error
    }

    func reportAppHotkeyRegistration(error: String?, for id: UUID) {
        appHotkeyRegistrationErrors[id] = error
    }

    private func saveAsterChanges() {
        Self.save(asterOverrides, key: Keys.aster, to: defaults)
        NotificationCenter.default.post(name: .asterShortcutsChanged, object: nil)
    }

    private func saveDisabledAsterShortcuts() {
        defaults.set(disabledAsterShortcuts.sorted(), forKey: Keys.disabledAster)
    }

    private func saveDisabledMacShortcuts() {
        defaults.set(disabledMacShortcuts.sorted(), forKey: Keys.disabledMac)
    }

    private func saveAppHotkeys() {
        guard let data = try? JSONEncoder().encode(appHotkeys) else { return }
        defaults.set(data, forKey: Keys.appHotkeys)
        NotificationCenter.default.post(name: .asterAppHotkeysChanged, object: nil)
    }

    private static func loadAppHotkeys(from defaults: UserDefaults) -> [AppHotkeyDefinition] {
        guard let data = defaults.data(forKey: Keys.appHotkeys),
              let value = try? JSONDecoder().decode([AppHotkeyDefinition].self, from: data) else {
            return []
        }
        return value
    }

    private static func load(key: String, from defaults: UserDefaults) -> [String: ShortcutBinding] {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return [:]
        }
        return value
    }

    private static func save(
        _ value: [String: ShortcutBinding],
        key: String,
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func sameKeyCombination(
        _ lhs: ShortcutBinding,
        _ rhs: ShortcutBinding
    ) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static let macShortcuts: [MacShortcutDefinition] = [
        MacShortcutDefinition("copy", category: "Everyday", title: "Copy", detail: "Copy the selected item.", key: "c", keyCode: 8, modifiers: .command),
        MacShortcutDefinition("cut", category: "Everyday", title: "Cut", detail: "Remove the selection and copy it.", key: "x", keyCode: 7, modifiers: .command),
        MacShortcutDefinition("paste", category: "Everyday", title: "Paste", detail: "Insert the Clipboard contents.", key: "v", keyCode: 9, modifiers: .command),
        MacShortcutDefinition("undo", category: "Everyday", title: "Undo", detail: "Reverse the last action.", key: "z", keyCode: 6, modifiers: .command),
        MacShortcutDefinition("redo", category: "Everyday", title: "Redo", detail: "Repeat the last action you undid.", key: "z", keyCode: 6, modifiers: [.shift, .command]),
        MacShortcutDefinition("selectAll", category: "Everyday", title: "Select all", detail: "Select every item in the active view.", key: "a", keyCode: 0, modifiers: .command),
        MacShortcutDefinition("find", category: "Everyday", title: "Find", detail: "Search in the active app or document.", key: "f", keyCode: 3, modifiers: .command),
        MacShortcutDefinition("save", category: "Everyday", title: "Save", detail: "Save the current document.", key: "s", keyCode: 1, modifiers: .command),
        MacShortcutDefinition("open", category: "Everyday", title: "Open", detail: "Open a file or choose an item.", key: "o", keyCode: 31, modifiers: .command),
        MacShortcutDefinition("new", category: "Everyday", title: "New", detail: "Create a new document or window.", key: "n", keyCode: 45, modifiers: .command),
        MacShortcutDefinition("print", category: "Everyday", title: "Print", detail: "Open the print dialog.", key: "p", keyCode: 35, modifiers: .command),
        MacShortcutDefinition("close", category: "Everyday", title: "Close window", detail: "Close the front window or tab.", key: "w", keyCode: 13, modifiers: .command),
        MacShortcutDefinition("quit", category: "Everyday", title: "Quit app", detail: "Quit the active app.", key: "q", keyCode: 12, modifiers: .command),
        MacShortcutDefinition("settings", category: "Everyday", title: "App settings", detail: "Open settings for the active app.", key: ",", keyCode: 43, modifiers: .command),
        MacShortcutDefinition("pasteStyle", category: "Everyday", title: "Paste and match style", detail: "Paste text using the surrounding style.", key: "v", keyCode: 9, modifiers: [.option, .shift, .command]),
        MacShortcutDefinition("emoji", category: "Everyday", title: "Emoji & Symbols", detail: "Open the Character Viewer.", key: "space", keyCode: 49, modifiers: [.control, .command]),

        MacShortcutDefinition("spotlight", category: "Mac & apps", title: "Spotlight", detail: "Search apps, files, and more.", key: "space", keyCode: 49, modifiers: .command),
        MacShortcutDefinition("switchApp", category: "Mac & apps", title: "Switch apps", detail: "Move to the next recently used app.", key: "tab", keyCode: 48, modifiers: .command),
        MacShortcutDefinition("switchWindow", category: "Mac & apps", title: "Switch windows", detail: "Cycle through windows in the active app.", key: "`", keyCode: 50, modifiers: .command),
        MacShortcutDefinition("forceQuit", category: "Mac & apps", title: "Force Quit", detail: "Choose an unresponsive app to close.", key: "escape", keyCode: 53, modifiers: [.option, .command]),
        MacShortcutDefinition("lockScreen", category: "Mac & apps", title: "Lock screen", detail: "Lock this Mac immediately.", key: "q", keyCode: 12, modifiers: [.control, .command]),
        MacShortcutDefinition("hideApp", category: "Mac & apps", title: "Hide active app", detail: "Hide the active app’s windows.", key: "h", keyCode: 4, modifiers: .command),
        MacShortcutDefinition("hideOthers", category: "Mac & apps", title: "Hide other apps", detail: "Keep the active app visible and hide the rest.", key: "h", keyCode: 4, modifiers: [.option, .command]),
        MacShortcutDefinition("minimize", category: "Mac & apps", title: "Minimize window", detail: "Send the front window to the Dock.", key: "m", keyCode: 46, modifiers: .command),
        MacShortcutDefinition("fullScreen", category: "Mac & apps", title: "Enter full screen", detail: "Toggle full-screen mode in supported apps.", key: "f", keyCode: 3, modifiers: [.control, .command]),
        MacShortcutDefinition("missionControl", category: "Mac & apps", title: "Mission Control", detail: "See every open window and desktop.", key: "up", keyCode: 126, modifiers: .control),
        MacShortcutDefinition("appExpose", category: "Mac & apps", title: "App Exposé", detail: "See every window in the active app.", key: "down", keyCode: 125, modifiers: .control),
        MacShortcutDefinition("previousDesktop", category: "Mac & apps", title: "Previous desktop", detail: "Move one Space to the left.", key: "left", keyCode: 123, modifiers: .control),
        MacShortcutDefinition("nextDesktop", category: "Mac & apps", title: "Next desktop", detail: "Move one Space to the right.", key: "right", keyCode: 124, modifiers: .control),
        MacShortcutDefinition("logOut", category: "Mac & apps", title: "Log out", detail: "Ask to log out of your account.", key: "q", keyCode: 12, modifiers: [.shift, .command]),

        MacShortcutDefinition("newFinderWindow", category: "Finder", title: "New Finder window", detail: "Open a new Finder window.", key: "n", keyCode: 45, modifiers: .command),
        MacShortcutDefinition("newFolder", category: "Finder", title: "New folder", detail: "Create a folder in the current location.", key: "n", keyCode: 45, modifiers: [.shift, .command]),
        MacShortcutDefinition("getInfo", category: "Finder", title: "Get Info", detail: "See details for the selected item.", key: "i", keyCode: 34, modifiers: .command),
        MacShortcutDefinition("quickLook", category: "Finder", title: "Quick Look", detail: "Preview the selected file.", key: "space", keyCode: 49, modifiers: []),
        MacShortcutDefinition("duplicate", category: "Finder", title: "Duplicate", detail: "Make a copy of the selected item.", key: "d", keyCode: 2, modifiers: .command),
        MacShortcutDefinition("moveToTrash", category: "Finder", title: "Move to Trash", detail: "Move the selected item to Trash.", key: "delete", keyCode: 51, modifiers: .command),
        MacShortcutDefinition("emptyTrash", category: "Finder", title: "Empty Trash", detail: "Permanently remove items in Trash.", key: "delete", keyCode: 51, modifiers: [.shift, .command]),
        MacShortcutDefinition("goToFolder", category: "Finder", title: "Go to Folder", detail: "Open a location by typing its path.", key: "g", keyCode: 5, modifiers: [.shift, .command]),
        MacShortcutDefinition("connectServer", category: "Finder", title: "Connect to server", detail: "Connect Finder to a network server.", key: "k", keyCode: 40, modifiers: .command),
        MacShortcutDefinition("hiddenFiles", category: "Finder", title: "Show hidden files", detail: "Toggle hidden files in Finder.", key: ".", keyCode: 47, modifiers: [.shift, .command]),
        MacShortcutDefinition("finderBack", category: "Finder", title: "Previous Finder location", detail: "Go back to the prior folder.", key: "[", keyCode: 33, modifiers: .command),
        MacShortcutDefinition("finderForward", category: "Finder", title: "Next Finder location", detail: "Go forward to the next folder.", key: "]", keyCode: 30, modifiers: .command),
        MacShortcutDefinition("containingFolder", category: "Finder", title: "Containing folder", detail: "Open the folder that contains the current item.", key: "up", keyCode: 126, modifiers: .command),
        MacShortcutDefinition("applicationsFolder", category: "Finder", title: "Applications folder", detail: "Open Applications in Finder.", key: "a", keyCode: 0, modifiers: [.shift, .command]),
        MacShortcutDefinition("desktopFolder", category: "Finder", title: "Desktop folder", detail: "Open the Desktop folder.", key: "d", keyCode: 2, modifiers: [.shift, .command]),
        MacShortcutDefinition("downloadsFolder", category: "Finder", title: "Downloads folder", detail: "Open the Downloads folder.", key: "l", keyCode: 37, modifiers: [.option, .command]),
        MacShortcutDefinition("homeFolder", category: "Finder", title: "Home folder", detail: "Open your Home folder.", key: "h", keyCode: 4, modifiers: [.shift, .command]),
        MacShortcutDefinition("computer", category: "Finder", title: "Computer", detail: "Show this Mac’s disks and network locations.", key: "c", keyCode: 8, modifiers: [.shift, .command]),
        MacShortcutDefinition("icloudDrive", category: "Finder", title: "iCloud Drive", detail: "Open iCloud Drive in Finder.", key: "i", keyCode: 34, modifiers: [.shift, .command]),
        MacShortcutDefinition("utilitiesFolder", category: "Finder", title: "Utilities folder", detail: "Open the Utilities folder.", key: "u", keyCode: 32, modifiers: [.shift, .command]),
        MacShortcutDefinition("airDrop", category: "Finder", title: "AirDrop", detail: "Open the AirDrop window.", key: "r", keyCode: 15, modifiers: [.shift, .command]),
        MacShortcutDefinition("eject", category: "Finder", title: "Eject selected disk", detail: "Safely eject the selected disk or volume.", key: "e", keyCode: 14, modifiers: .command),
        MacShortcutDefinition("iconView", category: "Finder", title: "Icon view", detail: "Show Finder items as icons.", key: "1", keyCode: 18, modifiers: .command),
        MacShortcutDefinition("listView", category: "Finder", title: "List view", detail: "Show Finder items in a list.", key: "2", keyCode: 19, modifiers: .command),
        MacShortcutDefinition("columnView", category: "Finder", title: "Column view", detail: "Show Finder items in columns.", key: "3", keyCode: 20, modifiers: .command),
        MacShortcutDefinition("galleryView", category: "Finder", title: "Gallery view", detail: "Show Finder items in a gallery.", key: "4", keyCode: 21, modifiers: .command),
        MacShortcutDefinition("viewOptions", category: "Finder", title: "View options", detail: "Customize the current Finder view.", key: "j", keyCode: 38, modifiers: .command),

        MacShortcutDefinition("screenshotScreen", category: "Screenshots", title: "Capture entire screen", detail: "Save a picture of every display.", key: "3", keyCode: 20, modifiers: [.shift, .command]),
        MacShortcutDefinition("screenshotArea", category: "Screenshots", title: "Capture an area", detail: "Drag to capture part of the screen.", key: "4", keyCode: 21, modifiers: [.shift, .command]),
        MacShortcutDefinition("screenshotTools", category: "Screenshots", title: "Screenshot controls", detail: "Open screenshot and screen-recording tools.", key: "5", keyCode: 23, modifiers: [.shift, .command]),

        MacShortcutDefinition("wordLeft", category: "Text editing", title: "Move back one word", detail: "Move the insertion point one word left.", key: "left", keyCode: 123, modifiers: .option),
        MacShortcutDefinition("wordRight", category: "Text editing", title: "Move forward one word", detail: "Move the insertion point one word right.", key: "right", keyCode: 124, modifiers: .option),
        MacShortcutDefinition("lineStart", category: "Text editing", title: "Start of line", detail: "Move to the beginning of the current line.", key: "left", keyCode: 123, modifiers: .command),
        MacShortcutDefinition("lineEnd", category: "Text editing", title: "End of line", detail: "Move to the end of the current line.", key: "right", keyCode: 124, modifiers: .command),
        MacShortcutDefinition("documentStart", category: "Text editing", title: "Start of document", detail: "Move to the beginning of the document.", key: "up", keyCode: 126, modifiers: .command),
        MacShortcutDefinition("documentEnd", category: "Text editing", title: "End of document", detail: "Move to the end of the document.", key: "down", keyCode: 125, modifiers: .command),
        MacShortcutDefinition("deleteWord", category: "Text editing", title: "Delete previous word", detail: "Delete from the insertion point to the prior word.", key: "delete", keyCode: 51, modifiers: .option),
        MacShortcutDefinition("newTab", category: "Web browsers", title: "New tab", detail: "Open a new browser tab.", key: "t", keyCode: 17, modifiers: .command),
        MacShortcutDefinition("reopenTab", category: "Web browsers", title: "Reopen closed tab", detail: "Restore the most recently closed tab.", key: "t", keyCode: 17, modifiers: [.shift, .command]),
        MacShortcutDefinition("addressBar", category: "Web browsers", title: "Focus address bar", detail: "Select the current web address.", key: "l", keyCode: 37, modifiers: .command),
        MacShortcutDefinition("reloadPage", category: "Web browsers", title: "Reload page", detail: "Load the current page again.", key: "r", keyCode: 15, modifiers: .command),
        MacShortcutDefinition("nextTab", category: "Web browsers", title: "Next tab", detail: "Move to the next open browser tab.", key: "tab", keyCode: 48, modifiers: .control),
        MacShortcutDefinition("previousTab", category: "Web browsers", title: "Previous tab", detail: "Move to the previous open browser tab.", key: "tab", keyCode: 48, modifiers: [.control, .shift])
    ]
}

private struct OptionalShortcutModifier: ViewModifier {
    let shortcut: ShortcutBinding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers.eventModifiers)
        } else {
            content
        }
    }
}

extension View {
    func optionalKeyboardShortcut(_ shortcut: ShortcutBinding?) -> some View {
        modifier(OptionalShortcutModifier(shortcut: shortcut))
    }
}

extension Notification.Name {
    static let asterShortcutsChanged = Notification.Name("Aster.shortcutsChanged")
    static let asterMacShortcutsChanged = Notification.Name("Aster.macShortcutsChanged")
    static let asterAppHotkeysChanged = Notification.Name("Aster.appHotkeysChanged")
}

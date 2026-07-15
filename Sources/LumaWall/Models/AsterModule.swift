import SwiftUI

enum AsterModule: String, CaseIterable, Identifiable {
    case home
    case canvas
    case clips
    case shelf
    case bar
    case switchboard
    case keys
    case ask

    static var visibleCases: [AsterModule] {
        allCases.filter { $0 != .ask }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .canvas: "Canvas"
        case .clips: "Clips"
        case .shelf: "Shelf"
        case .bar: "Bar"
        case .switchboard: "Switch"
        case .keys: "Keys"
        case .ask: "Ask"
        }
    }

    var subtitle: String {
        switch self {
        case .home: "Your private utility layer"
        case .canvas: "Still and motion wallpapers"
        case .clips: "Local clipboard history"
        case .shelf: "A home around the notch"
        case .bar: "A calmer menu bar"
        case .switchboard: "Fast controls for your Mac"
        case .keys: "Every shortcut in one place"
        case .ask: "Optional AI actions"
        }
    }

    var symbol: String {
        switch self {
        case .home: "sparkles"
        case .canvas: "photo.stack.fill"
        case .clips: "doc.on.clipboard.fill"
        case .shelf: "capsule.fill"
        case .bar: "menubar.rectangle"
        case .switchboard: "switch.2"
        case .keys: "keyboard.fill"
        case .ask: "wand.and.stars"
        }
    }

    var accent: Color {
        .asterPurple
    }

    var isAvailable: Bool { self != .ask }

    var shortcutAction: AsterShortcutAction? {
        switch self {
        case .home: .openHome
        case .canvas: .openCanvas
        case .clips: .openClips
        case .shelf: .openShelf
        case .bar: .openBar
        case .switchboard: .openSwitch
        case .keys: .openKeys
        case .ask: nil
        }
    }
}

enum AsterModuleSelection {
    static let defaultsKey = "Aster.Modules.enabled"

    static func load(from defaults: UserDefaults = .standard) -> Set<AsterModule> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(AsterModule.init(rawValue:)))
    }

    static func save(_ modules: Set<AsterModule>, to defaults: UserDefaults = .standard) {
        defaults.set(modules.map(\.rawValue).sorted(), forKey: defaultsKey)
    }

    static func initialModule(from defaults: UserDefaults = .standard) -> AsterModule {
        let enabled = load(from: defaults)
        return AsterModule.onboardingOrder.first(where: enabled.contains) ?? .home
    }
}

extension AsterModule {
    static let onboardingOrder: [AsterModule] = [.canvas, .clips, .shelf, .bar, .switchboard, .keys]
}

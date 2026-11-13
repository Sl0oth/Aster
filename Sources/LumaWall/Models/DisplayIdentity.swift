import AppKit

extension NSScreen {
    var asterDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }

    /// Identifies this physical display across restarts and reconnections.
    var asterDisplayKey: String {
        let displayID = asterDisplayID
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "display-\(displayID)"
    }
}

/// A connected display, as offered in Aster's display pickers.
struct AsterDisplay: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }

    @MainActor
    static var connected: [AsterDisplay] {
        NSScreen.screens.map { AsterDisplay(key: $0.asterDisplayKey, name: $0.localizedName) }
    }
}

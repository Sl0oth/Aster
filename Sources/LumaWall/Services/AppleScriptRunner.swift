import AppKit
import Foundation

/// Runs AppleScript away from the main thread. Scripts that talk to other apps
/// can take seconds, and running them on the main thread froze Aster's interface.
///
/// One serial queue creates and executes every script, which keeps each
/// `NSAppleScript` on the thread it was created on.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "app.aster.applescript", qos: .userInitiated)

    /// Executes `source` and passes its result — `nil` if the script failed — to
    /// `transform` on the script queue.
    static func run<Value: Sendable>(
        _ source: String,
        transform: @escaping @Sendable (NSAppleEventDescriptor?) -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: transform(error == nil ? result : nil))
            }
        }
    }

    static func succeeds(_ source: String) async -> Bool {
        await run(source) { $0 != nil }
    }

    static func boolean(_ source: String) async -> Bool? {
        await run(source) { $0?.booleanValue }
    }

    static func integer(_ source: String) async -> Int? {
        await run(source) { $0.map { Int($0.int32Value) } }
    }
}

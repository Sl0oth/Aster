import Foundation
import ServiceManagement

enum AsterLoginItemManager {
    enum Status: Equatable {
        case disabled
        case enabled
        case requiresApproval
    }

    private static let developmentAgentName = "app.aster.Aster.development.plist"

    static var status: Status {
        if usesNativeLoginItem {
            return nativeStatus
        }
        return FileManager.default.fileExists(atPath: developmentAgentURL.path)
            ? .enabled
            : .disabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Status {
        if usesNativeLoginItem {
            if enabled {
                switch nativeStatus {
                case .enabled, .requiresApproval:
                    break
                case .disabled:
                    try SMAppService.mainApp.register()
                }
            } else if nativeStatus != .disabled {
                try SMAppService.mainApp.unregister()
            }
            return nativeStatus
        }

        try setDevelopmentAgentEnabled(
            enabled,
            executableURL: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]),
            launchAgentsDirectory: developmentAgentURL.deletingLastPathComponent()
        )
        return enabled ? .enabled : .disabled
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func isPackagedApplication(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let path = bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    static func setDevelopmentAgentEnabled(
        _ enabled: Bool,
        executableURL: URL,
        launchAgentsDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let agentURL = launchAgentsDirectory.appendingPathComponent(developmentAgentName)
        if !enabled {
            if fileManager.fileExists(atPath: agentURL.path) {
                try fileManager.removeItem(at: agentURL)
            }
            return
        }

        try fileManager.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        let executablePath = executableURL.standardizedFileURL.path
        let propertyList: [String: Any] = [
            "Label": "app.aster.Aster.development",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: agentURL, options: .atomic)
    }

    private static var usesNativeLoginItem: Bool {
        isPackagedApplication()
    }

    private static var nativeStatus: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    private static var developmentAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(developmentAgentName)
    }
}

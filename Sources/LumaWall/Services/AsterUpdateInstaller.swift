import Foundation

enum AsterUpdateInstaller {
    struct ApplicationMetadata: Equatable {
        let bundleIdentifier: String
        let version: String
        let build: Int
    }

    enum InstallationError: LocalizedError {
        case appIsNotInstalled
        case destinationIsNotWritable
        case diskImageCouldNotBeMounted
        case applicationIsMissing
        case invalidApplicationMetadata
        case unexpectedBundleIdentifier
        case unexpectedVersion
        case unsupportedArchitecture
        case invalidCodeSignature
        case commandFailed(String)
        case replacementFailed

        var allowsManualInstallation: Bool {
            switch self {
            case .appIsNotInstalled, .destinationIsNotWritable:
                true
            default:
                false
            }
        }

        var errorDescription: String? {
            switch self {
            case .appIsNotInstalled:
                "Aster must be in Applications before it can update itself automatically."
            case .destinationIsNotWritable:
                "Aster cannot replace the installed copy without permission."
            case .diskImageCouldNotBeMounted:
                "The verified update disk image could not be mounted."
            case .applicationIsMissing:
                "The update disk image did not contain Aster.app."
            case .invalidApplicationMetadata:
                "The update did not contain valid application metadata."
            case .unexpectedBundleIdentifier:
                "The update contained an unexpected application identifier."
            case .unexpectedVersion:
                "The application in the update did not match the advertised version."
            case .unsupportedArchitecture:
                "The update did not contain the supported Apple-silicon application."
            case .invalidCodeSignature:
                "The application in the update did not pass code-signature verification."
            case let .commandFailed(command):
                "The update helper could not run \(command)."
            case .replacementFailed:
                "Aster could not safely replace the installed application."
            }
        }
    }

    static let expectedBundleIdentifier = "app.aster.Aster"

    static let relaunchHelperScript = #"""
    pid="$1"
    app="$2"
    backup="$3"
    registrar="$4"
    opener="$5"

    # Give Aster time to finish detaching the update image, remove the
    # downloaded installer, and respond to its normal terminate request.
    for _ in {1..30}; do
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
            break
        fi
        /bin/sleep 0.1
    done

    # A modal SwiftUI sheet can prevent NSApplication.terminate from closing
    # the old process. Finish that process externally so it cannot keep the
    # single-instance bundle registered and block the replacement app.
    if /bin/kill -0 "$pid" 2>/dev/null; then
        /bin/kill -TERM "$pid" 2>/dev/null || true
        for _ in {1..50}; do
            if ! /bin/kill -0 "$pid" 2>/dev/null; then
                break
            fi
            /bin/sleep 0.1
        done
    fi
    if /bin/kill -0 "$pid" 2>/dev/null; then
        /bin/kill -KILL "$pid" 2>/dev/null || true
        for _ in {1..20}; do
            if ! /bin/kill -0 "$pid" 2>/dev/null; then
                break
            fi
            /bin/sleep 0.1
        done
    fi
    if /bin/kill -0 "$pid" 2>/dev/null; then
        exit 1
    fi

    /bin/rm -rf -- "$backup"
    "$registrar" -f "$app" >/dev/null 2>&1 || true

    # Do not use `open -n`: Aster explicitly prohibits multiple instances,
    # and the flag makes Launch Services reject the relaunch if it has not yet
    # discarded the old registration.
    for _ in {1..20}; do
        if "$opener" "$app" >/dev/null 2>&1; then
            exit 0
        fi
        /bin/sleep 0.25
    done

    executable="$app/Contents/MacOS/Aster"
    if [ -x "$executable" ]; then
        /usr/bin/nohup "$executable" >/dev/null 2>&1 &
        exit 0
    fi
    exit 1
    """#

    static func install(
        diskImageURL: URL,
        release: AsterRelease,
        currentApplicationURL: URL = Bundle.main.bundleURL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try installSynchronously(
                diskImageURL: diskImageURL,
                release: release,
                currentApplicationURL: currentApplicationURL
            )
        }.value
    }

    static func applicationMetadata(at applicationURL: URL) throws -> ApplicationMetadata {
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let buildValue = info["CFBundleVersion"] as? String,
              let build = Int(buildValue) else {
            throw InstallationError.invalidApplicationMetadata
        }
        return ApplicationMetadata(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
    }

    static func validateMetadata(at applicationURL: URL, release: AsterRelease) throws {
        let metadata = try applicationMetadata(at: applicationURL)
        guard metadata.bundleIdentifier == expectedBundleIdentifier else {
            throw InstallationError.unexpectedBundleIdentifier
        }
        guard metadata.version == release.version, metadata.build == release.build else {
            throw InstallationError.unexpectedVersion
        }
    }

    private static func installSynchronously(
        diskImageURL: URL,
        release: AsterRelease,
        currentApplicationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let currentApplicationURL = currentApplicationURL.standardizedFileURL
        guard AsterLoginItemManager.isPackagedApplication(bundleURL: currentApplicationURL) else {
            throw InstallationError.appIsNotInstalled
        }

        let applicationsDirectory = currentApplicationURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: applicationsDirectory.path) else {
            throw InstallationError.destinationIsNotWritable
        }

        let mountURL = try mount(diskImageURL)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountURL.path]) }

        let sourceApplicationURL = mountURL.appendingPathComponent("Aster.app", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceApplicationURL.path) else {
            throw InstallationError.applicationIsMissing
        }
        try validateApplication(at: sourceApplicationURL, release: release)

        let identifier = UUID().uuidString.lowercased()
        let stagedApplicationURL = applicationsDirectory
            .appendingPathComponent(".Aster-update-\(identifier).app", isDirectory: true)
        let backupApplicationURL = applicationsDirectory
            .appendingPathComponent(".Aster-backup-\(identifier).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagedApplicationURL) }

        try run("/usr/bin/ditto", [sourceApplicationURL.path, stagedApplicationURL.path])
        try validateApplication(at: stagedApplicationURL, release: release)

        do {
            try fileManager.moveItem(at: currentApplicationURL, to: backupApplicationURL)
            do {
                try fileManager.moveItem(at: stagedApplicationURL, to: currentApplicationURL)
                try launchRelaunchHelper(
                    applicationURL: currentApplicationURL,
                    backupURL: backupApplicationURL
                )
            } catch {
                try? fileManager.removeItem(at: currentApplicationURL)
                try? fileManager.moveItem(at: backupApplicationURL, to: currentApplicationURL)
                throw error
            }
        } catch let error as InstallationError {
            throw error
        } catch {
            throw InstallationError.replacementFailed
        }
    }

    private static func validateApplication(at applicationURL: URL, release: AsterRelease) throws {
        try validateMetadata(at: applicationURL, release: release)

        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", applicationURL.path])
        } catch {
            throw InstallationError.invalidCodeSignature
        }

        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Aster")
        let architectures = try runCapturingOutput("/usr/bin/lipo", ["-archs", executableURL.path])
        guard architectures.split(whereSeparator: \Character.isWhitespace).contains("arm64") else {
            throw InstallationError.unsupportedArchitecture
        }
    }

    private static func mount(_ diskImageURL: URL) throws -> URL {
        let output = try runCapturingData(
            "/usr/bin/hdiutil",
            ["attach", diskImageURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: output,
            options: [],
            format: nil
        ) as? [String: Any],
              let entities = propertyList["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).last else {
            throw InstallationError.diskImageCouldNotBeMounted
        }
        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    private static func launchRelaunchHelper(applicationURL: URL, backupURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            relaunchHelperScript,
            "aster-update-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            applicationURL.path,
            backupURL.path,
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/usr/bin/open"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallationError.commandFailed("the relaunch helper")
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        try runCapturingData(executable, arguments)
    }

    private static func runCapturingOutput(_ executable: String, _ arguments: [String]) throws -> String {
        String(decoding: try runCapturingData(executable, arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runCapturingData(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallationError.commandFailed(
                    URL(fileURLWithPath: executable).lastPathComponent
                )
            }
            return data
        } catch {
            if let error = error as? InstallationError { throw error }
            throw InstallationError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)
        }
    }
}

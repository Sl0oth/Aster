import AppKit
import Foundation

enum ScreenSaverInstaller {
    enum Destination: String {
        case screenSaver
        case lockScreen
    }

    private struct MediaConfiguration: Codable {
        let mediaPath: String?
        let mediaFilename: String?
        let mediaKind: String
        let fillMode: String
        let muted: Bool
    }

    private struct Configuration: Codable {
        var screenSaver: MediaConfiguration
        var lockScreen: MediaConfiguration
    }

    private struct LegacyConfiguration: Decodable {
        let mediaPath: String?
        let mediaFilename: String?
        let mediaKind: String
        let fillMode: String
        let muted: Bool

        var media: MediaConfiguration {
            MediaConfiguration(
                mediaPath: mediaPath,
                mediaFilename: mediaFilename,
                mediaKind: mediaKind,
                fillMode: fillMode,
                muted: muted
            )
        }
    }

    enum InstallationError: LocalizedError {
        case moduleNotBuilt
        case signingFailed
        case configurationMissing

        var errorDescription: String? {
            switch self {
            case .moduleNotBuilt:
                "The Aster Screen Saver module is missing. Build Aster again, then retry."
            case .signingFailed:
                "macOS could not prepare the Aster Screen Saver module."
            case .configurationMissing:
                "Aster could not read the installed Screen Saver configuration."
            }
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBundleURL.path)
    }

    static func configure(
        destination: Destination,
        mediaURL: URL,
        mediaKind: WallpaperItem.Kind,
        fillMode: WallpaperController.FillMode,
        muted: Bool
    ) throws {
        if isInstalled {
            try updateConfiguration(
                destination: destination,
                mediaURL: mediaURL,
                mediaKind: mediaKind,
                fillMode: fillMode,
                muted: muted
            )
        } else {
            try install(
                mediaURL: mediaURL,
                mediaKind: mediaKind,
                fillMode: fillMode,
                muted: muted
            )
        }
    }

    private static func install(
        mediaURL: URL,
        mediaKind: WallpaperItem.Kind,
        fillMode: WallpaperController.FillMode,
        muted: Bool
    ) throws {
        guard let builtModuleURL else { throw InstallationError.moduleNotBuilt }

        let fileManager = FileManager.default
        let temporaryBundle = installedBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Aster.saver.installing", isDirectory: true)
        try? fileManager.removeItem(at: temporaryBundle)
        let contents = temporaryBundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("AsterScreenSaver")
        try fileManager.copyItem(at: builtModuleURL, to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "AsterScreenSaver",
            "CFBundleIdentifier": "app.aster.ScreenSaver",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Aster",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.1",
            "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "14.0",
            "NSHumanReadableCopyright": "Aster — free and private",
            "NSPrincipalClass": "AsterScreenSaverView"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

        let resources = resourcesURL(in: temporaryBundle)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let media = try copyMedia(
            mediaURL,
            named: "shared",
            to: resources,
            kind: mediaKind,
            fillMode: fillMode,
            muted: muted
        )
        try write(Configuration(screenSaver: media, lockScreen: media), in: temporaryBundle)
        try sign(temporaryBundle)

        try fileManager.createDirectory(
            at: installedBundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: installedBundleURL)
        try fileManager.moveItem(at: temporaryBundle, to: installedBundleURL)
        reloadScreenSaverHost()
    }

    private static func updateConfiguration(
        destination: Destination,
        mediaURL: URL,
        mediaKind: WallpaperItem.Kind,
        fillMode: WallpaperController.FillMode,
        muted: Bool
    ) throws {
        guard isInstalled else { throw InstallationError.moduleNotBuilt }
        guard var configuration = readConfiguration(in: installedBundleURL) else {
            throw InstallationError.configurationMissing
        }
        try refreshInstalledModule()

        let resources = resourcesURL(in: installedBundleURL)
        let media = try copyMedia(
            mediaURL,
            named: destination.rawValue,
            to: resources,
            kind: mediaKind,
            fillMode: fillMode,
            muted: muted
        )
        switch destination {
        case .screenSaver: configuration.screenSaver = media
        case .lockScreen: configuration.lockScreen = media
        }
        try write(configuration, in: installedBundleURL)
        removeUnusedMedia(in: resources, keeping: configuration)
        try sign(installedBundleURL)
        reloadScreenSaverHost()
    }

    private static func refreshInstalledModule() throws {
        guard let builtModuleURL else { throw InstallationError.moduleNotBuilt }
        let executable = installedBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AsterScreenSaver")
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: builtModuleURL, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private static func copyMedia(
        _ source: URL,
        named stem: String,
        to resources: URL,
        kind: WallpaperItem.Kind,
        fillMode: WallpaperController.FillMode,
        muted: Bool
    ) throws -> MediaConfiguration {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let extensionName = source.pathExtension.isEmpty ? "media" : source.pathExtension.lowercased()
        let filename = "\(stem).\(extensionName)"
        let destination = resources.appendingPathComponent(filename)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        return MediaConfiguration(
            mediaPath: nil,
            mediaFilename: filename,
            mediaKind: kind.rawValue,
            fillMode: fillMode.rawValue,
            muted: muted
        )
    }

    private static func readConfiguration(in bundle: URL) -> Configuration? {
        let url = resourcesURL(in: bundle).appendingPathComponent("configuration.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let current = try? JSONDecoder().decode(Configuration.self, from: data) {
            return current
        }
        if let legacy = try? JSONDecoder().decode(LegacyConfiguration.self, from: data) {
            return Configuration(screenSaver: legacy.media, lockScreen: legacy.media)
        }
        return nil
    }

    private static func write(_ configuration: Configuration, in bundle: URL) throws {
        let data = try JSONEncoder().encode(configuration)
        try data.write(
            to: resourcesURL(in: bundle).appendingPathComponent("configuration.json"),
            options: .atomic
        )
    }

    private static func removeUnusedMedia(in resources: URL, keeping configuration: Configuration) {
        let keep = Set([
            configuration.screenSaver.mediaFilename,
            configuration.lockScreen.mediaFilename,
            "configuration.json"
        ].compactMap { $0 })
        for file in (try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        )) ?? [] where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"
        ]
        for value in urls {
            guard let url = URL(string: value) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private static func reloadScreenSaverHost() {
        // The legacy ScreenSaver extension stays alive between lock cycles and keeps
        // its original player/configuration. End only that cached helper so macOS
        // creates a fresh instance with the newly signed media bundle next time.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["legacyScreenSaver"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // No cached helper is a valid state; the next lock creates one.
        }
    }

    private static func resourcesURL(in bundle: URL) -> URL {
        bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private static var installedBundleURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers", isDirectory: true)
            .appendingPathComponent("Aster.saver", isDirectory: true)
    }

    private static var builtModuleURL: URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("libAsterScreenSaver.dylib"))
            candidates.append(directory.appendingPathComponent("AsterScreenSaver"))
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent("libAsterScreenSaver.dylib"))
            candidates.append(frameworks.appendingPathComponent("AsterScreenSaver"))
        }
        let commandURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        candidates.append(
            commandURL.deletingLastPathComponent().appendingPathComponent("libAsterScreenSaver.dylib")
        )
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func sign(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallationError.signingFailed }
    }
}

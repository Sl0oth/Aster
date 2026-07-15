import AppKit
import CryptoKit
import Foundation
import Observation

struct AsterReleaseFeature: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let symbol: String
}

struct AsterRelease: Codable, Identifiable, Hashable {
    let version: String
    let build: Int
    let headline: String
    let summary: String
    let releaseDate: String
    let downloadURL: URL
    let sha256: String
    let minimumSystemVersion: String
    let features: [AsterReleaseFeature]

    var id: String { version }
}

struct AsterReleaseEnvelope: Codable {
    let payload: String
    let signature: String
}

struct AsterBundledReleaseNotes: Codable {
    let version: String
    let headline: String
    let summary: String
    let features: [AsterReleaseFeature]

    static func load() -> AsterBundledReleaseNotes? {
        guard let url = Bundle.asterResources.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AsterBundledReleaseNotes.self, from: data)
    }
}

@MainActor
@Observable
final class UpdateManager {
    enum State: Equatable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case downloaded
        case upToDate
        case failed
    }

    private(set) var state: State = .idle
    private(set) var statusMessage = "Updates are checked automatically"
    private(set) var availableRelease: AsterRelease?
    private(set) var downloadedFileURL: URL?
    private(set) var whatsNew: AsterBundledReleaseNotes?
    private(set) var presentsWhatsNew = false

    var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: Keys.automaticChecks)
        }
    }

    let currentVersion: String
    let currentBuild: Int

    var isFeedConfigured: Bool { feedURL != nil && updatePublicKey != nil }
    var isBusy: Bool { state == .checking || state == .downloading }
    var updateButtonTitle: String {
        switch state {
        case .checking: "Checking…"
        case .downloading: "Downloading…"
        case .downloaded: "Open Download"
        case .updateAvailable: "Download Update"
        default: "Check for Updates"
        }
    }

    private let defaults = UserDefaults.standard
    private let feedURL: URL?
    private let updatePublicKey: Curve25519.Signing.PublicKey?
    private var hasStarted = false
    private var automaticCheckTask: Task<Void, Never>?

    private enum Keys {
        static let automaticChecks = "Aster.Updates.automaticChecks"
        static let lastCheck = "Aster.Updates.lastCheck"
        static let lastLaunchedVersion = "Aster.Updates.lastLaunchedVersion"
        static let lastSeenWhatsNewVersion = "Aster.Updates.lastSeenWhatsNewVersion"
    }

    init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0-beta.1"
        currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
        automaticallyChecksForUpdates = defaults.object(forKey: Keys.automaticChecks) as? Bool ?? true
        let configuration = Self.loadReleaseConfiguration()
        feedURL = configuration.feedURL
        updatePublicKey = configuration.publicKey
        prepareWhatsNew()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        automaticCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                if let self,
                   self.automaticallyChecksForUpdates,
                   self.shouldRunAutomaticCheck,
                   !self.isBusy {
                    self.checkForUpdates(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    func checkForUpdates(userInitiated: Bool = true) {
        guard !isBusy else { return }
        guard let feedURL, let updatePublicKey else {
            state = .failed
            statusMessage = "The signed release feed has not been configured yet"
            return
        }

        state = .checking
        statusMessage = "Checking for a new version…"
        Task { [weak self] in
            await self?.performCheck(
                at: feedURL,
                publicKey: updatePublicKey,
                userInitiated: userInitiated
            )
        }
    }

    func downloadAvailableUpdate() {
        guard !isBusy, let release = availableRelease else { return }
        state = .downloading
        statusMessage = "Downloading Aster \(release.version)…"
        Task { [weak self] in
            await self?.performDownload(release)
        }
    }

    func openDownloadedUpdate() {
        guard let downloadedFileURL else { return }
        NSWorkspace.shared.open(downloadedFileURL)
    }

    func showWhatsNew() {
        guard whatsNew != nil else { return }
        presentsWhatsNew = true
    }

    func dismissWhatsNew() {
        if let whatsNew {
            defaults.set(whatsNew.version, forKey: Keys.lastSeenWhatsNewVersion)
        }
        presentsWhatsNew = false
    }

    private func performCheck(
        at feedURL: URL,
        publicKey: Curve25519.Signing.PublicKey,
        userInitiated: Bool
    ) async {
        do {
            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Aster/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard data.count <= 1_000_000 else { throw UpdateError.feedTooLarge }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.invalidServerResponse
            }

            let release = try Self.decodeSignedRelease(data, publicKey: publicKey)
            try validate(release)
            defaults.set(Date(), forKey: Keys.lastCheck)

            if Self.isNewer(
                candidateVersion: release.version,
                candidateBuild: release.build,
                installedVersion: currentVersion,
                installedBuild: currentBuild
            ) {
                availableRelease = release
                state = .updateAvailable
                statusMessage = "Aster \(release.version) is available"
            } else {
                availableRelease = nil
                state = .upToDate
                statusMessage = "Aster is up to date"
            }
        } catch {
            state = .failed
            statusMessage = userInitiated
                ? "Couldn’t check for updates: \(error.localizedDescription)"
                : "Automatic update check will try again later"
        }
    }

    private func performDownload(_ release: AsterRelease) async {
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            let (temporaryURL, response) = try await URLSession(configuration: configuration)
                .download(from: release.downloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.invalidServerResponse
            }

            let actualHash = try Self.sha256(of: temporaryURL)
            guard actualHash.caseInsensitiveCompare(release.sha256) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let fileExtension = release.downloadURL.pathExtension.isEmpty ? "dmg" : release.downloadURL.pathExtension
            let destination = downloads.appendingPathComponent("Aster-\(release.version).\(fileExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            downloadedFileURL = destination
            state = .downloaded
            statusMessage = "Downloaded Aster \(release.version)"
            NSWorkspace.shared.open(destination)
        } catch {
            state = .failed
            statusMessage = "Update download failed: \(error.localizedDescription)"
        }
    }

    private func validate(_ release: AsterRelease) throws {
        guard release.downloadURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureDownload
        }
        let hash = release.sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.invalidChecksum
        }
        guard !release.version.isEmpty, release.build > 0 else {
            throw UpdateError.invalidRelease
        }
        guard Self.systemVersion(
            ProcessInfo.processInfo.operatingSystemVersion,
            meetsMinimum: release.minimumSystemVersion
        ) else {
            throw UpdateError.incompatibleSystem(release.minimumSystemVersion)
        }
    }

    nonisolated static func isNewer(
        candidateVersion: String,
        candidateBuild: Int,
        installedVersion: String,
        installedBuild: Int
    ) -> Bool {
        guard let candidate = AsterSemanticVersion(candidateVersion),
              let installed = AsterSemanticVersion(installedVersion) else {
            let comparison = candidateVersion.compare(
                installedVersion,
                options: [.numeric, .caseInsensitive]
            )
            return comparison == .orderedDescending ||
                (comparison == .orderedSame && candidateBuild > installedBuild)
        }
        if candidate != installed { return candidate > installed }
        return candidateBuild > installedBuild
    }

    nonisolated static func systemVersion(
        _ current: OperatingSystemVersion,
        meetsMinimum minimum: String
    ) -> Bool {
        let pieces = minimum.split(separator: ".").compactMap { Int($0) }
        guard !pieces.isEmpty, pieces.count <= 3 else { return false }
        let required = OperatingSystemVersion(
            majorVersion: pieces[0],
            minorVersion: pieces.count > 1 ? pieces[1] : 0,
            patchVersion: pieces.count > 2 ? pieces[2] : 0
        )
        let lhs = [current.majorVersion, current.minorVersion, current.patchVersion]
        let rhs = [required.majorVersion, required.minorVersion, required.patchVersion]
        return !lhs.lexicographicallyPrecedes(rhs)
    }

    nonisolated static func decodeSignedRelease(
        _ data: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> AsterRelease {
        let envelope = try JSONDecoder().decode(AsterReleaseEnvelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              publicKey.isValidSignature(signature, for: payload) else {
            throw UpdateError.invalidSignature
        }
        return try JSONDecoder().decode(AsterRelease.self, from: payload)
    }

    private var shouldRunAutomaticCheck: Bool {
        guard let lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date else { return true }
        return Date().timeIntervalSince(lastCheck) >= 6 * 60 * 60
    }

    private func prepareWhatsNew() {
        whatsNew = AsterBundledReleaseNotes.load()
        let previousVersion = defaults.string(forKey: Keys.lastLaunchedVersion)
        defaults.set(currentVersion, forKey: Keys.lastLaunchedVersion)

        guard let previousVersion,
              previousVersion != currentVersion,
              let whatsNew,
              whatsNew.version == currentVersion,
              defaults.string(forKey: Keys.lastSeenWhatsNewVersion) != currentVersion else { return }
        presentsWhatsNew = true
    }

    private static func loadReleaseConfiguration() -> (
        feedURL: URL?,
        publicKey: Curve25519.Signing.PublicKey?
    ) {
        let infoFeed = Bundle.main.object(forInfoDictionaryKey: "AsterUpdateFeedURL") as? String
        let infoKey = Bundle.main.object(forInfoDictionaryKey: "AsterUpdatePublicKey") as? String
        let environment = ProcessInfo.processInfo.environment
        guard let configURL = Bundle.asterResources.url(forResource: "ReleaseConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (
                secureURL(from: infoFeed ?? environment["ASTER_UPDATE_FEED_URL"] ?? ""),
                signingPublicKey(from: infoKey ?? environment["ASTER_UPDATE_PUBLIC_KEY"] ?? "")
            )
        }
        let feedValue = infoFeed ?? environment["ASTER_UPDATE_FEED_URL"] ?? object["feedURL"] as? String ?? ""
        let keyValue = infoKey ?? environment["ASTER_UPDATE_PUBLIC_KEY"] ?? object["publicKey"] as? String ?? ""
        return (secureURL(from: feedValue), signingPublicKey(from: keyValue))
    }

    private static func secureURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    private static func signingPublicKey(from value: String) -> Curve25519.Signing.PublicKey? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct AsterSemanticVersion: Comparable, Equatable {
    private enum Identifier: Equatable {
        case number(Int)
        case text(String)
    }

    private let core: [Int]
    private let prerelease: [Identifier]?

    init?(_ value: String) {
        let withoutBuildMetadata = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let pieces = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let normalizedCore = pieces[0].hasPrefix("v") ? pieces[0].dropFirst() : pieces[0][...]
        let coreParts = normalizedCore.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(coreParts.count),
              coreParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        var numbers = coreParts.compactMap { Int($0) }
        while numbers.count < 3 { numbers.append(0) }
        core = numbers

        if pieces.count == 1 {
            prerelease = nil
        } else {
            let identifiers = pieces[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers.map { identifier in
                if let number = Int(identifier), identifier.allSatisfy(\.isNumber) {
                    return .number(number)
                }
                return .text(identifier.lowercased())
            }
        }
    }

    static func < (lhs: AsterSemanticVersion, rhs: AsterSemanticVersion) -> Bool {
        if lhs.core != rhs.core {
            return lhs.core.lexicographicallyPrecedes(rhs.core)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(lhsParts), .some(rhsParts)):
            for (left, right) in zip(lhsParts, rhsParts) where left != right {
                switch (left, right) {
                case let (.number(a), .number(b)): return a < b
                case (.number, .text): return true
                case (.text, .number): return false
                case let (.text(a), .text(b)): return a < b
                }
            }
            return lhsParts.count < rhsParts.count
        }
    }
}

private enum UpdateError: LocalizedError {
    case feedTooLarge
    case invalidServerResponse
    case insecureDownload
    case invalidChecksum
    case checksumMismatch
    case invalidRelease
    case invalidSignature
    case incompatibleSystem(String)

    var errorDescription: String? {
        switch self {
        case .feedTooLarge: "The update feed was unexpectedly large."
        case .invalidServerResponse: "The update server returned an invalid response."
        case .insecureDownload: "The update download did not use HTTPS."
        case .invalidChecksum: "The update did not include a valid checksum."
        case .checksumMismatch: "The download could not be verified and was deleted."
        case .invalidRelease: "The update feed contained an invalid release."
        case .invalidSignature: "The update feed signature could not be verified."
        case let .incompatibleSystem(version): "This update requires macOS \(version) or later."
        }
    }
}

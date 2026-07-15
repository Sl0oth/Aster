import AppKit
import CoreFoundation
import Darwin

struct SystemNowPlayingSnapshot {
    let title: String
    let artist: String
    let album: String
    let sourceName: String
    let sourceBundleIdentifier: String?
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let artworkData: Data?
}

enum SystemMediaControl {
    case previous
    case playPause
    case next

    fileprivate var rawValue: Int32 {
        switch self {
        case .playPause: 2
        case .next: 4
        case .previous: 5
        }
    }
}

/// Reads and controls the same system-wide media session used by Control Center.
/// MediaRemote is loaded dynamically so Aster still launches normally if the
/// framework or one of its functions changes on a future macOS release.
@MainActor
final class SystemNowPlayingService {
    static let shared = SystemNowPlayingService()

    private typealias GetNowPlayingInfoFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    private typealias GetDisplayIDFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (CFString?) -> Void
    ) -> Void
    private typealias GetIsPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> Bool

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: GetNowPlayingInfoFunction?
    private let getDisplayID: GetDisplayIDFunction?
    private let getIsPlaying: GetIsPlayingFunction?
    private let sendCommand: SendCommandFunction?
    private let keys: Keys

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        self.handle = handle
        getNowPlayingInfo = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingInfo",
            from: handle,
            as: GetNowPlayingInfoFunction.self
        )
        getDisplayID = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingApplicationDisplayID",
            from: handle,
            as: GetDisplayIDFunction.self
        )
        getIsPlaying = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            from: handle,
            as: GetIsPlayingFunction.self
        )
        sendCommand = Self.loadFunction(
            named: "MRMediaRemoteSendCommand",
            from: handle,
            as: SendCommandFunction.self
        )
        keys = Keys(handle: handle)
    }

    func fetchSnapshot(completion: @escaping @MainActor (SystemNowPlayingSnapshot?) -> Void) {
        guard let getNowPlayingInfo else {
            completion(nil)
            return
        }

        getNowPlayingInfo(.main) { [weak self] dictionary in
            MainActor.assumeIsolated {
                guard let self, let dictionary,
                      let partial = self.parse(dictionary: dictionary) else {
                    completion(nil)
                    return
                }
                self.fetchSourceAndPlaybackState(partial: partial, completion: completion)
            }
        }
    }

    @discardableResult
    func send(_ control: SystemMediaControl) -> Bool {
        sendCommand?(control.rawValue, nil) ?? false
    }

    private func fetchSourceAndPlaybackState(
        partial: PartialSnapshot,
        completion: @escaping @MainActor (SystemNowPlayingSnapshot?) -> Void
    ) {
        fetchDisplayID { [weak self] bundleIdentifier in
            guard let self else {
                completion(nil)
                return
            }
            self.fetchPlaybackState(defaultValue: partial.isPlaying) { isPlaying in
                completion(SystemNowPlayingSnapshot(
                    title: partial.title,
                    artist: partial.artist,
                    album: partial.album,
                    sourceName: Self.applicationName(for: bundleIdentifier),
                    sourceBundleIdentifier: bundleIdentifier,
                    isPlaying: isPlaying,
                    position: partial.position,
                    duration: partial.duration,
                    artworkData: partial.artworkData
                ))
            }
        }
    }

    private func fetchDisplayID(completion: @escaping @MainActor (String?) -> Void) {
        guard let getDisplayID else {
            completion(nil)
            return
        }
        getDisplayID(.main) { value in
            MainActor.assumeIsolated {
                completion(value as String?)
            }
        }
    }

    private func fetchPlaybackState(
        defaultValue: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let getIsPlaying else {
            completion(defaultValue)
            return
        }
        getIsPlaying(.main) { value in
            MainActor.assumeIsolated {
                completion(value)
            }
        }
    }

    private func parse(dictionary: CFDictionary) -> PartialSnapshot? {
        let info = dictionary as NSDictionary
        guard let title = stringValue(in: info, key: keys.title), !title.isEmpty else { return nil }
        let playbackRate = numberValue(in: info, key: keys.playbackRate) ?? 0
        return PartialSnapshot(
            title: title,
            artist: stringValue(in: info, key: keys.artist) ?? "",
            album: stringValue(in: info, key: keys.album) ?? "",
            isPlaying: playbackRate > 0,
            position: max(numberValue(in: info, key: keys.elapsedTime) ?? 0, 0),
            duration: max(numberValue(in: info, key: keys.duration) ?? 0, 0),
            artworkData: info[keys.artworkData] as? Data
        )
    }

    private func stringValue(in dictionary: NSDictionary, key: String) -> String? {
        if let value = dictionary[key] as? String { return value }
        return dictionary.firstValue(withKeyEndingIn: key).flatMap { $0 as? String }
    }

    private func numberValue(in dictionary: NSDictionary, key: String) -> Double? {
        if let value = dictionary[key] as? NSNumber { return value.doubleValue }
        return dictionary.firstValue(withKeyEndingIn: key).flatMap { ($0 as? NSNumber)?.doubleValue }
    }

    private static func applicationName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return "System" }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let bundle = Bundle(url: appURL) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
        }
        return bundleIdentifier.split(separator: ".").last.map(String.init) ?? "System"
    }

    private static func loadFunction<T>(
        named name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private struct PartialSnapshot {
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let position: TimeInterval
        let duration: TimeInterval
        let artworkData: Data?
    }

    private struct Keys {
        let title: String
        let artist: String
        let album: String
        let duration: String
        let elapsedTime: String
        let playbackRate: String
        let artworkData: String

        init(handle: UnsafeMutableRawPointer?) {
            title = Self.value(named: "kMRMediaRemoteNowPlayingInfoTitle", handle: handle)
            artist = Self.value(named: "kMRMediaRemoteNowPlayingInfoArtist", handle: handle)
            album = Self.value(named: "kMRMediaRemoteNowPlayingInfoAlbum", handle: handle)
            duration = Self.value(named: "kMRMediaRemoteNowPlayingInfoDuration", handle: handle)
            elapsedTime = Self.value(named: "kMRMediaRemoteNowPlayingInfoElapsedTime", handle: handle)
            playbackRate = Self.value(named: "kMRMediaRemoteNowPlayingInfoPlaybackRate", handle: handle)
            artworkData = Self.value(named: "kMRMediaRemoteNowPlayingInfoArtworkData", handle: handle)
        }

        private static func value(named name: String, handle: UnsafeMutableRawPointer?) -> String {
            guard let handle, let symbol = dlsym(handle, name),
                  let value = symbol.assumingMemoryBound(to: CFString?.self).pointee else {
                return name
            }
            return value as String
        }
    }
}

private extension NSDictionary {
    func firstValue(withKeyEndingIn expectedKey: String) -> Any? {
        for (key, value) in self {
            guard let key = key as? String else { continue }
            if key == expectedKey || key.hasSuffix(expectedKey) { return value }
        }
        return nil
    }
}

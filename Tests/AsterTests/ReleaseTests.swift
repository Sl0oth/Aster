import CryptoKit
import XCTest
@testable import Aster

final class ReleaseTests: XCTestCase {
    func testSemanticVersionOrdering() throws {
        XCTAssertGreaterThan(try version("1.0.0"), try version("1.0.0-beta.9"))
        XCTAssertGreaterThan(try version("1.0.0-beta.2"), try version("1.0.0-beta.1"))
        XCTAssertGreaterThan(try version("1.1.0"), try version("1.0.9"))
        XCTAssertEqual(try version("1.0"), try version("1.0.0"))
        XCTAssertEqual(try version("1.0.0+42"), try version("1.0.0+43"))
    }

    func testBundledReleaseNotesAreComplete() throws {
        let notes = try XCTUnwrap(AsterBundledReleaseNotes.load())
        XCTAssertEqual(notes.version, "1.0.0-beta.1")
        XCTAssertFalse(notes.headline.isEmpty)
        XCTAssertFalse(notes.summary.isEmpty)
        XCTAssertFalse(notes.features.isEmpty)
        XCTAssertTrue(notes.features.allSatisfy { !$0.title.isEmpty && !$0.description.isEmpty })
    }

    func testReleaseComparisonUsesVersionAndBuild() {
        XCTAssertTrue(UpdateManager.isNewer(
            candidateVersion: "1.0.1",
            candidateBuild: 1,
            installedVersion: "1.0.0",
            installedBuild: 99
        ))
        XCTAssertTrue(UpdateManager.isNewer(
            candidateVersion: "1.0.0",
            candidateBuild: 2,
            installedVersion: "1.0.0",
            installedBuild: 1
        ))
        XCTAssertFalse(UpdateManager.isNewer(
            candidateVersion: "1.0.0",
            candidateBuild: 1,
            installedVersion: "1.0.0",
            installedBuild: 1
        ))
    }

    func testMinimumSystemVersionComparison() {
        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertTrue(UpdateManager.systemVersion(macOS14, meetsMinimum: "14.0"))
        XCTAssertTrue(UpdateManager.systemVersion(macOS14, meetsMinimum: "13.6.9"))
        XCTAssertFalse(UpdateManager.systemVersion(macOS14, meetsMinimum: "14.1"))
        XCTAssertFalse(UpdateManager.systemVersion(macOS14, meetsMinimum: "invalid"))
    }

    func testSignedFeedAcceptsValidPayloadAndRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let release = AsterRelease(
            version: "1.1.0",
            build: 2,
            headline: "Test release",
            summary: "A signed update.",
            releaseDate: "2026-07-13",
            downloadURL: try XCTUnwrap(URL(string: "https://updates.example.org/Aster-1.1.0.dmg")),
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            features: []
        )
        let payload = try JSONEncoder().encode(release)
        let envelope = AsterReleaseEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
        let feed = try JSONEncoder().encode(envelope)
        let decoded = try UpdateManager.decodeSignedRelease(feed, publicKey: privateKey.publicKey)
        XCTAssertEqual(decoded, release)

        var tamperedPayload = payload
        tamperedPayload.append(0x20)
        let tampered = AsterReleaseEnvelope(
            payload: tamperedPayload.base64EncodedString(),
            signature: envelope.signature
        )
        XCTAssertThrowsError(
            try UpdateManager.decodeSignedRelease(
                JSONEncoder().encode(tampered),
                publicKey: privateKey.publicKey
            )
        )
    }

    func testModuleSelectionPersistsAndChoosesFirstEnabledModule() throws {
        let suiteName = "AsterTests.ModuleSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AsterModuleSelection.save([.switchboard, .canvas], to: defaults)
        XCTAssertEqual(AsterModuleSelection.load(from: defaults), [.canvas, .switchboard])
        XCTAssertEqual(AsterModuleSelection.initialModule(from: defaults), .canvas)
    }

    private func version(_ value: String) throws -> AsterSemanticVersion {
        try XCTUnwrap(AsterSemanticVersion(value), "Invalid test version: \(value)")
    }
}

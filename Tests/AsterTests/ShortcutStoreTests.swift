import XCTest
@testable import Aster

@MainActor
final class ShortcutStoreTests: XCTestCase {
    func testAsterShortcutPersistsAndRestoresIndividually() throws {
        let suiteName = "AsterTests.Shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = ShortcutBinding("k", keyCode: 40, modifiers: [.option, .command])
        let store = ShortcutStore(defaults: defaults)
        try store.update(.openKeys, to: custom)

        XCTAssertEqual(ShortcutStore(defaults: defaults).binding(for: .openKeys), custom)
        XCTAssertTrue(store.isCustomized(.openKeys))

        store.restore(.openKeys)
        XCTAssertEqual(store.binding(for: .openKeys), AsterShortcutAction.openKeys.defaultBinding)
        XCTAssertFalse(store.isCustomized(.openKeys))
    }

    func testAsterShortcutCanRestoreToDefaultThatMatchesMacShortcut() throws {
        let suiteName = "AsterTests.AsterDefaultRestore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ShortcutStore(defaults: defaults)
        let custom = ShortcutBinding("o", keyCode: 31, modifiers: [.control, .option])

        try store.update(.importCanvas, to: custom)
        try store.update(.importCanvas, to: AsterShortcutAction.importCanvas.defaultBinding)

        XCTAssertEqual(
            store.binding(for: .importCanvas),
            AsterShortcutAction.importCanvas.defaultBinding
        )
        XCTAssertFalse(store.isCustomized(.importCanvas))
    }

    func testAsterShortcutRejectsDuplicatesAndTypingKeys() throws {
        let suiteName = "AsterTests.ShortcutConflicts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ShortcutStore(defaults: defaults)

        XCTAssertThrowsError(try store.update(.openKeys, to: .init("1", keyCode: 18, modifiers: .command)))
        XCTAssertThrowsError(try store.update(.openKeys, to: .init("k", keyCode: 40, modifiers: .shift)))
    }

    func testMacReferenceShortcutPersistsWithoutChangingOtherRows() throws {
        let suiteName = "AsterTests.MacShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let copy = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "copy" }))
        let paste = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "paste" }))
        let store = ShortcutStore(defaults: defaults)
        let custom = ShortcutBinding("c", keyCode: 8, modifiers: [.control, .option])

        try store.update(copy, to: custom)

        XCTAssertEqual(store.binding(for: copy), custom)
        XCTAssertEqual(store.binding(for: paste), paste.defaultBinding)
    }

    func testMacShortcutRejectsConflictWithUnchangedDefault() throws {
        let suiteName = "AsterTests.MacDefaultConflict.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let copy = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "copy" }))
        let paste = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "paste" }))
        let store = ShortcutStore(defaults: defaults)

        XCTAssertThrowsError(try store.update(copy, to: paste.defaultBinding)) { error in
            XCTAssertEqual(error.localizedDescription, "That shortcut is already assigned to Paste.")
        }
        XCTAssertEqual(store.binding(for: copy), copy.defaultBinding)
        XCTAssertEqual(store.binding(for: paste), paste.defaultBinding)
    }

    func testAsterShortcutRejectsConflictWithUnchangedMacDefault() throws {
        let suiteName = "AsterTests.AsterMacDefaultConflict.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let copy = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "copy" }))
        let store = ShortcutStore(defaults: defaults)

        XCTAssertThrowsError(try store.update(.openKeys, to: copy.defaultBinding)) { error in
            XCTAssertEqual(error.localizedDescription, "That shortcut is already assigned to Copy.")
        }
        XCTAssertEqual(store.binding(for: .openKeys), AsterShortcutAction.openKeys.defaultBinding)
    }

    func testMacReferenceHasStableUniqueEntries() {
        let shortcuts = ShortcutStore.macShortcuts
        XCTAssertGreaterThan(shortcuts.count, 70)
        XCTAssertEqual(Set(shortcuts.map(\.id)).count, shortcuts.count)
        XCTAssertTrue(shortcuts.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.category.isEmpty })
    }

    func testDisabledShortcutsPersistAndRestoreIndividually() throws {
        let suiteName = "AsterTests.DisabledShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let spotlight = try XCTUnwrap(ShortcutStore.macShortcuts.first(where: { $0.id == "spotlight" }))
        let store = ShortcutStore(defaults: defaults)

        store.setDisabled(true, for: spotlight)
        store.setDisabled(true, for: .openKeys)

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertTrue(reloaded.isDisabled(spotlight))
        XCTAssertTrue(reloaded.isDisabled(.openKeys))

        reloaded.restore(spotlight)
        reloaded.restore(.openKeys)
        XCTAssertFalse(reloaded.isDisabled(spotlight))
        XCTAssertFalse(reloaded.isDisabled(.openKeys))
    }

    func testAppHotkeysPersistDisableRestoreAndRemove() throws {
        let suiteName = "AsterTests.AppHotkeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ShortcutStore(defaults: defaults)
        let id = try store.addApplication(
            name: "Test Notes",
            bundleIdentifier: "app.aster.tests.notes",
            applicationPath: "/Applications/Test Notes.app"
        )
        let original = ShortcutBinding("k", keyCode: 40, modifiers: [.control, .option])
        let custom = ShortcutBinding("j", keyCode: 38, modifiers: [.control, .option])

        try store.updateAppHotkey(id, to: original)
        try store.updateAppHotkey(id, to: custom)
        store.setAppHotkeyDisabled(true, id: id)

        let reloaded = ShortcutStore(defaults: defaults)
        let persisted = try XCTUnwrap(reloaded.appHotkeys.first(where: { $0.id == id }))
        XCTAssertEqual(persisted.binding, custom)
        XCTAssertEqual(persisted.defaultBinding, original)
        XCTAssertTrue(persisted.isDisabled)

        reloaded.restoreAppHotkey(id)
        let restored = try XCTUnwrap(reloaded.appHotkeys.first(where: { $0.id == id }))
        XCTAssertEqual(restored.binding, original)
        XCTAssertFalse(restored.isDisabled)

        reloaded.removeAppHotkey(id)
        XCTAssertTrue(ShortcutStore(defaults: defaults).appHotkeys.isEmpty)
    }

    func testAppHotkeysRejectDuplicateAppsAndShortcutConflicts() throws {
        let suiteName = "AsterTests.AppHotkeyConflicts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ShortcutStore(defaults: defaults)
        let id = try store.addApplication(
            name: "Test Browser",
            bundleIdentifier: "app.aster.tests.browser",
            applicationPath: "/Applications/Test Browser.app"
        )

        XCTAssertThrowsError(try store.addApplication(
            name: "Same Browser",
            bundleIdentifier: "app.aster.tests.browser",
            applicationPath: "/Applications/Renamed Browser.app"
        ))
        XCTAssertThrowsError(try store.updateAppHotkey(
            id,
            to: AsterShortcutAction.openKeys.defaultBinding
        ))
        XCTAssertThrowsError(try store.updateAppHotkey(
            id,
            to: ShortcutBinding("k", keyCode: 40, modifiers: .shift)
        ))
    }
}

# Aster

**Your Mac, your way.**

Aster is a free, private, modular utility layer for macOS. It has no account, analytics, telemetry, advertising, or forced cloud connection. Modules remain independent so people can enable only the tools they want.

## Modules

- **Canvas** — Import, preview, organize, and independently assign still, GIF, or looping video media to the Desktop, Lock Screen, and Screen Saver. Includes a full-bleed editor, filtering, sorting, drag-and-drop import, persistent destination badges, and motion auto-resume.
- **Clips** — Opt-in local clipboard history for text, links, colors, and images. Press `Command-Shift-V` anywhere to open the floating board; includes search, persistent boards, drag-and-drop, source-app labels, and password-manager exclusions.
- **Shelf** — A hover-activated notch panel with configurable media controls, Drop Zone, Reminders, Shortcuts, timers, alarms, battery, system health, Weather, Calendar, and recent clips.
- **Bar** — Group real third-party utility icons behind Aster, then reveal or hide the group with one click. Uses native macOS status items and keeps the arrangement across launches.
- **Switch** — Put common local Mac controls—sleep, Finder, Dock, appearance, audio, and screenshots—in one place.

Canvas, Clips, Shelf, Bar, and Switch are functional. Aster starts only the modules selected during onboarding; each background-capable module can be disabled later.

## Bar

Enable Bar, then hold `Command` while dragging the thin divider to the right edge of the utility icons you want hidden. Place Aster immediately to the divider's right. Everything left of the divider collapses; icons to its right stay visible. Click Aster to collapse or reveal the group. macOS stores the dragged status-item positions, while Aster stores its own Bar settings. Use **Reset Aster control positions** if the two controls become separated. The Icon Spacing slider adjusts the system-wide gap between status items; system controls refresh when applied, while third-party menu apps may need to be reopened.

## Run

Requires an Apple-silicon Mac with macOS 14 or later. Building from source requires Xcode 16 or later.

```bash
swift run Aster
```

For a distributable `.app`, use `ReleaseTools/build-release.sh`. Production mode refuses to continue without a real signed-feed URL, update public key, Developer ID identity, and notarization profile. It embeds the screen-saver runtime, signs the app and DMG, notarizes and staples the DMG, and verifies the result. See `ReleaseTools/README.md` for publishing steps. Launch-at-login registration requires a signed application bundle and may not register when launched with `swift run`.

## Updates and What’s New

Aster checks its configured HTTPS release feed at launch and at most once every six hours. Release metadata must carry a valid Ed25519 signature from Aster’s embedded update key. Aster checks semantic version, build number, minimum macOS version, HTTPS transport, and the signed SHA-256 checksum before opening a download. After an upgraded version launches, Aster shows its bundled What’s New notes once.

The signed feed and notarized installers are hosted by the public [Sl0oth/Aster](https://github.com/Sl0oth/Aster) repository, so Aster does not depend on a separately operated update server.

## Privacy behavior

- Clipboard monitoring is off until explicitly enabled.
- Clipboard history, boards, and locally stored image previews stay in `~/Library/Application Support/Aster`.
- Common password managers and Keychain are excluded from clipboard capture.
- Drop Zone file references last only for the current Aster session.
- Shortcuts and system health stay local. Reminders and media controls use explicit macOS app automation.
- Bar does not inspect, record, or imitate other apps. It organizes their native menu-bar icons without Accessibility permission.
- Weather is off-network until a city is entered; while enabled, only that city name is sent to Open-Meteo for geocoding and forecasts.
- Every watcher and permission belongs to a visible module and can be disabled.

## Motion wallpapers

macOS has no public API for arbitrary video wallpapers. Aster displays looping videos in click-through windows above the system wallpaper and below Finder’s desktop icons. Aster must remain open while a motion wallpaper is active.

## Screen Saver and Lock Screen

Canvas can install its native `Aster.saver` module in `~/Library/Screen Savers`. Desktop, Lock Screen, and Screen Saver assignments are stored separately. Desktop and Screen Saver accept still or motion media. macOS only allows a still image on the secure Lock Screen, so Aster disables video and GIF selections for that destination and stores the chosen still in the system desktop layer.

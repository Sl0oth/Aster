# Opening Aster for the first time

Aster's community releases are not signed or notarized by Apple because the project does not currently have an Apple Developer Program account. Only download Aster from the official **Sl0oth/Aster GitHub Releases** page.

## Install and open

1. Open the downloaded `Aster-*.dmg`.
2. Drag **Aster** into the **Applications** folder shown in the disk image.
3. Open `/Applications/Aster.app` once. macOS will warn that it cannot verify the developer.
4. Open **System Settings → Privacy & Security** and scroll to **Security**.
5. Find the message saying Aster was blocked, click **Open Anyway**, authenticate, and confirm **Open**.

The Open Anyway button is normally available for about an hour after the blocked launch. Once approved, Aster opens normally from Applications.

Apple documents this override at [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac).

## Optional permissions

Aster asks only when a feature needs access:

- **Accessibility** lets Keys apply changed or disabled macOS shortcuts immediately.
- **Automation** lets explicitly enabled integrations control apps such as Music, Spotify, Reminders, Finder, or System Events.
- **Launch at Login** works after Aster has been copied into Applications.

Because community builds use an ad-hoc signature, macOS may ask you to approve Aster or its optional permissions again after an update.

## Security note

Apple has not reviewed or scanned this build. Do not bypass macOS security for a copy obtained from another website, a direct message, or an unknown mirror. The official GitHub release publishes the DMG's SHA-256 checksum alongside the download.

# Aster release updates

Aster is currently distributed as an ad-hoc-signed community build because the project does not have an Apple Developer Program account. GitHub hosts each DMG and the Ed25519-signed update feed at `releases/stable.json`. The update private key must never be committed.

Community signing is not Apple notarization. New users must approve Aster once in **System Settings → Privacy & Security**, following [`FIRST-LAUNCH.md`](../FIRST-LAUNCH.md). macOS may ask for optional permissions again after an update.

## One-time update-signing setup

Generate the independent update keypair:

```bash
ReleaseTools/generate-update-key.swift
```

Store the private value as the GitHub Actions secret `ASTER_UPDATE_PRIVATE_KEY`. Store the public value as the repository variable `ASTER_UPDATE_PUBLIC_KEY` and in `Sources/LumaWall/Resources/ReleaseConfiguration.json`.

The private key is also backed up locally in the macOS Keychain item **Aster Update Signing Key**. Retrieve it only when intentionally rotating or restoring release infrastructure:

```bash
security find-generic-password -a "$USER" -s "Aster Update Signing Key" -w
```

Never paste the private value into an issue, commit, release note, log, or chat.

## Publish through GitHub Actions

The manual **Publish Aster Release** workflow runs tests, creates the ad-hoc-signed community app and DMG, publishes the GitHub Release, signs the update feed, and pushes the feed to `main`.

Before starting it:

1. Commit and push every source file required by the release.
2. Update `Sources/LumaWall/Resources/ReleaseNotes.json`.
3. Confirm the version in the notes matches the workflow version.
4. Confirm the new build number is greater than the previous release.
5. Run **Actions → Publish Aster Release → Run workflow**.

The workflow requires only the update-signing secret and public-key variable. It intentionally does not request Apple certificate or notarization credentials.

## Build a community release locally

```bash
ASTER_RELEASE_MODE=community \
ASTER_VERSION=1.0.0-beta.1 \
ASTER_BUILD=1 \
ASTER_UPDATE_FEED_URL=https://raw.githubusercontent.com/Sl0oth/Aster/main/releases/stable.json \
ASTER_UPDATE_PUBLIC_KEY="$ASTER_UPDATE_PUBLIC_KEY" \
ReleaseTools/build-release.sh
```

The script builds the optimized app, embeds the screen-saver runtime, generates the transparent icon, applies ad-hoc signatures, verifies the bundle, creates and verifies the DMG, includes the first-launch guide, and prints the SHA-256 checksum.

`ASTER_RELEASE_MODE=test` uses the same packaging checks but marks the artifact as test-only. Neither community nor test mode submits anything to Apple.

## Optional future Developer ID release

If the project later joins the Apple Developer Program, production mode remains available. It fails closed unless a Developer ID Application identity and `notarytool` keychain profile are provided:

```bash
ASTER_RELEASE_MODE=production \
ASTER_VERSION=1.0.0 \
ASTER_BUILD=1 \
ASTER_UPDATE_FEED_URL=https://raw.githubusercontent.com/Sl0oth/Aster/main/releases/stable.json \
ASTER_UPDATE_PUBLIC_KEY="$ASTER_UPDATE_PUBLIC_KEY" \
ASTER_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
ASTER_NOTARY_PROFILE=Aster-Notary \
ReleaseTools/build-release.sh
```

Production mode enables hardened runtime, signs the nested module and app with Developer ID, signs the DMG, submits it to Apple, staples the ticket, and validates Gatekeeper acceptance.

## Update order

The GitHub workflow performs the safe publication order:

1. Build the DMG and calculate its SHA-256 checksum.
2. Create the signed update-feed payload.
3. Upload the DMG and publish its checksum and first-launch warning.
4. Publish `releases/stable.json` last.

Aster verifies the feed signature before trusting its download URL, checksum, minimum macOS version, or feature notes. Keep previous DMGs available so users can retry interrupted updates.

## Public repository checklist

- Keep `LICENSE`, `FIRST-LAUNCH.md`, release notes, and privacy behavior current.
- Never commit update private keys, credentials, `dist/`, `.build/`, `output/`, or `.wip/`.
- Never describe a community artifact as Apple-signed, notarized, reviewed, or malware-scanned.
- Publish community artifacts only from the official `Sl0oth/Aster` repository.
- Aster currently supports Apple-silicon Macs with macOS 14 or later.

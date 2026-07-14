# Aster release updates

Aster accepts only Ed25519-signed release feeds delivered over HTTPS. GitHub hosts the feed at `releases/stable.json` and each DMG as a GitHub Release asset. The feed URL and public key are embedded in the signed application; the private key must never be committed.

## One-time setup

Generate an update keypair and store the private value in a password manager or CI secret store:

```bash
ReleaseTools/generate-update-key.swift
```

Store the printed `ASTER_UPDATE_PRIVATE_KEY` as a release secret. The public value is safe to place in build configuration. Configure a Developer ID Application certificate and a `notarytool` keychain profile:

```bash
xcrun notarytool store-credentials Aster-Notary
```

This repository is already configured with the public key and GitHub feed URL. The private key is stored as the GitHub Actions secret `ASTER_UPDATE_PRIVATE_KEY` and in the local macOS Keychain item **Aster Update Signing Key**. GitHub never reveals a saved secret again. To retrieve the local backup intentionally:

```bash
security find-generic-password -a "$USER" -s "Aster Update Signing Key" -w
```

Do not paste that private value into an issue, commit, release note, or chat.

## GitHub Actions release setup

The manual **Publish Aster Release** workflow builds on an ARM64 macOS runner and handles testing, signing, notarization, GitHub Release creation, feed signing, and publishing. Before its first run, add these repository secrets:

- `ASTER_DEVELOPER_ID_P12` — base64-encoded Developer ID Application `.p12`
- `ASTER_DEVELOPER_ID_PASSWORD` — password used when exporting the `.p12`
- `ASTER_NOTARY_KEY` — contents of the App Store Connect `AuthKey_….p8` file
- `ASTER_NOTARY_KEY_ID` — App Store Connect API key ID
- `ASTER_NOTARY_ISSUER_ID` — App Store Connect issuer ID

The update secret and public variable are already configured. Start a release from **Actions → Publish Aster Release → Run workflow**, entering a version matching `ReleaseNotes.json` and a new numeric build.

## Build a production release

Production mode is the default and fails closed if signing or notarization configuration is missing:

```bash
ASTER_VERSION=1.0.0-beta.1 \
ASTER_BUILD=1 \
ASTER_UPDATE_FEED_URL=https://raw.githubusercontent.com/Sl0oth/Aster/main/releases/stable.json \
ASTER_UPDATE_PUBLIC_KEY="$ASTER_UPDATE_PUBLIC_KEY" \
ASTER_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
ASTER_NOTARY_PROFILE=Aster-Notary \
ReleaseTools/build-release.sh
```

The script embeds `libAsterScreenSaver.dylib`, adds the Apple Events usage description and hardened-runtime entitlement, signs the nested module before the app, verifies the bundle, signs the DMG, submits it to Apple, staples it, validates Gatekeeper acceptance, and prints the final SHA-256 checksum.

For local packaging QA only, use `ASTER_RELEASE_MODE=test`. Test artifacts are ad-hoc signed, visibly labeled by the script, and must not be published.

## Publish an update

1. Update `Sources/LumaWall/Resources/ReleaseNotes.json` and copy `update-feed.example.json` to a working release JSON file.
2. Build the production DMG and place its final SHA-256 value and real download URL in that JSON.
3. Sign the feed payload:

   ```bash
   ASTER_UPDATE_PRIVATE_KEY="$ASTER_UPDATE_PRIVATE_KEY" \
   ReleaseTools/sign-update-feed.swift release.json stable.json
   ```

4. Upload the notarized DMG first, then publish `stable.json` last.
5. Keep previous DMGs available so users can retry interrupted upgrades.

The private key signs the exact release JSON bytes. Aster verifies that signature before trusting the download URL, checksum, compatibility requirement, or feature notes.

## Public repository checklist

- Start the public repository from the current source snapshot, without the old local `.git` directory, so removed experimental modules are not present in history.
- Add the chosen `LICENSE` in the initial GitHub commit.
- Never commit update private keys, notarization credentials, `dist/`, `.build/`, or `output/`.
- Aster currently supports Apple-silicon Macs on macOS 14 or later.

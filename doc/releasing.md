# Releasing ShuTaPla

Builds a signed, notarized, stapled Apple-Silicon `.dmg` that launches on any arm64 Mac
(macOS 26+) with no Gatekeeper warnings, and publishes it as a GitHub Release asset.

The whole pipeline is `Scripts/release.sh`. It archives the Release configuration, exports it
with the Developer ID identity via `Scripts/ExportOptions.plist`, notarizes and staples the
app and the dmg, and (with `--publish`) uploads the dmg with `gh`.

## One-time setup

- **Signing certificate** — `Developer ID Application: Tigran Airapetian (JU443A4L25)` in the
  login keychain (`security find-identity -v -p codesigning` to confirm).
- **Homebrew mpv** — `brew install mpv`. `Scripts/bundle-mpv.sh` (a build phase) embeds libmpv
  and its dylib closure into the app and rewrites their paths to `@rpath`.
- **Notary credentials** — an App Store Connect API key (token-based auth, no app-specific
  password). In App Store Connect → **Users and Access → Integrations → App Store Connect API**,
  generate a Team key with **Developer** access; note its **Key ID** and the team's **Issuer ID**,
  and download the `.p8` file — it is downloadable only once. Store all three once as the keychain
  profile the script expects:

  ```
  xcrun notarytool store-credentials "ShuTaPla-notary" --key <path-to-AuthKey_XXXXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
  ```

  After this, the `.p8` is copied into the keychain; the raw key file is no longer needed by the
  script (keep it somewhere safe as a backup, out of the repo).

## Release

```
Scripts/release.sh            # archive → sign → notarize → staple → dmg → gate
Scripts/release.sh --publish  # …and upload the dmg as GitHub Release v<version>
```

The version is taken from `MARKETING_VERSION`. To bump it, edit the two lines in
`Config.xcconfig` at the repo root — the single source of `MARKETING_VERSION`
(`CFBundleShortVersionString`) and `CURRENT_PROJECT_VERSION` (`CFBundleVersion`, the build
number) for every target and configuration. Output lands in `build/Shutapla-<version>.dmg`
(gitignored).

The user-facing product is named **Shutapla** (`PRODUCT_NAME`), so the built bundle is
`Shutapla.app`. The Xcode target, scheme, Swift module, and bundle identifier stay `ShuTaPla`
(the internal codename); `PRODUCT_MODULE_NAME` is pinned to `ShuTaPla` so `import ShuTaPla`
keeps working despite the product rename.

`Scripts/release.sh --skip-notarize` builds and signs the dmg locally without contacting Apple —
useful for verifying the build before credentials are set up, or for a quick signed artifact.

## What "runs on other Macs" depends on

- **Bundled libmpv closure** — without `bundle-mpv.sh` the app would look for `/opt/homebrew/...`,
  which doesn't exist on other Macs. Verify with
  `otool -L build/export/Shutapla.app/Contents/MacOS/Shutapla` (no `/opt/homebrew` paths); the
  script fails the build if any leak in.
- **Developer ID signature + secure timestamp + hardened runtime** on the app and every nested
  dylib (`codesign -dvvv <path>` shows `Authority=Developer ID Application…`, `Timestamp=…`,
  `flags=0x10000(runtime)`). Notarization rejects the bundle otherwise.
- **Stapling** — embeds the notarization ticket so Gatekeeper accepts the app offline.

## Verifying a release

```
codesign --verify --deep --strict --verbose=2 build/export/Shutapla.app
spctl -a -vvv build/export/Shutapla.app        # → accepted, source=Notarized Developer ID
stapler validate build/Shutapla-<version>.dmg
```

The conclusive test is on a **second Mac or a fresh user account**: download the dmg (so it
carries the quarantine bit), drag the app to Applications, launch it, and confirm no
"unidentified developer"/"cannot verify" prompt and that video playback works.

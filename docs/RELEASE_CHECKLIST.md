# Release Checklist

This checklist tracks the first macOS DMG packaging flow for Mwoham 0.1.0.

## Scope

- Build `MwohamMac.app` in Release configuration.
- Bundle Local Whisper STT runtime resources into the app.
- Package `MwohamMac.app`, an `Applications` symlink, and install instructions in a DMG.
- Do not change app features, backend APIs, DB schema, recording policy, Dev Tracking policy, AI Provider Keychain policy, Timeline/Report semantics, Launch at Login policy, or menu bar/floating widget UX.
- Do not include real API keys, `.env`, or local model/runtime binaries in git.

## Packaging Command

```bash
./scripts/package_macos_dmg.sh --version 0.1.0 --internal-qa
```

Use `--internal-qa` only for internal QA when Apple Development signing is not available.
For a signed internal build, install an Apple Development certificate for Team ID
`XMP48Q3KXN` and run without `--internal-qa`.

## STT Runtime Policy

The release app includes:

```text
MwohamMac.app/Contents/Resources/STT/whisper-cli
MwohamMac.app/Contents/Resources/STT/models/ggml-large-v3-turbo.bin
MwohamMac.app/Contents/Resources/STT/lib/*.dylib
```

The current Homebrew `whisper-cli` is not standalone. It references Homebrew
`libwhisper`, `ggml`, and `libomp` dylib files, so packaging bundles those dylibs
and rewrites install names with `install_name_tool`.

## Automatic Verification

```bash
APP="/Applications/MwohamMac.app"
./scripts/check_release_stt_resources.sh "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|Runtime|Signature"
codesign --verify --deep --strict --verbose=2 "$APP"
hdiutil verify dist/Mwoham-0.1.0.dmg
```

Also run the focused app/backend regression checks listed in `docs/QA_CHECKLIST.md`.

## Manual Install QA

1. Mount `dist/Mwoham-0.1.0.dmg`.
2. Drag `MwohamMac.app` to `Applications`.
3. Launch the copied app from Applications, not from inside the DMG.
4. Confirm `/health`.
5. Confirm Local Whisper bundled runtime and bundled model in Settings.
6. Confirm meeting transcription can start and save transcript text.
7. Confirm Timeline and Report screens.
8. Confirm fallback report when no AI Provider key is configured.
9. Confirm AI report when a valid Gemini/OpenAI key is configured.
10. Confirm menu bar, floating widget, and Launch at Login behavior remain unchanged.
11. If right-click > Open is blocked, allow the app with System Settings > Privacy & Security > Open Anyway and launch again.
12. Confirm STT/backend resources resolve from the running bundle or Application Support even when the displayed app path is not `/Applications`.

## Public Release Follow-ups

- Developer ID Application signing.
- Notarization and stapling.
- `spctl --assess` acceptance criteria.
- Auto-update channel.
- Model download/replacement UI.
- Public release guide.

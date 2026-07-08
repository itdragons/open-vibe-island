# Signal Light — Online Firmware Update Check — Design Spec

Status: Approved for planning
Date: 2026-07-07

## Summary

Add the ability for the Signal Light settings pane to check whether a newer firmware version is available, and — if so — download it and flash it in one click, reusing the existing BLE OTA flow (`SignalLightFirmwareUpdater`, `SignalLightCoordinator.beginFirmwareUpdate(fileURL:)`).

This builds on [2026-07-04 signal-light-firmware-ota-design](2026-07-04-signal-light-firmware-ota-design.md), which shipped manual local-file OTA flashing but explicitly deferred "remote firmware distribution" and "automatic update checks" as non-goals. This spec closes that gap for the update-check and one-click-download part; manual local-file flashing (for unreleased dev builds) is unaffected and remains available.

## Goals

1. Settings → Signal Light → Firmware: a "Check for Updates" button that reports whether a newer firmware version than the currently connected device's is available.
2. If a newer version exists, one click downloads the `.bin` and feeds it directly into the existing OTA flash flow — progress bar, cancel, success/failure states all reused unchanged.
3. The existing "pick a local `.bin` file" flow stays available as-is, for local/dev builds not yet published.

## Non-goals

- Automatic or background checking. User-initiated only, via the "Check for Updates" button — no periodic polling, no check-on-connect.
- Compiling firmware in CI. The developer still builds the `.bin` locally (Arduino IDE "Export Compiled Binary") and manually publishes it by committing to the distribution path described below — same manual-build practice as the existing OTA flow, just a different manual publish step.
- GitHub Releases API / tag-based versioning. Firmware version info and the binary are served as two fixed-path files on a branch, not release assets (see Architecture — this was an explicit choice over versioned-directory/Releases-API alternatives, to keep the client-side logic to two plain HTTP GETs with no listing/filtering).
- Resuming an interrupted download. Firmware images are small (a few hundred KB); a failed download is retried from scratch.
- Rollback / access to historical firmware versions via a stable URL. Only the latest version is addressable by the fixed path; older versions remain in git history but aren't served to the app.
- Content/signature verification of the downloaded binary beyond what HTTPS transport already provides. Matches the existing OTA design's practice of trusting the distribution source and validating only at the OTA-protocol boundary (byte-count check in firmware).

## Architecture

### Firmware distribution (`wg` branch of `itdragons/open-vibe-island`)

Two fixed paths, overwritten on every new firmware publish (no per-version directories, no GitHub Releases):

```
signal-light/firmware/version.json    — { "version": "1.1.0", "notes": "optional changelog text" }
signal-light/firmware/signal-light.bin — latest compiled firmware binary
```

Publishing a new firmware version is: bump `FIRMWARE_VERSION` in `signal-light/led_esp32c3/config.h`, compile, export the `.bin`, overwrite both files above, commit and push to `wg`. No app-side changes needed per release — the app always requests the same two URLs, served through jsDelivr's GitHub CDN mirror rather than `raw.githubusercontent.com` directly:

```
https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/firmware/version.json
https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/firmware/signal-light.bin
```

`itdragons/open-vibe-island` is a public fork, so both URLs are reachable anonymously — no auth token needed.

**Why jsDelivr instead of raw.githubusercontent.com directly:** debugging a reported "download times out" issue found that direct connections to `raw.githubusercontent.com` reliably stall mid-transfer on some networks (reproduced with `curl --noproxy '*'`, consistently stuck partway into the 647KB binary) — a network-level block on that specific host, not an app bug. jsDelivr's edge for the same repo/branch/path was reliable across repeated tests and requires no code-side workaround.

**Publishing caveat:** jsDelivr caches `@branch` references for a while (not instant like `raw.githubusercontent.com`'s ~5-minute Fastly cache). After publishing a new firmware version, force an immediate cache refresh by hitting jsDelivr's purge endpoint for both files:

```
https://purge.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/firmware/version.json
https://purge.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/firmware/signal-light.bin
```

Otherwise the app may keep seeing the previous version for some time after a new one is pushed.

### `OpenIslandCore`

**New file `SignalLightFirmwareVersion.swift`**:
- A small `Comparable` value type parsing `"major.minor.patch"` strings (matching the existing `FIRMWARE_VERSION` format in `config.h`).
- Pure logic, unit-testable — follows the project's existing convention of keeping pure logic in `OpenIslandCore` with tests, versus `OpenIslandApp` code that touches CoreBluetooth/URLSession and is verified manually.
- Invalid strings fail to parse (`init?`) rather than crashing; callers treat a parse failure as "can't determine, don't claim an update is available."

### `OpenIslandApp`

**New file `SignalLightFirmwareUpdateChecker.swift`** (`@MainActor @Observable`, mirrors the existing shape of `UpdateChecker.swift`):
- State: `.idle | .checking | .upToDate | .updateAvailable(version: String, notes: String?) | .failed(String)`.
- `checkForUpdates(currentVersion: String) async`:
  1. `GET version.json` via `URLSession`.
  2. Decode `{version, notes?}`; parse `version` with `SignalLightFirmwareVersion`.
  3. Parse `currentVersion` the same way; compare.
  4. Set `.upToDate` or `.updateAvailable`, or `.failed(reason)` on any network/decode/parse error.
- `downloadLatestBinary() async throws -> URL`:
  - `GET signal-light.bin`, write to a fresh file in `FileManager.default.temporaryDirectory`, return its `URL`.
  - Throws on network failure; caller (the view) surfaces the error and leaves the existing manual-file flow untouched — no OTA flash is attempted until a local file URL is successfully in hand.
- Owned by `SignalLightCoordinator` as a new `let updateChecker = SignalLightFirmwareUpdateChecker()` property, parallel to the existing `let firmwareUpdater = SignalLightFirmwareUpdater()`. The view binds to `model.signalLight.updateChecker` directly, same pattern as `model.signalLight.firmwareUpdater`.

Splitting "check + download" (`SignalLightFirmwareUpdateChecker`) from "flash" (`SignalLightFirmwareUpdater`) means the existing BLE OTA state machine and UI are untouched — the only new behavior is *how a file URL is obtained* before calling the existing `beginFirmwareUpdate(fileURL:)`.

### Views

**`SignalLightSettingsPane.swift`** (existing Firmware section, additive):
- "Check for Updates" button next to the firmware version row — enabled only when connected and `coordinator.firmwareVersion` is known, and the checker is not already `.checking`.
- Renders by checker state:
  - `.checking`: spinner + "Checking for updates…"
  - `.upToDate`: "You're on the latest version"
  - `.updateAvailable(version, notes)`: "Version \(version) is available" + optional notes text + "Download & Update" button
  - `.failed(reason)`: "Couldn't check for updates: \(reason)", with the button re-enabled for retry
- "Download & Update" button: calls `updateChecker.downloadLatestBinary()`; on success, calls the same `coordinator.beginFirmwareUpdate(fileURL:)` used by the manual-file path, which shows the existing confirmation alert and progress UI unchanged. On download failure, shows an inline error and leaves state at `.updateAvailable` so the user can retry without re-checking.
- Existing "Choose Firmware File…" manual picker stays as a secondary control below, for local dev builds.

## Data flow

1. User taps "Check for Updates" → `updateChecker.checkForUpdates(currentVersion: coordinator.firmwareVersion)`.
2. `GET version.json` → decode → parse both versions → compare → `.upToDate` or `.updateAvailable`.
3. User taps "Download & Update" → `updateChecker.downloadLatestBinary()` → temp file URL.
4. `coordinator.beginFirmwareUpdate(fileURL:)` → existing OTA flow (`OTA_BEGIN` → chunked writes → `OTA_END`), progress/cancel/success/failure UI all unchanged.
5. Success → firmware restarts, reconnects, version re-read — matches existing behavior exactly.

## Error handling

| Scenario | Behavior |
|---|---|
| `version.json` unreachable / request times out | `.failed("Couldn't connect to update server")`; manual-file flow unaffected (fail-open) |
| `version.json` malformed / missing `version` field | `.failed("Update information is malformed")` |
| `version` or `currentVersion` isn't a valid `x.y.z` string | Same as above — no comparison attempted, no update falsely claimed |
| `signal-light.bin` download fails/times out | Stays at `.updateAvailable`, shows inline download error, retry available; no OTA flash attempted |
| Flash fails after a successful download | Unchanged — handled entirely by the existing `SignalLightFirmwareUpdater` error paths |

## Testing plan

- `OpenIslandCore`: unit tests for `SignalLightFirmwareVersion` — equal versions, patch/minor/major differences, invalid strings (non-numeric, wrong segment count, empty).
- `OpenIslandApp` (manual, following the existing convention that CoreBluetooth/network-touching code has no automated tests):
  1. Publish a `version.json` + `signal-light.bin` on `wg` with a version higher than the connected device's; tap "Check for Updates"; confirm the new version and notes display correctly.
  2. Tap "Download & Update"; confirm the full OTA flow runs end-to-end and the version display updates after reconnect.
  3. Disable networking and tap "Check for Updates"; confirm a friendly error, no crash, and that manual file selection still works.
  4. With the device already on the latest version, tap "Check for Updates"; confirm "You're on the latest version".
  5. Publish a malformed `version.json` (missing `version` field); confirm a friendly error.
  6. Simulate a download failure (e.g. disconnect mid-download); confirm retry works without needing a fresh "Check for Updates".

## Packaging note

No new entitlements needed — `com.apple.security.network.client` is already present in `config/packaging/OpenIslandApp.entitlements` (used by the existing Sparkle-based app updater), and covers this feature's plain HTTPS `GET` requests too.

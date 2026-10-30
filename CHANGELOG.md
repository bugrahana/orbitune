# Changelog

This branch adds a native Android APK wrapper (via Capacitor) around the
existing PWA, with real background-audio playback, lock-screen/notification
media controls, and a full CI/CD pipeline (automated tests + signed-release
builds). The web app itself (`index.html`, `styles.css`, `facts.js`,
`pets.js`) is unchanged; only `app.js` gained native-specific code paths and
bug fixes, all guarded behind `isNative`/`NativeAudio` checks so the
plain-web/PWA behavior is untouched.

## Added

### Android app wrapper
- `capacitor.config.json`, `package.json` / `package-lock.json`: Capacitor
  project config and dependencies (`@capacitor/core`, `@capacitor/android`,
  `@capgo/capacitor-native-audio`, `@capgo/capacitor-media-session`).
- `patches/`: two [patch-package](https://github.com/ds300/patch-package)
  patches fixing real bugs found in `@capgo/capacitor-media-session`'s
  Android source (see "Fixed" below) — applied automatically via a
  `postinstall` script on every `npm install`.

### CI/CD (`.github/workflows/`)
- **`android-apk.yml`** — builds and publishes a release APK to GitHub
  Releases. Triggered by pushing a `v*` tag (real release) or manually
  (`workflow_dispatch`, produces a `dev-N` pre-release build). See "Using the
  pipeline" below for the full walkthrough.
- **`debug-logcat.yml`** — "Real App Crash & Lifecycle Test": installs the
  actual app on an emulator and asserts the Activity/process survives a
  back-press at the root screen *and* with an in-app panel open (e.g.
  settings), that `app.js` isn't silently reloaded (which would orphan the
  native audio player), and that both a resumed and a fresh/force-stopped
  launch are crash-free. Runs on every push touching the app's JS/HTML/CI
  files, or manually.
- **`native-audio-smoketest.yml`** — two jobs:
  - `pure-logic-unit-tests`: the 7 Node test files in `ci/unit/` (no
    emulator, seconds to run).
  - `smoke-test`: builds a minimal harness app, boots an emulator, and
    asserts background playback + lock-screen/notification controls
    actually work, including a **ground-truth concurrency check**: it
    rapid-mashes station switching for ~1s while sampling
    `dumpsys audio`'s live `AudioPlaybackConfiguration` list, and fails the
    build if more than one is ever genuinely `state:started` for the app's
    uid at once (this is what caught and proved the fix for the
    "two stations play at once" bug — see "Fixed" below).

### Tests (`ci/unit/`, `ci/debug/`, `ci/smoke/`)
Pure-Node tests (no emulator) for the native-specific logic added to
`app.js`, each written test-first against a failing repro before the fix
landed:
- `playback-mutex.test.js` — the native-audio switch/overlap mutex, against
  fakes modeling two real confirmed plugin bugs (early-resolving `unload()`,
  and `preload()` rejecting on a stale registry entry).
- `resume-reconcile.test.js` — UI state resyncing to real native playback
  state on `visibilitychange`, including a race-condition scenario.
- `boot-reconcile.test.js` — same resync, but on a fresh `boot()` (a
  separate code path from resume).
- `dom-boot.test.js` — boots the real `index.html` + `app.js` + `facts.js` +
  `pets.js` in jsdom for both the plain-web and native-mocked code paths,
  asserting zero uncaught exceptions (sub-second regression guard for the
  "every button silently stopped working" crash class of bug).
- `pure-logic.test.js`, `display-and-state.test.js`, `data-integrity.test.js`
  — broader coverage added proactively (fade volume curves, country
  fallback logic, skip/autoskip behavior, queue-type-dependent neighbour
  selection, etc.), not tied to one specific incident.
- `ci/debug/check.sh` + `push-history.js` — emulator-based lifecycle
  assertions (see `debug-logcat.yml` above); `push-history.js` drives the
  app's WebView via the Chrome DevTools Protocol (on by default in debug
  builds) to simulate "a panel is open" without needing real UI taps.
- `ci/smoke/` — the minimal harness app + its own `app.js` used by the
  smoke-test job, including the rapid-switch stress sequence used for the
  ground-truth overlap measurement.

## Changed (`app.js`)

All native-only; the plain-web/PWA code paths are unchanged.

- Native audio playback now goes through `@capgo/capacitor-native-audio`
  (ExoPlayer-backed, survives backgrounding) instead of a WebView `<audio>`
  element, which Android can suspend in the background at any time.
- Native lock-screen/notification media controls (play/pause/next/previous)
  via `@capgo/capacitor-media-session`, mirroring the existing Web
  MediaSession API code path.
- Every native-audio-mutating call (`stop`/`unload`/`preload`/`play`) is
  serialized through a `queueNative` mutex with a `playGen` generation
  counter, so rapid station switching can never leave two overlapping
  streams or race a stale async result into stomping a newer action.
- `boot()` and the `visibilitychange` handler both reconcile `player.status`
  against what the native layer actually reports (`isPlaying`), instead of
  assuming the UI's last-known state is still correct — needed because an
  OEM killing/recreating the Activity in the background (or any other
  Activity-recreation trigger) can leave the UI showing "not playing" over
  audio that's genuinely still live.
- Station artwork fallback: when Radio Browser's own `favicon` field is
  empty/broken, a favicon-by-domain lookup (derived from the station's
  `homepage` field) is tried as a second `<img>` source, with its generic
  "no icon found" placeholder detected (by image size) and rejected rather
  than shown.
- Permission footprint deliberately kept to parity with Spotify: only the
  standard `POST_NOTIFICATIONS` runtime prompt (needed for the lock-screen/
  notification UI to be allowed to show on Android 13+) — no automatic
  battery-optimization-exemption request, no OEM "autostart" screens.

## Fixed

Real, user-reported bugs found on a physical device (Xiaomi Redmi Note 8
Pro, Android 11, MIUI) and in the plugins' own Android source, each with a
failing test added before the fix:

1. **Every button silently non-functional on first launch.** Root cause:
   `MediaSession.setActionHandler()` doesn't return a Promise (it's a
   RETURN_CALLBACK-style plugin method) — calling `.catch()` on its result
   threw `TypeError`, which aborted the rest of `app.js`'s top-level script
   before any click handler below it got wired up. Fixed by wrapping in
   `try`/`catch` instead.
2. **Back button orphaned the native audio player.** Capacitor's default
   back-button behavior can finish() the Activity even when there's nothing
   to navigate back to in-app; `MainActivity.onBackPressed()` now calls
   `webView.goBack()` when there's in-app history (closing a panel/sheet)
   or `moveTaskToBack(true)` otherwise (mirrors the Home button) — never
   `super.onBackPressed()`, whose behavior on a `BridgeActivity` isn't
   guaranteed to just navigate WebView history.
3. **Two stations playing at once / pause silently stopped working.**
   `@capgo/capacitor-native-audio`'s `unload()` resolves its JS promise
   before the actual native teardown (`player.release()`, posted to the UI
   thread) has necessarily run — confirmed by reading the plugin's Android
   source. A rapid station switch could issue a new `preload()`+`play()`
   while the previous stream was still mid-teardown, leaving two ExoPlayer
   instances genuinely active. Fixed with a short defensive delay after
   `unload()` plus the `queueNative`/`playGen` mutex described above;
   empirically verified via the `dumpsys audio` ground-truth stress test in
   `native-audio-smoketest.yml` (max concurrent `state:started` entries for
   the app's uid: **1**, under a 12-switch rapid-mash sequence).
4. **UI showed "not playing" after a background restart while audio was
   still genuinely live** (and vice versa). Neither `boot()` nor the resume
   path asked the native layer what was actually happening; both now
   reconcile against `NativeAudio.isPlaying()`.
5. **Notification/lock-screen play and pause buttons did nothing when
   tapped** (next/previous/stop worked fine). Root cause, found by reading
   `@capgo/capacitor-media-session`'s actual Android source: its play/pause
   notification buttons build their `PendingIntent` via
   `MediaButtonReceiver.buildMediaButtonPendingIntent(context, action)`,
   passing a bitwise-OR of two different `PlaybackStateCompat.ACTION_*`
   constants (e.g. `ACTION_PLAY_PAUSE | ACTION_PAUSE`) — but that helper's
   internal `toKeyCode(long)` only matches a single exact constant, so the
   combined value matches nothing and silently resolves to
   `KEYCODE_UNKNOWN`. Fixed via a `patch-package` patch passing the single
   correct flag instead.
6. **Swiping the app away from recents didn't stop playback.**
   `@capgo/capacitor-native-audio` has no `Service` of its own at all —
   the only thing keeping the process (and therefore the native player)
   alive in the background is `@capgo/capacitor-media-session`'s
   `MediaSessionService`, a foreground service which, like any foreground
   service, survives task removal unless it explicitly handles it. Fixed
   via a second `patch-package` patch adding `Service.onTaskRemoved()`
   (stops the foreground service, then kills the process directly, since
   by the time this fires the Activity/WebView — and any way to reach the
   player through the JS bridge — is already gone).
7. **Connecting to a station sometimes failed instantly, then worked after
   a couple of manual retries** — especially noticeable returning to a
   station just switched away from. Root cause, found by reading
   `@capgo/capacitor-native-audio`'s actual source: `preloadAsset()`
   unconditionally rejects if its internal registry still has an entry for
   the assetId; `unload()` is supposed to clear that entry, but its own
   native call can throw before reaching the line that removes it (silently
   swallowed on the JS side), so the very next `preload()` for the same
   station rejects immediately — no 15s timeout, just an instant error. A
   single bounded retry (force another `unload()` + `preload()`) recovers
   automatically instead of needing a manual re-tap.

## Using the pipeline

Three workflows live in `.github/workflows/`. The two test workflows run
automatically; the release workflow is deliberately **not** automatic on
every push — tags and manual runs only, so every real GitHub Release is a
deliberate action.

### Running the tests
- **`native-audio-smoketest.yml`** and **`debug-logcat.yml`** both run
  automatically on every push to `main` or `feature/**` that touches
  `app.js`, `index.html`, `facts.js`, `pets.js`, or the workflow/`ci/*`
  files themselves — no action needed, just open a PR or push a commit.
- To run either on demand without a qualifying push: GitHub →
  **Actions** → pick the workflow → **Run workflow** (this is
  `workflow_dispatch`, available on all three workflows).
- Both are emulator-based (except `pure-logic-unit-tests`, which is pure
  Node and takes seconds) and can occasionally fail on CI-runner/emulator
  flakiness unrelated to the code (`adb: device offline`, GPU/texture
  errors, transient Maven/network blips) — re-running the job is the normal
  fix for those; a *consistent* failure across a retry is the one worth
  investigating.

### Cutting a release
1. **Dev/pre-release build** (for testing on a real device before tagging):
   GitHub → **Actions** → **Android APK Release** → **Run workflow** on
   `main`. This produces a pre-release tagged `dev-N` (an incrementing
   counter) with the APK attached — use this to validate a change on a
   real device before committing to a version number.
2. **Real version release**: once a build has been validated, tag that
   exact commit and push the tag:
   ```sh
   git tag -a vX.Y.Z -m "Orbitune vX.Y.Z

   <changelog for this version>"
   git push origin vX.Y.Z
   ```
   Pushing a tag matching `v*` triggers the same workflow, but this time it
   publishes a real (non-prerelease) GitHub Release titled "Orbitune
   vX.Y.Z" with `Orbitune-vX.Y.Z.apk` attached.
3. The workflow itself: installs dependencies (applying the `patch-package`
   patches), copies the web assets into a fresh Capacitor Android project,
   patches in the background-audio permissions and `MainActivity.java`,
   builds a debug APK (no signing keystore needed — this is a sideloadable
   debug build, not a Play Store release), **verifies** the merged
   manifest actually has the 4 required permissions/components and that
   the exact permission set hasn't silently grown (a plugin update adding
   an unexpected permission fails the build on purpose, forcing a
   deliberate review), renames the APK to match the version, and publishes
   it as a GitHub Release.

### If a plugin gets updated
`npm install` re-applies both patches in `patches/` automatically via the
`postinstall` script — nothing else to do, *unless* the new plugin version
changed the exact lines the patches touch, in which case `patch-package`
will fail loudly at install time (not silently skip) and the patch needs
regenerating against the new version (`npx patch-package <pkg> --append` or
edit `node_modules/` directly and re-run `npx patch-package <pkg>`).

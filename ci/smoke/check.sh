#!/usr/bin/env bash
# Runs inside the android-emulator-runner step. Kept as its own script
# (instead of a multi-line `script:` block) because that action invokes
# each line of an inline script as a separate `sh -c` process, so shell
# variables set on one line are gone by the next - APK=$(...) on one line
# and adb install -r "$APK" on the next silently installed nothing.
set -euo pipefail

cd "$GITHUB_WORKSPACE"

APK=$(find ci/smoke/android/app/build/outputs/apk/debug -name '*.apk' | head -n1)
echo "Installing $APK"
adb install -r "$APK"

# Runtime POST_NOTIFICATIONS can't be tapped through a dialog headlessly; grant it directly.
adb shell pm grant com.orbitune.smoketest android.permission.POST_NOTIFICATIONS || true

adb shell am start -n com.orbitune.smoketest/.MainActivity
echo "Waiting for the harness to start playback..."
sleep 6

echo "Sending the app to the background (HOME), the way a real user would while listening..."
adb shell input keyevent KEYCODE_HOME
sleep 10

echo "--- dumpsys media_session ---"
adb shell dumpsys media_session > media_session.txt
cat media_session.txt

echo "--- dumpsys notification (this app only) ---"
adb shell dumpsys notification --noredact > notification_full.txt
grep -A 30 "com.orbitune.smoketest" notification_full.txt > notification.txt || true
cat notification.txt

echo "--- dumpsys activity services (this app only) ---"
adb shell dumpsys activity services com.orbitune.smoketest > services.txt
cat services.txt

fail=0

grep -q "com.orbitune.smoketest" media_session.txt \
  || { echo "::error::No media session owned by the app was found after backgrounding"; fail=1; }
grep -q "state=PLAYING" media_session.txt \
  || { echo "::error::Media session is not reporting PLAYING after backgrounding - audio likely got suspended"; fail=1; }

grep -q "com.orbitune.smoketest" notification.txt \
  || { echo "::error::No lock-screen/notification media card was posted while the app was backgrounded"; fail=1; }

grep -qi "MediaSessionService" services.txt \
  || { echo "::error::MediaSessionService is not running - the foreground service never started"; fail=1; }
grep -qi "isForeground=true" services.txt \
  || { echo "::error::The media session service is running but NOT as a foreground service - Android may kill it under memory pressure"; fail=1; }

echo "--- transport control check: does a real media button press reach our JS action handler? ---"
# This is what both the notification's buttons and a Bluetooth headset/hardware
# button ultimately send - a system media key event routed to the active
# session's MediaButtonReceiver. If this never reaches app.js, neither will a
# tap on the notification.
adb logcat -c
adb shell input keyevent KEYCODE_MEDIA_PAUSE
sleep 3
adb logcat -d > transport_logcat.txt
grep -q "SMOKE_ACTION_FIRED:pause" transport_logcat.txt \
  || { echo "::error::Media button press (KEYCODE_MEDIA_PAUSE) never reached the setActionHandler('pause') callback - notification/hardware transport buttons are likely non-functional"; fail=1; }
grep "SMOKE_ACTION_FIRED" transport_logcat.txt || true

echo "--- now the BACK button specifically (not HOME) - what the user actually does to exit ---"
adb shell am start -n com.orbitune.smoketest/.MainActivity
sleep 2
adb shell input keyevent KEYCODE_BACK
sleep 10

echo "--- dumpsys media_session after BACK ---"
adb shell dumpsys media_session > media_session_after_back.txt
cat media_session_after_back.txt

echo "--- dumpsys notification after BACK ---"
adb shell dumpsys notification --noredact > notification_full_after_back.txt
grep -A 30 "com.orbitune.smoketest" notification_full_after_back.txt > notification_after_back.txt || true
cat notification_after_back.txt

echo "--- dumpsys activity services after BACK ---"
adb shell dumpsys activity services com.orbitune.smoketest > services_after_back.txt
cat services_after_back.txt

grep -q "com.orbitune.smoketest" media_session_after_back.txt \
  || { echo "::error::No media session owned by the app after BACK press - the session was torn down"; fail=1; }
grep -q "state=PLAYING" media_session_after_back.txt \
  || { echo "::error::Media session is not reporting PLAYING after BACK press"; fail=1; }
grep -q "com.orbitune.smoketest" notification_after_back.txt \
  || { echo "::error::Notification/lock-screen media card disappeared after BACK press - matches the real-device report"; fail=1; }
grep -qi "isForeground=true" services_after_back.txt \
  || { echo "::error::Service is no longer a foreground service after BACK press"; fail=1; }

echo "--- transport control check after BACK ---"
adb logcat -c
adb shell input keyevent KEYCODE_MEDIA_PAUSE
sleep 3
adb logcat -d > transport_logcat_after_back.txt
grep -q "SMOKE_ACTION_FIRED:pause" transport_logcat_after_back.txt \
  || { echo "::error::Media button press after BACK never reached the JS action handler"; fail=1; }

echo "--- ground-truth overlap stress test: rapid-mash station switching, sampled via dumpsys audio ---"
# Not theory this time - relaunch fresh (the harness auto-runs a 12-switch
# mash between two audibly distinct tones ~2s after boot, using the exact
# same stop/unload/wait(120)/preload/play mutex as app.js), then repeatedly
# sample dumpsys audio's live AudioPlaybackConfiguration list for this
# app's uid while the mash is happening. If two native players are ever
# genuinely active at once, this is where it shows up - not in logcat text.
adb shell am force-stop com.orbitune.smoketest
APP_UID=$(adb shell dumpsys package com.orbitune.smoketest | grep -o 'userId=[0-9]*' | head -n1 | cut -d= -f2)
echo "App uid: $APP_UID"
adb logcat -c
adb shell am start -n com.orbitune.smoketest/.MainActivity

rm -f overlap_samples.txt
for i in $(seq 1 24); do
  sleep 0.15
  echo "=== sample $i ===" >> overlap_samples.txt
  adb shell dumpsys audio >> overlap_samples.txt 2>&1 || true
done

adb logcat -d > stress_logcat.txt
grep -q "SMOKE_STRESS_DONE" stress_logcat.txt \
  || echo "::warning::Stress sequence did not report completion in time - samples taken regardless"

echo "--- dumpsys audio output format, first sample (for diagnosing the grep pattern if this ever needs adjusting) ---"
sed -n '1,40p' overlap_samples.txt

MAX_CONCURRENT=0
awk -v target_uid="$APP_UID" '
  /^=== sample/ { count=0 }
  /AudioPlaybackConfiguration/ && $0 ~ ("uid:" target_uid "[^0-9]") && $0 ~ /state:started/ { count++ }
  /^=== sample/ && NR>1 { print prev_count }
  { prev_count = count }
  END { print count }
' overlap_samples.txt > /tmp/sample_counts.txt || true
MAX_CONCURRENT=$(sort -n /tmp/sample_counts.txt | tail -n1)
echo "Max concurrent 'started' AudioPlaybackConfiguration entries for uid=$APP_UID across all samples: ${MAX_CONCURRENT:-0}"

if [ -n "$MAX_CONCURRENT" ] && [ "$MAX_CONCURRENT" -gt 1 ]; then
  echo "::error::CONFIRMED: $MAX_CONCURRENT simultaneous active audio playback configurations for this app's uid during rapid station switching - two native players really were active at once"
  fail=1
else
  echo "OK: at most 1 active audio playback configuration for this app at any sampled moment during the rapid-switch stress test"
fi

exit $fail

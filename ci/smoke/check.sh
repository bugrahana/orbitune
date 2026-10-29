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

exit $fail

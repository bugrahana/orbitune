#!/usr/bin/env bash
# Real-app regression gate: installs the actual app on the emulator and
# asserts (not just prints) the two things that have already broken in
# production once each - a clean crash-free launch, and the back button
# at the root screen not destroying the Activity (which orphans the
# native audio player - see the "two stations play at once" incident).
set -euo pipefail
cd "$GITHUB_WORKSPACE"

APK=$(find android/app/build/outputs/apk/debug -name '*.apk' | head -n1)
echo "Installing $APK"
adb install -r "$APK"

adb logcat -c
adb shell am start -n com.orbitune.app/.MainActivity
echo "Waiting for the app to load and run its initial JS..."
sleep 8

adb logcat -d > full_logcat.txt
echo "--- filtered console/JS/exception lines ---"
grep -iE "chromium|console|orbitune|exception|JS |Uncaught|TypeError|ReferenceError|at file://|capacitor" full_logcat.txt > filtered_logcat.txt || true
cat filtered_logcat.txt

fail=0

if grep -q "Uncaught" full_logcat.txt; then
  echo "::error::Uncaught JS exception on initial launch - every click handler defined after it never gets wired up"
  grep "Uncaught" full_logcat.txt
  fail=1
else
  echo "OK: no uncaught JS exception on initial launch"
fi

echo "--- back-press-at-root lifecycle check ---"
adb logcat -c
adb shell input keyevent KEYCODE_BACK
sleep 2

TASK_COUNT=$(adb shell dumpsys activity activities | grep -c "com.orbitune.app" || true)
if [ "$TASK_COUNT" -eq 0 ]; then
  echo "::error::Activity task disappeared after back press at the root screen - back is finishing the Activity again, which orphans the native audio player"
  fail=1
else
  echo "OK: task still present after back press ($TASK_COUNT references)"
fi

if adb shell pidof com.orbitune.app > /dev/null 2>&1; then
  echo "OK: process still alive after back press"
else
  echo "::error::Process is gone after back press"
  fail=1
fi

echo "Re-opening via launcher intent (should resume the same instance, not reload app.js, if the fix works)..."
adb shell am start -n com.orbitune.app/.MainActivity
sleep 4
adb logcat -d > after_reopen_logcat.txt
RELOAD_COUNT=$(grep -c "Handling local request: https://localhost/app.js" after_reopen_logcat.txt || true)
echo "app.js load events since back press: $RELOAD_COUNT"
if [ "$RELOAD_COUNT" -gt 0 ]; then
  echo "::error::app.js reloaded after reopening - the Activity (and all its JS/plugin state, including the native audio tracking) was recreated from scratch instead of being resumed"
  fail=1
else
  echo "OK: existing instance was resumed, app.js was not reloaded"
fi

echo "--- full logcat saved as artifact regardless ---"
exit $fail

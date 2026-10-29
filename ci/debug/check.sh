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

if grep -q "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" full_logcat.txt; then
  echo "OK: battery-optimization exemption was requested on first launch"
else
  echo "::error::Battery-optimization exemption was never requested on first launch"
  fail=1
fi

MANUFACTURER=$(adb shell getprop ro.product.manufacturer | tr -d '\r')
echo "Emulator manufacturer: $MANUFACTURER"
if grep -qE "com\.miui\.securitycenter|com\.huawei\.systemmanager|com\.coloros\.safecenter|com\.oppo\.safe|com\.vivo\.permissionmanager|com\.iqoo\.secure|com\.letv\.android\.letvsafe|com\.asus\.mobilemanager|com\.meizu\.safe" full_logcat.txt; then
  echo "::error::An OEM-specific autostart screen was attempted on a non-matching manufacturer ($MANUFACTURER) - isKnownAggressiveOem() is misfiring"
  fail=1
else
  echo "OK: no OEM-specific autostart screen was attempted on this ($MANUFACTURER) emulator, as expected"
fi

echo "--- one-time-prompt check: a fresh process launch must NOT ask again ---"
adb shell am force-stop com.orbitune.app
adb logcat -c
adb shell am start -n com.orbitune.app/.MainActivity
sleep 6
adb logcat -d > second_launch_logcat.txt
if grep -q "Uncaught" second_launch_logcat.txt; then
  echo "::error::Uncaught JS exception on the second (fresh-process) launch"
  grep "Uncaught" second_launch_logcat.txt
  fail=1
else
  echo "OK: no uncaught JS exception on the second launch"
fi
if grep -q "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" second_launch_logcat.txt; then
  echo "::error::Battery-optimization exemption was requested AGAIN on a second fresh launch - the one-time SharedPreferences gate isn't working, this would nag the user every launch"
  fail=1
else
  echo "OK: second launch did not re-prompt for battery-optimization exemption"
fi

echo "--- full logcat saved as artifact regardless ---"
exit $fail

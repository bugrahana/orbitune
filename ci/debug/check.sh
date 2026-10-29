#!/usr/bin/env bash
# One-off diagnostic: install the real app on the emulator and capture its
# JS console output via logcat, to see the actual error instead of guessing.
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

echo "--- back-press-at-root lifecycle check ---"
adb logcat -c
adb shell input keyevent KEYCODE_BACK
sleep 2
echo "Task still present after back press?"
adb shell dumpsys activity activities | grep -c "com.orbitune.app" || true
echo "Process still alive after back press?"
adb shell pidof com.orbitune.app || echo "NOT RUNNING"

echo "Re-opening via launcher intent (should resume the same instance, not reload app.js, if the fix works)..."
adb shell am start -n com.orbitune.app/.MainActivity
sleep 4
adb logcat -d > after_reopen_logcat.txt
RELOAD_COUNT=$(grep -c "Handling local request: https://localhost/app.js" after_reopen_logcat.txt || true)
echo "app.js load events since back press: $RELOAD_COUNT (0 = resumed existing instance, 1+ = Activity was recreated from scratch)"
echo "--- full logcat saved as artifact regardless ---"

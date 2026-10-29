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
echo "--- full logcat saved as artifact regardless ---"

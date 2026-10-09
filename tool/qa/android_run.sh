#!/bin/bash
# Runs an integration test on an Android device and acts on the "[QA] ..."
# lines it prints:
#   SHOT name  → screenshot to $QA_OUT/shots/name.png
#   TAP x y    → adb tap            TYPE text → adb input text
#   KEY code   → adb keyevent       PUSH      → copy $QA_SHEET into the app
#   PULL path  → pull a saved file to $QA_OUT/pulled_android.pdf
# usage: tool/qa/android_run.sh integration_test/<test>.dart <log name>
# env: ANDROID_SERIAL (default emulator-5554), QA_OUT (default build/qa),
#      QA_SHEET (default "Character Sheet.pdf" in the repo root; a blank
#      5e character sheet you supply — it is not in the repo).
cd "$(dirname "$0")/../.."
DEV=${ANDROID_SERIAL:-emulator-5554}
OUT=${QA_OUT:-build/qa}
SHEET=${QA_SHEET:-Character Sheet.pdf}
A="adb -s $DEV"
mkdir -p "$OUT/shots"; rm -f "$OUT/$2.log"
flutter test "$1" -d "$DEV" 2>&1 | while IFS= read -r line; do
  echo "$line" >> "$OUT/$2.log"
  case "$line" in
    *"[QA] SHOT "*) n="${line##*\[QA\] SHOT }"; n="${n//[^A-Za-z0-9_-]/}"; $A exec-out screencap -p </dev/null > "$OUT/shots/$n.png";;
    *"[QA] TAP "*) xy="${line##*\[QA\] TAP }"; $A shell input tap $xy </dev/null;;
    *"[QA] TYPE "*) tx="${line##*\[QA\] TYPE }"; $A shell input text "'$tx'" </dev/null; sleep 0.6;;
    *"[QA] KEY "*) k="${line##*\[QA\] KEY }"; $A shell input keyevent $k </dev/null; sleep 1;;
    *"[QA] PUSH"*) $A exec-in run-as com.halworks.basicpdf sh -c 'mkdir -p app_flutter/qa && cat > "app_flutter/qa/Character Sheet.pdf"' < "$SHEET";;
    *"[QA] PULL "*) p="${line##*\[QA\] PULL }"; $A pull "$p" "$OUT/pulled_android.pdf" </dev/null >/dev/null;;
  esac
done
grep -E '\[QA\]|passed|failed|Error|Expected|Actual|Exception' "$OUT/$2.log" | grep -v "SHOT\|TYPE\|KEY 66" | tail -60

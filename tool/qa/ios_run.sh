#!/bin/zsh
# Runs an integration test on the iOS simulator as the app entrypoint
# (keeps app data unless --fresh), seeds fixtures, waits for "ALLDONE" in
# the app's qa_log.txt and prints it.
# usage: tool/qa/ios_run.sh integration_test/<test>.dart [--fresh] [--nobuild] [only=a,b]
# env: IOS_SIM (simulator UDID, default: booted), QA_OUT (default build/qa),
#      QA_SHEET (default "Character Sheet.pdf" in the repo root, optional).
cd "$(dirname "$0")/../.."
U=${IOS_SIM:-booted}
OUT=${QA_OUT:-build/qa}; mkdir -p "$OUT"
SHEET=${QA_SHEET:-Character Sheet.pdf}
T=$1; shift
FRESH=0; BUILD=1; ONLY=""
for a in "$@"; do [[ $a == --fresh ]] && FRESH=1; [[ $a == --nobuild ]] && BUILD=0; [[ $a == only=* ]] && ONLY=${a#only=}; done
if [[ $BUILD == 1 ]]; then
  flutter build ios --simulator --debug -t "$T" 2>&1 | tail -2 || exit 1
fi
xcrun simctl terminate $U com.halworks.basicpdf >/dev/null 2>&1
[[ $FRESH == 1 ]] && xcrun simctl uninstall $U com.halworks.basicpdf
xcrun simctl install $U build/ios/iphonesimulator/Runner.app || exit 1
D=$(xcrun simctl get_app_container $U com.halworks.basicpdf data)
mkdir -p "$D/Documents/qa"
if [[ ! -f "$D/Documents/qa/form.pdf" ]]; then
  cp test/fixtures/*.pdf "$D/Documents/qa/"
  [[ -f "$SHEET" ]] && cp "$SHEET" "$D/Documents/qa/Character Sheet.pdf"
  cp test/fixtures/form.pdf "$D/Documents/form.pdf"
fi
echo "container $D"
L="$D/Library/Caches/qa_log.txt"; rm -f "$L"
rm -f "$D/Library/Caches/qa_only.txt"; [[ -n "$ONLY" ]] && print -r -- "${ONLY//,/
}" > "$D/Library/Caches/qa_only.txt"
xcrun simctl launch --terminate-running-process $U com.halworks.basicpdf >/dev/null
for i in {1..900}; do
  grep -q "ALLDONE" "$L" 2>/dev/null && break
  sleep 1
done
cp "$L" "$OUT/last_ios_run.log" 2>/dev/null
cat "$L"

#!/bin/zsh
# Runs one XCUITest (ios/RunnerUITests) on the simulator and exports its
# screenshots to $QA_OUT/att_<testName>/.
# usage: tool/qa/ios_xc.sh <testName>
# env: IOS_SIM (simulator UDID, required), QA_OUT (default build/qa)
cd "$(dirname "$0")/../.."
OUT=$PWD/${QA_OUT:-build/qa}; mkdir -p "$OUT"
: ${IOS_SIM:?set IOS_SIM to the simulator UDID}
rm -rf "$OUT/xc_$1.xcresult" "$OUT/att_$1"; mkdir -p "$OUT/att_$1"
cd ios
xcodebuild test -workspace Runner.xcworkspace -scheme RunnerUITests \
  -destination "platform=iOS Simulator,id=$IOS_SIM" \
  -only-testing:RunnerUITests/RunnerUITests/$1 \
  -resultBundlePath "$OUT/xc_$1.xcresult" > "$OUT/xc_$1.log" 2>&1
grep -E "error:|Test Case .*(passed|failed)|\*\* " "$OUT/xc_$1.log" | head -10
xcrun xcresulttool export attachments --path "$OUT/xc_$1.xcresult" --output-path "$OUT/att_$1" >/dev/null 2>&1

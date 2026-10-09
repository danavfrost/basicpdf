#!/bin/zsh
# Run alongside tool/qa/ios_run.sh: watches the app's Library/Caches/shots
# for NAME.req files and saves a simulator screenshot to $QA_OUT/shots.
# env: IOS_SIM (simulator UDID, required), QA_OUT (default build/qa)
cd "$(dirname "$0")/../.."
: ${IOS_SIM:?set IOS_SIM to the simulator UDID}
OUT=$PWD/${QA_OUT:-build/qa}/shots; mkdir -p "$OUT"
while true; do
  D=$(xcrun simctl get_app_container $IOS_SIM com.halworks.basicpdf data 2>/dev/null)
  if [[ -n "$D" && -d "$D/Library/Caches/shots" ]]; then
    for f in "$D"/Library/Caches/shots/*.req(N); do
      n=$(basename "$f" .req)
      xcrun simctl io $IOS_SIM screenshot "$OUT/$n.png" >/dev/null 2>&1
      rm -f "$f"
    done
  fi
  sleep 0.3
done

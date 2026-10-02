#!/usr/bin/env bash
# maestro-runner bench: one maestro-runner run per nightly tag, each against the APK flavour the
# nightly uses for that tag (play = release.apk, internal = internal.apk). Mirrors Maestro Cloud's
# fresh-install-per-suite by reinstalling the APK before each suite.
set -uo pipefail

DEVICE="${DEVICE:-emulator-5554}"
RUNNER="${RUNNER:-$HOME/.maestro-runner/bin/maestro-runner}"
PKG=com.duckduckgo.mobile.android
INTERNAL_TAGS=" customTabsTest privacyTestInternal onboardingInternalTest unifiedInputTest "
EMU_OPTS="-port 5554 -avd test -no-snapshot -no-window -gpu ${EMU_GPU:-swiftshader_indirect} -noaudio -no-boot-anim -camera-back none -no-metrics"
mkdir -p reports

# Host memory/load trace, to diagnose emulator deaths.
( while true; do echo "$(date +%T) $(free -m | awk '/Mem:/{print "used="$3"MB avail="$7"MB"}') load=$(cut -d' ' -f1 /proc/loadavg) emu=$(pgrep -f qemu-system >/dev/null && echo up || echo DOWN)"; sleep 15; done ) > reports/host-monitor.txt 2>&1 &
MON_PID=$!
LOGCAT_PID=
start_logcat() {
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null
  adb -s "$DEVICE" logcat -b main,system,crash -v threadtime >> reports/logcat.txt 2>&1 &
  LOGCAT_PID=$!
}
trap 'kill $LOGCAT_PID $MON_PID 2>/dev/null || true' EXIT

# Relaunch the emulator if it died (the action only launches it once).
ensure_device() {
  if [ "$(adb -s "$DEVICE" get-state 2>/dev/null)" = "device" ]; then return 0; fi
  echo "::warning::emulator $DEVICE is gone - relaunching ($(date +%T))"
  echo "$(date +%T) emulator relaunch" >> reports/emulator-restarts.txt
  sudo dmesg 2>/dev/null | tail -40 >> reports/emulator-restarts.txt
  pkill -9 -f qemu-system 2>/dev/null; sleep 2
  nohup "$ANDROID_HOME/emulator/emulator" $EMU_OPTS >> reports/emulator-relaunch.log 2>&1 &
  adb -s "$DEVICE" wait-for-device
  for _ in $(seq 1 120); do
    [ "$(adb -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  adb -s "$DEVICE" shell settings put global window_animation_scale 0.0
  adb -s "$DEVICE" shell settings put global transition_animation_scale 0.0
  adb -s "$DEVICE" shell settings put global animator_duration_scale 0.0
  start_logcat
}

start_logcat
adb -s "$DEVICE" shell getprop ro.build.version.sdk
rc=0
: > reports/summary.txt
IFS=',' read -ra TAGS <<< "${INCLUDE_TAGS}"
for tag in "${TAGS[@]}"; do
  tag="$(echo "$tag" | xargs)"
  [ -z "$tag" ] && continue
  if [[ "$INTERNAL_TAGS" == *" $tag "* ]]; then apk=apk/internal.apk; else apk=apk/release.apk; fi
  echo "::group::$tag ($apk)"
  ensure_device
  adb -s "$DEVICE" uninstall "$PKG" >/dev/null 2>&1 || true
  adb -s "$DEVICE" install -r "$apk" || { echo "install failed for $tag"; rc=1; echo "::endgroup::"; continue; }
  start=$(date +%s)
  "$RUNNER" --platform android --device "$DEVICE" test \
    --include-tags "$tag" --retries 2 \
    --output "reports/$tag" --flatten .maestro
  r=$?
  echo "$tag apk=$(basename "$apk") exit=$r seconds=$(( $(date +%s) - start )) device=$(adb -s "$DEVICE" get-state 2>&1)" | tee -a reports/summary.txt
  [ $r -ne 0 ] && rc=1
  echo "::endgroup::"
done

sudo dmesg 2>/dev/null | grep -iE "oom|killed|qemu|segfault" | tail -40 > reports/dmesg-tail.txt || true
cat reports/summary.txt
exit $rc

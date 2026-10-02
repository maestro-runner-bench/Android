#!/usr/bin/env bash
# maestro-runner bench: one maestro-runner run per nightly tag, each against the APK flavour the
# nightly uses for that tag (play = release.apk, internal = internal.apk). Mirrors Maestro Cloud's
# fresh-install-per-suite by reinstalling the APK before each suite.
set -uo pipefail

DEVICE="${DEVICE:-emulator-5554}"
RUNNER="${RUNNER:-$HOME/.maestro-runner/bin/maestro-runner}"
PKG=com.duckduckgo.mobile.android
INTERNAL_TAGS=" customTabsTest privacyTestInternal onboardingInternalTest unifiedInputTest "
mkdir -p reports

adb -s "$DEVICE" logcat -b main,system,crash -v threadtime > reports/logcat.txt 2>&1 &
LOGCAT_PID=$!
trap 'kill $LOGCAT_PID 2>/dev/null || true' EXIT

adb -s "$DEVICE" shell getprop ro.build.version.sdk
rc=0
: > reports/summary.txt
IFS=',' read -ra TAGS <<< "${INCLUDE_TAGS}"
for tag in "${TAGS[@]}"; do
  tag="$(echo "$tag" | xargs)"
  [ -z "$tag" ] && continue
  if [[ "$INTERNAL_TAGS" == *" $tag "* ]]; then apk=apk/internal.apk; else apk=apk/release.apk; fi
  echo "::group::$tag ($apk)"
  adb -s "$DEVICE" uninstall "$PKG" >/dev/null 2>&1 || true
  adb -s "$DEVICE" install -r "$apk" || { echo "install failed for $tag"; rc=1; echo "::endgroup::"; continue; }
  start=$(date +%s)
  "$RUNNER" --platform android --device "$DEVICE" test \
    --include-tags "$tag" --retries 2 \
    --output "reports/$tag" --flatten .maestro
  r=$?
  echo "$tag apk=$(basename "$apk") exit=$r seconds=$(( $(date +%s) - start ))" | tee -a reports/summary.txt
  [ $r -ne 0 ] && rc=1
  echo "::endgroup::"
done

cat reports/summary.txt
exit $rc

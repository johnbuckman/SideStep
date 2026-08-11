# 05-appid — Tier B: reinstalling an app REUSES the same com.sidestep.<name>.<team> id
# instead of minting a new one each time. Apple's real cap is 10 NEW App IDs per rolling
# 7 days, so a regression that per-install-randomized the id would silently exhaust the
# account. Install twice at different versions; assert the id is identical and only the
# version changed. (Oracle-verified, never SideStep's claim.)
ensure_provision >/dev/null 2>&1 || { fail "Tier-B: build Provision"; return 0 2>/dev/null || true; }

V1="1.0.$(( (RANDOM % 400) + 100 ))"; V2="1.0.$(( (RANDOM % 400) + 500 ))"
"$REPO/regression/build-test-app.sh" "$V1" --name SelfId >/dev/null 2>&1
IWISH_UDID="$UDID" "$PROVISION" --app "$REPO/regression/artifacts/SelfId.app" >/tmp/ss-id1.log 2>&1
BID1="$(oracle apps "$UDID" | awk -F'\t' '$1 ~ /^com\.sidestep\.selfid\./{print $1; exit}')"

"$REPO/regression/build-test-app.sh" "$V2" --name SelfId >/dev/null 2>&1
IWISH_UDID="$UDID" "$PROVISION" --app "$REPO/regression/artifacts/SelfId.app" >/tmp/ss-id2.log 2>&1
BID2="$(oracle apps "$UDID" | awk -F'\t' '$1 ~ /^com\.sidestep\.selfid\./{print $1; exit}')"

if [ -n "$BID1" ] && [ "$BID1" = "$BID2" ]; then
  pass "App-ID reuse: same id across reinstalls ($BID1)"
else
  fail "App-ID reuse: id stable across reinstalls" "first='$BID1' second='$BID2'"
fi
assert_device_version "App-ID reuse: version updated v1→v2" "$UDID" "$BID2" "$V2"

IWISH_UDID="$UDID" "$PROVISION" --uninstall "$BID2" >/tmp/ss-id-un.log 2>&1
assert_device_absent "App-ID reuse: cleaned up" "$UDID" "$BID2"

# 07-back-to-back — Tier B: install a LARGE app, then IMMEDIATELY install it again with NO
# uninstall in between. This is the field sequence that surfaced ">>> INSTALL FAILED: afc
# write": a ~125MB de1app installed fine, then a second install seconds later failed mid
# AFC-upload. The staging file is a fixed name (PublicStaging/sidestep.ipa) reused every
# install, so back-to-back copies stress the exact spot that stalled. A fresh AFC session +
# WRONLY(O_TRUNC) + SideStep's install retry (isRetryableInstallFailure) must make the
# second copy land clean. Asserted against installd (the oracle) — the retry may log an
# "afc write" on a first attempt and still recover, so we check the DEVICE, not the log.
ensure_provision >/dev/null 2>&1 || { fail "Tier-B: build Provision"; return 0 2>/dev/null || true; }

_b2b_name="B2BTest"; _b2b_lower="b2btest"; _b2b_pad="--pad 150"
_b2b_v1="1.0.$(( (RANDOM % 900) + 100 ))"
_b2b_v2="1.0.$(( (RANDOM % 900) + 100 ))"
_b2b_prefix="^com\\.sidestep\\.$_b2b_lower\\."

# Pre-clean: drop any prior/running instance so the version asserts are unambiguous.
_b2b_prev="$(oracle apps "$UDID" | awk -F'\t' -v p="$_b2b_prefix" '$1 ~ p {print $1; exit}')"
[ -n "$_b2b_prev" ] && "$HELPER" uninstall "$UDID" "$_b2b_prev" >/dev/null 2>&1

# --- first install (v1) ---
if "$REPO/regression/build-test-app.sh" "$_b2b_v1" --name "$_b2b_name" $_b2b_pad >/dev/null 2>&1; then
  pass "b2b: build v$_b2b_v1"
else fail "b2b: build v$_b2b_v1"; return; fi
IWISH_UDID="$UDID" "$PROVISION" --app "$REPO/regression/artifacts/$_b2b_name.app" >"/tmp/ss-$_b2b_lower-1.log" 2>&1
_b2b_bid="$(oracle apps "$UDID" | awk -F'\t' -v p="$_b2b_prefix" '$1 ~ p {print $1; exit}')"
if [ -z "$_b2b_bid" ]; then
  fail "b2b: first install landed" "installd has no com.sidestep.$_b2b_lower.* — $(grep -aoE '>>> INSTALL FAILED: [^\"]{0,80}' "/tmp/ss-$_b2b_lower-1.log" | tail -1)"
  return
fi
pass "b2b: first install landed ($_b2b_bid)"

# --- second install (v2), back-to-back, NO uninstall between (the field repro) ---
if "$REPO/regression/build-test-app.sh" "$_b2b_v2" --name "$_b2b_name" $_b2b_pad >/dev/null 2>&1; then
  pass "b2b: build v$_b2b_v2"
else fail "b2b: build v$_b2b_v2"; fi
IWISH_UDID="$UDID" "$PROVISION" --app "$REPO/regression/artifacts/$_b2b_name.app" >"/tmp/ss-$_b2b_lower-2.log" 2>&1
# The definitive check: installd now reports v2. A back-to-back "afc write" that the retry
# never recovered would leave v1 in place (or nothing) → this fails with the real reason.
if grep -q "afc write" "/tmp/ss-$_b2b_lower-2.log"; then
  _dim "    note: an 'afc write' stall occurred on the 2nd upload; SideStep retried — checking device settled clean"
fi
assert_device_version "b2b: second install landed clean (v$_b2b_v2)" "$UDID" "$_b2b_bid" "$_b2b_v2"

# --- cleanup ---
IWISH_UDID="$UDID" "$PROVISION" --uninstall "$_b2b_bid" >/dev/null 2>&1
assert_device_absent "b2b: removed from device" "$UDID" "$_b2b_bid"

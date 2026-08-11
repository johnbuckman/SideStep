# 04-beacon — Tier C: the on-device beacon's OUTBOUND control channel. The beacon dials
# the Mac (reliable direction) and answers commands; we assert it responds and reports its
# real state. Requires a SelfTest app FOREGROUNDED on the device (open it) — SKIPs cleanly
# otherwise, so the suite stays green without manual setup. No devicectl (which contends
# with the libimobiledevice install path).
ensure_provision >/dev/null 2>&1 || { skip "Tier-C: build Provision"; return 0 2>/dev/null || true; }
export SIDESTEP_BEACON_TOKEN="$(cat "$TOKEN_FILE")"

PONG="$("$PROVISION" --beacon-serve PING --wait 6 2>/dev/null)"
case "$PONG" in
  PONG*)
    pass "beacon answers PING over control channel ($PONG)"
    STATE="$("$PROVISION" --beacon-serve STATE --wait 6 2>/dev/null)"
    case "$STATE" in
      *'"version"'*) pass "beacon reports STATE (${STATE:0:60}…)" ;;
      *)             fail "beacon reports STATE" "unexpected: ${STATE:0:80}" ;;
    esac
    ;;
  *)
    skip "beacon control channel" "no device dialed in — open a SelfTest app on the device to run Tier C"
    ;;
esac

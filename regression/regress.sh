#!/bin/bash
# regression/regress.sh — SideStep regression runner.
#
#   ./regress.sh                 run all scenarios against the USB-connected device
#   ./regress.sh <scenario>...   run only the named scenario file(s) (regression/scenarios/<name>.sh)
#
# Every scenario drives SideStep (headless Provision CLI) or the on-device beacon
# (TCP debug port) and then asserts against the DEVICE ORACLE — installd's real
# state — so a false "INSTALL OK" can never make a test pass. Uses the paid
# johnbuckman@mac.com account (no signing limits).
cd "$(dirname "$0")"
source ./lib.sh

UDID="${SIDESTEP_TEST_UDID:-$(usb_device)}"
if [ -z "$UDID" ]; then _red "No USB device connected — plug one in (or set SIDESTEP_TEST_UDID)."; exit 2; fi
NAME="$("$HELPER" list 2>/dev/null | awk -F'\t' -v u="$UDID" '$1==u{print $2; exit}')"
_dim "Target: ${NAME:-?}  ($UDID)"
_dim "Oracle: $HELPER"
echo

# Discover scenarios (regression/scenarios/*.sh), or run just the ones named on the CLI.
if [ "$#" -gt 0 ]; then
  SCENARIOS=(); for s in "$@"; do SCENARIOS+=("scenarios/$s.sh"); done
else
  SCENARIOS=(scenarios/*.sh)
fi

for s in "${SCENARIOS[@]}"; do
  [ -f "$s" ] || { _red "missing scenario: $s"; FAIL=$((FAIL+1)); continue; }
  echo "▸ $(basename "$s" .sh)"
  # shellcheck disable=SC1090
  source "$s"
done

summary

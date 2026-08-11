# 01-logic — Tier A: pure Mac-side logic, no device. Runs the Provision --selftest
# suite (normalizeRepo, AltStore v1/v2 parse, VersionCompare, installFailReason) and
# folds each individual check into the runner's tally.
if ! ensure_provision; then
  fail "Tier-A: build Provision" "swift build --product Provision failed"
else
  _out="$("$PROVISION" --selftest 2>/dev/null)"
  if ! printf '%s' "$_out" | grep -q '>>> SELFTEST'; then
    fail "Tier-A: selftest ran" "no SELFTEST marker in output"
  else
    while IFS= read -r line; do
      case "$line" in
        "  PASS  "*) pass "${line#  PASS  }" ;;
        "  FAIL  "*) fail "${line#  FAIL  }" ;;
      esac
    done <<< "$_out"
  fi
fi

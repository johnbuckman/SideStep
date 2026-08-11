# regression/lib.sh — shared helpers for the SideStep regression suite.
# Sourced by regress.sh and individual scenario files. Pure bash + the bundled
# idevice helpers; no GUI. The guiding rule: ASSERT AGAINST THE DEVICE ORACLE
# (installd via `idevicehelper apps/appinfo`), never against SideStep's own claim.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO/Helpers/idevice/idevicehelper"
PROVISION="$REPO/.build/debug/Provision"          # headless SideStep driver (Tier A + device verbs)
TOKEN_FILE="$REPO/regression/beacon-token.txt"   # gitignored; shared with the on-device beacon
# Pin the device helpers to the repo's freshly-built copies so the headless CLI can never
# fall back to a stale helper (the exact trap that produced a false "INSTALL OK").
export SIDESTEP_HELPER_DIR="$REPO/Helpers/idevice"

# Build the Provision CLI if it's missing/stale. Returns non-zero if the build fails.
ensure_provision() {
  ( cd "$REPO" && swift build --product Provision ) >/dev/null 2>&1
  [ -x "$PROVISION" ]
}

# ---- pass/fail bookkeeping -------------------------------------------------
PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=()
_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
_dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS+1)); _green  "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); _red "  FAIL  $1${2:+  — $2}"; }
skip() { SKIP=$((SKIP+1)); _yellow "  SKIP  $1${2:+  — $2}"; }

# assert_eq <name> <expected> <actual>
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$2', got '$3'"; }

summary() {
  echo
  local skipnote=""; [ "$SKIP" -gt 0 ] && skipnote=" ($SKIP skipped)"
  if [ "$FAIL" -eq 0 ]; then _green "ALL GREEN — $PASS passed$skipnote"; else
    _red "$FAIL FAILED / $((PASS+FAIL)) total$skipnote"; printf '   - %s\n' "${FAILED_NAMES[@]}"; fi
  [ "$FAIL" -eq 0 ]
}

# ---- device oracle ---------------------------------------------------------
# Device access must tolerate transient lockdown/usbmux contention: the running
# SideStep polls the SAME device (RefreshDaemon), so a browse can collide and fail.
# `oracle` retries until it gets a DEFINITIVE marker line (OK / ABSENT), so a flaky
# collision never masquerades as a real ABSENT. Prints the winning output.
oracle() {   # oracle <helper-args...>
  local out i
  for i in 1 2 3 4 5; do
    out="$("$HELPER" "$@" 2>&1)"
    case "$out" in
      *">>> APPS OK"*|*">>> APPINFO OK"*|*">>> APPINFO ABSENT"*) printf '%s' "$out"; return 0 ;;
    esac
    sleep 0.6
  done
  printf '%s' "$out"; return 1   # genuine failure (device gone, service dead)
}

# The UDID of whatever device is currently on USB (the suite's default target).
# `list` columns are: udid <TAB> name <TAB> conn  — so the udid is $1.
usb_device() {
  "$HELPER" list 2>/dev/null | awk -F'\t' '$3=="usb"{print $1; exit}'
}

# oracle_state <udid> <bundleid>  → echoes exactly one of: present | absent | error.
# "error" (device unreachable / service failed) is DISTINCT from "absent" so a comms
# failure can never be mistaken for "the app isn't installed" (a false pass).
oracle_state() {
  local out; out="$(oracle appinfo "$1" "$2")"
  case "$out" in
    *">>> APPINFO OK"*)     echo present ;;
    *">>> APPINFO ABSENT"*) echo absent  ;;
    *)                      echo error   ;;
  esac
}

# oracle_version <udid> <bundleid>  → installd short-version, or empty if absent/error.
oracle_version() {
  oracle appinfo "$1" "$2" | awk -F'\t' -v b="$2" '$1==b{print $2; exit}'
}

# ---- assertions that speak to the oracle -----------------------------------
# assert_device_installed <name> <udid> <bundleid>
assert_device_installed() {
  case "$(oracle_state "$2" "$3")" in
    present) pass "$1" ;;
    absent)  fail "$1" "installd reports $3 ABSENT" ;;
    *)       fail "$1" "oracle ERROR querying $3 (device unreachable?)" ;;
  esac
}
# assert_device_absent <name> <udid> <bundleid>
assert_device_absent() {
  case "$(oracle_state "$2" "$3")" in
    absent)  pass "$1" ;;
    present) fail "$1" "installd still has $3" ;;
    *)       fail "$1" "oracle ERROR querying $3 (device unreachable?)" ;;
  esac
}
# assert_device_version <name> <udid> <bundleid> <expected-version>
assert_device_version() {
  local got; got="$(oracle_version "$2" "$3")"
  assert_eq "$1" "$4" "$got"
}

# install_uninstall_cycle <label> <AppName> <version> [--ext]
# Full Tier-B cycle: build a versioned test app → SideStep signs+installs it → assert
# installd shows it at that exact version → SideStep uninstalls → assert installd drops it.
# Distinct version each run proves a real re-sign+install, not a cached copy.
install_uninstall_cycle() {
  local label="$1" name="$2" ver="$3" ext="${4:-}"
  local lower; lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  # shellcheck disable=SC2086
  if "$REPO/regression/build-test-app.sh" "$ver" --name "$name" $ext >/dev/null 2>&1; then
    pass "$label: build v$ver"
  else fail "$label: build v$ver"; return; fi

  # Pre-clean: remove any prior/running instance first. iOS defers the bundle swap for a
  # RUNNING app, so installing over one leaves the OLD version in place while SideStep still
  # reports "Installed" — uninstalling kills the process and guarantees a clean version assert.
  local prev; prev="$(oracle apps "$UDID" | awk -F'\t' -v p="^com\\.sidestep\\.$lower\\." '$1 ~ p {print $1; exit}')"
  [ -n "$prev" ] && "$HELPER" uninstall "$UDID" "$prev" >/dev/null 2>&1

  IWISH_UDID="$UDID" "$PROVISION" --app "$REPO/regression/artifacts/$name.app" >"/tmp/ss-$lower.log" 2>&1
  local bid; bid="$(oracle apps "$UDID" | awk -F'\t' -v p="^com\\.sidestep\\.$lower\\." '$1 ~ p {print $1; exit}')"
  if [ -z "$bid" ]; then
    fail "$label: installed on device" "installd has no com.sidestep.$lower.* — Provision: $(grep -aoE '>>> (INSTALL OK <<<|INSTALL FAILED: [^\"]{0,80})' "/tmp/ss-$lower.log" | tail -1)"
    return
  fi
  pass "$label: installed on device ($bid)"
  assert_device_version "$label: exact version landed" "$UDID" "$bid" "$ver"
  IWISH_UDID="$UDID" "$PROVISION" --uninstall "$bid" >"/tmp/ss-$lower-un.log" 2>&1
  assert_device_absent "$label: removed from device" "$UDID" "$bid"
}

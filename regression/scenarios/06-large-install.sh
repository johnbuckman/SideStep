# 06-large-install — Tier B: SideStep installs a LARGE (~150 MB) app and it lands on the
# device. Regression guard for the "Install failed: afc write" failure — a mid-upload
# afc_file_write error (Helpers/idevicehelper.c) hit while installing the ~125 MB de1app
# IPA. 02-install only ships a few-KB SelfTest.app, one AFC chunk, so it can never
# exercise the many-chunk upload loop where that failure lives. Here we pad a synthetic
# app to de1app scale with incompressible data (so the zipped .ipa stays large) and
# assert against installd (the oracle), never SideStep's own "INSTALL OK".
#
# ~150 MB re-signs + uploads over USB each run, so this is the slowest scenario — that
# cost is the point: it's the only one that drives a real multi-chunk AFC write.
ensure_provision >/dev/null 2>&1 || { fail "Tier-B: build Provision"; return 0 2>/dev/null || true; }
install_uninstall_cycle "large-app(~150MB)" "BigTest" "1.0.$(( (RANDOM % 900) + 100 ))" "--pad 150"

# 02-install — Tier B: SideStep genuinely installs a plain versioned app, then removes it.
# Asserted against installd (the oracle), never SideStep's own "INSTALL OK".
ensure_provision >/dev/null 2>&1 || { fail "Tier-B: build Provision"; return 0 2>/dev/null || true; }
install_uninstall_cycle "plain-app" "SelfTest" "1.0.$(( (RANDOM % 900) + 100 ))"

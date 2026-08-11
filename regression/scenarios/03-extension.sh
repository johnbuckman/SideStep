# 03-extension — Tier B: an app WITH a nested .appex installs (the extension-bundle-id
# nesting bug: SideStep must re-id PlugIns/*.appex to nest under the rewritten main id, or
# installd rejects the whole app with "Failed to set app extension placeholders").
ensure_provision >/dev/null 2>&1 || { fail "Tier-B: build Provision"; return 0 2>/dev/null || true; }
install_uninstall_cycle "extension-app" "SelfExt" "1.0.$(( (RANDOM % 900) + 100 ))" "--ext"

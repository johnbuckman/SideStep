// idevicehelper — minimal device ops for SideStep, built on libimobiledevice.
// Replaces the pymobiledevice3 python helpers. No libzip needed.
//   idevicehelper list
//   idevicehelper install   <udid> <ipa>
//   idevicehelper uninstall <udid> <bundleid>
//   idevicehelper apps      <udid>              — installd's list of USER apps (ground truth)
//   idevicehelper appinfo   <udid> <bundleid>   — one app's version, or "(not installed)"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

static int g_err = 0;
static char g_errmsg[512];
static volatile int g_done = 0;   // set by status_cb when installd reaches a terminal state

// installation_proxy delivers status updates here on a background thread while the
// install runs. We capture the real installd error (name + description) so failures
// are actionable instead of a bare code, emit on-device install %, and flag terminal
// completion so cmd_install can wait for the true end of the operation.
static void status_cb(plist_t command, plist_t status, void *udata) {
    (void)command; (void)udata;
    char *nm = NULL, *ds = NULL; uint64_t code = 0;
    instproxy_status_get_error(status, &nm, &ds, &code);
    if (nm) {
        g_err = 1;
        snprintf(g_errmsg, sizeof(g_errmsg), "%s%s%s", nm, ds ? ": " : "", ds ? ds : "");
        free(nm); free(ds);
        g_done = 1;   // error is terminal
        return;
    }
    free(nm); free(ds);
    // installation_proxy reports 0…100 as it copies/verifies/installs on-device. Emit it
    // on its own PROGRESS line (parsed by the Mac side) so we can show a bar + ETA for the
    // "Installing on iPad…" phase, which used to be a bare spinner.
    int pct = -1;
    instproxy_status_get_percent_complete(status, &pct);
    if (pct >= 0) { printf(">>> PROGRESS %d Installing\n", pct); fflush(stdout); }
    // "Complete" is the successful terminal status.
    char *st = NULL;
    instproxy_status_get_name(status, &st);
    if (st) { if (!strcmp(st, "Complete")) g_done = 1; free(st); }
}

static idevice_t connect_dev(const char *udid) {
    idevice_t d = NULL;
    // Include NETWORK so WiFi-reachable devices work (prefers USB when both present).
    enum idevice_options opt = (enum idevice_options)(IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK);
    if (idevice_new_with_options(&d, udid, opt) != IDEVICE_E_SUCCESS) return NULL;
    return d;
}

static int cmd_list(void) {
    idevice_info_t *devs = NULL; int count = 0;
    if (idevice_get_device_list_extended(&devs, &count) != IDEVICE_E_SUCCESS) return 0;
    // One row per unique UDID: "udid\tname\tconn". A device can appear twice (USB +
    // Wi-Fi); we prefer the USB entry because dev-mode control + first-time install
    // need USB, and we report conn so the UI can label USB vs Wi-Fi explicitly.
    for (int i = 0; i < count; i++) {
        const char *udid = devs[i]->udid;
        int dup = 0;
        for (int j = 0; j < i; j++) if (!strcmp(devs[j]->udid, udid)) { dup = 1; break; }
        if (dup) continue;
        int usb = 0, wifi = 0;
        for (int j = 0; j < count; j++) if (!strcmp(devs[j]->udid, udid)) {
            if (devs[j]->conn_type == CONNECTION_USBMUXD) usb = 1;
            else if (devs[j]->conn_type == CONNECTION_NETWORK) wifi = 1;
        }
        const char *conn = usb ? "usb" : (wifi ? "wifi" : "usb");
        char *name = NULL;
        idevice_t d = connect_dev(udid);
        lockdownd_client_t ld = NULL;
        if (d && lockdownd_client_new_with_handshake(d, &ld, "sidestep") == LOCKDOWN_E_SUCCESS) {
            plist_t v = NULL;
            if (lockdownd_get_value(ld, NULL, "DeviceName", &v) == LOCKDOWN_E_SUCCESS && v) {
                plist_get_string_val(v, &name);
                plist_free(v);
            }
            lockdownd_client_free(ld);
        }
        // Leave the name column EMPTY when lockdown wouldn't give us DeviceName (e.g. a
        // Wi-Fi device that isn't trust-paired right now) — never echo the UDID as a
        // name, or the UI ends up showing a 40-hex blob instead of "iPad".
        printf("%s\t%s\t%s\n", udid, name ? name : "", conn);
        free(name);
        if (d) idevice_free(d);
    }
    idevice_device_list_extended_free(devs);
    return 0;
}

static int cmd_uninstall(const char *udid, const char *bid) {
    idevice_t d = connect_dev(udid);
    if (!d) { printf(">>> UNINSTALL FAILED: no device\n"); return 2; }
    lockdownd_client_t ld = NULL;
    lockdownd_client_new_with_handshake(d, &ld, "sidestep");
    lockdownd_service_descriptor_t svc = NULL;
    lockdownd_start_service(ld, "com.apple.mobile.installation_proxy", &svc);
    instproxy_client_t ip = NULL;
    instproxy_client_new(d, svc, &ip);
    // SYNC (callback == NULL): like instproxy_install, instproxy_uninstall is ASYNC
    // when given a status callback — it returns 0 immediately and the helper exits
    // before installd finishes, a false "OK". NULL runs it synchronously and returns
    // the real result.
    instproxy_error_t e = instproxy_uninstall(ip, bid, NULL, NULL, NULL);
    if (e == INSTPROXY_E_SUCCESS && !g_err) { printf(">>> UNINSTALL OK <<<\n"); return 0; }
    printf(">>> UNINSTALL FAILED: %s (%d)\n", g_errmsg, e);
    return 3;
}

static int cmd_install(const char *udid, const char *ipa, const char *expect_bid) {
    idevice_t d = connect_dev(udid);
    if (!d) { printf(">>> INSTALL FAILED: no device\n"); return 2; }
    lockdownd_client_t ld = NULL;
    if (lockdownd_client_new_with_handshake(d, &ld, "sidestep") != LOCKDOWN_E_SUCCESS) {
        printf(">>> INSTALL FAILED: lockdown handshake\n"); return 2;
    }
    // upload the .ipa into PublicStaging via AFC
    lockdownd_service_descriptor_t afcsvc = NULL;
    if (lockdownd_start_service(ld, "com.apple.afc", &afcsvc) != LOCKDOWN_E_SUCCESS) {
        printf(">>> INSTALL FAILED: could not start AFC\n"); return 2;
    }
    afc_client_t afc = NULL;
    if (afc_client_new(d, afcsvc, &afc) != AFC_E_SUCCESS) { printf(">>> INSTALL FAILED: afc client\n"); return 2; }
    afc_make_directory(afc, "PublicStaging");
    const char *remote = "PublicStaging/sidestep.ipa";
    uint64_t h = 0;
    if (afc_file_open(afc, remote, AFC_FOPEN_WRONLY, &h) != AFC_E_SUCCESS) {
        printf(">>> INSTALL FAILED: afc open\n"); return 2;
    }
    FILE *f = fopen(ipa, "rb");
    if (!f) { printf(">>> INSTALL FAILED: cannot read ipa\n"); return 2; }
    // Total size so we can report upload progress (the AFC copy is often the slow part).
    long long total = 0;
    if (fseek(f, 0, SEEK_END) == 0) { total = ftello(f); fseek(f, 0, SEEK_SET); }
    long long uploaded = 0; int last_pct = -1;
    char buf[131072]; size_t r;
    while ((r = fread(buf, 1, sizeof(buf), f)) > 0) {
        uint32_t off = 0;
        while (off < r) {
            uint32_t wr = 0;
            if (afc_file_write(afc, h, buf + off, (uint32_t)(r - off), &wr) != AFC_E_SUCCESS || wr == 0) {
                fclose(f); printf(">>> INSTALL FAILED: afc write\n"); return 2;
            }
            off += wr;
        }
        uploaded += (long long)r;
        if (total > 0) {
            int pct = (int)(uploaded * 100 / total);
            if (pct != last_pct) { last_pct = pct; printf(">>> PROGRESS %d Uploading\n", pct); fflush(stdout); }
        }
    }
    fclose(f);
    afc_file_close(afc, h);
    afc_client_free(afc);
    // install what we uploaded
    lockdownd_service_descriptor_t ipsvc = NULL;
    lockdownd_start_service(ld, "com.apple.mobile.installation_proxy", &ipsvc);
    instproxy_client_t ip = NULL;
    instproxy_client_new(d, ipsvc, &ip);
    plist_t opts = instproxy_client_options_new();
    // ASYNC + WAIT. instproxy_install is SYNC only with a NULL callback, but the sync
    // path returns just a numeric code — installd's real error text ("APIInternalError:
    // <why>", "ApplicationVerificationFailed: …") only reaches us through the status
    // callback. So we pass status_cb (to capture that text + on-device install %) and
    // then WAIT for it to signal a terminal state. Without the wait, instproxy_install
    // returns immediately after dispatching its status thread and the process would exit
    // mid-install, so installd aborts it (the old false-"OK"). The wait is bounded so a
    // silent installd can't hang us; the 300s ProcessWatchdog on the Mac side is the
    // outer backstop.
    g_err = 0; g_done = 0;
    instproxy_error_t e = instproxy_install(ip, remote, opts, status_cb, NULL);
    instproxy_client_options_free(opts);
    if (e != INSTPROXY_E_SUCCESS) { instproxy_client_free(ip); printf(">>> INSTALL FAILED: could not start install (%d)\n", e); return 3; }
    for (int ms = 0; !g_done && ms < 240000; ms += 50) usleep(50 * 1000);   // ≤4 min
    if (!(g_done && !g_err)) {
        instproxy_client_free(ip);   // joins the status thread cleanly
        printf(">>> INSTALL FAILED: %s\n", g_errmsg[0] ? g_errmsg : "no completion from installd (timed out)");
        return 3;
    }
    // Ground-truth verify on the still-open client: installd must actually list the bundle
    // now. instproxy's own "Complete" is not proof the app landed — that same claim is what
    // lied during the false-OK bug — so confirm against installd's app list (the oracle)
    // before reporting OK, which is what the Mac side keys the tracked-app record on. No
    // expected id passed → skip, staying backward-compatible.
    if (expect_bid && expect_bid[0]) {
        plist_t bopts = instproxy_client_options_new();
        instproxy_client_options_add(bopts, "ApplicationType", "User", NULL);
        plist_t apps = NULL;
        instproxy_error_t be = instproxy_browse(ip, bopts, &apps);
        instproxy_client_options_free(bopts);
        int present = 0;
        if (be == INSTPROXY_E_SUCCESS && apps) {
            uint32_t n = plist_array_get_size(apps);
            for (uint32_t i = 0; i < n; i++) {
                plist_t app = plist_array_get_item(apps, i);
                plist_t p = plist_dict_get_item(app, "CFBundleIdentifier");
                char *b = NULL; if (p) plist_get_string_val(p, &b);
                if (b && !strcmp(b, expect_bid)) present = 1;
                if (b) free(b);
                if (present) break;
            }
        }
        if (apps) plist_free(apps);
        if (!present) {
            instproxy_client_free(ip);
            printf(">>> INSTALL FAILED: %s not present on device after install (Developer Mode off, or install rejected)\n", expect_bid);
            return 3;
        }
    }
    instproxy_client_free(ip);
    printf(">>> INSTALL OK <<<\n");
    return 0;
}

// installd's ground-truth list of installed USER apps. This is the oracle the
// regression suite asserts against — never SideStep's own "INSTALL OK" claim, which
// is exactly what lied during the false-OK bug. Output: one TAB-separated line per app
// (bundleID<TAB>shortVersion<TAB>buildVersion<TAB>name), then ">>> APPS OK <n> <<<".
static int browse_apps(const char *udid, plist_t *out) {
    idevice_t d = connect_dev(udid);
    if (!d) { printf(">>> APPS FAILED: no device\n"); return 2; }
    lockdownd_client_t ld = NULL;
    if (lockdownd_client_new_with_handshake(d, &ld, "sidestep") != LOCKDOWN_E_SUCCESS) { printf(">>> APPS FAILED: lockdown handshake\n"); return 2; }
    lockdownd_service_descriptor_t svc = NULL;
    if (lockdownd_start_service(ld, "com.apple.mobile.installation_proxy", &svc) != LOCKDOWN_E_SUCCESS) { printf(">>> APPS FAILED: start installation_proxy\n"); return 2; }
    instproxy_client_t ip = NULL;
    if (instproxy_client_new(d, svc, &ip) != INSTPROXY_E_SUCCESS) { printf(">>> APPS FAILED: instproxy client\n"); return 2; }
    plist_t opts = instproxy_client_options_new();
    instproxy_client_options_add(opts, "ApplicationType", "User", NULL);
    instproxy_error_t e = instproxy_browse(ip, opts, out);
    instproxy_client_options_free(opts);
    if (e != INSTPROXY_E_SUCCESS || !*out) { printf(">>> APPS FAILED: browse (%d)\n", e); return 3; }
    return 0;
}
static char *dict_str(plist_t app, const char *key) {
    plist_t p = plist_dict_get_item(app, key);
    if (!p) return NULL;
    char *v = NULL; plist_get_string_val(p, &v); return v;
}
static int cmd_apps(const char *udid) {
    plist_t apps = NULL;
    int rc = browse_apps(udid, &apps); if (rc) return rc;
    uint32_t n = plist_array_get_size(apps);
    for (uint32_t i = 0; i < n; i++) {
        plist_t app = plist_array_get_item(apps, i);
        char *bid = dict_str(app, "CFBundleIdentifier"), *sv = dict_str(app, "CFBundleShortVersionString"),
             *bv = dict_str(app, "CFBundleVersion"), *nm = dict_str(app, "CFBundleName");
        printf("%s\t%s\t%s\t%s\n", bid?bid:"", sv?sv:"", bv?bv:"", nm?nm:"");
        free(bid); free(sv); free(bv); free(nm);
    }
    plist_free(apps);
    printf(">>> APPS OK %u <<<\n", n);
    return 0;
}
static int cmd_appinfo(const char *udid, const char *bid) {
    plist_t apps = NULL;
    int rc = browse_apps(udid, &apps); if (rc) return rc;
    uint32_t n = plist_array_get_size(apps);
    for (uint32_t i = 0; i < n; i++) {
        plist_t app = plist_array_get_item(apps, i);
        char *b = dict_str(app, "CFBundleIdentifier");
        if (b && !strcmp(b, bid)) {
            char *sv = dict_str(app, "CFBundleShortVersionString"), *bv = dict_str(app, "CFBundleVersion"), *nm = dict_str(app, "CFBundleName");
            printf("%s\t%s\t%s\t%s\n", b, sv?sv:"", bv?bv:"", nm?nm:"");
            printf(">>> APPINFO OK <<<\n");
            free(b); free(sv); free(bv); free(nm); plist_free(apps); return 0;
        }
        free(b);
    }
    plist_free(apps);
    printf("%s\t(not installed)\n>>> APPINFO ABSENT <<<\n", bid);
    return 1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "list")) return cmd_list();
    if (argc >= 4 && !strcmp(argv[1], "install")) return cmd_install(argv[2], argv[3], argc >= 5 ? argv[4] : NULL);
    if (argc >= 4 && !strcmp(argv[1], "uninstall")) return cmd_uninstall(argv[2], argv[3]);
    if (argc >= 3 && !strcmp(argv[1], "apps")) return cmd_apps(argv[2]);
    if (argc >= 4 && !strcmp(argv[1], "appinfo")) return cmd_appinfo(argv[2], argv[3]);
    fprintf(stderr, "usage: idevicehelper list | install <udid> <ipa> | uninstall <udid> <bundleid> | apps <udid> | appinfo <udid> <bundleid>\n");
    return 64;
}

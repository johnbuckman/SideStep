// idevicehelper — minimal device ops for SideStep, built on libimobiledevice.
// Replaces the pymobiledevice3 python helpers. No libzip needed.
//   idevicehelper list
//   idevicehelper install   <udid> <ipa>
//   idevicehelper uninstall <udid> <bundleid>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/installation_proxy.h>

static int g_err = 0;
static char g_errmsg[512];

static void status_cb(plist_t command, plist_t status, void *udata) {
    char *nm = NULL, *ds = NULL; uint64_t code = 0;
    instproxy_status_get_error(status, &nm, &ds, &code);
    if (nm) {
        g_err = 1;
        snprintf(g_errmsg, sizeof(g_errmsg), "%s%s%s", nm, ds ? ": " : "", ds ? ds : "");
    }
    free(nm); free(ds);
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
        printf("%s\t%s\t%s\n", udid, name ? name : udid, conn);
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
    instproxy_error_t e = instproxy_uninstall(ip, bid, NULL, status_cb, NULL);
    if (e == INSTPROXY_E_SUCCESS && !g_err) { printf(">>> UNINSTALL OK <<<\n"); return 0; }
    printf(">>> UNINSTALL FAILED: %s (%d)\n", g_errmsg, e);
    return 3;
}

static int cmd_install(const char *udid, const char *ipa) {
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
    instproxy_error_t e = instproxy_install(ip, remote, opts, status_cb, NULL);
    instproxy_client_options_free(opts);
    if (e == INSTPROXY_E_SUCCESS && !g_err) { printf(">>> INSTALL OK <<<\n"); return 0; }
    printf(">>> INSTALL FAILED: %s (%d)\n", g_errmsg, e);
    return 3;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "list")) return cmd_list();
    if (argc >= 4 && !strcmp(argv[1], "install")) return cmd_install(argv[2], argv[3]);
    if (argc >= 4 && !strcmp(argv[1], "uninstall")) return cmd_uninstall(argv[2], argv[3]);
    fprintf(stderr, "usage: idevicehelper list | install <udid> <ipa> | uninstall <udid> <bundleid>\n");
    return 64;
}

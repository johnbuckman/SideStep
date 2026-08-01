// Enable the device's "Show this device when on Wi-Fi" (lockdown
// EnableWifiConnections) over a USB trusted session, so future beacon /
// direct-IP installs can open a trusted Wi-Fi session. Idempotent, and it
// READS THE VALUE BACK to confirm the change actually took. Output contract:
//   >>> WIFI-SYNC OK ...     already on, or set + verified on   (exit 0)
//   >>> WIFI-SYNC MANUAL ... couldn't set/verify -> user must do it by hand (exit 3)
//   >>> WIFI-SYNC SKIP ...   no USB device / no handshake -> not applicable (exit 2)
#include <stdio.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
static uint8_t readWifi(lockdownd_client_t ld){
    plist_t v=0; uint8_t b=0;
    if(lockdownd_get_value(ld,"com.apple.mobile.wireless_lockdown","EnableWifiConnections",&v)==0
       && v && plist_get_node_type(v)==PLIST_BOOLEAN) plist_get_bool_val(v,&b);
    if(v) plist_free(v);
    return b;
}
int main(int argc, char** argv){
    if(argc<2){ fprintf(stderr,"usage: %s <udid>\n",argv[0]); return 64; }
    idevice_t d=0;
    if(idevice_new(&d, argv[1])!=IDEVICE_E_SUCCESS || !d){ printf(">>> WIFI-SYNC SKIP: no USB device\n"); return 2; }
    lockdownd_client_t ld=0;
    if(lockdownd_client_new_with_handshake(d,&ld,"SideStep-wifienable")!=0){ printf(">>> WIFI-SYNC SKIP: no handshake\n"); return 2; }
    if(readWifi(ld)){ printf(">>> WIFI-SYNC OK (already on)\n"); return 0; }
    lockdownd_error_t e=lockdownd_set_value(ld,"com.apple.mobile.wireless_lockdown","EnableWifiConnections",plist_new_bool(1));
    // Verify by reading it back — a 0 return from set isn't proof it stuck.
    if(readWifi(ld)){ printf(">>> WIFI-SYNC OK (enabled)\n"); return 0; }
    printf(">>> WIFI-SYNC MANUAL: could not enable automatically (set err %d)\n", e);
    return 3;
}

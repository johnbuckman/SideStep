// Enable (or read) "Show this iPad when on Wi-Fi" == wireless_lockdown
// EnableWifiConnections, over USB, so SideStep can turn it on itself during the
// first cabled install and the user never has to open Finder.
//   idevice_setwifi <udid> [0|1]      no value = just read current state
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef void* idevice_t;
typedef void* lockdownd_client_t;
typedef void* plist_t;
extern int  idevice_new_with_options(idevice_t*, const char*, int);
extern int  idevice_free(idevice_t);
extern int  lockdownd_client_new_with_handshake(idevice_t, lockdownd_client_t*, const char*);
extern int  lockdownd_set_value(lockdownd_client_t, const char*, const char*, plist_t);
extern int  lockdownd_get_value(lockdownd_client_t, const char*, const char*, plist_t*);
extern int  lockdownd_client_free(lockdownd_client_t);
extern plist_t plist_new_bool(int);
extern void plist_get_bool_val(plist_t, uint8_t*);
extern void plist_free(plist_t);
#define IDEVICE_LOOKUP_USBMUX 2
#define DOMAIN "com.apple.mobile.wireless_lockdown"
#define KEY    "EnableWifiConnections"

static int readbool(lockdownd_client_t ld){
    plist_t v=0; uint8_t b=2;
    if(lockdownd_get_value(ld,DOMAIN,KEY,&v)==0 && v){ plist_get_bool_val(v,&b); plist_free(v); }
    return b;
}

int main(int argc,char**argv){
    if(argc<2){ fprintf(stderr,"usage: %s <udid> [0|1]\n",argv[0]); return 64; }
    const char* udid=argv[1];
    idevice_t d=0;
    if(idevice_new_with_options(&d,udid,IDEVICE_LOOKUP_USBMUX)!=0||!d){ printf(">>> FAIL: device not on USB\n"); return 2; }
    lockdownd_client_t ld=0;
    if(lockdownd_client_new_with_handshake(d,&ld,"SideStep-setwifi")!=0){ printf(">>> FAIL: lockdown handshake\n"); return 2; }
    printf("EnableWifiConnections (before): %d\n", readbool(ld));
    if(argc>=3){
        int want = atoi(argv[2]) ? 1 : 0;
        int rc = lockdownd_set_value(ld,DOMAIN,KEY, plist_new_bool(want));
        printf("set -> %d : %s\n", want, rc==0?"OK":"FAILED");
        printf("EnableWifiConnections (after):  %d\n", readbool(ld));
    }
    lockdownd_client_free(ld); idevice_free(d);
    return 0;
}

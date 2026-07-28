// Probe a device at an IP by direct connection (no mDNS): is it reachable, and is
// it unlocked? Identity is confirmed by the stored pair record for <udid>.
//   idevice_ipprobe <udid> <ip>
// Prints one line:  <ip>\t<REACHABLE|UNREACHABLE>\t<UNLOCKED|LOCKED|-> \t<DeviceName|->
// Exit 0 = reachable+unlocked, 1 = reachable+locked, 2 = unreachable.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef void* idevice_t;
typedef void* lockdownd_client_t;
typedef void* lockdownd_service_descriptor_t;
typedef void* afc_client_t;
typedef void* plist_t;

extern int  idevice_new_network(idevice_t*, const char*, const char*);
extern int  idevice_free(idevice_t);
extern void idevice_set_debug_level(int);
extern int  lockdownd_client_new_with_handshake(idevice_t, lockdownd_client_t*, const char*);
extern int  lockdownd_start_service(lockdownd_client_t, const char*, lockdownd_service_descriptor_t*);
extern int  lockdownd_get_value(lockdownd_client_t, const char*, const char*, plist_t*);
extern int  lockdownd_client_free(lockdownd_client_t);
extern int  afc_client_new(idevice_t, lockdownd_service_descriptor_t, afc_client_t*);
extern int  afc_read_directory(afc_client_t, const char*, char***);
extern int  afc_client_free(afc_client_t);
extern void plist_get_string_val(plist_t, char**);
extern void plist_free(plist_t);

int main(int argc, char** argv){
    if(argc<3){ fprintf(stderr,"usage: %s <udid> <ip>\n",argv[0]); return 64; }
    const char *udid=argv[1], *ip=argv[2];
    if(getenv("IPDBG")) idevice_set_debug_level(1);
    idevice_t d=0;
    if(idevice_new_network(&d,udid,ip)!=0||!d){ printf("%s\tUNREACHABLE\t-\t-\n",ip); return 2; }
    lockdownd_client_t ld=0;
    if(lockdownd_client_new_with_handshake(d,&ld,"SideStep-probe")!=0){ printf("%s\tUNREACHABLE\t-\t-\n",ip); return 2; }
    // device name (best-effort; may be prohibited while locked)
    char* name=NULL; plist_t v=NULL;
    if(lockdownd_get_value(ld,NULL,"DeviceName",&v)==0 && v){ plist_get_string_val(v,&name); plist_free(v); }
    // unlock test: AFC service must actually serve a directory listing (fails when locked)
    lockdownd_service_descriptor_t afcsvc=0; int unlocked=0;
    if(lockdownd_start_service(ld,"com.apple.afc",&afcsvc)==0){
        afc_client_t afc=0;
        if(afc_client_new(d,afcsvc,&afc)==0){
            char** list=NULL;
            if(afc_read_directory(afc,".",&list)==0){ unlocked=1; if(list){ for(int i=0;list[i];i++) free(list[i]); free(list);} }
            afc_client_free(afc);
        }
    }
    printf("%s\tREACHABLE\t%s\t%s\n", ip, unlocked?"UNLOCKED":"LOCKED", name?name:"-");
    lockdownd_client_free(ld); idevice_free(d);
    return unlocked?0:1;
}

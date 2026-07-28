// One-off validation tool: install an .ipa over a FORCED transport (network-only,
// usb-only, or both) to prove whether a WiFi install completes on iOS 26.
// Links the bundled libimobiledevice via forward-declared ABI (no headers needed).
//   idevice_netinstall <udid> <ipa> [net|usb|both]      default: net
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef void* idevice_t;
typedef void* lockdownd_client_t;
typedef void* lockdownd_service_descriptor_t;
typedef void* afc_client_t;
typedef void* instproxy_client_t;
typedef void* plist_t;
typedef void (*instproxy_status_cb_t)(plist_t, plist_t, void*);

extern int  idevice_new_with_options(idevice_t*, const char*, int);
extern int  idevice_free(idevice_t);
extern int  lockdownd_client_new_with_handshake(idevice_t, lockdownd_client_t*, const char*);
extern int  lockdownd_start_service(lockdownd_client_t, const char*, lockdownd_service_descriptor_t*);
extern int  lockdownd_client_free(lockdownd_client_t);
extern int  afc_client_new(idevice_t, lockdownd_service_descriptor_t, afc_client_t*);
extern int  afc_make_directory(afc_client_t, const char*);
extern int  afc_file_open(afc_client_t, const char*, int, uint64_t*);
extern int  afc_file_write(afc_client_t, uint64_t, const char*, uint32_t, uint32_t*);
extern int  afc_file_close(afc_client_t, uint64_t);
extern int  afc_client_free(afc_client_t);
extern int  instproxy_client_new(idevice_t, lockdownd_service_descriptor_t, instproxy_client_t*);
extern plist_t instproxy_client_options_new(void);
extern int  instproxy_install(instproxy_client_t, const char*, plist_t, instproxy_status_cb_t, void*);
extern void instproxy_client_options_free(plist_t);
extern void instproxy_status_get_error(plist_t, char**, char**, uint64_t*);

#define IDEVICE_LOOKUP_USBMUX  (1<<1)   // 2
#define IDEVICE_LOOKUP_NETWORK (1<<2)   // 4
#define AFC_FOPEN_WRONLY       3

static int g_err = 0; static char g_msg[512];
static void cb(plist_t command, plist_t status, void* u) {
    char *n=0,*d=0; uint64_t c=0;
    instproxy_status_get_error(status,&n,&d,&c);
    if (n) { g_err=1; snprintf(g_msg,sizeof g_msg,"%s%s%s",n,d?": ":"",d?d:""); }
    if (n) free(n); if (d) free(d);
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr,"usage: %s <udid> <ipa> [net|usb|both]\n",argv[0]); return 64; }
    const char *udid=argv[1], *ipa=argv[2];
    int opt = IDEVICE_LOOKUP_NETWORK; const char* mode="NETWORK";
    if (argc>=4) {
        if (!strcmp(argv[3],"usb"))  { opt=IDEVICE_LOOKUP_USBMUX; mode="USB"; }
        else if (!strcmp(argv[3],"both")) { opt=IDEVICE_LOOKUP_USBMUX|IDEVICE_LOOKUP_NETWORK; mode="BOTH"; }
    }
    fprintf(stderr,"[transport = %s]\n",mode);
    idevice_t d=0;
    if (idevice_new_with_options(&d,udid,opt)!=0 || !d) { printf(">>> FAIL: device not reachable over %s\n",mode); return 2; }
    lockdownd_client_t ld=0;
    if (lockdownd_client_new_with_handshake(d,&ld,"SideStep-nettest")!=0) { printf(">>> FAIL: lockdown handshake over %s\n",mode); return 2; }
    lockdownd_service_descriptor_t afcsvc=0;
    if (lockdownd_start_service(ld,"com.apple.afc",&afcsvc)!=0) { printf(">>> FAIL: start afc\n"); return 2; }
    afc_client_t afc=0;
    if (afc_client_new(d,afcsvc,&afc)!=0) { printf(">>> FAIL: afc client\n"); return 2; }
    afc_make_directory(afc,"PublicStaging");
    const char* remote="PublicStaging/sidestep-nettest.ipa";
    uint64_t h=0;
    if (afc_file_open(afc,remote,AFC_FOPEN_WRONLY,&h)!=0) { printf(">>> FAIL: afc open\n"); return 2; }
    FILE* f=fopen(ipa,"rb"); if(!f){ printf(">>> FAIL: cannot read ipa\n"); return 2; }
    char buf[131072]; size_t r; uint64_t total=0;
    while ((r=fread(buf,1,sizeof buf,f))>0) {
        uint32_t off=0;
        while (off<r) { uint32_t wr=0;
            if (afc_file_write(afc,h,buf+off,(uint32_t)(r-off),&wr)!=0 || wr==0) { fclose(f); printf(">>> FAIL: afc write at %llu bytes\n",(unsigned long long)total); return 2; }
            off+=wr; total+=wr;
        }
    }
    fclose(f); afc_file_close(afc,h); afc_client_free(afc);
    fprintf(stderr,"uploaded %llu bytes over %s; installing...\n",(unsigned long long)total,mode);
    lockdownd_service_descriptor_t ipsvc=0;
    lockdownd_start_service(ld,"com.apple.mobile.installation_proxy",&ipsvc);
    instproxy_client_t ip=0; instproxy_client_new(d,ipsvc,&ip);
    plist_t opts=instproxy_client_options_new();
    int e=instproxy_install(ip,remote,opts,cb,0);
    instproxy_client_options_free(opts);
    lockdownd_client_free(ld); idevice_free(d);
    if (e==0 && !g_err) { printf(">>> %s INSTALL OK <<<\n",mode); return 0; }
    printf(">>> %s INSTALL FAILED: %s (%d)\n",mode,g_msg,e);
    return 3;
}

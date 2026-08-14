// Install an .ipa to a device by its IP address DIRECTLY, bypassing usbmuxd's
// Bonjour/mDNS discovery (which fails on mesh Wi-Fi that blocks multicast).
// libimobiledevice already talks to network devices by connecting to a stored
// sockaddr; we just hand-build that idevice_t ourselves and point it at the IP.
// The pairing record is still read from usbmuxd (/var/db/lockdown/<udid>.plist),
// so the SSL handshake works without the device being "discovered".
//   idevice_ipinstall <udid> <ip> <ipa>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
struct lockdownd_service_descriptor { uint16_t port; uint8_t ssl_enabled; char* identifier; };

// Mirror of libimobiledevice src/idevice.h `struct idevice_private` (stable layout).
struct idevice_private { char *udid; uint32_t mux_id; int conn_type; void *conn_data; int version; int device_class; };
typedef struct idevice_private* idevice_t;
#define CONNECTION_NETWORK 2

typedef void* lockdownd_client_t;
typedef void* lockdownd_service_descriptor_t;
typedef void* afc_client_t;
typedef void* instproxy_client_t;
typedef void* plist_t;
typedef void (*instproxy_status_cb_t)(plist_t,plist_t,void*);
typedef void* heartbeat_client_t;
extern int  heartbeat_client_new(idevice_t, lockdownd_service_descriptor_t, heartbeat_client_t*);
extern int  heartbeat_receive_with_timeout(heartbeat_client_t, plist_t*, uint32_t);
extern int  heartbeat_send(heartbeat_client_t, plist_t);
extern plist_t plist_new_dict(void);
extern void plist_dict_set_item(plist_t, const char*, plist_t);
extern plist_t plist_new_string(const char*);
extern void plist_free(plist_t);

/* iOS tears down NETWORK service connections unless the host answers the
   device's heartbeat Marco pings with Polo. Without this, AFC gets an active
   TCP RST right after its SSL handshake (looks like a firewall/lock problem,
   but it is the device). Not needed over USB. */
static heartbeat_client_t g_hb = NULL;
static volatile int g_hb_run = 1;
static void* hb_thread(void* a){
    (void)a;
    while (g_hb_run) {
        // Parent-death guard: if SideStep (our parent) quits, crashes, or is force-
        // killed mid-install, this process is reparented to launchd (ppid==1). Left
        // alive it keeps answering the device heartbeat and holds the AFC/instproxy
        // session open, wedging the NEXT SideStep session's install of this device.
        // macOS has no PDEATHSIG, so poll ppid here (loop runs every ≤15s / 200ms) and
        // self-exit promptly when orphaned, releasing the device.
        if (getppid() == 1) _exit(1);
        plist_t ping = NULL;
        if (heartbeat_receive_with_timeout(g_hb, &ping, 15000) != 0) { usleep(200000); continue; }
        plist_t polo = plist_new_dict();
        plist_dict_set_item(polo, "Command", plist_new_string("Polo"));
        heartbeat_send(g_hb, polo);
        plist_free(polo);
        if (ping) plist_free(ping);
    }
    return NULL;
}

extern void idevice_set_debug_level(int);
extern int  idevice_new_network(idevice_t*, const char*, const char*);
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
extern void instproxy_status_get_name(plist_t, char**);
extern void instproxy_status_get_percent_complete(plist_t, int*);
extern void instproxy_client_options_add(plist_t, ...);
extern int  instproxy_browse(instproxy_client_t, plist_t, plist_t*);
extern int  instproxy_client_free(instproxy_client_t);
extern uint32_t plist_array_get_size(plist_t);
extern plist_t  plist_array_get_item(plist_t, uint32_t);
extern plist_t  plist_dict_get_item(plist_t, const char*);
extern void     plist_get_string_val(plist_t, char**);

#define AFC_FOPEN_WRONLY 3
static int g_err=0; static char g_msg[512]; static volatile int g_done=0;
// installation_proxy delivers status on a background thread while the install runs.
// Capture installd's real error text (so a dev-mode-off / bad-profile rejection is
// actionable, not a bare code), emit on-device install %, and flag terminal completion
// so main() can WAIT for the true end of the operation instead of trusting the call's
// immediate return. Mirrors idevicehelper.c's status_cb.
static void status_cb(plist_t c, plist_t s, void* u){
    (void)c; (void)u;
    char*n=0,*d=0; uint64_t cc=0; instproxy_status_get_error(s,&n,&d,&cc);
    if(n){ g_err=1; snprintf(g_msg,sizeof g_msg,"%s%s%s",n,d?": ":"",d?d:""); free(n); if(d)free(d); g_done=1; return; }
    if(d) free(d);
    int pct=-1; instproxy_status_get_percent_complete(s,&pct);
    if(pct>=0){ printf(">>> PROGRESS %d Installing\n",pct); fflush(stdout); }
    char* st=0; instproxy_status_get_name(s,&st);
    if(st){ if(!strcmp(st,"Complete")) g_done=1; free(st); }
}

int main(int argc, char** argv){
    if(argc<4){ fprintf(stderr,"usage: %s <udid> <ip> <ipa> [expected-bundle-id]\n",argv[0]); return 64; }
    const char *udid=argv[1], *ip=argv[2], *ipa=argv[3];
    // Optional 4th arg: the bundle id we expect to be installed. When present, we verify
    // it against installd's own app list before reporting OK (ground-truth, not our claim).
    const char *expect_bid=(argc>=5)?argv[4]:0;
    if(getenv("IPDBG")) idevice_set_debug_level(1);
    idevice_t d=0;
    if(idevice_new_network(&d, udid, ip)!=0 || !d){ printf(">>> FAIL: idevice_new_network\n"); return 2; }

    fprintf(stderr,"[direct-IP  udid=%s  ip=%s]\n", udid, ip);
    lockdownd_client_t ld=0;
    int e = lockdownd_client_new_with_handshake(d, &ld, "SideStep-ipinstall");
    if(e!=0){ printf(">>> FAIL: lockdown handshake by IP (err %d) — device unreachable/locked or no pair record\n", e); return 2; }
    lockdownd_service_descriptor_t hbsvc=0;
    if(lockdownd_start_service(ld,"com.apple.mobile.heartbeat",&hbsvc)==0 &&
       heartbeat_client_new(d,hbsvc,&g_hb)==0){
        pthread_t t; pthread_create(&t,NULL,hb_thread,NULL); pthread_detach(t);
        sleep(1);
        fprintf(stderr,"[heartbeat running]\n");
    } else {
        fprintf(stderr,"[WARN: no heartbeat — AFC will likely be reset]\n");
    }
    lockdownd_service_descriptor_t afcsvc=0;
    if(lockdownd_start_service(ld,"com.apple.afc",&afcsvc)!=0){ printf(">>> FAIL: start afc\n"); return 2; }
    afc_client_t afc=0;
    if(afc_client_new(d,afcsvc,&afc)!=0){ printf(">>> FAIL: afc client\n"); return 2; }
    int mkd=afc_make_directory(afc,"PublicStaging");
    const char* remote="PublicStaging/sidestep-ip.ipa";
    uint64_t h=0;
    int oe=afc_file_open(afc,remote,AFC_FOPEN_WRONLY,&h);
    if(oe!=0){ printf(">>> FAIL: afc open (mkdir=%d open=%d)  [afc err 8=perm/locked, 4=obj-not-found]\n",mkd,oe); return 2; }
    FILE* f=fopen(ipa,"rb"); if(!f){ printf(">>> FAIL: cannot read ipa\n"); return 2; }
    fseek(f,0,SEEK_END); long fsz=ftell(f); fseek(f,0,SEEK_SET);
    // 1 MB chunks: each afc_file_write is one SSL round-trip, so bigger chunks
    // cut round-trips ~8x — important on high-latency Wi-Fi/mesh links.
    static char buf[1048576]; size_t r; uint64_t total=0, lastEmit=0;
    printf("PROGRESS 0 %ld\n", fsz); fflush(stdout);
    while((r=fread(buf,1,sizeof buf,f))>0){ uint32_t off=0; while(off<r){ uint32_t wr=0;
        if(afc_file_write(afc,h,buf+off,(uint32_t)(r-off),&wr)!=0||wr==0){ fclose(f); printf(">>> FAIL: afc write @%llu bytes\n",(unsigned long long)total); return 2; }
        off+=wr; total+=wr; }
        if(total-lastEmit >= 262144){ printf("PROGRESS %llu %ld\n",(unsigned long long)total,fsz); fflush(stdout); lastEmit=total; } }
    printf("PROGRESS %llu %ld\n",(unsigned long long)total,fsz); fflush(stdout);
    fclose(f); afc_file_close(afc,h); afc_client_free(afc);
    fprintf(stderr,"uploaded %llu bytes by IP; installing...\n",(unsigned long long)total);
    lockdownd_service_descriptor_t ipsvc=0;
    lockdownd_start_service(ld,"com.apple.mobile.installation_proxy",&ipsvc);
    instproxy_client_t ipc=0; instproxy_client_new(d,ipsvc,&ipc);
    plist_t opts=instproxy_client_options_new();
    /* ASYNC + WAIT (mirrors idevicehelper.c). The old code called this SYNC (NULL
       callback) believing that avoided a false "OK" — but over a NETWORK connection the
       sync call itself returned 0 for installs installd later aborted (dev-mode-off, or
       the connection torn down mid-install): exactly the "device listed as having an app
       it never received" bug. So pass status_cb and WAIT for a terminal state; the OK now
       reflects installd actually finishing, and a rejection arrives as a real FAILED with
       installd's reason. The bounded wait keeps a silent installd from hanging us. */
    g_err=0; g_done=0;
    e=instproxy_install(ipc,remote,opts,status_cb,NULL);
    instproxy_client_options_free(opts);
    if(e!=0){ instproxy_client_free(ipc); lockdownd_client_free(ld); g_hb_run=0;
        printf(">>> DIRECT-IP INSTALL FAILED: could not start install (%d)\n", e); return 3; }
    for(int ms=0; !g_done && ms<240000; ms+=50) usleep(50*1000);   // ≤4 min
    if(!(g_done && !g_err)){
        instproxy_client_free(ipc);   // joins the status thread cleanly
        lockdownd_client_free(ld); g_hb_run=0;
        printf(">>> DIRECT-IP INSTALL FAILED: %s\n", g_msg[0]?g_msg:"no completion from installd (timed out)");
        return 3;
    }
    // Ground-truth verify: instproxy saying "Complete" is NOT enough on its own — that is
    // what lied during the false-OK bug. Ask installd for its actual app list and confirm
    // the bundle is really present before we emit OK (which is what the Mac side keys the
    // tracked-app record on). Heartbeat must stay alive here — this browse rides the same
    // network connection. No expected id passed → skip, staying backward-compatible.
    if(expect_bid && expect_bid[0]){
        plist_t bopts=instproxy_client_options_new();
        instproxy_client_options_add(bopts,"ApplicationType","User",NULL);
        plist_t apps=0; int be=instproxy_browse(ipc,bopts,&apps);
        instproxy_client_options_free(bopts);
        int present=0;
        if(be==0 && apps){
            uint32_t n=plist_array_get_size(apps);
            for(uint32_t i=0;i<n;i++){
                plist_t app=plist_array_get_item(apps,i);
                plist_t p=plist_dict_get_item(app,"CFBundleIdentifier");
                char* b=0; if(p) plist_get_string_val(p,&b);
                if(b && !strcmp(b,expect_bid)) present=1;
                if(b) free(b);
                if(present) break;
            }
        }
        if(apps) plist_free(apps);
        if(!present){
            instproxy_client_free(ipc); lockdownd_client_free(ld); g_hb_run=0;
            printf(">>> DIRECT-IP INSTALL FAILED: %s not present on device after install (Developer Mode off, or install rejected)\n", expect_bid);
            return 3;
        }
    }
    instproxy_client_free(ipc);
    lockdownd_client_free(ld);
    g_hb_run = 0;
    printf(">>> DIRECT-IP INSTALL OK <<<\n");
    return 0;
}

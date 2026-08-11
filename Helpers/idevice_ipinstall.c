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

#define AFC_FOPEN_WRONLY 3
static int g_err=0; static char g_msg[512];
static void cb(plist_t c, plist_t s, void* u){ char*n=0,*d=0; uint64_t cc=0; instproxy_status_get_error(s,&n,&d,&cc); if(n){g_err=1; snprintf(g_msg,sizeof g_msg,"%s%s%s",n,d?": ":"",d?d:"");} if(n)free(n); if(d)free(d); }

int main(int argc, char** argv){
    if(argc<4){ fprintf(stderr,"usage: %s <udid> <ip> <ipa>\n",argv[0]); return 64; }
    const char *udid=argv[1], *ip=argv[2], *ipa=argv[3];
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
    /* SYNC (callback==NULL): instproxy_install is ASYNC when given a status
       callback -- it returns 0 immediately and the process exits, tearing the
       connection down mid-install so installd aborts it (false "OK"). */
    e=instproxy_install(ipc,remote,opts,NULL,0);
    instproxy_client_options_free(opts);
    lockdownd_client_free(ld);
    g_hb_run = 0;
    if(e==0 && !g_err){ printf(">>> DIRECT-IP INSTALL OK <<<\n"); return 0; }
    printf(">>> DIRECT-IP INSTALL FAILED: %s (%d)\n", g_msg, e);
    return 3;
}

// Local implementation of idevice_new_network() so the direct-IP tools can be
// built against the STOCK libimobiledevice (no library patch needed). We hand-
// build a CONNECTION_NETWORK idevice_t pointing at <ip>; libimobiledevice's
// connect path uses socket_connect_addr(saddr, port) with the caller-supplied
// port, so the sockaddr port is irrelevant. The pair record is still looked up
// by UDID via usbmuxd, so the lockdown SSL handshake works with no discovery.
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// Must match src/idevice.h `struct idevice_private` exactly.
struct idevice_private { char *udid; uint32_t mux_id; int conn_type; void *conn_data; int version; int device_class; };

int idevice_new_network(struct idevice_private **out, const char *udid, const char *ip)
{
    if (!out || !udid || !ip) return -1;
    struct idevice_private *d = (struct idevice_private*)calloc(1, sizeof(*d));
    if (!d) return -1;
    d->udid = strdup(udid);
    d->mux_id = 0;
    d->conn_type = 2;        // CONNECTION_NETWORK
    // Pre-set a modern OS version. Over the network, lockdown restricts the
    // pre-SSL ProductVersion read, so the library can't auto-detect it and
    // leaves version=0 -> idevice_connection_enable_ssl() caps AFC's TLS at 1.0
    // -> iOS 16+ rejects it (AFC_E_SSL_ERROR=34). IDEVICE_DEVICE_VERSION(a,b,c)
    // = (a<<16)|(b<<8)|c; anything >= 10.0.0 lifts the cap. Use 17.0.0.
    d->version = (17 << 16);  // 0x110000, >= 10.0.0
    d->device_class = 0;
    struct sockaddr_in *sa = (struct sockaddr_in*)calloc(1, sizeof(*sa));
    if (!sa) { free(d->udid); free(d); return -1; }
    sa->sin_len = sizeof(*sa);
    sa->sin_family = AF_INET;
    sa->sin_port = 0;        // port is supplied per-connection, not from here
    if (inet_pton(AF_INET, ip, &sa->sin_addr) != 1) { free(sa); free(d->udid); free(d); return -1; }
    d->conn_data = sa;
    *out = d;
    return 0;
}

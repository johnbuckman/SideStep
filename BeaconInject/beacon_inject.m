// BeaconInject.dylib — always-on "keep me updated over Wi-Fi" library that
// SideStep injects into every app it installs. One PREBUILT dylib serves any
// app/device: all per-install config is read at RUNTIME from BeaconConfig.plist
// (which SideStep writes into the app bundle), not baked in at compile time.
//
// No user prompt. It continuously (on launch, while in use, on OS background
// wake) checks how old its signing profile is; if older than the update
// interval it fires a UDP beacon so the Mac (SideStep) re-signs and pushes a
// fresh copy — which silently resets the profile clock. It also keeps a local
// notification scheduled warning the user to open the app before the free
// provisioning profile expires (else a USB reinstall is needed).
//
// "Time since last update" needs no stored state: every push mints a new
// provisioning profile, so the profile's CreationDate == last-update time.
//
// A hidden diagnostic gesture (two fingers held in any two of the four screen
// corners for 1.5s) opens a vitals panel + an "Update app now" button.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <UserNotifications/UserNotifications.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <Network/Network.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

#define BG_TASK_ID @"com.sidestep.beacon.refresh"
#define NOTIF_ID   @"com.sidestep.beacon.expiry"

// ---- runtime config (from BeaconConfig.plist in the app bundle) ----
static NSString *g_macIP  = @"";           // SideStep's LAN IP at install time (unicast fallback)
static NSString *g_udid   = @"";           // this device's UDID (so the Mac knows who beacs)
static NSString *g_bundle = @"";           // installed bundle id (so the Mac knows which app)
static int g_port         = 51234;
static int g_updateSec    = 86400;         // beacon if the profile is older than this (24h)
static int g_fgSec        = 1800;          // re-check every 30 min while the app is open

static NSString *g_bonjourIP = nil;        // filled in async by the Bonjour browser
static NSString *g_foundVia = @"";         // how SideStep found this app (repo/url/file)
static BOOL      g_autoUpdates = NO;        // YES = SideStep pushes new versions
static NSDate   *g_lastBeaconAt = nil;
static int       g_beaconCount = 0;
static NSString *g_lastReason = @"(none yet)";
static BOOL      g_localNetStarted = NO;    // gate: local-network access (and its prompt) has begun
static BOOL      g_lnNagShown = NO;         // Local Network refusal card already shown once

static void loadConfig(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"BeaconConfig" ofType:@"plist"];
    NSDictionary *c = p ? [NSDictionary dictionaryWithContentsOfFile:p] : nil;
    if (!c) return;
    if (c[@"mac_ip"])          g_macIP = c[@"mac_ip"];
    if (c[@"udid"])            g_udid = c[@"udid"];
    if (c[@"bundleid"])        g_bundle = c[@"bundleid"];
    if (c[@"port"])            g_port = [c[@"port"] intValue];
    if (c[@"update_interval"]) g_updateSec = [c[@"update_interval"] intValue];
    if (c[@"foreground_check"])g_fgSec = [c[@"foreground_check"] intValue];
    if (c[@"found_via"])       g_foundVia = c[@"found_via"];
    if (c[@"auto_updates"])    g_autoUpdates = [c[@"auto_updates"] boolValue];
    if (g_bundle.length == 0)  g_bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
}

// ---------- provisioning profile dates (no stored state needed) ----------
static NSDictionary *profileDict(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *d = p ? [NSData dataWithContentsOfFile:p] : nil;
    if (!d) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    NSRange a = [s rangeOfString:@"<plist"], b = [s rangeOfString:@"</plist>"];
    if (a.location == NSNotFound || b.location == NSNotFound) return nil;
    NSData *pl = [[s substringWithRange:NSMakeRange(a.location, b.location + b.length - a.location)]
                 dataUsingEncoding:NSISOLatin1StringEncoding];
    id dict = [NSPropertyListSerialization propertyListWithData:pl options:0 format:nil error:nil];
    return [dict isKindOfClass:NSDictionary.class] ? dict : nil;
}
static void profileDates(NSDate **created, NSDate **expires) {
    NSDictionary *d = profileDict();
    *created = d[@"CreationDate"]; *expires = d[@"ExpirationDate"];
}

// ---------- persisted last auto-update attempt + outcome (shown in the popup) ----------
// So that, hours later, the diagnostics popup can answer: did it try? when? and
// if it failed, why. Stored in the app's own NSUserDefaults (survives launches).
static NSString * const kAttemptAt = @"ss_attemptAt";
static NSString * const kAttemptWhy = @"ss_attemptWhy";
static NSString * const kResultAt = @"ss_resultAt";
static NSString * const kResult = @"ss_result";
static NSString * const kResultOK = @"ss_resultOK";
static void recordAttempt(NSString *why) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:[NSDate date] forKey:kAttemptAt];
    [d setObject:(why ?: @"?") forKey:kAttemptWhy];
}
static void recordResult(NSString *text, BOOL ok) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:[NSDate date] forKey:kResultAt];
    [d setObject:(text ?: @"?") forKey:kResult];
    [d setBool:ok forKey:kResultOK];
}

// ---------- send the beacon everywhere we can reach the Mac ----------
static void sendTo(int s, const char *ip, const char *msg, size_t len) {
    if (!ip || !*ip) return;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(g_port);
    if (inet_pton(AF_INET, ip, &a.sin_addr) == 1)
        sendto(s, msg, len, 0, (struct sockaddr *)&a, sizeof a);
}
// Send the beacon out of an existing socket (caller may keep it open to receive
// STATUS replies from the Mac).
static void sendBeaconOn(int s) {
    BOOL unlocked = UIApplication.sharedApplication.isProtectedDataAvailable;
    NSString *m = [NSString stringWithFormat:@"BEACON udid=%@ bundleid=%@ name=%@ unlocked=%d\n",
                   g_udid, g_bundle,
                   [UIDevice.currentDevice.name stringByReplacingOccurrencesOfString:@" " withString:@"_"],
                   unlocked ? 1 : 0];
    const char *msg = m.UTF8String; size_t len = strlen(msg);
    sendTo(s, g_macIP.UTF8String, msg, len);              // 1) baked-in Mac IP
    if (g_bonjourIP) sendTo(s, g_bonjourIP.UTF8String, msg, len); // 2) Bonjour-resolved
    sendTo(s, "255.255.255.255", msg, len);               // 3) limited broadcast
    struct ifaddrs *ifs = NULL;                            // 4) directed broadcast (real netmask)
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *ia = ifs; ia; ia = ia->ifa_next) {
            if (!ia->ifa_addr || ia->ifa_addr->sa_family != AF_INET) continue;
            if (!(ia->ifa_flags & IFF_BROADCAST) || (ia->ifa_flags & IFF_LOOPBACK)) continue;
            uint32_t ip = ((struct sockaddr_in *)ia->ifa_addr)->sin_addr.s_addr;
            uint32_t mask = ((struct sockaddr_in *)ia->ifa_netmask)->sin_addr.s_addr;
            struct in_addr bc; bc.s_addr = (ip & mask) | ~mask;
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &bc, buf, sizeof buf)) sendTo(s, buf, msg, len);
        }
        freeifaddrs(ifs);
    }
    g_lastBeaconAt = [NSDate date];
    g_beaconCount++;
}
static void sendBeacon(void) {   // fire-and-forget (automatic path, no UI)
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return;
    int on = 1; setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, sizeof on);
    sendBeaconOn(s);
    close(s);
}

// Beacon and then listen (~4 min) for the Mac's STATUS / PROGRESS replies on the
// same socket. onStatus + onProgress are dispatched to the main thread.
static void beaconAndTrack(void (^onStatus)(NSString *), void (^onProgress)(int pct, int eta)) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { return; }
    int on = 1; setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, sizeof on);
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    sendBeaconOn(s);
    NSDate *start = [NSDate date]; BOOL sawAny = NO, noReplyRecorded = NO;
    while (-start.timeIntervalSinceNow < 240) {
        char buf[600]; struct sockaddr_in from; socklen_t fl = sizeof from;
        ssize_t n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n > 0) {
            buf[n] = 0;
            if (strncmp(buf, "STATUS ", 7) == 0) {
                sawAny = YES;
                NSString *t = [[NSString stringWithUTF8String:buf + 7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSString *lc = t.lowercaseString;
                if ([lc containsString:@"complete"] || [lc containsString:@"relaunch"]) recordResult(t, YES);
                else if ([lc containsString:@"failed"]) recordResult(t, NO);
                dispatch_async(dispatch_get_main_queue(), ^{ onStatus(t); });
                if ([lc containsString:@"failed"]) break;
            } else if (strncmp(buf, "PROGRESS ", 9) == 0) {
                sawAny = YES;
                int pct = -1, eta = -1; sscanf(buf + 9, "%d %d", &pct, &eta);
                if (pct >= 100) recordResult(@"Update delivered (100%).", YES);
                dispatch_async(dispatch_get_main_queue(), ^{ onProgress(pct, eta); });
            }
        } else if (!sawAny && -start.timeIntervalSinceNow > 12) {
            if (!noReplyRecorded) { recordResult(@"No reply — is SideStep running on your Mac?", NO); noReplyRecorded = YES; }
            dispatch_async(dispatch_get_main_queue(), ^{ onStatus(@"No reply yet — is SideStep running on your Mac?"); });
        }
    }
    close(s);
}

// ---------- expiry notification ----------
static void rescheduleExpiryNotification(void) {
    NSDate *created, *expires; profileDates(&created, &expires);
    if (!expires) return;
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    [c removePendingNotificationRequestsWithIdentifiers:@[NOTIF_ID]];
    NSTimeInterval untilExpiry = expires.timeIntervalSinceNow;
    NSTimeInterval fireIn = untilExpiry - 86400;   // one day before expiry
    if (fireIn < 5) fireIn = 5;
    int days = (int)ceil(untilExpiry / 86400.0);
    UNMutableNotificationContent *ct = [UNMutableNotificationContent new];
    ct.title = @"Update needed soon";
    ct.body = [NSString stringWithFormat:
        @"%@ expires in %d day%@. Open it now (on Wi-Fi near your Mac) so it can refresh "
        @"automatically — otherwise it will need a USB reinstall.",
        NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"This app",
        days, days == 1 ? @"" : @"s"];
    ct.sound = UNNotificationSound.defaultSound;
    UNTimeIntervalNotificationTrigger *tr = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:fireIn repeats:NO];
    [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:NOTIF_ID content:ct trigger:tr] withCompletionHandler:nil];
}

// Automatic (no-UI) beacon that ALSO listens briefly and PERSISTS the outcome,
// so a background / launch auto-update leaves a record the popup can show later.
// Runs off the main thread; calls `done` on the main thread when finished.
static void autoBeaconTracked(int maxSec, void (^done)(void)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) { if (done) dispatch_async(dispatch_get_main_queue(), done); return; }
        int on = 1; setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, sizeof on);
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        sendBeaconOn(s);
        NSDate *start = [NSDate date]; BOOL sawAny = NO, terminal = NO;
        while (-start.timeIntervalSinceNow < maxSec && !terminal) {
            char buf[600]; ssize_t n = recvfrom(s, buf, sizeof buf - 1, 0, NULL, NULL);
            if (n <= 0) continue;
            buf[n] = 0;
            if (strncmp(buf, "STATUS ", 7) == 0) {
                sawAny = YES;
                NSString *t = [[NSString stringWithUTF8String:buf + 7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSString *lc = t.lowercaseString;
                if ([lc containsString:@"failed"]) { recordResult(t, NO); terminal = YES; }
                else if ([lc containsString:@"complete"] || [lc containsString:@"relaunch"]) { recordResult(t, YES); terminal = YES; }
            } else if (strncmp(buf, "PROGRESS ", 9) == 0) {
                sawAny = YES; int pct = -1; sscanf(buf + 9, "%d", &pct);
                if (pct >= 100) { recordResult(@"Update delivered (100%).", YES); terminal = YES; }
            }
        }
        if (!sawAny) recordResult(@"No reply — SideStep wasn’t reachable (Mac asleep/off, or not on the same Wi-Fi).", NO);
        close(s);
        if (done) dispatch_async(dispatch_get_main_queue(), done);
    });
}

// ---------- the core ----------
static void maybeUpdate(const char *why) {
    g_lastReason = [NSString stringWithUTF8String:why];
    NSDate *created, *expires; profileDates(&created, &expires);
    NSTimeInterval age = created ? -created.timeIntervalSinceNow : 1e12;
    NSLog(@"[beacon] check (%s): profile age %.0fs, threshold %ds", why, age, g_updateSec);
    if (age > g_updateSec) {
        NSLog(@"[beacon] stale -> beaconing");
        recordAttempt(g_lastReason);
        autoBeaconTracked(25, nil);   // send + listen + persist outcome for the popup
    }
    rescheduleExpiryNotification();
}

static void scheduleBGRefresh(void) {
    if (@available(iOS 13.0, *)) {
        BGAppRefreshTaskRequest *r = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:BG_TASK_ID];
        r.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:3600];
        [BGTaskScheduler.sharedScheduler submitTaskRequest:r error:nil];
    }
}

// ---------- Bonjour browse for SideStep ----------
@interface BeaconBonjour : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *pending;
@end
@implementation BeaconBonjour
- (void)start {
    self.pending = [NSMutableArray array];
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_sidestep._udp." inDomain:@"local."];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didFindService:(NSNetService *)svc moreComing:(BOOL)more {
    [self.pending addObject:svc]; svc.delegate = self; [svc resolveWithTimeout:5];
}
- (void)netServiceDidResolveAddress:(NSNetService *)svc {
    for (NSData *addr in svc.addresses) {
        const struct sockaddr *sa = addr.bytes;
        if (sa->sa_family == AF_INET) {
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)sa)->sin_addr, buf, sizeof buf);
            g_bonjourIP = [NSString stringWithUTF8String:buf];
            NSLog(@"[beacon] Bonjour resolved SideStep at %@", g_bonjourIP);
        }
    }
    [self.pending removeObject:svc];
}
@end
static BeaconBonjour *g_bonjour;

// ---------- diagnostic vitals overlay ----------
static NSString *fmtDate(NSDate *d) {
    if (!d) return @"—";
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd HH:mm";
    return [f stringFromDate:d];
}
static NSString *fmtAgo(NSDate *d) {
    if (!d) return @"never";
    NSTimeInterval s = -d.timeIntervalSinceNow;
    if (s < 90) return [NSString stringWithFormat:@"%.0fs ago", s];
    if (s < 5400) return [NSString stringWithFormat:@"%.0f min ago", s/60];
    if (s < 172800) return [NSString stringWithFormat:@"%.1f h ago", s/3600];
    return [NSString stringWithFormat:@"%.1f days ago", s/86400];
}
static NSString *vitalsText(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary, *prof = profileDict();
    NSDate *created = prof[@"CreationDate"], *expires = prof[@"ExpirationDate"];
    NSTimeInterval ageS = created ? -created.timeIntervalSinceNow : -1;
    NSTimeInterval expS = expires ? expires.timeIntervalSinceNow : -1;
    BOOL stale = ageS > g_updateSec;
    // Last automatic-update attempt + its outcome (persisted across launches) — so
    // opening this popup after (say) 24h answers: did it try, and if so why did it fail.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSDate *aAt = [ud objectForKey:kAttemptAt];
    NSString *tryStr = aAt ? [NSString stringWithFormat:@"%@ (%@)", fmtAgo(aAt), [ud stringForKey:kAttemptWhy] ?: @"?"] : @"(none yet)";
    NSDate *rAt = [ud objectForKey:kResultAt];
    NSString *resStr = rAt
        ? [NSString stringWithFormat:@"%@  (%@)\n            %@", [ud boolForKey:kResultOK] ? @"✓ OK" : @"✗ FAILED", fmtAgo(rAt), [ud stringForKey:kResult] ?: @"?"]
        : @"(no attempt has reported back yet)";
    return [NSString stringWithFormat:
        @"APP\n  %@  v%@ (%@)\n  %@\n\n"
        @"SOURCE\n  found via: %@\n  %@\n\n"
        @"SIGNING PROFILE\n  team:     %@\n  profile:  %@\n  devices:  %d provisioned\n"
        @"  updated:  %@  (%@)\n  expires:  %@\n  in:       %.1f days\n\n"
        @"UPDATER\n  interval: %d s\n  status:   %@\n  last chk: %@\n  beacons:  %d sent, last %@\n"
        @"  tried:    %@\n  result:   %@\n\n"
        @"DISCOVERY (Mac)\n  baked IP: %@ : %d\n  bonjour:  %@\n  unlocked: %@",
        info[@"CFBundleDisplayName"] ?: @"?", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?",
        info[@"CFBundleIdentifier"] ?: @"?",
        g_foundVia.length ? g_foundVia : @"(unknown)", g_autoUpdates ? @"(app keeps up to date)" : @"(one-time install)",
        prof[@"TeamName"] ?: @"?", prof[@"Name"] ?: @"?", (int)[prof[@"ProvisionedDevices"] count],
        fmtDate(created), fmtAgo(created), fmtDate(expires), expS/86400.0,
        g_updateSec, stale ? @"STALE → will beacon" : @"fresh", g_lastReason,
        g_beaconCount, fmtAgo(g_lastBeaconAt),
        tryStr, resStr,
        g_macIP.length ? g_macIP : @"(none)", g_port, g_bonjourIP ?: @"(not resolved)",
        UIApplication.sharedApplication.isProtectedDataAvailable ? @"yes" : @"no (locked)"];
}

// Fires only when TWO fingers are held simultaneously in ANY two of the four
// corners (top-left, top-right, bottom-left, bottom-right) — for 1.5s. A
// two-hand, location-locked hold that cannot occur by accident and collides with
// no iPad system gesture.
@interface CornerHoldRecognizer : UIGestureRecognizer @end
@implementation CornerHoldRecognizer { NSTimer *_t; }
- (BOOL)cornersHeld {
    UIView *v = self.view;
    if (!v || self.numberOfTouches != 2) return NO;
    CGFloat W = v.bounds.size.width, H = v.bounds.size.height, C = 140;
    BOOL tl = NO, tr = NO, bl = NO, br = NO;
    for (NSUInteger i = 0; i < 2; i++) {
        CGPoint p = [self locationOfTouch:i inView:v];
        BOOL top = p.y <= C, bottom = p.y >= H - C, left = p.x <= C, right = p.x >= W - C;
        if      (top && left)  tl = YES;
        else if (top && right) tr = YES;
        else if (bottom && left)  bl = YES;
        else if (bottom && right) br = YES;
    }
    // Two touches occupying two DISTINCT corners → any pair of the four corners.
    return (tl + tr + bl + br) >= 2;
}
- (void)cancelTimer { [_t invalidate]; _t = nil; }
- (void)fire { self.state = [self cornersHeld] ? UIGestureRecognizerStateRecognized : UIGestureRecognizerStateFailed; }
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if ([self cornersHeld] && !_t) _t = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(fire) userInfo:nil repeats:NO];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (![self cornersHeld]) [self cancelTimer]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self cancelTimer]; if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self cancelTimer]; self.state = UIGestureRecognizerStateCancelled; }
- (void)reset { [self cancelTimer]; [super reset]; }
@end

// ---------- "Install more apps…" — talk to SideStep's TCP install server ----------
static const uint16_t kInstallPort = 51235;

// Blocking request/response (LIST, SEARCH): returns the Mac's full reply, or nil.
static NSString *tcpAsk(NSString *ip, NSString *req) {
    if (ip.length == 0) return nil;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return nil;
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(kInstallPort);
    if (inet_pton(AF_INET, ip.UTF8String, &a.sin_addr) != 1) { close(s); return nil; }
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return nil; }
    NSString *line = [req stringByAppendingString:@"\n"];
    const char *m = line.UTF8String; send(s, m, strlen(m), 0);
    NSMutableData *buf = [NSMutableData data]; char tmp[4096]; ssize_t n;
    while ((n = recv(s, tmp, sizeof tmp, 0)) > 0) [buf appendBytes:tmp length:n];
    close(s);
    return [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
}

// Streaming request (INSTALL): calls onLine on the main thread for each reply line,
// then "__CLOSED__" when the Mac closes.
static void tcpStream(NSString *ip, NSString *req, void (^onLine)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        void (^emit)(NSString *) = ^(NSString *l){ dispatch_async(dispatch_get_main_queue(), ^{ onLine(l); }); };
        if (s < 0) { emit(@"DONE fail no socket"); return; }
        struct timeval tv = { .tv_sec = 300, .tv_usec = 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_family = AF_INET; a.sin_port = htons(kInstallPort);
        if (inet_pton(AF_INET, ip.UTF8String, &a.sin_addr) != 1 || connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
            close(s); emit(@"DONE fail can’t reach your Mac — is SideStep running and on the same Wi-Fi?"); return;
        }
        NSString *line = [req stringByAppendingString:@"\n"];
        const char *m = line.UTF8String; send(s, m, strlen(m), 0);
        NSMutableData *acc = [NSMutableData data]; char tmp[2048]; ssize_t n;
        NSData *nlD = [NSData dataWithBytes:"\n" length:1];
        while ((n = recv(s, tmp, sizeof tmp, 0)) > 0) {
            [acc appendBytes:tmp length:n];
            while (1) {
                NSRange nl = [acc rangeOfData:nlD options:0 range:NSMakeRange(0, acc.length)];
                if (nl.location == NSNotFound) break;
                NSString *ln = [[NSString alloc] initWithData:[acc subdataWithRange:NSMakeRange(0, nl.location)] encoding:NSUTF8StringEncoding];
                [acc replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
                if (ln.length) emit(ln);
            }
        }
        close(s); emit(@"__CLOSED__");
    });
}

// Simple picker list for other-device apps and AltStore search results.
@interface BeaconListVC : UITableViewController
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) void (^onPick)(NSDictionary *);
@end
@implementation BeaconListVC
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *it = self.items[ip.row];
    c.textLabel.text = it[@"title"]; c.detailTextLabel.text = it[@"subtitle"];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (self.onPick) self.onPick(self.items[ip.row]);
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@interface BeaconVitals : NSObject
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UILabel *label;
@property(nonatomic, weak) UIView *updatingCard;
@property(nonatomic, weak) UILabel *statusLabel;
@property(nonatomic, weak) UIProgressView *progressView;
@property(nonatomic, weak) UILabel *pctLabel;
@property(nonatomic, assign) BOOL exiting;
@end
@implementation BeaconVitals
+ (instancetype)shared { static BeaconVitals *v; static dispatch_once_t o; dispatch_once(&o, ^{ v = [BeaconVitals new]; }); return v; }
- (UIWindow *)keyWindow {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    return nil;
}
- (void)attach {
    UIWindow *w = [self keyWindow]; if (!w) return;
    for (UIGestureRecognizer *g in w.gestureRecognizers) if ([g.name isEqualToString:@"beaconVitals"]) return;
    CornerHoldRecognizer *r = [[CornerHoldRecognizer alloc] initWithTarget:self action:@selector(trigger:)];
    r.name = @"beaconVitals"; r.cancelsTouchesInView = NO; r.delaysTouchesBegan = NO;
    [w addGestureRecognizer:r];
}
- (void)trigger:(UIGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateRecognized && !self.overlay) [self show]; }
static UIButton *styledButton(NSString *title, BOOL primary, id target, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.backgroundColor = primary ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.92 alpha:1];
    [b setTitleColor:primary ? UIColor.whiteColor : [UIColor colorWithWhite:0.2 alpha:1] forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    [b addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)show {
    UIWindow *w = [self keyWindow]; if (!w) return;
    UIView *dim = [[UIView alloc] initWithFrame:w.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.40];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CGFloat W = w.bounds.size.width, H = w.bounds.size.height;
    CGFloat cardW = MIN(560, W - 48), cardH = MIN(H - 120, 620);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((W - cardW)/2, (H - cardH)/2, cardW, cardH)];
    card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 20;
    card.layer.shadowColor = UIColor.blackColor.CGColor; card.layer.shadowOpacity = 0.25;
    card.layer.shadowRadius = 24; card.layer.shadowOffset = CGSizeMake(0, 8);
    card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(24, 22, cardW - 48, 30)];
    title.text = [NSString stringWithFormat:@"%@ — Updater", info[@"CFBundleDisplayName"] ?: @"App"];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    [card addSubview:title];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(24, 52, cardW - 48, 18)];
    sub.text = @"Wireless auto-update status";
    sub.font = [UIFont systemFontOfSize:13]; sub.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    [card addSubview:sub];
    UIView *rule = [[UIView alloc] initWithFrame:CGRectMake(24, 82, cardW - 48, 1)];
    rule.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1]; [card addSubview:rule];

    CGFloat btnH = 48, gap = 16, btnW = (cardW - 48 - gap)/2;
    CGFloat rowUpd = cardH - 64;                 // Update / Close row
    CGFloat rowMore = rowUpd - btnH - 12;        // "Install more apps…" row (full width)
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(20, 92, cardW - 40, rowMore - 104)];
    UILabel *lbl = [UILabel new];
    lbl.numberOfLines = 0; lbl.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    lbl.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    lbl.text = vitalsText(); lbl.frame = CGRectMake(4, 4, sv.bounds.size.width - 8, 10); [lbl sizeToFit];
    sv.contentSize = CGSizeMake(sv.bounds.size.width, lbl.frame.size.height + 8);
    [sv addSubview:lbl]; [card addSubview:sv]; self.label = lbl;

    UIButton *more = styledButton(@"Install more apps…", NO, self, @selector(installMore:));
    more.frame = CGRectMake(24, rowMore, cardW - 48, btnH); [card addSubview:more];
    UIButton *upd = styledButton(@"Update app now", YES, self, @selector(updateNow));
    upd.frame = CGRectMake(24, rowUpd, btnW, btnH); [card addSubview:upd];
    UIButton *cls = styledButton(@"Close", NO, self, @selector(close));
    cls.frame = CGRectMake(24 + btnW + gap, rowUpd, btnW, btnH); [card addSubview:cls];

    [dim addSubview:card]; [w addSubview:dim]; self.overlay = dim;
}

// ---------- "Install more apps…" flows ----------
- (NSString *)macIP { return g_bonjourIP.length ? g_bonjourIP : g_macIP; }
- (UIViewController *)presenter { return [self keyWindow].rootViewController; }

- (void)installMore:(UIButton *)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Install more apps"
        message:@"Choose an app to install on this device over Wi-Fi." preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Apps on your other devices" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self browseOtherDevices]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Search AltStore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self searchAltStore]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Install from GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self githubPrompt]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = sender;          // required on iPad
    ac.popoverPresentationController.sourceRect = sender.bounds;
    [[self presenter] presentViewController:ac animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)parseApps:(NSString *)resp {
    if (!resp.length) return @[];
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSArray *apps = [j[@"apps"] isKindOfClass:NSArray.class] ? j[@"apps"] : @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in apps) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [a[@"name"] length] ? a[@"name"] : (a[@"bundle"] ?: @"App");
        NSString *ver = [a[@"version"] length] ? [NSString stringWithFormat:@"v%@", a[@"version"]] : @"";
        NSString *extra = [a[@"device"] length] ? a[@"device"] : ([a[@"source"] length] ? a[@"source"] : (a[@"via"] ?: @""));
        NSString *sub = ver.length && extra.length ? [NSString stringWithFormat:@"%@ · %@", ver, extra] : (ver.length ? ver : extra);
        NSMutableDictionary *it = [@{ @"title": name, @"subtitle": sub ?: @"", @"name": name, @"bundle": a[@"bundle"] ?: @"" } mutableCopy];
        if (a[@"url"]) it[@"url"] = a[@"url"];
        if (a[@"repo"]) it[@"repo"] = a[@"repo"];
        [out addObject:it];
    }
    return out;
}

- (void)presentList:(NSString *)title items:(NSArray *)items empty:(NSString *)empty onPick:(void (^)(NSDictionary *))onPick {
    if (items.count == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:empty preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self presenter] presentViewController:ac animated:YES completion:nil];
        return;
    }
    BeaconListVC *vc = [BeaconListVC new]; vc.title = title; vc.items = items;
    __weak BeaconListVC *wvc = vc;
    vc.onPick = ^(NSDictionary *it){ [wvc dismissViewControllerAnimated:YES completion:^{ onPick(it); }]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:vc action:@selector(done)];
    [[self presenter] presentViewController:nav animated:YES completion:nil];
}

- (void)browseOtherDevices {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = tcpAsk([self macIP], [NSString stringWithFormat:@"LIST udid=%@", g_udid]);
        NSArray *apps = [self parseApps:r];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentList:@"On your other devices" items:apps
                        empty:@"No apps found on your other devices — or SideStep isn’t running / reachable on Wi-Fi."
                       onPick:^(NSDictionary *it){
                [self runInstall:[NSString stringWithFormat:@"INSTALL udid=%@ kind=other bundle=%@", g_udid, it[@"bundle"]] title:it[@"title"]];
            }];
        });
    });
}

- (void)searchAltStore {
    UIAlertController *p = [UIAlertController alertControllerWithTitle:@"Search AltStore" message:@"Search the app catalog by name." preferredStyle:UIAlertControllerStyleAlert];
    [p addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"e.g. music, emulator, reader"; }];
    [p addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [p addAction:[UIAlertAction actionWithTitle:@"Search" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *q = p.textFields.firstObject.text ?: @"";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *r = tcpAsk([self macIP], [NSString stringWithFormat:@"SEARCH udid=%@ q=%@", g_udid, q]);
            NSArray *apps = [self parseApps:r];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentList:[NSString stringWithFormat:@"AltStore: “%@”", q] items:apps
                            empty:@"No matching apps — or SideStep isn’t reachable on Wi-Fi."
                           onPick:^(NSDictionary *it){
                    [self runInstall:[NSString stringWithFormat:@"INSTALL udid=%@ kind=source bundle=%@ url=%@ name=%@", g_udid, it[@"bundle"], it[@"url"] ?: @"", it[@"name"]] title:it[@"title"]];
                }];
            });
        });
    }]];
    [[self presenter] presentViewController:p animated:YES completion:nil];
}

- (void)githubPrompt {
    UIAlertController *p = [UIAlertController alertControllerWithTitle:@"Install from GitHub" message:@"Enter a repo (owner/name), or just a username to see all their apps." preferredStyle:UIAlertControllerStyleAlert];
    [p addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"owner/name  or  username"; tf.autocapitalizationType = UITextAutocapitalizationTypeNone; tf.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [p addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [p addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *t = [p.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        t = [[t stringByReplacingOccurrencesOfString:@"https://github.com/" withString:@""] stringByReplacingOccurrencesOfString:@"github.com/" withString:@""];
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (t.length == 0) return;
        if ([t containsString:@"/"]) {   // full repo → install directly
            [self runInstall:[NSString stringWithFormat:@"INSTALL udid=%@ kind=github repo=%@", g_udid, t] title:t];
            return;
        }
        // bare username → list their repos that publish an .ipa, then pick one
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *r = tcpAsk([self macIP], [NSString stringWithFormat:@"GHUSER user=%@", t]);
            NSArray *apps = [self parseApps:r];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentList:[NSString stringWithFormat:@"%@’s apps on GitHub", t] items:apps
                            empty:@"No public repos with an .ipa release for that user — or the Mac isn’t reachable."
                           onPick:^(NSDictionary *it){
                    [self runInstall:[NSString stringWithFormat:@"INSTALL udid=%@ kind=github repo=%@", g_udid, it[@"repo"] ?: @""] title:it[@"title"]];
                }];
            });
        });
    }]];
    [[self presenter] presentViewController:p animated:YES completion:nil];
}

- (void)runInstall:(NSString *)line title:(NSString *)title {
    UIAlertController *p = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Installing %@…", title] message:@"Contacting your Mac…" preferredStyle:UIAlertControllerStyleAlert];
    [[self presenter] presentViewController:p animated:YES completion:nil];
    __block BOOL finished = NO;
    tcpStream([self macIP], line, ^(NSString *ln){
        if ([ln hasPrefix:@"STATUS "]) {
            p.message = [ln substringFromIndex:7];
        } else if ([ln hasPrefix:@"PROGRESS "]) {
            int pct = -1; sscanf(ln.UTF8String, "PROGRESS %d", &pct);
            if (pct >= 0) p.message = [NSString stringWithFormat:@"Sending to your device… %d%%", pct];
        } else if ([ln hasPrefix:@"DONE ok"]) {
            finished = YES; p.title = @"Installed";
            p.message = [NSString stringWithFormat:@"%@ was installed. It will appear on your Home Screen.", title];
            [p addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:nil]];
        } else if ([ln hasPrefix:@"DONE fail"]) {
            finished = YES; p.title = @"Couldn’t install";
            p.message = ln.length > 10 ? [ln substringFromIndex:10] : @"Install failed.";
            [p addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        } else if ([ln isEqualToString:@"__CLOSED__"] && !finished) {
            finished = YES; p.message = @"The connection closed before the install finished.";
            [p addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        }
    });
}

static NSString *fmtEta(int s) {
    if (s < 0) return @"";
    if (s < 60) return [NSString stringWithFormat:@"~%ds left", s];
    return [NSString stringWithFormat:@"~%dm %02ds left", s/60, s%60];
}

// "Updating app now" popup with live status, a % progress bar + ETA, and a
// self-restart at the end (iOS defers replacing a running app, so we exit to
// let the swap finish, then the user reopens the new version).
- (void)updateNow {
    UIWindow *w = [self keyWindow]; if (!w) return;
    self.exiting = NO;
    CGFloat W = w.bounds.size.width, H = w.bounds.size.height;
    // ~50% wider than the old 480pt, but never wider than the screen allows, so
    // the status text stops wrapping unless the device genuinely can't fit it.
    CGFloat cardW = MIN(720, W - 64), cardH = 260;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((W - cardW)/2, (H - cardH)/2, cardW, cardH)];
    card.backgroundColor = UIColor.whiteColor; card.layer.cornerRadius = 20;
    card.layer.shadowColor = UIColor.blackColor.CGColor; card.layer.shadowOpacity = 0.3; card.layer.shadowRadius = 28;
    card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, cardW - 40, 28)];
    t.text = @"Updating app now"; t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold]; t.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    [card addSubview:t];
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.color = UIColor.systemBlueColor; spin.center = CGPointMake(cardW/2, 70); [spin startAnimating]; [card addSubview:spin];
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(20, 92, cardW - 40, 44)];
    st.numberOfLines = 2; st.textAlignment = NSTextAlignmentCenter;
    st.font = [UIFont systemFontOfSize:16]; st.textColor = [UIColor colorWithWhite:0.3 alpha:1];
    st.text = @"Contacting your Mac…"; [card addSubview:st]; self.statusLabel = st;
    UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    pv.frame = CGRectMake(28, 150, cardW - 56, 6); pv.progressTintColor = UIColor.systemBlueColor;
    pv.trackTintColor = [UIColor colorWithWhite:0.9 alpha:1]; pv.hidden = YES; [card addSubview:pv]; self.progressView = pv;
    UILabel *pct = [[UILabel alloc] initWithFrame:CGRectMake(20, 162, cardW - 40, 20)];
    pct.textAlignment = NSTextAlignmentCenter; pct.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    pct.textColor = [UIColor colorWithWhite:0.45 alpha:1]; [card addSubview:pct]; self.pctLabel = pct;
    UIButton *cls = styledButton(@"Hide", NO, self, @selector(closeUpdating));
    cls.frame = CGRectMake(cardW/2 - 70, cardH - 56, 140, 44); [card addSubview:cls];
    [self.overlay addSubview:card]; self.updatingCard = card;

    __weak BeaconVitals *ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        beaconAndTrack(
          ^(NSString *status) { if (ws.statusLabel) ws.statusLabel.text = status; },
          ^(int p, int eta) { [ws onProgress:p eta:eta]; });
    });
}

- (void)onProgress:(int)pct eta:(int)eta {
    if (pct < 0) return;
    self.progressView.hidden = NO;
    [self.progressView setProgress:pct/100.0 animated:YES];
    self.pctLabel.text = pct >= 100 ? @"100% — finishing…"
        : [NSString stringWithFormat:@"%d%%   %@", pct, fmtEta(eta)];
    if (pct >= 100 && !self.exiting) {
        self.exiting = YES;
        self.statusLabel.text = @"Upload complete — restarting to apply the update…";
        // iOS won't swap a running app's bundle; exit so the swap completes, then
        // the user reopens the new version.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }
}
- (void)closeUpdating { [self.updatingCard removeFromSuperview]; }
- (void)close { [self.overlay removeFromSuperview]; }
@end

// ---------- deferred permission flow ----------
// The notification + Local Network prompts used to fire during launch, which
// froze the launch screen. Now: wait 5s, ask for notifications, and only once
// THAT is resolved trigger Local Network (Bonjour + the first beacon). If either
// is refused, a card explains SideStep can't keep the app updated without it,
// offering a default "Try Again" (opens Settings) and an "I understand".

static UIWindow *beaconKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *win in ((UIWindowScene *)sc).windows) if (win.isKeyWindow) return win;
    return nil;
}

static void openAppSettings(void) {
    NSURL *u = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}

static UIButton *nagButton(NSString *title, BOOL primary, void (^handler)(void)) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.backgroundColor = primary ? UIColor.systemBlueColor : [UIColor colorWithWhite:0.92 alpha:1];
    [b setTitleColor:primary ? UIColor.whiteColor : [UIColor colorWithWhite:0.2 alpha:1] forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { if (handler) handler(); }]
        forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// A modal card: <permName> was refused → SideStep can't work properly. Default
// "Try Again" (primary) + "I understand". Both dismiss; the caller supplies what
// each does.
static void showPermissionNag(NSString *permName, NSString *detail,
                              void (^tryAgain)(void), void (^skip)(void)) {
    UIWindow *w = beaconKeyWindow(); if (!w) return;
    for (UIView *sub in w.subviews) if (sub.tag == 0x5EED0001) return;   // only one at a time

    CGFloat W = w.bounds.size.width, H = w.bounds.size.height;
    UIView *dim = [[UIView alloc] initWithFrame:w.bounds];
    dim.tag = 0x5EED0001;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CGFloat pad = 24, cardW = MIN(460, W - 48), contentW = cardW - pad * 2;
    UIFont *bodyFont = [UIFont systemFontOfSize:15];
    CGRect br = [detail boundingRectWithSize:CGSizeMake(contentW, 1000)
                    options:NSStringDrawingUsesLineFragmentOrigin
                    attributes:@{NSFontAttributeName: bodyFont} context:nil];
    CGFloat bodyH = ceil(br.size.height), btnH = 48;
    CGFloat cardH = pad + 28 + 12 + bodyH + 22 + btnH + pad;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((W - cardW)/2, (H - cardH)/2, cardW, cardH)];
    card.backgroundColor = UIColor.whiteColor; card.layer.cornerRadius = 20;
    card.layer.shadowColor = UIColor.blackColor.CGColor; card.layer.shadowOpacity = 0.3; card.layer.shadowRadius = 28;
    card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, pad, contentW, 28)];
    title.text = [NSString stringWithFormat:@"Allow %@ access", permName];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(pad, pad + 28 + 12, contentW, bodyH)];
    body.text = detail; body.font = bodyFont; body.numberOfLines = 0;
    body.textColor = [UIColor colorWithWhite:0.3 alpha:1];
    [card addSubview:body];

    CGFloat gap = 12, btnW = (contentW - gap)/2, btnY = cardH - pad - btnH;
    UIButton *again = nagButton(@"Try Again", YES, ^{ [dim removeFromSuperview]; if (tryAgain) tryAgain(); });
    again.frame = CGRectMake(pad, btnY, btnW, btnH); [card addSubview:again];
    UIButton *ok = nagButton(@"I understand", NO, ^{ [dim removeFromSuperview]; if (skip) skip(); });
    ok.frame = CGRectMake(pad + btnW + gap, btnY, btnW, btnH); [card addSubview:ok];

    [dim addSubview:card]; [w addSubview:dim];
}

// A tiny NWBrowser used ONLY to learn whether Local Network access was DENIED
// (a policy refusal, distinct from Wi-Fi merely being off) so we can nag.
// Discovery itself still runs through BeaconBonjour.
static nw_browser_t g_lnProbe = nil;
static void startLocalNetworkProbe(void) {
    if (@available(iOS 14.0, *)) {
        nw_browse_descriptor_t desc = nw_browse_descriptor_create_bonjour_service("_sidestep._udp", NULL);
        nw_parameters_t params = nw_parameters_create();
        g_lnProbe = nw_browser_create(desc, params);
        nw_browser_set_queue(g_lnProbe, dispatch_get_main_queue());
        nw_browser_set_state_changed_handler(g_lnProbe, ^(nw_browser_state_t state, nw_error_t error) {
            if (state == nw_browser_state_ready) return;              // access allowed
            if (state == nw_browser_state_waiting && error) {
                nw_error_domain_t dom = nw_error_get_error_domain(error);
                int code = nw_error_get_error_code(error);
                // Only a policy denial should nag; ENETDOWN etc. (Wi-Fi off) must not.
                BOOL denied = (dom == nw_error_domain_dns && code == -65570 /* kDNSServiceErr_PolicyDenied */)
                           || (dom == nw_error_domain_posix && code == EPERM);
                if (denied && !g_lnNagShown) {
                    g_lnNagShown = YES;
                    showPermissionNag(@"Local Network",
                        @"SideStep keeps this app up to date by contacting your Mac over Wi-Fi. "
                        @"Without Local Network access it can’t receive new versions.",
                        ^{ openAppSettings(); }, ^{ });
                }
            }
        });
        nw_browser_start(g_lnProbe);
    }
}

// The SECOND prompt: begin all local-network activity (Bonjour discovery, the
// refusal probe, and the first beacon). Guarded so it runs exactly once.
static void startLocalNetwork(void) {
    if (g_localNetStarted) return;
    g_localNetStarted = YES;
    g_bonjour = [BeaconBonjour new]; [g_bonjour start];   // discovery (triggers the Local Network prompt)
    startLocalNetworkProbe();                             // detect a Local Network refusal → nag
    maybeUpdate("launch");                                // first beacon
}

// The FIRST prompt: notifications. Only once that's resolved do we trigger Local
// Network — "delay the 2nd one until you get the 1st". A refusal shows the nag
// but still proceeds to Local Network (notifications aren't required to update).
static void requestNotificationsThenLocalNet(void) {
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    NSString *detail = @"SideStep sends a reminder to reopen this app before its 7-day signing "
                       @"expires. Without notifications, it can quietly stop working.";
    [c getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        UNAuthorizationStatus st = s.authorizationStatus;
        if (st == UNAuthorizationStatusNotDetermined) {
            [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                completionHandler:^(BOOL granted, NSError *e) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) startLocalNetwork();
                        else showPermissionNag(@"Notifications", detail,
                                 ^{ openAppSettings(); startLocalNetwork(); },
                                 ^{ startLocalNetwork(); });
                    });
                }];
        } else if (st == UNAuthorizationStatusDenied) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showPermissionNag(@"Notifications", detail,
                    ^{ openAppSettings(); startLocalNetwork(); },
                    ^{ startLocalNetwork(); });
            });
        } else {   // authorized / provisional / ephemeral
            dispatch_async(dispatch_get_main_queue(), ^{ startLocalNetwork(); });
        }
    }];
}

// ---------- wire-up ----------
static void onLaunch(void) {
    if (@available(iOS 13.0, *)) {
        [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:BG_TASK_ID usingQueue:nil
            launchHandler:^(BGTask *task) {
                scheduleBGRefresh();
                g_lastReason = @"bg";
                NSDate *created, *expires; profileDates(&created, &expires);
                NSTimeInterval age = created ? -created.timeIntervalSinceNow : 1e12;
                rescheduleExpiryNotification();
                if (age > g_updateSec) {
                    // Record the attempt and listen for the outcome; only finish the
                    // background task once the tracked beacon has persisted a result.
                    recordAttempt(@"bg");
                    [task setExpirationHandler:^{}];
                    autoBeaconTracked(25, ^{ [task setTaskCompletedWithSuccess:YES]; });
                } else {
                    [task setTaskCompletedWithSuccess:YES];
                }
            }];
    }
    scheduleBGRefresh();
    // Attach the diagnostic gesture soon, but do NOT ask for permissions or touch
    // the network yet — those prompts froze the launch screen. Defer the whole
    // permission flow 5s so the app's first screen renders first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [BeaconVitals.shared attach]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ requestNotificationsThenLocalNet(); });
    [NSTimer scheduledTimerWithTimeInterval:g_fgSec repeats:YES block:^(NSTimer *t) {
        if (g_localNetStarted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
            maybeUpdate("foreground-timer");
    }];
}

__attribute__((constructor))
static void beacon_init(void) {
    loadConfig();
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { onLaunch(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (g_localNetStarted) maybeUpdate("became-active");   // don't beacon before the perm flow runs
            [BeaconVitals.shared attach];
        }];
}

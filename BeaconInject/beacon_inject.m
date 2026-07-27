// BeaconInject.dylib — always-on "keep me updated over Wi-Fi" library that
// iSideload injects into every app it installs. One PREBUILT dylib serves any
// app/device: all per-install config is read at RUNTIME from BeaconConfig.plist
// (which iSideload writes into the app bundle), not baked in at compile time.
//
// No user prompt. It continuously (on launch, while in use, on OS background
// wake) checks how old its signing profile is; if older than the update
// interval it fires a UDP beacon so the Mac (iSideload) re-signs and pushes a
// fresh copy — which silently resets the profile clock. It also keeps a local
// notification scheduled warning the user to open the app before the free
// provisioning profile expires (else a USB reinstall is needed).
//
// "Time since last update" needs no stored state: every push mints a new
// provisioning profile, so the profile's CreationDate == last-update time.
//
// A hidden diagnostic gesture (two fingers held in the top-left AND top-right
// corners for 1.5s) opens a vitals panel + a Force-update button.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <UserNotifications/UserNotifications.h>
#import <BackgroundTasks/BackgroundTasks.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define BG_TASK_ID @"com.isideload.beacon.refresh"
#define NOTIF_ID   @"com.isideload.beacon.expiry"

// ---- runtime config (from BeaconConfig.plist in the app bundle) ----
static NSString *g_macIP  = @"";           // iSideload's LAN IP at install time (unicast fallback)
static NSString *g_udid   = @"";           // this device's UDID (so the Mac knows who beacs)
static NSString *g_bundle = @"";           // installed bundle id (so the Mac knows which app)
static int g_port         = 51234;
static int g_updateSec    = 86400;         // beacon if the profile is older than this (24h)
static int g_fgSec        = 1800;          // re-check every 30 min while the app is open

static NSString *g_bonjourIP = nil;        // filled in async by the Bonjour browser
static NSDate   *g_lastBeaconAt = nil;
static int       g_beaconCount = 0;
static NSString *g_lastReason = @"(none yet)";

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
    NSDate *start = [NSDate date]; BOOL sawAny = NO;
    while (-start.timeIntervalSinceNow < 240) {
        char buf[600]; struct sockaddr_in from; socklen_t fl = sizeof from;
        ssize_t n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n > 0) {
            buf[n] = 0;
            if (strncmp(buf, "STATUS ", 7) == 0) {
                sawAny = YES;
                NSString *t = [[NSString stringWithUTF8String:buf + 7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{ onStatus(t); });
                if ([t.lowercaseString containsString:@"failed"]) break;
            } else if (strncmp(buf, "PROGRESS ", 9) == 0) {
                sawAny = YES;
                int pct = -1, eta = -1; sscanf(buf + 9, "%d %d", &pct, &eta);
                dispatch_async(dispatch_get_main_queue(), ^{ onProgress(pct, eta); });
            }
        } else if (!sawAny && -start.timeIntervalSinceNow > 12) {
            dispatch_async(dispatch_get_main_queue(), ^{ onStatus(@"No reply yet — is iSideload running on your Mac?"); });
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

// ---------- the core ----------
static void maybeUpdate(const char *why) {
    g_lastReason = [NSString stringWithUTF8String:why];
    NSDate *created, *expires; profileDates(&created, &expires);
    NSTimeInterval age = created ? -created.timeIntervalSinceNow : 1e12;
    NSLog(@"[beacon] check (%s): profile age %.0fs, threshold %ds", why, age, g_updateSec);
    if (age > g_updateSec) { NSLog(@"[beacon] stale -> beaconing"); sendBeacon(); }
    rescheduleExpiryNotification();
}

static void scheduleBGRefresh(void) {
    if (@available(iOS 13.0, *)) {
        BGAppRefreshTaskRequest *r = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:BG_TASK_ID];
        r.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:3600];
        [BGTaskScheduler.sharedScheduler submitTaskRequest:r error:nil];
    }
}

// ---------- Bonjour browse for iSideload ----------
@interface BeaconBonjour : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *pending;
@end
@implementation BeaconBonjour
- (void)start {
    self.pending = [NSMutableArray array];
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_isideload._udp." inDomain:@"local."];
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
            NSLog(@"[beacon] Bonjour resolved iSideload at %@", g_bonjourIP);
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
    return [NSString stringWithFormat:
        @"APP\n  %@  v%@ (%@)\n  %@\n\n"
        @"SIGNING PROFILE\n  team:     %@\n  profile:  %@\n  devices:  %d provisioned\n"
        @"  updated:  %@  (%@)\n  expires:  %@\n  in:       %.1f days\n\n"
        @"UPDATER\n  interval: %d s\n  status:   %@\n  last chk: %@\n  beacons:  %d sent, last %@\n\n"
        @"DISCOVERY (Mac)\n  baked IP: %@ : %d\n  bonjour:  %@\n  unlocked: %@",
        info[@"CFBundleDisplayName"] ?: @"?", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?",
        info[@"CFBundleIdentifier"] ?: @"?",
        prof[@"TeamName"] ?: @"?", prof[@"Name"] ?: @"?", (int)[prof[@"ProvisionedDevices"] count],
        fmtDate(created), fmtAgo(created), fmtDate(expires), expS/86400.0,
        g_updateSec, stale ? @"STALE → will beacon" : @"fresh", g_lastReason,
        g_beaconCount, fmtAgo(g_lastBeaconAt),
        g_macIP.length ? g_macIP : @"(none)", g_port, g_bonjourIP ?: @"(not resolved)",
        UIApplication.sharedApplication.isProtectedDataAvailable ? @"yes" : @"no (locked)"];
}

// Fires only when TWO fingers are held simultaneously — one top-left, one
// top-right — for 1.5s. A two-hand, location-locked hold that cannot occur by
// accident and collides with no iPad system gesture.
@interface CornerHoldRecognizer : UIGestureRecognizer @end
@implementation CornerHoldRecognizer { NSTimer *_t; }
- (BOOL)cornersHeld {
    UIView *v = self.view;
    if (!v || self.numberOfTouches != 2) return NO;
    CGFloat W = v.bounds.size.width, C = 140; BOOL left = NO, right = NO;
    for (NSUInteger i = 0; i < 2; i++) {
        CGPoint p = [self locationOfTouch:i inView:v];
        if (p.y <= C && p.x <= C) left = YES; else if (p.y <= C && p.x >= W - C) right = YES;
    }
    return left && right;
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

    CGFloat btnY = cardH - 64, btnH = 48, gap = 16, btnW = (cardW - 48 - gap)/2;
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(20, 92, cardW - 40, btnY - 104)];
    UILabel *lbl = [UILabel new];
    lbl.numberOfLines = 0; lbl.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    lbl.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    lbl.text = vitalsText(); lbl.frame = CGRectMake(4, 4, sv.bounds.size.width - 8, 10); [lbl sizeToFit];
    sv.contentSize = CGSizeMake(sv.bounds.size.width, lbl.frame.size.height + 8);
    [sv addSubview:lbl]; [card addSubview:sv]; self.label = lbl;

    UIButton *upd = styledButton(@"Update app now", YES, self, @selector(updateNow));
    upd.frame = CGRectMake(24, btnY, btnW, btnH); [card addSubview:upd];
    UIButton *cls = styledButton(@"Close", NO, self, @selector(close));
    cls.frame = CGRectMake(24 + btnW + gap, btnY, btnW, btnH); [card addSubview:cls];

    [dim addSubview:card]; [w addSubview:dim]; self.overlay = dim;
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
    CGFloat cardW = MIN(480, W - 64), cardH = 260;
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

// ---------- wire-up ----------
static void onLaunch(void) {
    if (@available(iOS 13.0, *)) {
        [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:BG_TASK_ID usingQueue:nil
            launchHandler:^(BGTask *task) { maybeUpdate("bg"); scheduleBGRefresh(); [task setTaskCompletedWithSuccess:YES]; }];
    }
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError *e) {}];
    g_bonjour = [BeaconBonjour new]; [g_bonjour start];
    scheduleBGRefresh();
    maybeUpdate("launch");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [BeaconVitals.shared attach]; });
    [NSTimer scheduledTimerWithTimeInterval:g_fgSec repeats:YES block:^(NSTimer *t) {
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) maybeUpdate("foreground-timer");
    }];
}

__attribute__((constructor))
static void beacon_init(void) {
    loadConfig();
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { onLaunch(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { maybeUpdate("became-active"); [BeaconVitals.shared attach]; }];
}

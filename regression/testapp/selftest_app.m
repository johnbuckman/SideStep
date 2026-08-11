// Minimal UIKit app for the SideStep regression suite. Deterministic, tiny, and
// version-stamped by build-test-app.sh so a test can assert the exact version that
// SideStep signed + installed shows up on-device (via the installd oracle).
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemIndigoColor;
    UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.whiteColor;
    l.numberOfLines = 0;
    NSString *v = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    l.text = [NSString stringWithFormat:@"SideStep\nSelfTest\nv%@", v];
    l.font = [UIFont boldSystemFontOfSize:28];
    [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}

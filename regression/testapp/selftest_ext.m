// Minimal app-extension principal class — just enough for installd to accept the .appex
// so the regression suite can prove SideStep re-ids nested extensions correctly (the
// "Failed to set app extension placeholders" bug). Entry point is NSExtensionMain
// (linked via -e _NSExtensionMain); this only needs to be a valid extension bundle.
#import <UIKit/UIKit.h>

@interface SelfTestExtVC : UIViewController
@end

@implementation SelfTestExtVC
@end

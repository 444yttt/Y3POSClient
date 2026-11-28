#import <UIKit/UIKit.h>
#import "../BLDState.h"
#import <math.h>
#import <stdlib.h>

static BOOL enabled;
static NSUInteger starts, stops, checks;
static NSArray *lastPoints;
static double lastSpeed,lastAccuracy;
static UIWindow *hostWindow;
static UIViewController *hostRoot;
static BOOL scheduled;

BOOL BLDStart(NSArray<NSArray<NSNumber *> *> *points, double speed, double accuracy, NSError **error) {
    (void)error;
    if (!points.count || speed < 0 || accuracy <= 0) return NO;
    lastPoints=points;lastSpeed=speed;lastAccuracy=accuracy;
    enabled = YES; starts++; return YES;
}
void BLDStop(void) { enabled = NO; stops++; }
BOOL BLDIsEnabled(void) { return enabled; }
NSString *BLDStatusText(void) { return enabled ? @"UI fixture: input ON" : @"UI fixture: input OFF"; }

static void result(NSString *status, NSString *detail) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"status":status,@"detail":detail,@"checks":@(checks),@"real_location_calls":@0,@"app_binary_executed":@NO} options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:[dir stringByAppendingPathComponent:@"ui-tests.json"] atomically:YES];
}
static void check(BOOL value, NSString *detail) {
    checks++;
    if (!value) { result(@"failed",detail); exit(1); }
}
static UIView *find(UIView *root, BOOL (^predicate)(UIView *)) {
    if (predicate(root)) return root;
    for (UIView *child in root.subviews) { UIView *found = find(child,predicate); if (found) return found; }
    return nil;
}
static UIButton *button(NSString *title, NSString *identifier) {
    return (UIButton *)find(hostWindow, ^BOOL(UIView *view) {
        if (![view isKindOfClass:UIButton.class]) return NO;
        UIButton *button = (UIButton *)view;
        return (identifier && [button.accessibilityIdentifier isEqualToString:identifier]) ||
            (title && [[button titleForState:UIControlStateNormal] isEqualToString:title]);
    });
}
static void after(double delay, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
}
static void checkHost(void) {
    check(hostWindow.isKeyWindow,@"application keeps key window");
    check(hostWindow.rootViewController == hostRoot,@"application root controller is unchanged");
    check(hostWindow.windowLevel == UIWindowLevelNormal,@"application window level is unchanged");
    check([hostRoot.view.backgroundColor isEqual:UIColor.whiteColor],@"original visible content is unchanged");
}
static void runChecks(void) {
    checkHost();
    NSUInteger visible = 0;
    for (UIWindow *window in hostWindow.windowScene.windows) if (!window.hidden && window.alpha > 0 && window.rootViewController) visible++;
    check(visible == 1,@"debug controls create no extra visible application window");
    UIButton *open = button(nil,@"bld.openControls");
    check(open != nil && !open.hidden,@"debug button attaches to ready application window");
    check(open.window == hostWindow,@"debug button uses existing app window");
    [open sendActionsForControlEvents:UIControlEventTouchUpInside];
    after(0.8, ^{
        checkHost();
        UINavigationController *nav = (UINavigationController *)hostRoot.presentedViewController;
        check([nav isKindOfClass:UINavigationController.class],@"controls present from original app controller");
        UIViewController *form = nav.topViewController;
        check([form.title isEqualToString:@"位置情報テスト"],@"location controls are visible");
        UIButton *copy = button(nil,@"bld.copyScreenDiagnostics");
        check(copy != nil,@"screen diagnostics are available");
        [copy sendActionsForControlEvents:UIControlEventTouchUpInside];
        check([UIPasteboard.generalPasteboard.string containsString:@"existing-app-window/v1"],@"diagnostic copy records UI revision");
        UITextView *coordinates = (UITextView *)find(form.view,^BOOL(UIView *view) { return [view isKindOfClass:UITextView.class]; });
        check(coordinates != nil,@"coordinate editor remains available");
        [coordinates becomeFirstResponder];
        after(0.7, ^{
            check(hostWindow.isKeyWindow,@"editing does not steal app key status");
            UIButton *start = button(@"この座標で開始・更新",nil);
            check(start != nil,@"start/update control remains available");
            [start sendActionsForControlEvents:UIControlEventTouchUpInside];
            check(enabled && starts == 1,@"UI sends coordinate configuration to feed entry");
            check(lastPoints.count == 1 && fabs([lastPoints[0][0] doubleValue]-35.681236)<0.000001 && fabs([lastPoints[0][1] doubleValue]-139.767125)<0.000001,@"coordinate fields reach the feed unchanged");
            check(fabs(lastSpeed-1.4)<0.001 && fabs(lastAccuracy-5)<0.001,@"speed and accuracy fields reach the feed unchanged");
            UIButton *stop = button(@"注入を停止して実際の位置に戻す",nil);
            check(stop != nil && stop.enabled,@"stop control is enabled while feed active");
            [stop sendActionsForControlEvents:UIControlEventTouchUpInside];
            check(!enabled && stops == 1,@"UI stops the feed");
            UIBarButtonItem *done = form.navigationItem.rightBarButtonItem;
            [UIApplication.sharedApplication sendAction:done.action to:done.target from:done forEvent:nil];
            after(0.8, ^{
                checkHost();
                check(hostRoot.presentedViewController == nil,@"closing controls restores original app content");
                check(button(nil,@"bld.openControls") && !button(nil,@"bld.openControls").hidden,@"debug button returns after dismissal");
                result(@"passed",@"existing window, root, key status, content, editing, controls and dismissal verified");
            });
        });
    });
}

@interface BLDTestRoot : UIViewController
@end
@implementation BLDTestRoot
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.whiteColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20,220,340,160)];
    label.text=@"Original app content remains visible";label.textColor=UIColor.blackColor;label.backgroundColor=UIColor.systemTealColor;
    label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.font=[UIFont boldSystemFontOfSize:28];
    label.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:label];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!scheduled) { scheduled=YES; after(2, ^{ runChecks(); }); }
}
@end
@interface BLDTestScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation BLDTestScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    hostRoot=[BLDTestRoot new]; self.window.rootViewController=hostRoot; hostWindow=self.window;
    [self.window makeKeyAndVisible];
}
@end
@interface BLDTestApp : UIResponder <UIApplicationDelegate>
@end
@implementation BLDTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    // Exercise installation before the real app scene/root/window exists.
    BLDInstallDebugUI(); return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application;(void)options;
    UISceneConfiguration *config=[[UISceneConfiguration alloc] initWithName:@"Tests" sessionRole:session.role];
    config.delegateClass=BLDTestScene.class; return config;
}
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(BLDTestApp.class)); }
}

#import <UIKit/UIKit.h>
#import "../BLDState.h"
#import <math.h>
#import <stdlib.h>
#import <objc/runtime.h>

static BOOL enabled;
static NSUInteger starts, stops, checks;
static NSArray *lastPoints;
static double lastSpeed,lastAccuracy;
static UIWindow *hostWindow;
static UIViewController *hostRoot;
static BOOL scheduled;
static UITextField *nativeAge;
static UIButton *nativeContinue;
static NSUInteger nativeEnds,nativeContinues;
@interface BLDTouchFixture : NSObject
@property(nonatomic,strong) UIView *view;
@end
@implementation BLDTouchFixture
@end

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
static UIBarButtonItem *toolbarItem(UIView *input,NSString *title) {
    UIView *accessory = input.inputAccessoryView;
    check([accessory isKindOfClass:UIToolbar.class],@"every editor has a keyboard toolbar");
    for (UIBarButtonItem *item in ((UIToolbar *)accessory).items) if ([item.title isEqualToString:title]) return item;
    return nil;
}
static void useItem(UIBarButtonItem *item) {
    check(item != nil && item.enabled,@"keyboard toolbar action is available");
    [UIApplication.sharedApplication sendAction:item.action to:item.target from:item forEvent:nil];
}
static void openDebugChecks(void) {
    UIButton *open = button(nil,@"bld.openControls");
    [open sendActionsForControlEvents:UIControlEventTouchUpInside];
    after(0.8, ^{
        checkHost();
        UINavigationController *nav = (UINavigationController *)hostRoot.presentedViewController;
        check([nav isKindOfClass:UINavigationController.class],@"controls present from original app controller");
        UIViewController *form = nav.topViewController;
        check([form.title isEqualToString:@"位置情報テスト"],@"location controls are visible");
        UIButton *toggle=button(nil,@"bld.toggleDiagnostics");
        UIButton *copy=button(nil,@"bld.copyScreenDiagnostics");
        check(toggle && copy.hidden,@"technical diagnostics start collapsed");
        [toggle sendActionsForControlEvents:UIControlEventTouchUpInside];
        check(!copy.hidden,@"diagnostics can be expanded");
        [copy sendActionsForControlEvents:UIControlEventTouchUpInside];
        check([UIPasteboard.generalPasteboard.string containsString:@"existing-app-window/v3-age-keyboard"],@"diagnostic copy identifies keyboard revision");
        [toggle sendActionsForControlEvents:UIControlEventTouchUpInside];
        UITextView *coordinates=(UITextView *)find(form.view,^BOOL(UIView *v){return [v.accessibilityIdentifier isEqualToString:@"bld.coordinates"];});
        UITextField *speed=(UITextField *)find(form.view,^BOOL(UIView *v){return [v.accessibilityIdentifier isEqualToString:@"bld.speed"];});
        UITextField *accuracy=(UITextField *)find(form.view,^BOOL(UIView *v){return [v.accessibilityIdentifier isEqualToString:@"bld.accuracy"];});
        check(coordinates && speed && accuracy,@"all input fields are accessible");
        NSString *originalCoordinates=coordinates.text;
        [coordinates becomeFirstResponder];
        after(0.8, ^{
            check(coordinates.isFirstResponder,@"coordinate editor accepts focus");
            check(coordinates.inputAccessoryView.window != nil,@"keyboard close toolbar is attached to a visible keyboard");
            useItem(toolbarItem(coordinates,@"キーボードを閉じる"));
            check(!coordinates.isFirstResponder,@"coordinate keyboard dismisses without closing form");
            check([coordinates.text isEqualToString:originalCoordinates],@"keyboard dismissal preserves coordinate text");
            [coordinates becomeFirstResponder];
            useItem(toolbarItem(coordinates,@"次へ"));
            check(speed.isFirstResponder,@"next moves from coordinates to speed");
            useItem(toolbarItem(speed,@"次へ"));
            check(accuracy.isFirstResponder,@"next moves to accuracy");
            check(!toolbarItem(accuracy,@"次へ").enabled,@"next is disabled at final field");
            useItem(toolbarItem(accuracy,@"前へ"));
            check(speed.isFirstResponder,@"previous returns to speed");
            useItem(toolbarItem(speed,@"キーボードを閉じる"));
            check(!speed.isFirstResponder,@"numeric keyboard has a working dismiss action");
            [accuracy becomeFirstResponder];
            useItem(toolbarItem(accuracy,@"キーボードを閉じる"));
            check(!accuracy.isFirstResponder,@"accuracy numeric keyboard dismisses");
            UIScrollView *scroll=(UIScrollView *)find(form.view,^BOOL(UIView *v){return [v isKindOfClass:UIScrollView.class] && ![v isKindOfClass:UITextView.class];});
            UITapGestureRecognizer *blank=nil;
            for (UIGestureRecognizer *g in scroll.gestureRecognizers) if ([g isKindOfClass:UITapGestureRecognizer.class] && g.delegate==(id)form) blank=(UITapGestureRecognizer *)g;
            check(blank && !blank.cancelsTouchesInView,@"blank-area dismiss gesture does not cancel controls");
            BLDTouchFixture *touch=[BLDTouchFixture new];touch.view=speed;
            check(![blank.delegate gestureRecognizer:blank shouldReceiveTouch:(UITouch *)(id)touch],@"editing field taps are preserved");
            touch.view=button(nil,@"bld.startFeed");
            check(![blank.delegate gestureRecognizer:blank shouldReceiveTouch:(UITouch *)(id)touch],@"action button taps are preserved");
            touch.view=[UILabel new];
            check([blank.delegate gestureRecognizer:blank shouldReceiveTouch:(UITouch *)(id)touch],@"blank content permits keyboard dismissal");
            check(scroll.keyboardDismissMode==UIScrollViewKeyboardDismissModeInteractive,@"dragging can dismiss the keyboard interactively");
            [speed becomeFirstResponder];speed.text=@"invalid";
            UIButton *start=button(nil,@"bld.startFeed");
            [start sendActionsForControlEvents:UIControlEventTouchUpInside];
            check(!speed.isFirstResponder && !enabled && starts==0,@"invalid input dismisses keyboard and does not start feed");
            UIViewController *alert=form.presentedViewController;
            check([alert isKindOfClass:UIAlertController.class],@"validation message remains accessible");
            [alert dismissViewControllerAnimated:NO completion:^{
                speed.text=@"1.4";
                [coordinates becomeFirstResponder];
                after(0.7, ^{
                    [form.view layoutIfNeeded];
                    CGRect frame=[start convertRect:start.bounds toView:form.view];
                    check(CGRectGetMaxY(frame)<=CGRectGetMinY(form.view.keyboardLayoutGuide.layoutFrame)+1,@"start action stays above keyboard");
                    [start sendActionsForControlEvents:UIControlEventTouchUpInside];
                    check(enabled && starts==1 && !coordinates.isFirstResponder,@"start works while keyboard is open and dismisses it");
                    check(lastPoints.count==1 && fabs([lastPoints[0][0] doubleValue]-35.681236)<0.000001 && fabs([lastPoints[0][1] doubleValue]-139.767125)<0.000001,@"coordinate data reaches feed unchanged");
                    check(fabs(lastSpeed-1.4)<0.001 && fabs(lastAccuracy-5)<0.001,@"numeric data reaches feed unchanged");
                    [accuracy becomeFirstResponder];
                    UIButton *stop=button(nil,@"bld.stopFeed");
                    [stop sendActionsForControlEvents:UIControlEventTouchUpInside];
                    check(!enabled && stops==1 && !accuracy.isFirstResponder,@"stop works without manually hiding keyboard first");
                    [coordinates becomeFirstResponder];
                    UIBarButtonItem *done=form.navigationItem.rightBarButtonItem;
                    [UIApplication.sharedApplication sendAction:done.action to:done.target from:done forEvent:nil];
                    after(0.8, ^{
                        checkHost();
                        check(!coordinates.isFirstResponder && hostRoot.presentedViewController==nil,@"closing form ends editing and restores app content");
                        check(button(nil,@"bld.openControls") && !button(nil,@"bld.openControls").hidden,@"debug button returns after dismissal");
                        // Leave a native number pad open for the regression screenshot.
                        nativeAge.text=@"2";
                        [nativeAge becomeFirstResponder];
                        after(0.8, ^{
                            check(!button(nil,@"bld.dismissAppKeyboard").hidden,@"native keyboard close control returns outside settings");
                            result(@"passed",@"automatic native age number pad dismissal, unchanged age/continue flow, all settings keyboard controls, validation, sticky actions and original window verified");
                        });
                    });
                });
            }];
        });
    });
}
static void nativeAutoDismissChecks(void) {
    nativeAge.text=@"2";
    [nativeAge becomeFirstResponder];
    [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:nativeAge];
    after(1.15, ^{
        check(nativeAge.isFirstResponder,@"incomplete one-digit age is not dismissed automatically");
        nativeAge.text=@"24";
        [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:nativeAge];
        after(0.3, ^{
            check(nativeAge.isFirstResponder,@"age keyboard stays open during the typing pause");
            nativeAge.text=@"25";
            [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:nativeAge];
            after(0.7, ^{
                check(nativeAge.isFirstResponder,@"further typing cancels the previous pending dismissal");
                after(0.65, ^{
                    check(!nativeAge.isFirstResponder && nativeEnds>=2,@"settled native age automatically dismisses through editing-end delegate");
                    check([nativeAge.text isEqualToString:@"25"],@"automatic dismissal preserves the entered age");
                    check(nativeContinues==1,@"automatic dismissal never submits or skips age verification");
                    [nativeContinue sendActionsForControlEvents:UIControlEventTouchUpInside];
                    check(nativeContinues==2,@"original next button remains usable after automatic dismissal");
                    // A different screen's number pad must never auto-dismiss.
                    UIView *ageContainer=nativeAge.superview;
                    [hostRoot.view addSubview:nativeAge];
                    [nativeAge becomeFirstResponder];
                    [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:nativeAge];
                    after(1.2, ^{
                        check(nativeAge.isFirstResponder,@"unrelated native number pad is not dismissed");
                        [hostWindow endEditing:YES];
                        [ageContainer addSubview:nativeAge];
                        openDebugChecks();
                    });
                });
            });
        });
    });
}
static void runChecks(void) {
    checkHost();
    NSUInteger visible=0;
    for (UIWindow *window in hostWindow.windowScene.windows) if (!window.hidden && window.alpha>0 && window.rootViewController) visible++;
    check(visible==1,@"debug controls create no extra application window");
    check(button(nil,@"bld.openControls").window==hostWindow,@"controls attach to original app window");
    UIButton *floating=button(nil,@"bld.openControls");
    check(CGRectGetMinY(floating.frame)>=hostWindow.safeAreaInsets.top+88,@"default debug button leaves native top navigation clear");
    CGFloat initialX=floating.center.x;
    NSArray<UIAccessibilityCustomAction *> *moves=floating.accessibilityCustomActions;
    check(moves.count==2 && moves[0].actionHandler && moves[1].actionHandler,@"button movement is accessible without dragging");
    check(moves[0].actionHandler(moves[0]) && floating.center.x<initialX,@"floating controls can move away from native buttons");
    check(moves[1].actionHandler(moves[1]) && fabs(floating.center.x-initialX)<1,@"floating controls can return to the right");
    checkHost();
    check(nativeAge.inputAccessoryView==nil,@"native age input starts with unmodified number pad");
    [nativeAge becomeFirstResponder];
    after(0.8, ^{
        UIButton *dismiss=button(nil,@"bld.dismissAppKeyboard");
        check(nativeAge.isFirstResponder && dismiss && !dismiss.hidden,@"native age screen exposes an explicit keyboard close control");
        check(nativeAge.inputAccessoryView==nil && nativeAge.keyboardType==UIKeyboardTypeNumberPad,@"helper does not replace native keyboard or accessory");
        [dismiss sendActionsForControlEvents:UIControlEventTouchUpInside];
        after(0.5, ^{
            check(!nativeAge.isFirstResponder && nativeEnds>=1,@"native keyboard closes through original editing-end delegate");
            check([nativeAge.text isEqualToString:@"24"],@"native age value is preserved");
            check(nativeContinues==0,@"keyboard close does not bypass onboarding");
            check(dismiss.hidden,@"keyboard close control hides when no keyboard remains");
            [nativeContinue sendActionsForControlEvents:UIControlEventTouchUpInside];
            check(nativeContinues==1,@"original continue action remains usable after dismissal");
            nativeAutoDismissChecks();
        });
    });
}

@interface BLDTestRoot : UIViewController <UITextFieldDelegate>
@end
@implementation BLDTestRoot
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.whiteColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20,220,340,160)];
    label.text=@"Original app content remains visible";label.textColor=UIColor.blackColor;label.backgroundColor=UIColor.systemTealColor;
    label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.font=[UIFont boldSystemFontOfSize:28];
    label.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:label];
    nativeAge=[[UITextField alloc] initWithFrame:CGRectMake(20,110,140,70)];
    nativeAge.keyboardType=UIKeyboardTypeNumberPad;nativeAge.text=@"24";nativeAge.font=[UIFont systemFontOfSize:40];nativeAge.delegate=self;
    // Use the exact pinned runtime class name only inside this test host.
    Class ageClass=objc_allocateClassPair(UIView.class,"_TtC13OnboardingAPI7AgeView",0);
    objc_registerClassPair(ageClass);
    UIView *ageContainer=[[ageClass alloc] initWithFrame:self.view.bounds];
    ageContainer.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:ageContainer];
    [ageContainer addSubview:nativeAge];
    nativeContinue=[UIButton buttonWithType:UIButtonTypeSystem];
    [nativeContinue setTitle:@"Continue onboarding" forState:UIControlStateNormal];
    nativeContinue.translatesAutoresizingMaskIntoConstraints=NO;
    [nativeContinue addTarget:self action:@selector(continueOnboarding) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeContinue];
    [NSLayoutConstraint activateConstraints:@[[nativeContinue.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],[nativeContinue.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],[nativeContinue.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],[nativeContinue.heightAnchor constraintEqualToConstant:48]]];
}
- (void)textFieldDidEndEditing:(UITextField *)textField { (void)textField;nativeEnds++; }
- (void)continueOnboarding { nativeContinues++; }
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

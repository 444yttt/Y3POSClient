#import "BLDState.h"
#import <UIKit/UIKit.h>
#include <math.h>

@class BLDOverlayController;

/* The idle window only receives touches inside its visible control. */
@interface BLDOverlayWindow : UIWindow
@end

@implementation BLDOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.rootViewController.presentedViewController) return hit;
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface BLDOverlayRootController : UIViewController
@property(nonatomic, strong) UIButton *debugButton;
@end

@implementation BLDOverlayRootController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = UIColor.clearColor;
    self.debugButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.debugButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.baseBackgroundColor = UIColor.systemIndigoColor;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    self.debugButton.configuration = configuration;
    self.debugButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.debugButton.accessibilityLabel = @"位置情報テストの設定を開く";
    [self.view addSubview:self.debugButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.debugButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.debugButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.debugButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.debugButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
}
@end

@interface BLDFormController : UIViewController
@property(nonatomic, copy) void (^finish)(void);
@property(nonatomic, copy) void (^saveFields)(NSString *, NSString *, NSString *);
@property(nonatomic, copy) NSString *initialCoordinates;
@property(nonatomic, copy) NSString *initialSpeed;
@property(nonatomic, copy) NSString *initialAccuracy;
@property(nonatomic, strong) UITextView *coordinates;
@property(nonatomic, strong) UITextField *speed;
@property(nonatomic, strong) UITextField *accuracy;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) UIButton *stopButton;
- (void)refreshStatus;
- (void)rememberFields;
@end

static UILabel *BLDLabel(NSString *text, UIFontTextStyle style) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

static UITextField *BLDNumberField(NSString *value, NSString *label) {
    UITextField *field = [[UITextField alloc] init];
    field.text = value;
    field.accessibilityLabel = label;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = UIKeyboardTypeDecimalPad;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return field;
}

static BOOL BLDParseNumber(NSString *text, double *value) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:trimmed];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double result = 0;
    if (![scanner scanDouble:&result] || !scanner.isAtEnd || !isfinite(result)) return NO;
    *value = result;
    return YES;
}

@implementation BLDFormController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"位置情報テスト";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完了" style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];

    self.status = BLDLabel(@"", UIFontTextStyleFootnote);
    self.status.accessibilityLabel = @"位置情報注入の状態";
    [stack addArrangedSubview:self.status];
    [stack addArrangedSubview:BLDLabel(@"テスト座標（緯度, 経度）", UIFontTextStyleHeadline)];
    [stack addArrangedSubview:BLDLabel(@"1行なら固定位置。複数行なら、その順に移動します（最大256地点）。開始するまで位置情報は置き換わりません。", UIFontTextStyleFootnote)];

    self.coordinates = [[UITextView alloc] init];
    self.coordinates.text = self.initialCoordinates;
    self.coordinates.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular]];
    self.coordinates.adjustsFontForContentSizeCategory = YES;
    self.coordinates.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.coordinates.layer.cornerRadius = 8;
    self.coordinates.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.coordinates.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.coordinates.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.coordinates.autocorrectionType = UITextAutocorrectionTypeNo;
    self.coordinates.spellCheckingType = UITextSpellCheckingTypeNo;
    self.coordinates.accessibilityLabel = @"テスト座標。1行につき緯度、カンマ、経度";
    [self.coordinates.heightAnchor constraintEqualToConstant:170].active = YES;
    [stack addArrangedSubview:self.coordinates];

    [stack addArrangedSubview:BLDLabel(@"移動速度（m/s、0で最初の地点に固定）", UIFontTextStyleHeadline)];
    self.speed = BLDNumberField(self.initialSpeed, @"移動速度。メートル毎秒");
    [stack addArrangedSubview:self.speed];
    [stack addArrangedSubview:BLDLabel(@"水平精度（m、0より大きい数）", UIFontTextStyleHeadline)];
    self.accuracy = BLDNumberField(self.initialAccuracy, @"水平精度。メートル");
    [stack addArrangedSubview:self.accuracy];

    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.startButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.startButton setTitle:@"この座標で注入を開始" forState:UIControlStateNormal];
    [self.startButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    self.startButton.accessibilityLabel = @"入力した座標で位置情報の置き換えを開始する";
    [self.startButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [stack addArrangedSubview:self.startButton];

    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.stopButton.configuration = [UIButtonConfiguration borderedButtonConfiguration];
    [self.stopButton setTitle:@"注入を停止して実際の位置に戻す" forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [self.stopButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [stack addArrangedSubview:self.stopButton];
    [stack addArrangedSubview:BLDLabel(@"経路の終端では最後の地点に留まります。「完了」で画面を閉じても、開始した注入は停止するまで続きます。", UIFontTextStyleFootnote)];
    [self refreshStatus];
}

- (void)rememberFields {
    if (self.saveFields) self.saveFields(self.coordinates.text ?: @"", self.speed.text ?: @"", self.accuracy.text ?: @"");
}

- (void)done {
    [self.view endEditing:YES];
    [self rememberFields];
    if (self.finish) self.finish();
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"入力を確認してください"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)start {
    NSMutableArray<NSArray<NSNumber *> *> *points = [NSMutableArray array];
    NSArray<NSString *> *lines = [self.coordinates.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSUInteger lineNumber = 0;
    for (NSString *raw in lines) {
        ++lineNumber;
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        NSArray<NSString *> *parts;
        if ([line containsString:@","]) {
            parts = [line componentsSeparatedByString:@","];
        } else {
            NSMutableArray<NSString *> *tokens = [NSMutableArray array];
            for (NSString *part in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
                if (part.length) [tokens addObject:part];
            }
            parts = tokens;
        }
        double latitude, longitude;
        if (parts.count != 2 || !BLDParseNumber(parts[0], &latitude) || !BLDParseNumber(parts[1], &longitude)
            || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
            [self showError:[NSString stringWithFormat:@"%lu行目は「緯度, 経度」で入力してください。緯度は−90〜90、経度は−180〜180です。", (unsigned long)lineNumber]];
            return;
        }
        [points addObject:@[@(latitude), @(longitude)]];
        if (points.count > 256) {
            [self showError:@"座標は256地点まで入力できます。"];
            return;
        }
    }
    if (!points.count) {
        [self showError:@"テストする座標を1地点以上入力してください。"];
        return;
    }
    double speed, accuracy;
    if (!BLDParseNumber(self.speed.text, &speed) || speed < 0) {
        [self showError:@"移動速度は0以上の有限の数で入力してください。"];
        return;
    }
    if (!BLDParseNumber(self.accuracy.text, &accuracy) || accuracy <= 0) {
        [self showError:@"水平精度は0より大きい有限の数で入力してください。"];
        return;
    }
    NSError *error = nil;
    if (!BLDStart(points, speed, accuracy, &error)) {
        [self showError:error.localizedDescription ?: @"位置情報の注入を開始できませんでした。"];
        return;
    }
    [self.view endEditing:YES];
    [self rememberFields];
    [self refreshStatus];
}

- (void)stop {
    BLDStop();
    [self refreshStatus];
}

- (void)refreshStatus {
    if (!self.isViewLoaded) return;
    BOOL active = BLDIsEnabled();
    self.status.text = BLDStatusText();
    self.status.accessibilityValue = self.status.text;
    self.status.textColor = active ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    self.startButton.accessibilityValue = active ? @"注入中。押すと経路を最初から開始します" : @"停止中";
    self.stopButton.enabled = active;
}
@end

@interface BLDOverlayController : NSObject <UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) BLDOverlayWindow *window;
@property(nonatomic, strong) BLDOverlayRootController *root;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, weak) BLDFormController *form;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *coordinatesText;
@property(nonatomic, copy) NSString *speedText;
@property(nonatomic, copy) NSString *accuracyText;
@end

@implementation BLDOverlayController
- (instancetype)init {
    if ((self = [super init])) {
        _coordinatesText = @"35.681236,139.767125";
        _speedText = @"1.4";
        _accuracyText = @"5";
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillEnterForegroundNotification,
                                 UISceneDidActivateNotification, UISceneWillDeactivateNotification, UISceneDidDisconnectNotification]) {
            [center addObserver:self selector:@selector(sceneChanged:) name:name object:nil];
        }
        _timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (UIWindowScene *)foregroundScene {
    UIWindowScene *inactive = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (scene.activationState == UISceneActivationStateForegroundInactive) inactive = (UIWindowScene *)scene;
    }
    return inactive;
}

- (void)sceneChanged:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self refresh];
    [self.form refreshStatus];
}

- (void)refresh {
    UIWindowScene *scene = [self foregroundScene];
    if (!scene) {
        self.window.hidden = YES;
        return;
    }
    if (self.window.windowScene != scene) {
        if (self.navigation) [self closeAnimated:NO];
        self.window.hidden = YES;
        self.root = [[BLDOverlayRootController alloc] init];
        self.window = [[BLDOverlayWindow alloc] initWithWindowScene:scene];
        self.window.backgroundColor = UIColor.clearColor;
        self.window.windowLevel = UIWindowLevelStatusBar + 1;
        self.window.rootViewController = self.root;
        [self.root loadViewIfNeeded];
        [self.root.debugButton addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    }
    self.window.frame = scene.coordinateSpace.bounds;
    self.window.hidden = NO;
    BOOL active = BLDIsEnabled();
    UIButtonConfiguration *configuration = self.root.debugButton.configuration;
    configuration.title = active ? @"位置注入 ON" : @"位置テスト";
    configuration.baseBackgroundColor = active ? UIColor.systemOrangeColor : UIColor.systemIndigoColor;
    self.root.debugButton.configuration = configuration;
    self.root.debugButton.accessibilityValue = active ? @"位置情報を置き換えています" : @"実際の位置情報を使用しています";
}

- (void)open {
    if (self.navigation || self.root.presentedViewController) return;
    for (UIWindow *window in self.window.windowScene.windows) {
        if (window.isKeyWindow && window != self.window) {
            self.previousKeyWindow = window;
            break;
        }
    }
    BLDFormController *form = [[BLDFormController alloc] init];
    form.initialCoordinates = self.coordinatesText;
    form.initialSpeed = self.speedText;
    form.initialAccuracy = self.accuracyText;
    __weak BLDOverlayController *weakSelf = self;
    form.finish = ^{ [weakSelf closeAnimated:YES]; };
    form.saveFields = ^(NSString *coordinates, NSString *speed, NSString *accuracy) {
        weakSelf.coordinatesText = coordinates;
        weakSelf.speedText = speed;
        weakSelf.accuracyText = accuracy;
    };
    self.form = form;
    self.navigation = [[UINavigationController alloc] initWithRootViewController:form];
    self.navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    self.navigation.presentationController.delegate = self;
    self.navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
    self.navigation.sheetPresentationController.prefersGrabberVisible = YES;
    /* Become key once for editing, then restore the app's prior key window. */
    [self.window makeKeyWindow];
    [self.root presentViewController:self.navigation animated:YES completion:nil];
}

- (void)restoreAppKeyWindow {
    UIWindow *previous = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    if (previous && !previous.hidden && previous.windowScene == self.window.windowScene) {
        [previous makeKeyWindow];
    } else {
        for (UIWindow *candidate in self.window.windowScene.windows) {
            if (candidate != self.window && !candidate.hidden && candidate.windowLevel == UIWindowLevelNormal) {
                [candidate makeKeyWindow];
                break;
            }
        }
    }
}

- (void)closeAnimated:(BOOL)animated {
    [self.form.view endEditing:YES];
    [self.form rememberFields];
    [self.root dismissViewControllerAnimated:animated completion:nil];
    [self restoreAppKeyWindow];
    self.navigation = nil;
    self.form = nil;
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    [self.form.view endEditing:YES];
    [self.form rememberFields];
    self.navigation = nil;
    self.form = nil;
    [self restoreAppKeyWindow];
}
@end

void BLDInstallDebugUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static BLDOverlayController *controller;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ controller = [[BLDOverlayController alloc] init]; });
        [controller refresh];
    });
}

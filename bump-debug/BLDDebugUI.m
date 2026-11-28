#import "BLDState.h"
#import <UIKit/UIKit.h>
#include <math.h>

static CGRect BLDLastKeyboardFrame;
static BOOL BLDKeyboardVisible;
static void BLDAppendNativeControls(UIView *view, UIWindow *window, NSMutableArray<NSString *> *lines, NSUInteger *visited, NSUInteger *recorded) {
    if (!view || *visited >= 150 || *recorded >= 24) return;
    (*visited)++;
    BOOL own = [view.accessibilityIdentifier hasPrefix:@"bld."];
    if (own) return;
    if (!own && ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class])) {
        (*recorded)++;
        CGRect frame=[view convertRect:view.bounds toView:window];
        NSString *entry=[NSString stringWithFormat:@"control=%@ frame=%@ hidden=%d alpha=%.2f",NSStringFromClass(view.class),NSStringFromCGRect(frame),view.hidden,(double)view.alpha];
        if ([view isKindOfClass:UIControl.class]) entry=[entry stringByAppendingFormat:@" enabled=%d",((UIControl *)view).enabled];
        if ([view isKindOfClass:UITextField.class]) {
            UITextField *field=(UITextField *)view;
            entry=[entry stringByAppendingFormat:@" keyboard=%ld return=%ld editing=%d length=%@ accessory=%@",(long)field.keyboardType,(long)field.returnKeyType,field.isFirstResponder,field.secureTextEntry ? @"redacted" : [NSString stringWithFormat:@"%lu",(unsigned long)field.text.length],field.inputAccessoryView ? NSStringFromClass(field.inputAccessoryView.class) : @"none"];
        }
        [lines addObject:entry];
    }
    for (UIView *child in view.subviews) BLDAppendNativeControls(child,window,lines,visited,recorded);
}
// Scope automatic dismissal to the age screen in the pinned Bump build.
// Other number pads (phone, verification code, debug inputs) retain their behavior.
static BOOL BLDIsNativeAgeField(UITextField *field) {
    if (!field || field.secureTextEntry || [field.accessibilityIdentifier hasPrefix:@"bld."]) return NO;
    Class ageClass=NSClassFromString(@"_TtC13OnboardingAPI7AgeView");
    if (!ageClass) return NO;
    if ([field.delegate isKindOfClass:ageClass]) return YES;
    for (UIView *view=field.superview;view;view=view.superview) if ([view isKindOfClass:ageClass]) return YES;
    return NO;
}
static BOOL BLDCompleteAgeText(NSString *text) {
    if (text.length<2 || text.length>3) return NO;
    return [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location==NSNotFound;
}
static NSString *BLDScreenDiagnostics(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"UI: existing-app-window/v3-age-keyboard"];
    [lines addObject:[NSString stringWithFormat:@"appState=%ld keyboardVisible=%d lastKeyboard=%@", (long)UIApplication.sharedApplication.applicationState, BLDKeyboardVisible, NSStringFromCGRect(BLDLastKeyboardFrame)]];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        [lines addObject:[NSString stringWithFormat:@"sceneState=%ld windows=%lu", (long)scene.activationState, (unsigned long)ws.windows.count]];
        for (UIWindow *window in ws.windows) {
            UIViewController *root = window.rootViewController;
            UIView *view = root.viewIfLoaded;
            [lines addObject:[NSString stringWithFormat:@"%@ key=%d hidden=%d level=%.0f root=%@ loaded=%d attached=%d children=%lu presented=%@",
                NSStringFromClass(window.class), window.isKeyWindow, window.hidden, (double)window.windowLevel,
                root ? NSStringFromClass(root.class) : @"none", root.isViewLoaded, view.window == window,
                (unsigned long)root.childViewControllers.count,
                root.presentedViewController ? NSStringFromClass(root.presentedViewController.class) : @"none"]];
            if (window.windowLevel == UIWindowLevelNormal && view) {
                NSUInteger visited=0,recorded=0;
                BLDAppendNativeControls(view,window,lines,&visited,&recorded);
            }
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

@interface BLDFormController : UIViewController <UITextFieldDelegate, UITextViewDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, copy) void (^finish)(void);
@property(nonatomic, copy) void (^saveFields)(NSString *, NSString *, NSString *);
@property(nonatomic, copy) NSString *initialCoordinates;
@property(nonatomic, copy) NSString *initialSpeed;
@property(nonatomic, copy) NSString *initialAccuracy;
@property(nonatomic, strong) UITextView *coordinates;
@property(nonatomic, strong) UITextField *speed;
@property(nonatomic, strong) UITextField *accuracy;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UILabel *screenStatus;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UIStackView *actions;
@property(nonatomic, strong) UIToolbar *keyboardToolbar;
@property(nonatomic, strong) UIBarButtonItem *previousInput;
@property(nonatomic, strong) UIBarButtonItem *nextInput;
@property(nonatomic, strong) UIButton *diagnosticToggle;
@property(nonatomic, strong) UIButton *diagnosticCopy;
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
        initWithTitle:@"閉じる" style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    self.keyboardToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0,0,CGRectGetWidth(self.view.bounds),44)];
    self.keyboardToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.previousInput = [[UIBarButtonItem alloc] initWithTitle:@"前へ" style:UIBarButtonItemStylePlain target:self action:@selector(previousField)];
    self.nextInput = [[UIBarButtonItem alloc] initWithTitle:@"次へ" style:UIBarButtonItemStylePlain target:self action:@selector(nextField)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *dismiss = [[UIBarButtonItem alloc] initWithTitle:@"キーボードを閉じる" style:UIBarButtonItemStyleDone target:self action:@selector(dismissKeyboard)];
    self.keyboardToolbar.items = @[self.previousInput,self.nextInput,space,dismiss];
    self.actions = [[UIStackView alloc] init];
    self.actions.axis = UILayoutConstraintAxisHorizontal;
    self.actions.distribution = UIStackViewDistributionFillEqually;
    self.actions.spacing = 10;
    self.actions.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actions];
    UIScrollView *scroll = [[UIScrollView alloc] init];
    self.scroll = scroll;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    UITapGestureRecognizer *blankTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    blankTap.cancelsTouchesInView = NO;
    blankTap.delegate = self;
    [scroll addGestureRecognizer:blankTap];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardShown:) name:UIKeyboardDidShowNotification object:nil];
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSLayoutConstraint *keyboardBottom = [self.actions.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8];
    keyboardBottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        keyboardBottom,
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [self.actions.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.actions.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.actions.topAnchor constant:-12],
        [self.actions.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [self.actions.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
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
    self.coordinates.inputAccessoryView = self.keyboardToolbar;
    self.coordinates.delegate = self;
    self.coordinates.accessibilityIdentifier = @"bld.coordinates";
    self.coordinates.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.coordinates.autocorrectionType = UITextAutocorrectionTypeNo;
    self.coordinates.spellCheckingType = UITextSpellCheckingTypeNo;
    self.coordinates.accessibilityLabel = @"テスト座標。1行につき緯度、カンマ、経度";
    [self.coordinates.heightAnchor constraintEqualToConstant:170].active = YES;
    [stack addArrangedSubview:self.coordinates];

    [stack addArrangedSubview:BLDLabel(@"移動速度（m/s、0で最初の地点に固定）", UIFontTextStyleHeadline)];
    self.speed = BLDNumberField(self.initialSpeed, @"移動速度。メートル毎秒");
    self.speed.inputAccessoryView = self.keyboardToolbar;
    self.speed.delegate = self;
    self.speed.accessibilityIdentifier = @"bld.speed";
    [stack addArrangedSubview:self.speed];
    [stack addArrangedSubview:BLDLabel(@"水平精度（m、0より大きい数）", UIFontTextStyleHeadline)];
    self.accuracy = BLDNumberField(self.initialAccuracy, @"水平精度。メートル");
    self.accuracy.inputAccessoryView = self.keyboardToolbar;
    self.accuracy.delegate = self;
    self.accuracy.accessibilityIdentifier = @"bld.accuracy";
    [stack addArrangedSubview:self.accuracy];

    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.startButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    self.startButton.accessibilityIdentifier = @"bld.startFeed";
    [self.startButton setTitle:@"開始・更新" forState:UIControlStateNormal];
    [self.startButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    self.startButton.accessibilityLabel = @"入力した座標で位置情報の置き換えを開始する";
    [self.startButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [self.actions addArrangedSubview:self.startButton];

    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.stopButton.configuration = [UIButtonConfiguration borderedButtonConfiguration];
    self.stopButton.accessibilityIdentifier = @"bld.stopFeed";
    self.stopButton.accessibilityLabel = @"位置情報の注入を停止する";
    [self.stopButton setTitle:@"停止" forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [self.stopButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [self.actions addArrangedSubview:self.stopButton];
    [stack addArrangedSubview:BLDLabel(@"経路の終端では最後の地点に留まります。「閉じる」で画面を閉じても、開始した注入は停止するまで続きます。", UIFontTextStyleFootnote)];
    [stack addArrangedSubview:BLDLabel(@"位置テストのボタンはドラッグで移動できます。本体の操作ボタンに重なる場合は移動してください。", UIFontTextStyleFootnote)];
    [stack addArrangedSubview:BLDLabel(@"Bump内部の位置情報経路に合成データを渡します。別アプリやMFi認証は使いません。内蔵GPSの実測値ではなく、他のアプリの位置は変更しません。", UIFontTextStyleFootnote)];
    self.diagnosticToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticToggle setTitle:@"診断情報を表示" forState:UIControlStateNormal];
    self.diagnosticToggle.accessibilityIdentifier = @"bld.toggleDiagnostics";
    [self.diagnosticToggle addTarget:self action:@selector(toggleDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.diagnosticToggle];
    self.screenStatus = BLDLabel(@"", UIFontTextStyleCaption1);
    self.screenStatus.hidden = YES;
    [stack addArrangedSubview:self.screenStatus];
    self.diagnosticCopy = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticCopy setTitle:@"画面診断をコピー" forState:UIControlStateNormal];
    self.diagnosticCopy.accessibilityIdentifier = @"bld.copyScreenDiagnostics";
    self.diagnosticCopy.hidden = YES;
    [self.diagnosticCopy addTarget:self action:@selector(copyScreenDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.diagnosticCopy];
    [self refreshStatus];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSArray<UIView *> *)inputs { return @[self.coordinates,self.speed,self.accuracy]; }
- (NSInteger)activeInputIndex {
    NSArray *inputs = [self inputs];
    for (NSUInteger i=0;i<inputs.count;i++) if ([inputs[i] isFirstResponder]) return (NSInteger)i;
    return NSNotFound;
}
- (void)updateInputNavigation {
    NSInteger index = [self activeInputIndex];
    self.previousInput.enabled = index != NSNotFound && index > 0;
    self.nextInput.enabled = index != NSNotFound && index < 2;
}
- (void)scrollToInput {
    NSInteger index = [self activeInputIndex];
    if (index == NSNotFound) return;
    UIView *input = [self inputs][(NSUInteger)index];
    [self.view layoutIfNeeded];
    CGRect rect = [input convertRect:input.bounds toView:self.scroll];
    [self.scroll scrollRectToVisible:CGRectInset(rect,-8,-8) animated:YES];
}
- (void)keyboardShown:(NSNotification *)note { (void)note; [self scrollToInput]; }
- (void)inputBegan {
    [self updateInputNavigation];
    dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToInput]; });
}
- (void)textFieldDidBeginEditing:(UITextField *)textField { (void)textField; [self inputBegan]; }
- (void)textViewDidBeginEditing:(UITextView *)textView { (void)textView; [self inputBegan]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { (void)textField; [self dismissKeyboard]; return YES; }
- (void)previousField {
    NSInteger index=[self activeInputIndex];
    if (index != NSNotFound && index > 0) [[self inputs][(NSUInteger)(index-1)] becomeFirstResponder];
}
- (void)nextField {
    NSInteger index=[self activeInputIndex];
    if (index != NSNotFound && index < 2) [[self inputs][(NSUInteger)(index+1)] becomeFirstResponder];
}
- (void)dismissKeyboard { [self.view.window endEditing:YES]; [self updateInputNavigation]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    for (UIView *view=touch.view;view;view=view.superview) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class]) return NO;
    }
    return YES;
}
- (void)toggleDiagnostics {
    [self dismissKeyboard];
    BOOL show = self.screenStatus.hidden;
    self.screenStatus.hidden = !show; self.diagnosticCopy.hidden = !show;
    [self.diagnosticToggle setTitle:show ? @"診断情報を閉じる" : @"診断情報を表示" forState:UIControlStateNormal];
}
- (void)copyScreenDiagnostics {
    UIPasteboard.generalPasteboard.string = BLDScreenDiagnostics();
}
- (void)rememberFields {
    if (self.saveFields) self.saveFields(self.coordinates.text ?: @"", self.speed.text ?: @"", self.accuracy.text ?: @"");
}

- (void)done {
    [self dismissKeyboard];
    [self rememberFields];
    if (self.finish) self.finish();
}

- (void)showError:(NSString *)message {
    [self dismissKeyboard];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"入力を確認してください"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)start {
    [self dismissKeyboard];
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
    [self dismissKeyboard];
    BLDStop();
    [self refreshStatus];
}

- (void)refreshStatus {
    if (!self.isViewLoaded) return;
    BOOL active = BLDIsEnabled();
    NSString *fullStatus = BLDStatusText();
    NSArray<NSString *> *lines = [fullStatus componentsSeparatedByString:@"\n"];
    self.status.text = lines.count >= 3 ? [@[lines[0],lines[2]] componentsJoinedByString:@"\n"] : fullStatus;
    self.screenStatus.text = [NSString stringWithFormat:@"%@\n%@",fullStatus,BLDScreenDiagnostics()];
    self.status.accessibilityValue = self.status.text;
    self.status.textColor = active ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    self.startButton.accessibilityValue = active ? @"注入中。押すと経路を最初から開始します" : @"停止中";
    self.stopButton.enabled = active;
}
@end

@interface BLDOverlayController : NSObject <UIAdaptivePresentationControllerDelegate>
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, strong) UIButton *debugButton;
@property(nonatomic, strong) UIButton *appKeyboardButton;
@property(nonatomic) BOOL appKeyboardVisible;
@property(nonatomic) NSUInteger ageEditingGeneration;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *buttonConstraints;
@property(nonatomic, strong) NSLayoutConstraint *buttonTop;
@property(nonatomic, strong) NSLayoutConstraint *buttonTrailing;
@property(nonatomic) CGPoint dragOrigin;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, weak) BLDFormController *form;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *coordinatesText;
@property(nonatomic, copy) NSString *speedText;
@property(nonatomic, copy) NSString *accuracyText;
- (void)placeControlsAtCenter:(CGPoint)center;
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
        for (NSString *name in @[UIKeyboardWillShowNotification,UIKeyboardWillHideNotification]) {
            [center addObserver:self selector:@selector(appKeyboardChanged:) name:name object:nil];
        }
        for (NSString *name in @[UITextFieldTextDidBeginEditingNotification,UITextFieldTextDidChangeNotification,UITextFieldTextDidEndEditingNotification]) {
            [center addObserver:self selector:@selector(nativeAgeEdited:) name:name object:nil];
        }
        _timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (UIWindow *)readyAppWindow {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.hidden || candidate.alpha <= 0 || fabs(candidate.windowLevel - UIWindowLevelNormal) > 0.01) continue;
            UIViewController *root = candidate.rootViewController;
            // Do not create/load a root, attach a new UIWindow or take key status
            // while the real application is still connecting its scene.
            if (!root || !root.isViewLoaded || root.viewIfLoaded.window != candidate || CGRectIsEmpty(candidate.bounds)) continue;
            if (candidate.isKeyWindow) return candidate;
            if (!fallback) fallback = candidate;
        }
    }
    return fallback;
}

- (void)sceneChanged:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([note.name isEqualToString:UISceneDidDisconnectNotification] && self.window.windowScene == note.object) {
            if (self.navigation) [self closeAnimated:NO];
            [NSLayoutConstraint deactivateConstraints:self.buttonConstraints ?: @[]];
            self.buttonConstraints = nil;
            [self.debugButton removeFromSuperview];
            [self.appKeyboardButton removeFromSuperview];
            self.window = nil;
        }
        [self refresh];
    });
}
- (void)appKeyboardChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.appKeyboardVisible = [note.name isEqualToString:UIKeyboardWillShowNotification];
        BLDKeyboardVisible = self.appKeyboardVisible;
        if (self.appKeyboardVisible) BLDLastKeyboardFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        [self refresh];
    });
}
- (void)nativeAgeEdited:(NSNotification *)note {
    if (![note.object isKindOfClass:UITextField.class]) return;
    UITextField *field=(UITextField *)note.object;
    // Invalidate pending work even when focus moves to a different editor.
    NSUInteger generation=++self.ageEditingGeneration;
    if (self.navigation || !field.isFirstResponder || field.window!=self.window ||
        !BLDIsNativeAgeField(field) || !BLDCompleteAgeText(field.text) || field.markedTextRange) return;
    NSString *text=[field.text copy];
    __weak UITextField *weakField=field;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.9*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        UITextField *current=weakField;
        if (self.ageEditingGeneration!=generation || self.navigation ||
            UIApplication.sharedApplication.applicationState!=UIApplicationStateActive ||
            !current.isFirstResponder || current.window!=self.window ||
            !BLDIsNativeAgeField(current) || ![current.text isEqualToString:text] || current.markedTextRange) return;
        // Preserve the value, native delegate, editing-ended event and age validation.
        // Only dismiss; the user still presses Bump's original next button.
        [self dismissAppKeyboard];
    });
}
- (void)dismissAppKeyboard {
    if ([self.window endEditing:YES]) { self.appKeyboardVisible = NO; BLDKeyboardVisible = NO; }
    [self refresh];
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self refresh];
    [self.form refreshStatus];
}
- (void)refresh {
    UIWindow *window = [self readyAppWindow];
    if (!window) { self.debugButton.hidden = YES; self.appKeyboardButton.hidden = YES; return; }
    if (self.navigation && !self.navigation.presentingViewController) {
        [self.form rememberFields]; self.navigation = nil; self.form = nil;
    }
    if (self.window != window) {
        if (self.navigation) [self closeAnimated:NO];
        [NSLayoutConstraint deactivateConstraints:self.buttonConstraints ?: @[]];
        [self.debugButton removeFromSuperview];
        [self.appKeyboardButton removeFromSuperview];
        self.window = window;
        if (!self.debugButton) {
            self.debugButton = [UIButton buttonWithType:UIButtonTypeSystem];
            self.debugButton.translatesAutoresizingMaskIntoConstraints = NO;
            self.debugButton.titleLabel.adjustsFontForContentSizeCategory = YES;
            self.debugButton.accessibilityLabel = @"位置情報テストの設定を開く";
            self.debugButton.accessibilityIdentifier = @"bld.openControls";
            self.debugButton.accessibilityHint = @"ドラッグで移動できます。";
            UIPanGestureRecognizer *move=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveControls:)];
            [self.debugButton addGestureRecognizer:move];
            __weak BLDOverlayController *weakSelf=self;
            UIAccessibilityCustomAction *left=[[UIAccessibilityCustomAction alloc] initWithName:@"左側へ移動" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
                (void)action; BLDOverlayController *controller=weakSelf;
                if (!controller.window) return NO;
                [controller placeControlsAtCenter:CGPointMake(0,controller.debugButton.center.y)];return YES;
            }];
            UIAccessibilityCustomAction *right=[[UIAccessibilityCustomAction alloc] initWithName:@"右側へ移動" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
                (void)action; BLDOverlayController *controller=weakSelf;
                if (!controller.window) return NO;
                [controller placeControlsAtCenter:CGPointMake(CGRectGetMaxX(controller.window.bounds),controller.debugButton.center.y)];return YES;
            }];
            self.debugButton.accessibilityCustomActions=@[left,right];
            [self.debugButton addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        }
        if (!self.appKeyboardButton) {
            self.appKeyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
            self.appKeyboardButton.translatesAutoresizingMaskIntoConstraints = NO;
            UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
            configuration.title = @"キーボードを閉じる";
            configuration.contentInsets = NSDirectionalEdgeInsetsMake(10,12,10,12);
            self.appKeyboardButton.configuration = configuration;
            self.appKeyboardButton.accessibilityLabel = @"Bumpのキーボードを閉じる";
            self.appKeyboardButton.accessibilityIdentifier = @"bld.dismissAppKeyboard";
            [self.appKeyboardButton addTarget:self action:@selector(dismissAppKeyboard) forControlEvents:UIControlEventTouchUpInside];
        }
        [window addSubview:self.debugButton];
        [window addSubview:self.appKeyboardButton];
        self.buttonTop=[self.debugButton.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:104];
        self.buttonTrailing=[self.debugButton.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12];
        self.buttonConstraints = @[
            self.buttonTop,
            self.buttonTrailing,
            [self.debugButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
            [self.debugButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.appKeyboardButton.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8],
            [self.appKeyboardButton.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [self.appKeyboardButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
            [self.appKeyboardButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ];
        [NSLayoutConstraint activateConstraints:self.buttonConstraints];
        self.debugButton.layer.zPosition = 10000;
        self.appKeyboardButton.layer.zPosition = 10000;
    }
    self.debugButton.hidden = self.navigation != nil;
    self.appKeyboardButton.hidden = !self.appKeyboardVisible || self.navigation != nil;
    [window bringSubviewToFront:self.debugButton];
    [window bringSubviewToFront:self.appKeyboardButton];
    BOOL active = BLDIsEnabled();
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = active ? @"位置注入 ON" : @"位置テスト";
    configuration.baseBackgroundColor = active ? UIColor.systemOrangeColor : UIColor.systemIndigoColor;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    self.debugButton.configuration = configuration;
    self.debugButton.accessibilityValue = active ? @"合成入力ON" : @"合成入力OFF";
}

- (void)placeControlsAtCenter:(CGPoint)center {
    UIWindow *window=self.window;
    if (!window) return;
    [window layoutIfNeeded];
    CGRect safe=UIEdgeInsetsInsetRect(window.bounds,window.safeAreaInsets);
    CGFloat halfWidth=CGRectGetWidth(self.debugButton.bounds)/2;
    CGFloat halfHeight=CGRectGetHeight(self.debugButton.bounds)/2;
    center.x=MAX(CGRectGetMinX(safe)+12+halfWidth,MIN(CGRectGetMaxX(safe)-12-halfWidth,center.x));
    center.y=MAX(CGRectGetMinY(safe)+8+halfHeight,MIN(CGRectGetMaxY(safe)-8-halfHeight,center.y));
    self.buttonTop.constant=center.y-halfHeight-CGRectGetMinY(safe);
    self.buttonTrailing.constant=center.x+halfWidth-CGRectGetMaxX(safe);
    [window layoutIfNeeded];
}
- (void)moveControls:(UIPanGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan) self.dragOrigin=self.debugButton.center;
    if (gesture.state==UIGestureRecognizerStateChanged || gesture.state==UIGestureRecognizerStateEnded) {
        CGPoint movement=[gesture translationInView:self.window];
        [self placeControlsAtCenter:CGPointMake(self.dragOrigin.x+movement.x,self.dragOrigin.y+movement.y)];
    }
}
- (UIViewController *)presenter {
    UIViewController *current = self.window.rootViewController;
    for (NSUInteger depth = 0; current && depth < 32; depth++) {
        if (current.presentedViewController && !current.presentedViewController.isBeingDismissed) {
            current = current.presentedViewController;
        } else if ([current isKindOfClass:UINavigationController.class] && ((UINavigationController *)current).visibleViewController) {
            current = ((UINavigationController *)current).visibleViewController;
        } else if ([current isKindOfClass:UITabBarController.class] && ((UITabBarController *)current).selectedViewController) {
            current = ((UITabBarController *)current).selectedViewController;
        } else break;
    }
    return current;
}
- (void)open {
    if (self.navigation) return;
    [self.window endEditing:YES];
    UIViewController *presenter = [self presenter];
    if (!presenter || !presenter.isViewLoaded || presenter.viewIfLoaded.window != self.window ||
        presenter.isBeingPresented || presenter.isBeingDismissed || [presenter isKindOfClass:UIAlertController.class]) return;
    BLDFormController *form = [[BLDFormController alloc] init];
    form.initialCoordinates = self.coordinatesText;
    form.initialSpeed = self.speedText;
    form.initialAccuracy = self.accuracyText;
    __weak BLDOverlayController *weakSelf = self;
    form.finish = ^{ [weakSelf closeAnimated:YES]; };
    form.saveFields = ^(NSString *coordinates, NSString *speed, NSString *accuracy) {
        weakSelf.coordinatesText = coordinates; weakSelf.speedText = speed; weakSelf.accuracyText = accuracy;
    };
    self.form = form;
    self.navigation = [[UINavigationController alloc] initWithRootViewController:form];
    self.navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    self.navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
    self.navigation.sheetPresentationController.prefersGrabberVisible = YES;
    self.navigation.presentationController.delegate = self;
    self.debugButton.hidden = YES;
    [presenter presentViewController:self.navigation animated:YES completion:nil];
}
- (void)closeAnimated:(BOOL)animated {
    UINavigationController *navigation = self.navigation;
    if (!navigation) return;
    [navigation.view endEditing:YES];
    [self.form rememberFields];
    __weak BLDOverlayController *weakSelf = self;
    [navigation dismissViewControllerAnimated:animated completion:^{
        if (weakSelf.navigation == navigation) {
            weakSelf.navigation = nil; weakSelf.form = nil; [weakSelf refresh];
        }
    }];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController != self.navigation) return;
    [self.form rememberFields];
    self.navigation = nil; self.form = nil;
    [self refresh];
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

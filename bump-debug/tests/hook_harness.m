#import "../BLDState.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

/*
 * All manager objects below are NSObject test doubles. Before hook installation,
 * the CLLocationManager methods that the hooks capture as originals are replaced
 * by harmless in-process fixtures. No real CLLocationManager is initialized and
 * no location scan, permission request or daemon-backed API is invoked.
 */
static NSUInteger checks;
static const void *receivedKey = &receivedKey;
static const void *callbackCountKey = &callbackCountKey;
static const void *callbackMainThreadKey = &callbackMainThreadKey;
static const void *delegateKey = &delegateKey;
static const void *storedLocationKey = &storedLocationKey;
static const void *startCountKey = &startCountKey;
static const void *stopCountKey = &stopCountKey;
static const void *significantStartCountKey = &significantStartCountKey;
static const void *significantStopCountKey = &significantStopCountKey;
static const void *requestCountKey = &requestCountKey;

#define REQUIRE(condition, label) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, (label)); \
        exit(1); \
    } \
} while (0)

@interface BLDFilesFixture : NSFileManager
@property(nonatomic, strong) NSURL *root;
@property(nonatomic) BOOL failCreation;
@property(nonatomic) NSUInteger writes;
@end
@implementation BLDFilesFixture
- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domains {
    (void)directory; (void)domains;
    return self.root ? @[self.root] : @[];
}
- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)create attributes:(NSDictionary *)attributes error:(NSError **)error {
    (void)url; (void)create; (void)attributes; (void)error;
    self.writes++;
    return !self.failCreation;
}
@end

static void checkStartup(void) {
    NSMutableDictionary *info = [@{@"CFBundleIdentifier":@"com.ayato.bumpdebug.2CLB9J3SQB",
        @"CFBundleShortVersionString":@"2.135.0", @"CFBundleVersion":@"261126153935", @"CFBundleExecutable":@"Location"} mutableCopy];
    REQUIRE(BLDIsSupportedBundleInfo(info), "installed team-suffixed identity supported");
    for (NSString *identifier in @[@"co.amo.ios.location", @"com.ayato.bumpdebug"]) {
        info[@"CFBundleIdentifier"] = identifier;
        REQUIRE(BLDIsSupportedBundleInfo(info), "original and delivery identities supported");
    }
    for (NSString *identifier in @[@"com.unrelated.app", @"com.ayato.bumpdebug.evil", @"com.ayato.bumpdebug.2CLB9J3SQB.extra", @"com.ayato.bumpdebug.2clb9j3sqb"]) {
        info[@"CFBundleIdentifier"] = identifier;
        REQUIRE(!BLDIsSupportedBundleInfo(info), "unrelated or malformed identity rejected");
    }
    info[@"CFBundleIdentifier"] = @"com.ayato.bumpdebug.2CLB9J3SQB";
    info[@"CFBundleVersion"] = @"other";
    REQUIRE(!BLDIsSupportedBundleInfo(info), "different app binary build rejected");
    BLDFilesFixture *files = [BLDFilesFixture new];
    files.root = [NSURL fileURLWithPath:@"/fixture/app-private-support" isDirectory:YES];
    NSURL *original = [NSURL fileURLWithPath:@"/fixture/valid-group" isDirectory:YES];
    REQUIRE(BLDResolveGroupContainer(files, original, @"group.co.amo") == original, "existing group identity retained");
    REQUIRE(files.writes == 0, "valid group does not trigger fallback writes");
    REQUIRE(BLDResolveGroupContainer(files, nil, @"group.unrelated") == nil, "unrelated missing group untouched");
    NSURL *fallback = BLDResolveGroupContainer(files, nil, @"group.co.amo");
    REQUIRE([fallback.path isEqualToString:@"/fixture/app-private-support/BumpLocationDebug/GroupContainer"], "missing original group resolves app-private startup URL");
    files.failCreation = YES;
    REQUIRE(BLDResolveGroupContainer(files, nil, @"group.co.amo") == nil, "filesystem failure propagates");
    files.root = nil;
    REQUIRE(BLDResolveGroupContainer(files, nil, @"group.co.amo") == nil, "absent app support path handled");
}


static void increment(id object, const void *key) {
    NSUInteger count = [objc_getAssociatedObject(object, key) unsignedIntegerValue];
    objc_setAssociatedObject(object, key, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSUInteger countFor(id object, const void *key) {
    return [objc_getAssociatedObject(object, key) unsignedIntegerValue];
}

static void receive(id receiver, SEL selector, CLLocationManager *manager,
                    NSArray<CLLocation *> *locations) {
    (void)selector;
    (void)manager;
    objc_setAssociatedObject(receiver, receivedKey, locations, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver, callbackMainThreadKey, @(NSThread.isMainThread),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    increment(receiver, callbackCountKey);
}

static void setDelegate(id manager, SEL selector, id delegate) {
    (void)selector;
    objc_setAssociatedObject(manager, delegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id getDelegate(id manager, SEL selector) {
    (void)selector;
    return objc_getAssociatedObject(manager, delegateKey);
}

static id getLocation(id manager, SEL selector) {
    (void)selector;
    return objc_getAssociatedObject(manager, storedLocationKey);
}

static void startUpdating(id manager, SEL selector) {
    (void)selector;
    increment(manager, startCountKey);
}

static void stopUpdating(id manager, SEL selector) {
    (void)selector;
    increment(manager, stopCountKey);
}

static void startSignificant(id manager, SEL selector) {
    (void)selector;
    increment(manager, significantStartCountKey);
}

static void stopSignificant(id manager, SEL selector) {
    (void)selector;
    increment(manager, significantStopCountKey);
}

static void requestLocation(id manager, SEL selector) {
    (void)selector;
    increment(manager, requestCountKey);
}

static void installStub(SEL selector, IMP implementation, const char *fallback) {
    Method original = class_getInstanceMethod(CLLocationManager.class, selector);
    const char *encoding = original ? method_getTypeEncoding(original) : fallback;
    class_replaceMethod(CLLocationManager.class, selector, implementation, encoding);
}

static void installManagerFixtures(void) {
    installStub(@selector(setDelegate:), (IMP)setDelegate, "v24@0:8@16");
    installStub(@selector(delegate), (IMP)getDelegate, "@16@0:8");
    installStub(@selector(location), (IMP)getLocation, "@16@0:8");
    installStub(@selector(startUpdatingLocation), (IMP)startUpdating, "v16@0:8");
    installStub(@selector(stopUpdatingLocation), (IMP)stopUpdating, "v16@0:8");
    installStub(@selector(startMonitoringSignificantLocationChanges), (IMP)startSignificant, "v16@0:8");
    installStub(@selector(stopMonitoringSignificantLocationChanges), (IMP)stopSignificant, "v16@0:8");
    installStub(@selector(requestLocation), (IMP)requestLocation, "v16@0:8");
}

static Class makeDelegateClass(const char *name, const char *encoding) {
    Class cls = objc_allocateClassPair(NSObject.class, name, 0);
    REQUIRE(cls != Nil, "allocate exact-name delegate fixture");
    REQUIRE(class_addMethod(cls, @selector(locationManager:didUpdateLocations:),
                           (IMP)receive, encoding), "fixture owns its callback");
    objc_registerClassPair(cls);
    return cls;
}

static Class makeManagerClass(void) {
    Class cls = objc_allocateClassPair(NSObject.class, "BLDHarnessManager", 0);
    REQUIRE(cls != Nil, "allocate manager test double");
    SEL selectors[] = {
        @selector(setDelegate:), @selector(delegate), @selector(location),
        @selector(startUpdatingLocation), @selector(stopUpdatingLocation),
        @selector(startMonitoringSignificantLocationChanges),
        @selector(stopMonitoringSignificantLocationChanges), @selector(requestLocation)
    };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        Method method = class_getInstanceMethod(CLLocationManager.class, selectors[i]);
        REQUIRE(method != NULL, "installed manager entry exists");
        REQUIRE(class_addMethod(cls, selectors[i], method_getImplementation(method),
                               method_getTypeEncoding(method)), "copy installed hook to NSObject fixture");
    }
    objc_registerClassPair(cls);
    return cls;
}

static void invokeVoid(id object, SEL selector) {
    IMP implementation = class_getMethodImplementation(object_getClass(object), selector);
    ((void (*)(id, SEL))implementation)(object, selector);
}

static void assignDelegate(id manager, id delegate) {
    SEL selector = @selector(setDelegate:);
    IMP implementation = class_getMethodImplementation(object_getClass(manager), selector);
    ((void (*)(id, SEL, id))implementation)(manager, selector, delegate);
}

static CLLocation *currentLocation(id manager) {
    SEL selector = @selector(location);
    IMP implementation = class_getMethodImplementation(object_getClass(manager), selector);
    return ((CLLocation *(*)(id, SEL))implementation)(manager, selector);
}

static void deliver(id delegate, id manager, NSArray<CLLocation *> *locations) {
    SEL selector = @selector(locationManager:didUpdateLocations:);
    IMP implementation = class_getMethodImplementation(object_getClass(delegate), selector);
    ((void (*)(id, SEL, id, id))implementation)(delegate, selector, manager, locations);
}

static void pump(NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
        }
    }
}

static void rejectRoute(NSArray *route, double speed, double accuracy) {
    NSError *error = nil;
    REQUIRE(!BLDStart(route, speed, accuracy, &error), "invalid route rejected");
    REQUIRE(error != nil, "invalid route returns an error");
    REQUIRE(!BLDIsEnabled(), "invalid input cannot enable injection");
}

static void checkSample(CLLocation *location, double latitude, double longitude,
                         double accuracy, NSDate *earliest) {
    REQUIRE(location != nil, "replacement location exists");
    REQUIRE(fabs(location.coordinate.latitude - latitude) < 1e-9, "fixed latitude substituted");
    REQUIRE(fabs(location.coordinate.longitude - longitude) < 1e-9, "fixed longitude substituted");
    REQUIRE(location.horizontalAccuracy == accuracy, "specified horizontal accuracy retained");
    REQUIRE(location.verticalAccuracy < 0.0, "altitude accuracy remains unknown");
    REQUIRE(location.speed == 0.0, "fixed point has zero speed");
    REQUIRE(location.course < 0.0, "fixed point has unknown course");
    REQUIRE(location.sourceInformation == nil, "default CLLocation has no fabricated source metadata");
    REQUIRE(!location.sourceInformation.isProducedByAccessory, "external accessory flag is false");
    REQUIRE([location.timestamp isEqualToDate:earliest], "native callback timestamp is preserved");

}

int main(void) {
    @autoreleasepool {
        REQUIRE(NSThread.isMainThread, "harness runs on main thread");
        checkStartup();
        installManagerFixtures();
        IMP beforeInstall = class_getMethodImplementation(CLLocationManager.class, @selector(setDelegate:));
        REQUIRE(!BLDInstallHooks(), "missing target classes fail closed");
        REQUIRE(class_getMethodImplementation(CLLocationManager.class, @selector(setDelegate:)) == beforeInstall,
                "failed install leaves manager entries intact");

        const char *firstName = "_TtC15LocationBindingP33_6C00B80C985AD151B6934B64C045240F19CoreLocationManager";
        const char *secondName = "_TtC21LocationManagerShared23LocationManagerProvider";
        Class firstClass = makeDelegateClass(firstName, "v32@0:8@16@24");
        REQUIRE(!BLDInstallHooks(), "one missing callback cannot partially install");
        Class secondClass = makeDelegateClass(secondName, "@32@0:8@16@24");
        REQUIRE(!BLDInstallHooks(), "wrong callback ABI fails closed");
        REQUIRE(class_getMethodImplementation(firstClass, @selector(locationManager:didUpdateLocations:)) == (IMP)receive,
                "ABI rejection leaves the other delegate unmodified");
        // Replacing an existing IMP does not replace its runtime type encoding.
        // No instances exist, so discard this deliberately incompatible fixture.
        objc_disposeClassPair(secondClass);
        REQUIRE(objc_getClass(secondName) == Nil, "discard incompatible fixture without instances");
        secondClass = makeDelegateClass(secondName, "v32@0:8@16@24");
        REQUIRE(BLDInstallHooks(), "both exact callbacks install successfully");
        IMP installed = class_getMethodImplementation(firstClass, @selector(locationManager:didUpdateLocations:));
        IMP installedManager = class_getMethodImplementation(CLLocationManager.class, @selector(setDelegate:));
        REQUIRE(installed != (IMP)receive, "target callback was replaced");
        REQUIRE(BLDInstallHooks(), "second installation succeeds idempotently");
        REQUIRE(class_getMethodImplementation(firstClass, @selector(locationManager:didUpdateLocations:)) == installed,
                "callback is not wrapped twice");
        REQUIRE(class_getMethodImplementation(CLLocationManager.class, @selector(setDelegate:)) == installedManager,
                "manager is not wrapped twice");
        REQUIRE(!BLDIsEnabled(), "injection starts disabled");
        REQUIRE([BLDStatusText() containsString:@"2/2"], "status reports both installed callbacks");

        rejectRoute(@[], 1.0, 5.0);
        rejectRoute(@[@[@91.0, @0.0]], 1.0, 5.0);
        rejectRoute(@[@[@0.0, @181.0]], 1.0, 5.0);
        rejectRoute(@[@[@(NAN), @0.0]], 1.0, 5.0);
        rejectRoute(@[@[@0.0]], 1.0, 5.0);
        rejectRoute(@[@[@"0", @"0"]], 1.0, 5.0);
        rejectRoute(@[NSNull.null], 1.0, 5.0);
        rejectRoute(@[@[@0.0, @0.0]], -1.0, 5.0);
        rejectRoute(@[@[@0.0, @0.0]], INFINITY, 5.0);
        rejectRoute(@[@[@0.0, @0.0]], 1.0, 0.0);
        rejectRoute(@[@[@0.0, @0.0]], 1.0, NAN);
        NSMutableArray *tooMany = [NSMutableArray array];
        for (NSUInteger i = 0; i < 257; i++) [tooMany addObject:@[@0.0, @0.0]];
        rejectRoute(tooMany, 1.0, 5.0);

        Class managerClass = makeManagerClass();
        id firstDelegate = [firstClass new];
        id firstManager = [managerClass new];
        assignDelegate(firstManager, firstDelegate);
        CLLocation *original = [[CLLocation alloc] initWithLatitude:12.0 longitude:34.0];
        NSArray *originals = @[original];
        objc_setAssociatedObject(firstManager, storedLocationKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        deliver(firstDelegate, firstManager, originals);
        REQUIRE(objc_getAssociatedObject(firstDelegate, receivedKey) == originals,
                "disabled callback preserves exact array identity");
        REQUIRE(currentLocation(firstManager) == original,
                "disabled getter preserves original location identity");

        NSError *error = nil;
        NSDate *started = original.timestamp;
        REQUIRE(BLDStart(@[@[@35.0, @139.0]], 0.0, 4.0, &error), "fixed route enabled");
        REQUIRE(BLDIsEnabled(), "successful start enables injection");
        deliver(firstDelegate, firstManager, originals);
        NSArray *replacement = objc_getAssociatedObject(firstDelegate, receivedKey);
        REQUIRE(replacement != originals && replacement.count == 1, "enabled callback replaces array with one fix");
        checkSample(replacement.firstObject, 35.0, 139.0, 4.0, started);
        checkSample(currentLocation(firstManager), 35.0, 139.0, 4.0, started);
        REQUIRE(currentLocation(firstManager) == replacement.lastObject, "getter returns the same injected fix as callback");
        CLLocation *older = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(1, 2)
            altitude:0 horizontalAccuracy:3 verticalAccuracy:-1 timestamp:[NSDate dateWithTimeInterval:-1 sinceDate:original.timestamp]];
        deliver(firstDelegate, firstManager, @[older, original]);
        NSArray *batch = objc_getAssociatedObject(firstDelegate, receivedKey);
        REQUIRE(batch.count == 2, "batch cardinality preserved");
        REQUIRE([((CLLocation *)batch[0]).timestamp isEqualToDate:older.timestamp], "first batch timestamp/order preserved");
        REQUIRE([((CLLocation *)batch[1]).timestamp isEqualToDate:original.timestamp], "last batch timestamp/order preserved");
        REQUIRE(currentLocation(firstManager) == batch.lastObject, "batch last fix matches getter cache");
        id batchForwarded = [secondClass new];
        deliver(batchForwarded, firstManager, batch);
        REQUIRE(objc_getAssociatedObject(batchForwarded, receivedKey) == batch, "forwarded multi-fix array identity preserved");


        Class unrelatedClass = makeDelegateClass("BLDUnrelatedDelegate", "v32@0:8@16@24");
        id unrelatedDelegate = [unrelatedClass new];
        id unrelatedManager = [managerClass new];
        assignDelegate(unrelatedManager, unrelatedDelegate);
        objc_setAssociatedObject(unrelatedManager, storedLocationKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        deliver(unrelatedDelegate, unrelatedManager, originals);
        REQUIRE(objc_getAssociatedObject(unrelatedDelegate, receivedKey) == originals,
                "unrelated callback unaffected while injection enabled");
        REQUIRE(currentLocation(unrelatedManager) == original,
                "unrelated manager getter unaffected");
        REQUIRE(class_getMethodImplementation(unrelatedClass, @selector(locationManager:didUpdateLocations:)) == (IMP)receive,
                "unrelated class method unmodified");

        NSUInteger count = countFor(firstDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(firstDelegate, callbackCountKey) == count,
                "observed callback alone does not start periodic injection");

        // The actual provider forwards a CLLocation array to another hooked
        // delegate on a work queue. That downstream invocation must neither
        // replace our generated fix again nor move the manager's delivery loop.
        id forwardedDelegate = [secondClass new];
        invokeVoid(firstManager, @selector(startUpdatingLocation));
        count = countFor(firstDelegate, callbackCountKey);
        dispatch_semaphore_t forwarded = dispatch_semaphore_create(0);
        __block BOOL forwardedOnBackground = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                forwardedOnBackground = !NSThread.isMainThread;
                deliver(forwardedDelegate, firstManager, replacement);
            }
            dispatch_semaphore_signal(forwarded);
        });
        REQUIRE(dispatch_semaphore_wait(forwarded, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                "background forwarded callback completed");
        REQUIRE(forwardedOnBackground, "forwarding fixture actually ran off the main thread");
        NSArray *forwardedLocations = objc_getAssociatedObject(forwardedDelegate, receivedKey);
        REQUIRE(forwardedLocations == replacement, "forwarded injected array identity is preserved");
        REQUIRE(forwardedLocations.firstObject == replacement.firstObject,
                "forwarded injected CLLocation identity is preserved");
        REQUIRE(![objc_getAssociatedObject(forwardedDelegate, callbackMainThreadKey) boolValue],
                "downstream fixture observed the background callback");
        pump(1.3);
        REQUIRE(countFor(firstDelegate, callbackCountKey) > count,
                "background forwarding preserves periodic delivery to actual delegate");
        REQUIRE([objc_getAssociatedObject(firstDelegate, callbackMainThreadKey) boolValue],
                "periodic delivery retains the actual delegate's main run loop");
        invokeVoid(firstManager, @selector(stopUpdatingLocation));

        id secondDelegate = [secondClass new];
        id secondManager = [managerClass new];
        assignDelegate(secondManager, secondDelegate);
        invokeVoid(secondManager, @selector(startUpdatingLocation));
        REQUIRE(countFor(secondManager, startCountKey) == 1, "start forwarded to harmless fixture");
        pump(1.3);
        REQUIRE(countFor(secondDelegate, callbackCountKey) == 0,
                "no synthetic delivery before observing actual callback run loop");
        deliver(secondDelegate, secondManager, originals);
        checkSample([objc_getAssociatedObject(secondDelegate, receivedKey) firstObject],
                    35.0, 139.0, 4.0, started);
        count = countFor(secondDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(secondDelegate, callbackCountKey) > count,
                "started observed manager receives periodic synthetic updates");
        invokeVoid(secondManager, @selector(stopUpdatingLocation));
        REQUIRE(countFor(secondManager, stopCountKey) == 1, "stop forwarded to harmless fixture");
        count = countFor(secondDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(secondDelegate, callbackCountKey) == count,
                "stopped manager receives no periodic synthetic updates");

        invokeVoid(firstManager, @selector(startMonitoringSignificantLocationChanges));
        REQUIRE(countFor(firstManager, significantStartCountKey) == 1,
                "significant-change start forwarded to harmless fixture");
        count = countFor(firstDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(firstDelegate, callbackCountKey) > count,
                "observed significant-change manager receives synthetic update");
        invokeVoid(firstManager, @selector(stopMonitoringSignificantLocationChanges));
        REQUIRE(countFor(firstManager, significantStopCountKey) == 1,
                "significant-change stop forwarded to harmless fixture");
        count = countFor(firstDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(firstDelegate, callbackCountKey) == count,
                "significant-change stop ends periodic delivery");

        id requestDelegate = [firstClass new];
        id requestManager = [managerClass new];
        assignDelegate(requestManager, requestDelegate);
        invokeVoid(requestManager, @selector(requestLocation));
        pump(0.1);
        REQUIRE(countFor(requestManager, requestCountKey) == 1, "request forwarded to harmless fixture");
        REQUIRE(countFor(requestDelegate, callbackCountKey) == 0,
                "one-shot without observed run loop does not synthesize");
        deliver(requestDelegate, requestManager, originals);
        count = countFor(requestDelegate, callbackCountKey);
        invokeVoid(requestManager, @selector(requestLocation));
        pump(0.1);
        REQUIRE(countFor(requestDelegate, callbackCountKey) == count + 1,
                "observed one-shot request receives one synthetic callback");
        REQUIRE(countFor(requestManager, requestCountKey) == 2,
                "both one-shot requests were forwarded");

        // An already queued one-shot must not leak into a newly started configuration.
        invokeVoid(requestManager, @selector(requestLocation));
        NSUInteger previousRequests = countFor(requestDelegate, callbackCountKey);
        BLDStop();
        REQUIRE(BLDStart(@[@[@36.0,@140.0]],0,4,&error), "restart accepts new configuration");
        pump(0.1);
        REQUIRE(countFor(requestDelegate, callbackCountKey) == previousRequests, "old queued work cannot inject after restart");
        deliver(firstDelegate, firstManager, originals);
        checkSample(currentLocation(firstManager),36,140,4,original.timestamp);
        BLDStop();
        REQUIRE(!BLDIsEnabled(), "stop disables injection");
        deliver(firstDelegate, firstManager, originals);
        REQUIRE(objc_getAssociatedObject(firstDelegate, receivedKey) == originals,
                "stop restores exact original callback array");
        REQUIRE(currentLocation(firstManager) == original, "stop restores original getter result");
        count = countFor(firstDelegate, callbackCountKey);
        pump(1.3);
        REQUIRE(countFor(firstDelegate, callbackCountKey) == count,
                "disabled timer generates no callbacks");

        NSDictionary *result = @{
            @"status": @"passed", @"checks": @(checks),
            @"fixture": @"NSObject manager doubles and exact-name delegate classes",
            @"real_location_api_calls": @0,
            @"app_binary_executed": @NO,
            @"covers": @[@"fail-closed installation", @"ABI rejection", @"idempotence",
                          @"disabled identity", @"route rejection", @"fixed replacement",
                          @"default source metadata", @"preserved callback timestamps", @"unrelated delegate",
                          @"observed run-loop requirement", @"forwarded array identity",
                          @"background forwarding retains delivery loop",
                          @"periodic delivery", @"stop restoration"]
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
        REQUIRE(json != nil, "serialize safe result");
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}

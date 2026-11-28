#import "BLDState.h"
#import "BLDRoute.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

// Names and Objective-C signatures are pinned to the supplied 2.135.0 binary.
static const char *BLDDelegateNames[] = {
    "_TtC15LocationBindingP33_6C00B80C985AD151B6934B64C045240F19CoreLocationManager",
    "_TtC21LocationManagerShared23LocationManagerProvider"
};
typedef void (*BLDLocationCallback)(id, SEL, CLLocationManager *, NSArray<CLLocation *> *);
static Class BLDDelegateClasses[2];
static BLDLocationCallback BLDOriginalCallbacks[2];
static NSUInteger BLDInstalledCount;
static const void *BLDManagerKey = &BLDManagerKey;
static const void *BLDInjectedLocationKey = &BLDInjectedLocationKey;

@interface BLDManagerState : NSObject
@property(nonatomic, assign) CFRunLoopRef deliveryRunLoop;
@property(nonatomic) BOOL continuous;
@property(nonatomic) BOOL significant;
@property(nonatomic) BOOL pending;
@property(nonatomic) NSUInteger loopGeneration;
@property(nonatomic, strong) CLLocation *latestInjected;
@property(nonatomic) NSUInteger latestGeneration;
@end
@implementation BLDManagerState
- (instancetype)init {
    self = [super init];
    return self;
}
- (void)dealloc { if (_deliveryRunLoop) CFRelease(_deliveryRunLoop); }
@end

@protocol BLDBackgroundManager <NSObject>
@property(nonatomic) BOOL allowsBackgroundLocationUpdates;
@property(nonatomic) BOOL pausesLocationUpdatesAutomatically;
@end
@interface BLDBackgroundSnapshot : NSObject
@property(nonatomic) BOOL allowed;
@property(nonatomic) BOOL pauses;
@end
@implementation BLDBackgroundSnapshot
@end
static const void *BLDBackgroundKey=&BLDBackgroundKey;
BOOL BLDBackgroundPolicyApply(id object,BOOL enabled,BOOL locationModeAllowed) {
    @synchronized(object) {
        BLDBackgroundSnapshot *saved=objc_getAssociatedObject(object,BLDBackgroundKey);
        id<BLDBackgroundManager> manager=object;
        if(!enabled || !locationModeAllowed){
            if(saved){
                @try {
                    if(manager.allowsBackgroundLocationUpdates)manager.allowsBackgroundLocationUpdates=saved.allowed;
                    if(!manager.pausesLocationUpdatesAutomatically)manager.pausesLocationUpdatesAutomatically=saved.pauses;
                } @catch(NSException *exception){(void)exception;}
                objc_setAssociatedObject(object,BLDBackgroundKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return NO;
        }
        if(saved)return YES;
        for(NSString *name in @[@"allowsBackgroundLocationUpdates",@"setAllowsBackgroundLocationUpdates:",@"pausesLocationUpdatesAutomatically",@"setPausesLocationUpdatesAutomatically:"])
            if(![object respondsToSelector:NSSelectorFromString(name)])return NO;
        saved=[BLDBackgroundSnapshot new];
        @try {
            saved.allowed=manager.allowsBackgroundLocationUpdates;saved.pauses=manager.pausesLocationUpdatesAutomatically;
            manager.allowsBackgroundLocationUpdates=YES;manager.pausesLocationUpdatesAutomatically=NO;
            objc_setAssociatedObject(object,BLDBackgroundKey,saved,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return YES;
        } @catch(NSException *exception){
            (void)exception;@try {manager.allowsBackgroundLocationUpdates=saved.allowed;manager.pausesLocationUpdatesAutomatically=saved.pauses;} @catch(NSException *restore){(void)restore;}
            return NO;
        }
    }
}

@interface BLDController : NSObject {
@public
    BLDPoint points[BLD_ROUTE_MAX_POINTS];
    NSUInteger count;
    double speed;
    double accuracy;
    NSTimeInterval startedAt;
    BOOL enabled;
    NSUInteger received;
    NSUInteger injected;
    NSUInteger synthetic;
    NSUInteger generation;
}
@property(nonatomic, strong) NSHashTable<CLLocationManager *> *managers;
@property(nonatomic) BOOL backgroundEnabled;
@end
@implementation BLDController
@end

static BLDController *BLDShared(void) {
    static BLDController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [BLDController new];
        controller.managers = [NSHashTable weakObjectsHashTable];
        controller.backgroundEnabled = YES;
    });
    return controller;
}

static NSInteger BLDDelegateIndex(id delegate) {
    if (!delegate) return -1;
    for (Class cls = object_getClass(delegate); cls; cls = class_getSuperclass(cls)) {
        for (NSUInteger i = 0; i < 2; i++) {
            if (BLDDelegateClasses[i] && cls == BLDDelegateClasses[i]) return (NSInteger)i;
        }
    }
    return -1;
}

static BLDManagerState *BLDState(CLLocationManager *manager, BOOL create) {
    @synchronized(manager) {
        BLDManagerState *state = objc_getAssociatedObject(manager, BLDManagerKey);
        if (!state && create) {
            state = [BLDManagerState new];
            objc_setAssociatedObject(manager, BLDManagerKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BLDController *controller = BLDShared();
            @synchronized(controller) { [controller.managers addObject:manager]; }
        }
        return state;
    }
}

static void BLDUpdateBackground(CLLocationManager *manager) {
    BLDManagerState *state=BLDState(manager,NO);
    if(!state)return;
    CFRunLoopRef loop=NULL;
    @synchronized(state){if(state.deliveryRunLoop)loop=(CFRunLoopRef)CFRetain(state.deliveryRunLoop);}
    if(!loop)return; // Wait for an observed native callback; never create another manager.
    __weak CLLocationManager *weakManager=manager;
    void (^apply)(void)=^{
        CLLocationManager *current=weakManager;if(!current)return;
        BLDController *controller=BLDShared();BOOL enabled;
        @synchronized(controller){enabled=controller->enabled && controller.backgroundEnabled;}
        BLDManagerState *currentState=BLDState(current,NO);BOOL continuous=NO;
        @synchronized(currentState){continuous=currentState.continuous;}
        BOOL allowed=NO;
#ifndef BLD_TEST_HOST
        id modes=NSBundle.mainBundle.infoDictionary[@"UIBackgroundModes"];
        allowed=[modes isKindOfClass:NSArray.class] && [modes containsObject:@"location"];
#endif
        BLDBackgroundPolicyApply(current,enabled && continuous && BLDDelegateIndex(current.delegate)>=0,allowed);
    };
    if(CFRunLoopGetCurrent()==loop)apply();
    else {CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,apply);CFRunLoopWakeUp(loop);}
    CFRelease(loop);
}
void BLDSetBackgroundEnabled(BOOL enabled) {
    BLDController *controller=BLDShared();NSArray *managers;
    @synchronized(controller){controller.backgroundEnabled=enabled;managers=controller.managers.allObjects;}
    for(CLLocationManager *manager in managers)BLDUpdateBackground(manager);
}
BOOL BLDBackgroundEnabled(void) { BLDController *controller=BLDShared();@synchronized(controller){return controller.backgroundEnabled;} }

static CLLocation *BLDSaveLatest(BLDManagerState *state, CLLocation *location, NSUInteger generation) {
    @synchronized(state) {
        if (state.latestGeneration != generation || !state.latestInjected ||
            [location.timestamp compare:state.latestInjected.timestamp] != NSOrderedAscending) {
            state.latestInjected = location;
            state.latestGeneration = generation;
        }
        return state.latestInjected;
    }
}

static CLLocation *BLDSampledLocation(NSDate *timestamp, NSUInteger generation) {
    BLDController *controller = BLDShared();
    BLDSample sample;
    double accuracy;
    @synchronized(controller) {
        if (!controller->enabled || controller->generation != generation) return nil;
        double age = timestamp ? MIN(0.0, timestamp.timeIntervalSinceNow) : 0.0;
        double elapsed = MAX(0.0, NSProcessInfo.processInfo.systemUptime - controller->startedAt + age);
        if (!BLDRouteSample(controller->points, controller->count, controller->speed, elapsed, &sample)) return nil;
        accuracy = controller->accuracy;
    }
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(sample.point.latitude, sample.point.longitude)
        altitude:0 horizontalAccuracy:accuracy verticalAccuracy:-1
        course:sample.course courseAccuracy:(sample.course < 0 ? -1 : 5)
        speed:sample.speed speedAccuracy:0.2 timestamp:timestamp ?: [NSDate date]];
    objc_setAssociatedObject(location, BLDInjectedLocationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return location;
}

static void BLDReceivedLocations(id delegate, SEL selector, CLLocationManager *manager, NSArray<CLLocation *> *locations) {
    NSInteger index = BLDDelegateIndex(delegate);
    if (index < 0 || !BLDOriginalCallbacks[index]) return;
    BLDController *controller = BLDShared();
    // The provider can forward to the other hooked class on another queue.
    // Only the manager's actual delegate establishes its delivery run loop.
    if (manager.delegate == delegate) {
        BLDManagerState *state = BLDState(manager, YES);
        @synchronized(state) {
            CFRunLoopRef current = CFRunLoopGetCurrent();
            if (state.deliveryRunLoop != current) {
                if (state.deliveryRunLoop) CFRelease(state.deliveryRunLoop);
                state.deliveryRunLoop = (CFRunLoopRef)CFRetain(current);
                state.loopGeneration++;
                state.pending = NO;
            }
        }
        @synchronized(controller) { controller->received++; }
        BLDUpdateBackground(manager);
    }
    NSUInteger generation;
    @synchronized(controller) { generation = controller->generation; }
    if (!BLDIsEnabled() || !locations.count) {
        BLDOriginalCallbacks[index](delegate, selector, manager, locations);
        return;
    }
    NSMutableArray<CLLocation *> *mapped = [NSMutableArray arrayWithCapacity:locations.count];
    BOOL changed = NO;
    for (CLLocation *location in locations) {
        if (objc_getAssociatedObject(location, BLDInjectedLocationKey)) {
            [mapped addObject:location];
        } else {
            CLLocation *replacement = BLDSampledLocation(location.timestamp, generation);
            if (!replacement) {
                BLDOriginalCallbacks[index](delegate, selector, manager, locations);
                return;
            }
            [mapped addObject:replacement];
            if (replacement) changed = YES;
        }
    }
    if (changed) {
        BOOL current;
        @synchronized(controller) {
            current = controller->enabled && controller->generation == generation;
            if (current) controller->injected += locations.count;
        }
        if (!current) {
            BLDOriginalCallbacks[index](delegate, selector, manager, locations);
            return;
        }
        if (manager.delegate == delegate) {
            BLDManagerState *state = BLDState(manager, YES);
            BLDSaveLatest(state, mapped.lastObject, generation);
        }
        BLDOriginalCallbacks[index](delegate, selector, manager, mapped);
    } else BLDOriginalCallbacks[index](delegate, selector, manager, locations);
}

static void BLDSchedule(CLLocationManager *manager, BOOL oneShot) {
    if (BLDDelegateIndex(manager.delegate) < 0 || !BLDIsEnabled()) return;
    BLDController *controller = BLDShared();
    NSUInteger injectionGeneration;
    @synchronized(controller) { injectionGeneration = controller->generation; }
    BLDManagerState *state = BLDState(manager, YES);
    CFRunLoopRef loop;
    NSUInteger generation;
    @synchronized(state) {
        // Only schedule on a run loop observed delivering the app's real callback.
        if (!state.deliveryRunLoop || state.pending || (!oneShot && !state.continuous && !state.significant)) return;
        state.pending = YES;
        generation = state.loopGeneration;
        loop = (CFRunLoopRef)CFRetain(state.deliveryRunLoop);
    }
    __weak CLLocationManager *weakManager = manager;
    __weak BLDManagerState *weakState = state;
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{
        BLDManagerState *deliveryState = weakState;
        if (!deliveryState) return;
        BOOL shouldDeliver;
        @synchronized(deliveryState) {
            if (deliveryState.loopGeneration != generation) return;
            deliveryState.pending = NO;
            shouldDeliver = oneShot || deliveryState.continuous || deliveryState.significant;
        }
        CLLocationManager *currentManager = weakManager;
        if (!currentManager || !shouldDeliver) return;
        id delegate = currentManager.delegate;
        NSInteger index = BLDDelegateIndex(delegate);
        if (index < 0) return;
        CLLocation *location = BLDSampledLocation(nil, injectionGeneration);
        if (!location) return;
        BLDController *controller = BLDShared();
        @synchronized(controller) { controller->injected++; controller->synthetic++; }
        BLDSaveLatest(deliveryState, location, injectionGeneration);
        BLDOriginalCallbacks[index](delegate, @selector(locationManager:didUpdateLocations:), currentManager, @[location]);
    });
    CFRunLoopWakeUp(loop);
    CFRelease(loop);
}

static void BLDEnsureTimer(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            if (!BLDIsEnabled()) return;
            BLDController *controller = BLDShared();
            NSArray *managers;
            @synchronized(controller) { managers = controller.managers.allObjects; }
            for (CLLocationManager *manager in managers) BLDSchedule(manager, NO);
        });
        dispatch_resume(timer);
    });
}

BOOL BLDStart(NSArray<NSArray<NSNumber *> *> *route, double speed, double accuracy, NSError **error) {
    NSString *reason = nil;
    BLDPoint parsed[BLD_ROUTE_MAX_POINTS];
    if (BLDInstalledCount != 2) reason = @"このバージョンの位置更新処理を確認できません。";
    else if (route.count == 0 || route.count > BLD_ROUTE_MAX_POINTS) reason = @"座標は1〜256地点で指定してください。";
    else if (!isfinite(speed) || speed < 0 || !isfinite(accuracy) || accuracy <= 0) reason = @"速度は0以上、精度は0より大きい数値を指定してください。";
    if (!reason) {
        for (NSUInteger i = 0; i < route.count; i++) {
            NSArray *pair = route[i];
            if (![pair isKindOfClass:NSArray.class] || pair.count != 2 ||
                ![pair[0] isKindOfClass:NSNumber.class] || ![pair[1] isKindOfClass:NSNumber.class]) {
                reason = @"各地点には緯度と経度を指定してください。"; break;
            }
            parsed[i] = (BLDPoint){ [pair[0] doubleValue], [pair[1] doubleValue] };
            if (!BLDPointIsValid(parsed[i])) { reason = @"緯度は−90〜90、経度は−180〜180の範囲で指定してください。"; break; }
        }
    }
    if (reason) {
        if (error) *error = [NSError errorWithDomain:@"BumpLocationDebug" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
        return NO;
    }
    BLDController *controller = BLDShared();
    @synchronized(controller) {
        memcpy(controller->points, parsed, route.count * sizeof(BLDPoint));
        controller->count = route.count;
        controller->speed = speed;
        controller->accuracy = accuracy;
        controller->startedAt = NSProcessInfo.processInfo.systemUptime;
        controller->generation++;
        controller->enabled = YES;
    }
    BLDEnsureTimer();
    NSArray *managers;@synchronized(controller){managers=controller.managers.allObjects;}
    for(CLLocationManager *manager in managers)BLDUpdateBackground(manager);
    return YES;
}

void BLDStop(void) {
    BLDController *controller = BLDShared();
    NSArray *managers;
    @synchronized(controller) { controller->enabled = NO; controller->generation++; managers=controller.managers.allObjects; }
    for(CLLocationManager *manager in managers)BLDUpdateBackground(manager);
}

BOOL BLDIsEnabled(void) {
    BLDController *controller = BLDShared();
    @synchronized(controller) { return controller->enabled; }
}

NSString *BLDStatusText(void) {
    BLDController *controller = BLDShared();
    BOOL on;
    NSUInteger received, injected, synthetic, managers = 0;
    @synchronized(controller) {
        on = controller->enabled;
        received = controller->received;
        injected = controller->injected;
        synthetic = controller->synthetic;
        for (CLLocationManager *manager in controller.managers.allObjects) {
            if (BLDDelegateIndex(manager.delegate) >= 0) managers++;
        }
    }
    return [NSString stringWithFormat:@"位置情報の置換：%@\n対象フック：%lu/2　位置取得：%lu\n更新の受信：%lu　注入：%lu（定期：%lu）\nBump内部への合成入力です。システム全体の位置や、Core Locationの出所判定の実装は書き換えません。\n背景継続：%@（位置情報の許可・iOSの稼働が必要）",
        on ? @"ON" : @"OFF", (unsigned long)BLDInstalledCount, (unsigned long)managers,
        (unsigned long)received, (unsigned long)injected, (unsigned long)synthetic, BLDBackgroundEnabled() ? @"有効" : @"無効"];
}

static void (*BLDOriginalSetDelegate)(id, SEL, id);
static void (*BLDOriginalStart)(id, SEL);
static void (*BLDOriginalStop)(id, SEL);
static void (*BLDOriginalSignificantStart)(id, SEL);
static void (*BLDOriginalSignificantStop)(id, SEL);
static void (*BLDOriginalRequest)(id, SEL);
static CLLocation *(*BLDOriginalLocation)(id, SEL);
BOOL BLDIsSupportedBundleInfo(NSDictionary *info) {
    NSString *identifier = info[@"CFBundleIdentifier"];
    if (![identifier isKindOfClass:NSString.class]) return NO;
    BOOL allowed = [identifier isEqualToString:@"co.amo.ios.location"] ||
                   [identifier isEqualToString:@"com.ayato.bumpdebug"];
    NSString *prefix = @"com.ayato.bumpdebug.";
    if ([identifier hasPrefix:prefix]) {
        NSString *suffix = [identifier substringFromIndex:prefix.length];
        NSCharacterSet *teamCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        allowed = suffix.length == 10 && [suffix rangeOfCharacterFromSet:teamCharacters.invertedSet].location == NSNotFound;
    }
    return allowed && [info[@"CFBundleShortVersionString"] isEqualToString:@"2.135.0"] &&
        [info[@"CFBundleVersion"] isEqualToString:@"261126153935"] &&
        [info[@"CFBundleExecutable"] isEqualToString:@"Location"];
}

NSURL *BLDResolveGroupContainer(NSFileManager *files, NSURL *original, NSString *group) {
    if (original || ![group isEqualToString:@"group.co.amo"]) return original;
    // The original App Group is unavailable after signing with another team.
    // This fallback is app-private and does not share extension containers.
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!support) return nil;
    NSURL *fallback = [support URLByAppendingPathComponent:@"BumpLocationDebug/GroupContainer" isDirectory:YES];
    NSError *error = nil;
    if (![files createDirectoryAtURL:fallback withIntermediateDirectories:YES attributes:nil error:&error]) return nil;
    return fallback;
}

#ifndef BLD_TEST_HOST
static NSURL *(*BLDOriginalGroupContainer)(id, SEL, NSString *);
static NSURL *BLDGroupContainer(id files, SEL selector, NSString *group) {
    NSURL *original = BLDOriginalGroupContainer(files, selector, group);
    return BLDResolveGroupContainer(files, original, group);
}
static BOOL BLDInstallContainerFallback(void) {
    if (BLDOriginalGroupContainer) return YES;
    Method method = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 3 || signature.methodReturnType[0] != '@' ||
        [signature getArgumentTypeAtIndex:2][0] != '@') return NO;
    BLDOriginalGroupContainer = (void *)method_setImplementation(method, (IMP)BLDGroupContainer);
    return YES;
}
#endif


static void BLDSetDelegate(id manager, SEL selector, id delegate) {
    BLDOriginalSetDelegate(manager, selector, delegate);
    if (BLDDelegateIndex(delegate) >= 0) BLDState(manager, YES);
    BLDUpdateBackground(manager);
}
static void BLDStartUpdating(id manager, SEL selector) {
    BLDManagerState *state = BLDState(manager, YES);
    @synchronized(state) { state.continuous = YES; }
    BLDOriginalStart(manager, selector);
    BLDUpdateBackground(manager);
}
static void BLDStopUpdating(id manager, SEL selector) {
    BLDManagerState *state = BLDState(manager, NO);
    if (state) @synchronized(state) { state.continuous = NO; }
    BLDOriginalStop(manager, selector);
    BLDUpdateBackground(manager);
}
static void BLDStartSignificant(id manager, SEL selector) {
    BLDManagerState *state = BLDState(manager, YES);
    @synchronized(state) { state.significant = YES; }
    BLDOriginalSignificantStart(manager, selector);
}
static void BLDStopSignificant(id manager, SEL selector) {
    BLDManagerState *state = BLDState(manager, NO);
    if (state) @synchronized(state) { state.significant = NO; }
    BLDOriginalSignificantStop(manager, selector);
}
static void BLDRequestLocation(id manager, SEL selector) {
    BLDOriginalRequest(manager, selector);
    BLDSchedule(manager, YES);
}
static CLLocation *BLDCurrentLocation(id manager, SEL selector) {
    CLLocation *original = BLDOriginalLocation(manager, selector);
    if (BLDDelegateIndex([manager delegate]) < 0 || !BLDIsEnabled()) return original;
    BLDController *controller = BLDShared();
    NSUInteger generation;
    @synchronized(controller) { generation = controller->generation; }
    BLDManagerState *state = BLDState(manager, YES);
    @synchronized(state) {
        if (state.latestGeneration == generation && state.latestInjected) return state.latestInjected;
    }
    if (!original) return nil;
    CLLocation *replacement = BLDSampledLocation(original.timestamp, generation);
    if (!replacement) return original;
    return BLDSaveLatest(state, replacement, generation);
}

static BOOL BLDIsObjectArgument(const char *encoding) {
    return encoding && encoding[0] == '@';
}
static BOOL BLDCallbackIsCompatible(Method method) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return signature.numberOfArguments == 4 && !strcmp(signature.methodReturnType, @encode(void)) &&
        BLDIsObjectArgument([signature getArgumentTypeAtIndex:0]) &&
        !strcmp([signature getArgumentTypeAtIndex:1], @encode(SEL)) &&
        BLDIsObjectArgument([signature getArgumentTypeAtIndex:2]) &&
        BLDIsObjectArgument([signature getArgumentTypeAtIndex:3]);
}
static BOOL BLDManagerMethodCompatible(SEL selector, const char *returnType, NSUInteger arguments) {
    Method method = class_getInstanceMethod(CLLocationManager.class, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != arguments) return NO;
    if (returnType[0] == '@') { if (!BLDIsObjectArgument(signature.methodReturnType)) return NO; }
    else if (strcmp(signature.methodReturnType, returnType)) return NO;
    return arguments == 2 || BLDIsObjectArgument([signature getArgumentTypeAtIndex:2]);
}
static IMP BLDReplaceManagerMethod(SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(CLLocationManager.class, selector);
    IMP original = method_getImplementation(method);
    if (!class_addMethod(CLLocationManager.class, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
    return original;
}

BOOL BLDInstallHooks(void) {
    if (BLDInstalledCount == 2) return YES;
#ifndef BLD_TEST_HOST
    if (!BLDIsSupportedBundleInfo(NSBundle.mainBundle.infoDictionary)) return NO;
    if (!BLDInstallContainerFallback()) return NO;
#endif
    SEL callback = @selector(locationManager:didUpdateLocations:);
    Method methods[2];
    Class classes[2];
    for (NSUInteger i = 0; i < 2; i++) {
        classes[i] = objc_getClass(BLDDelegateNames[i]);
        methods[i] = classes[i] ? class_getInstanceMethod(classes[i], callback) : NULL;
        if (!BLDCallbackIsCompatible(methods[i])) return NO;
        // Require an owned callback so replacing it cannot mutate a superclass.
        unsigned int count = 0;
        Method *owned = class_copyMethodList(classes[i], &count);
        BOOL found = NO;
        for (unsigned int j = 0; j < count; j++) if (method_getName(owned[j]) == callback) found = YES;
        free(owned);
        if (!found) return NO;
    }
    if (!BLDManagerMethodCompatible(@selector(setDelegate:), @encode(void), 3) ||
        !BLDManagerMethodCompatible(@selector(startUpdatingLocation), @encode(void), 2) ||
        !BLDManagerMethodCompatible(@selector(stopUpdatingLocation), @encode(void), 2) ||
        !BLDManagerMethodCompatible(@selector(startMonitoringSignificantLocationChanges), @encode(void), 2) ||
        !BLDManagerMethodCompatible(@selector(stopMonitoringSignificantLocationChanges), @encode(void), 2) ||
        !BLDManagerMethodCompatible(@selector(requestLocation), @encode(void), 2) ||
        !BLDManagerMethodCompatible(@selector(location), @encode(id), 2)) return NO;

    for (NSUInteger i = 0; i < 2; i++) {
        BLDDelegateClasses[i] = classes[i];
        BLDOriginalCallbacks[i] = (BLDLocationCallback)method_setImplementation(methods[i], (IMP)BLDReceivedLocations);
    }
    BLDOriginalSetDelegate = (void *)BLDReplaceManagerMethod(@selector(setDelegate:), (IMP)BLDSetDelegate);
    BLDOriginalStart = (void *)BLDReplaceManagerMethod(@selector(startUpdatingLocation), (IMP)BLDStartUpdating);
    BLDOriginalStop = (void *)BLDReplaceManagerMethod(@selector(stopUpdatingLocation), (IMP)BLDStopUpdating);
    BLDOriginalSignificantStart = (void *)BLDReplaceManagerMethod(@selector(startMonitoringSignificantLocationChanges), (IMP)BLDStartSignificant);
    BLDOriginalSignificantStop = (void *)BLDReplaceManagerMethod(@selector(stopMonitoringSignificantLocationChanges), (IMP)BLDStopSignificant);
    BLDOriginalRequest = (void *)BLDReplaceManagerMethod(@selector(requestLocation), (IMP)BLDRequestLocation);
    BLDOriginalLocation = (void *)BLDReplaceManagerMethod(@selector(location), (IMP)BLDCurrentLocation);
    BLDInstalledCount = 2;
    return YES;
}

#ifndef BLD_TEST_HOST
__attribute__((constructor)) static void BLDInitialize(void) {
    @autoreleasepool {
        BLDInstallHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ BLDInstallDebugUI(); });
    }
}
#endif

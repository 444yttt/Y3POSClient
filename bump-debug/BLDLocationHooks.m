#import "BLDState.h"
#import <objc/runtime.h>

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

BOOL BLDStart(NSArray<NSArray<NSNumber *> *> *points, double speed, double accuracy, NSError **error) {
    (void)points; (void)speed; (void)accuracy;
    if (error) *error = [NSError errorWithDomain:@"BumpLocationDebug" code:2 userInfo:@{NSLocalizedDescriptionKey:@"位置はReloc側で設定してください。この版はiOSからの位置更新をそのまま使用します。"}];
    return NO;
}
void BLDStop(void) {}
BOOL BLDIsEnabled(void) { return NO; }
NSString *BLDStatusText(void) {
    return @"位置情報：iOSの通常入力\nアプリ内の座標置換・合成更新は行いません。Relocを利用する場合は、Reloc側で位置を設定してからBumpに戻ってください。\n外部アクセサリ由来の位置は、内蔵GPSの実測値とは異なります。";
}
BOOL BLDInstallHooks(void) {
#ifndef BLD_TEST_HOST
    if (!BLDIsSupportedBundleInfo(NSBundle.mainBundle.infoDictionary)) return NO;
    return BLDInstallContainerFallback();
#else
    return YES;
#endif
}
#ifndef BLD_TEST_HOST
__attribute__((constructor)) static void BLDInitialize(void) {
    @autoreleasepool {
        BLDInstallHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ BLDInstallDebugUI(); });
    }
}
#endif

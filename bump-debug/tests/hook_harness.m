#import "../BLDState.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
static NSUInteger checks;
#define REQUIRE(condition, label) do { checks++; if (!(condition)) { fprintf(stderr,"FAIL: %s\n",label); exit(1); } } while(0)
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


int main(void) {
 @autoreleasepool {
  checkStartup();
  SEL selectors[] = {@selector(location), @selector(setDelegate:), @selector(startUpdatingLocation), @selector(stopUpdatingLocation), @selector(requestLocation)};
  IMP originals[5];
  for (NSUInteger i=0;i<5;i++) originals[i]=class_getMethodImplementation(CLLocationManager.class, selectors[i]);
  REQUIRE(BLDInstallHooks(), "storage bootstrap succeeds");
  for (NSUInteger i=0;i<5;i++) REQUIRE(originals[i]==class_getMethodImplementation(CLLocationManager.class,selectors[i]), "native location entry points untouched");
  NSError *error=nil;
  REQUIRE(!BLDStart(@[@[@35,@139]], 1.4, 5, &error), "old injection cannot start");
  REQUIRE(error != nil, "external location guidance returned");
  REQUIRE(!BLDIsEnabled(), "internal injection remains off");
  BLDStop();
  REQUIRE(!BLDIsEnabled(), "stop leaves native input intact");
  REQUIRE([BLDStatusText() containsString:@"Reloc"], "external input explained");
  NSDictionary *result=@{@"status":@"passed",@"checks":@(checks),@"real_location_api_calls":@0,@"app_binary_executed":@NO,@"mode":@"unmodified system Core Location input"};
  NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
  fwrite(data.bytes,1,data.length,stdout);
 }
 return 0;
}

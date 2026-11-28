#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL BLDStart(NSArray<NSArray<NSNumber *> *> *points,
                                double speed, double accuracy, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BLDStop(void);
FOUNDATION_EXPORT BOOL BLDIsEnabled(void);
FOUNDATION_EXPORT void BLDSetBackgroundEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL BLDBackgroundEnabled(void);
FOUNDATION_EXPORT BOOL BLDBackgroundPolicyApply(id manager, BOOL enabled, BOOL locationModeAllowed);
FOUNDATION_EXPORT NSString *BLDStatusText(void);
FOUNDATION_EXPORT void BLDInstallDebugUI(void);
FOUNDATION_EXPORT BOOL BLDInstallHooks(void);
FOUNDATION_EXPORT BOOL BLDIsSupportedBundleInfo(NSDictionary *info);
FOUNDATION_EXPORT NSURL * _Nullable BLDResolveGroupContainer(NSFileManager *files, NSURL * _Nullable original, NSString *group);
NS_ASSUME_NONNULL_END

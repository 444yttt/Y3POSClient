#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL BLDStart(NSArray<NSArray<NSNumber *> *> *points,
                                double speed, double accuracy, NSError **error);
FOUNDATION_EXPORT void BLDStop(void);
FOUNDATION_EXPORT BOOL BLDIsEnabled(void);
FOUNDATION_EXPORT NSString *BLDStatusText(void);
FOUNDATION_EXPORT void BLDInstallDebugUI(void);
FOUNDATION_EXPORT BOOL BLDInstallHooks(void);
NS_ASSUME_NONNULL_END

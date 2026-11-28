#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSArray<NSArray<NSNumber *> *> * _Nullable BLDParseCoordinates(NSString *text, NSUInteger limit, NSError **error);
FOUNDATION_EXPORT NSString *BLDCoordinateText(NSArray<NSArray<NSNumber *> *> *points);
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable BLDImportCandidates(NSData *data, NSString *extension, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable BLDReadImportURL(NSURL *url, NSError **error);
@interface BLDLibrary : NSObject
@property(nonatomic,readonly,nullable) NSError *loadError;
+ (instancetype)sharedLibrary;
- (instancetype)initWithURL:(NSURL *)url;
- (NSDictionary *)snapshot;
- (BOOL)saveDraft:(NSDictionary *)draft error:(NSError **)error;
- (BOOL)addTo:(NSString *)collection name:(NSString *)name points:(NSArray<NSArray<NSNumber *> *> *)points speed:(double)speed accuracy:(double)accuracy error:(NSError **)error;
- (BOOL)removeFrom:(NSString *)collection identifier:(NSString *)identifier error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

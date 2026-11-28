#import "BLDLibrary.h"
#import <TargetConditionals.h>
#include <math.h>
static const NSUInteger BLDImportLimit=2*1024*1024;
static NSError *BLDLibraryError(NSString *message) { return [NSError errorWithDomain:@"BumpLocationLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL fail(NSError **error,NSString *message) { if(error)*error=BLDLibraryError(message);return NO; }
static BOOL number(NSString *text,double *result) {
    if(![text isKindOfClass:NSString.class])return NO;
    NSScanner *s=[NSScanner scannerWithString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    s.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [s scanDouble:result] && s.isAtEnd && isfinite(*result);
}
static BOOL validPair(id pair) {
    if(![pair isKindOfClass:NSArray.class] || [pair count]!=2)return NO;
    id a=pair[0],b=pair[1];if(![a isKindOfClass:NSNumber.class] || ![b isKindOfClass:NSNumber.class])return NO;
    double lat=[a doubleValue],lon=[b doubleValue];return isfinite(lat)&&isfinite(lon)&&fabs(lat)<=90&&fabs(lon)<=180;
}
static NSArray<NSString *> *fields(NSString *line) {
    if([line containsString:@","])return [line componentsSeparatedByString:@","];
    NSMutableArray *values=[NSMutableArray array];
    for(NSString *s in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])if(s.length)[values addObject:s];
    return values;
}
static NSString *column(NSString *text) { return [[text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\"\r\n"]] lowercaseString]; }
NSArray<NSArray<NSNumber *> *> *BLDParseCoordinates(NSString *text,NSUInteger limit,NSError **error) {
    if(![text isKindOfClass:NSString.class] || text.length>BLDImportLimit){fail(error,@"座標テキストが大きすぎます。");return nil;}
    NSMutableArray *points=[NSMutableArray array];NSUInteger lineNumber=0;NSInteger latitudeColumn=0,longitudeColumn=1;BOOL first=YES,hasHeader=NO;
    text=[text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\ufeff"]];
    for(NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        lineNumber++;NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!line.length)continue;
        NSArray *parts=fields(line);
        if(first){
            first=NO;NSInteger lat=NSNotFound,lon=NSNotFound;
            for(NSUInteger i=0;i<parts.count;i++){
                NSString *name=column(parts[i]);if([@[@"lat",@"latitude",@"緯度"] containsObject:name])lat=(NSInteger)i;
                if([@[@"lon",@"lng",@"longitude",@"経度"] containsObject:name])lon=(NSInteger)i;
            }
            if(lat!=NSNotFound && lon!=NSNotFound){latitudeColumn=lat;longitudeColumn=lon;hasHeader=YES;continue;}
        }
        double lat,lon;
        if((NSUInteger)MAX(latitudeColumn,longitudeColumn)>=parts.count ||
           !number(column(parts[(NSUInteger)latitudeColumn]),&lat) || !number(column(parts[(NSUInteger)longitudeColumn]),&lon) || fabs(lat)>90 || fabs(lon)>180){
            fail(error,[NSString stringWithFormat:@"%lu行目の緯度・経度を読み取れません。",(unsigned long)lineNumber]);return nil;
        }
        if(parts.count!=2 && !hasHeader){fail(error,@"CSVは緯度・経度の2列、または列名付きで指定してください。");return nil;}
        [points addObject:@[@(lat),@(lon)]];
        if(points.count>limit){fail(error,[NSString stringWithFormat:@"座標は%lu地点まで読み込めます。切り捨てずに中止しました。",(unsigned long)limit]);return nil;}
    }
    if(!points.count){fail(error,@"座標がありません。");return nil;}return [points copy];
}
NSString *BLDCoordinateText(NSArray<NSArray<NSNumber *> *> *points) {
    NSMutableArray *lines=[NSMutableArray array];for(NSArray *p in points)[lines addObject:[NSString stringWithFormat:@"%.8f,%.8f",[p[0] doubleValue],[p[1] doubleValue]]];
    return [lines componentsJoinedByString:@"\n"];
}
static NSDictionary *candidate(NSString *name,NSArray *points) { return @{@"name":name.length?[name substringToIndex:MIN(name.length,80)]:@"読み込んだ経路",@"points":[points copy]}; }
static BOOL appendJSONGeometry(NSDictionary *geometry,NSString *name,NSMutableArray *out,NSError **error) {
    NSString *type=geometry[@"type"];id coordinates=geometry[@"coordinates"];
    if(![type isKindOfClass:NSString.class])return fail(error,@"GeoJSONのgeometryが不正です。");
    NSArray *groups;
    if([type isEqual:@"Point"])groups=@[@[coordinates?:NSNull.null]];
    else if([type isEqual:@"LineString"] || [type isEqual:@"MultiPoint"])groups=@[coordinates?:NSNull.null];
    else if([type isEqual:@"MultiLineString"] && [coordinates isKindOfClass:NSArray.class])groups=coordinates;
    else return fail(error,@"GeoJSONはPoint・MultiPoint・LineString・MultiLineStringに対応しています。");
    for(id group in groups){
        if(![group isKindOfClass:NSArray.class] || ![group count] || [group count]>10000)return fail(error,@"GeoJSONの地点数が不正です（1〜10000地点）。");
        NSMutableArray *points=[NSMutableArray array];
        for(id xyz in group){
            if(![xyz isKindOfClass:NSArray.class] || [xyz count]<2)return fail(error,@"GeoJSONの座標配列が不正です。");
            NSArray *pair=@[xyz[1],xyz[0]];if(!validPair(pair))return fail(error,@"GeoJSONの緯度・経度が範囲外です。");[points addObject:pair];
        }
        [out addObject:candidate(name,points)];if(out.count>100)return fail(error,@"1ファイルの経路数は100本までです。");
    }return YES;
}
@interface BLDGPXReader : NSObject <NSXMLParserDelegate>
@property(nonatomic,strong) NSMutableArray *routes;
@property(nonatomic,strong) NSMutableArray *group;
@property(nonatomic,strong) NSMutableArray<NSString *> *stack;
@property(nonatomic,copy) NSString *trackName;
@property(nonatomic,copy) NSString *groupName;
@property(nonatomic,strong) NSMutableString *nameBuffer;
@property(nonatomic,strong) NSError *failure;
@end
@implementation BLDGPXReader
- (instancetype)init { if((self=[super init])){_routes=[NSMutableArray array];_stack=[NSMutableArray array];_trackName=@"";_groupName=@"";}return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *,NSString *> *)attrs {
    (void)uri;(void)qualified;NSString *tag=[element componentsSeparatedByString:@":"].lastObject;NSString *parent=self.stack.lastObject;
    if([tag isEqual:@"trk"])self.trackName=@"";
    if([@[@"trkseg",@"rte",@"wpt"] containsObject:tag]){
        if(self.group){self.failure=BLDLibraryError(@"GPXの経路構造が不正です。");[parser abortParsing];return;}
        self.group=[NSMutableArray array];self.groupName=[tag isEqual:@"trkseg"]?self.trackName:@"";
    }
    if([tag isEqual:@"name"] && [@[@"trk",@"rte",@"wpt"] containsObject:parent])self.nameBuffer=[NSMutableString string];
    if([@[@"trkpt",@"rtept",@"wpt"] containsObject:tag]){
        double lat,lon;
        if(!self.group || !number(attrs[@"lat"],&lat) || !number(attrs[@"lon"],&lon) || fabs(lat)>90 || fabs(lon)>180 || self.group.count>=10000){self.failure=BLDLibraryError(@"GPXの地点が不正、または10000地点を超えています。");[parser abortParsing];return;}
        [self.group addObject:@[@(lat),@(lon)]];
    }
    [self.stack addObject:tag];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { (void)parser;if(self.nameBuffer && self.nameBuffer.length<200)[self.nameBuffer appendString:string]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
    (void)uri;(void)qualified;NSString *tag=[element componentsSeparatedByString:@":"].lastObject;
    if([tag isEqual:@"name"] && self.nameBuffer){NSString *n=[self.nameBuffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(self.group)self.groupName=n;else self.trackName=n;self.nameBuffer=nil;}
    if([@[@"trkseg",@"rte",@"wpt"] containsObject:tag]){
        if(self.group.count)[self.routes addObject:candidate(self.groupName,self.group)];self.group=nil;
        if(self.routes.count>100){self.failure=BLDLibraryError(@"1ファイルの経路数は100本までです。");[parser abortParsing];}
    }
    if(self.stack.count)[self.stack removeLastObject];
}
@end
NSArray<NSDictionary *> *BLDImportCandidates(NSData *data,NSString *extension,NSError **error) {
    if(!data.length || data.length>BLDImportLimit){fail(error,@"ファイルは空ではない2MB以下のものを選んでください。");return nil;}
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text){fail(error,@"文字コードはUTF-8に対応しています。");return nil;}
    NSString *trim=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *out=[NSMutableArray array];
    if([extension.lowercaseString isEqual:@"gpx"] || [extension.lowercaseString isEqual:@"xml"] || [trim hasPrefix:@"<"]){
        if([text rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location!=NSNotFound){fail(error,@"DTDを含むXMLは読み込みません。");return nil;}
        BLDGPXReader *reader=[BLDGPXReader new];NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];parser.delegate=reader;parser.shouldResolveExternalEntities=NO;parser.shouldProcessNamespaces=YES;
        if(![parser parse] || reader.failure){if(error)*error=reader.failure?:BLDLibraryError(@"GPX/XMLを読み取れません。");return nil;}[out addObjectsFromArray:reader.routes];
    }else if([trim hasPrefix:@"{"] || [extension.lowercaseString isEqual:@"geojson"] || [extension.lowercaseString isEqual:@"json"]){
        id root=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if(![root isKindOfClass:NSDictionary.class]){fail(error,@"GeoJSONの形式を確認してください。");return nil;}
        NSArray *features=[root[@"type"] isEqual:@"FeatureCollection"]?root[@"features"]:@[root];
        if(![features isKindOfClass:NSArray.class] || features.count>100){fail(error,@"GeoJSONは100個以下の地物にしてください。");return nil;}
        for(id f in features){
            if(![f isKindOfClass:NSDictionary.class]){fail(error,@"GeoJSONの地物が不正です。");return nil;}
            id geometry=[f[@"type"] isEqual:@"Feature"]?f[@"geometry"]:f;
            if(![geometry isKindOfClass:NSDictionary.class]){fail(error,@"GeoJSONのgeometryがありません。");return nil;}
            id properties=f[@"properties"];id name=[properties isKindOfClass:NSDictionary.class]?properties[@"name"]:nil;
            if(!appendJSONGeometry(geometry,[name isKindOfClass:NSString.class]?name:@"GeoJSON経路",out,error))return nil;
        }
    }else{
        NSArray *points=BLDParseCoordinates(text,10000,error);if(!points)return nil;[out addObject:candidate(@"テキスト経路",points)];
    }
    if(!out.count){fail(error,@"読み込める経路・地点がありません。");return nil;}return [out copy];
}
NSData *BLDReadImportURL(NSURL *url,NSError **error) {
    if(!url.isFileURL){fail(error,@"ファイルのURLを選んでください。");return nil;}
    NSInputStream *stream=[NSInputStream inputStreamWithURL:url];[stream open];NSMutableData *data=[NSMutableData data];uint8_t bytes[8192];NSInteger count;
    while((count=[stream read:bytes maxLength:sizeof(bytes)])>0){[data appendBytes:bytes length:(NSUInteger)count];if(data.length>BLDImportLimit){[stream close];fail(error,@"ファイルは2MB以下にしてください。");return nil;}}
    NSError *failure=stream.streamError;[stream close];if(count<0 || failure){if(error)*error=failure?:BLDLibraryError(@"ファイルを読み取れません。");return nil;}return data;
}
@interface BLDLibrary ()
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,strong) NSDictionary *state;
@property(nonatomic,readwrite,strong) NSError *loadError;
@end
@implementation BLDLibrary
+ (instancetype)sharedLibrary {
    static BLDLibrary *library;static dispatch_once_t once;dispatch_once(&once,^{
        NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        library=[[BLDLibrary alloc] initWithURL:[[base URLByAppendingPathComponent:@"BumpLocationDebug" isDirectory:YES] URLByAppendingPathComponent:@"library-v1.json"]];
    });return library;
}
- (instancetype)initWithURL:(NSURL *)url {
    if((self=[super init])){
        _url=url;_state=@{@"schema":@1,@"draft":@{},@"routes":@[],@"places":@[],@"history":@[]};
        if(!url){_loadError=BLDLibraryError(@"保存先を取得できません。");return self;}
        if([NSFileManager.defaultManager fileExistsAtPath:url.path]){
            NSError *error=nil;NSData *data=BLDReadImportURL(url,&error);id root=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
            BOOL valid=[root isKindOfClass:NSDictionary.class] && [root[@"schema"] isEqual:@1] && [root[@"draft"] isKindOfClass:NSDictionary.class];
            if(valid){
                NSDictionary *draft=root[@"draft"];
                for(NSString *key in @[@"coordinates",@"speed",@"accuracy"]){id value=draft[key];if(value && (![value isKindOfClass:NSString.class] || [value length]>([key isEqual:@"coordinates"]?262144:64)))valid=NO;}
                if(draft[@"background"] && ![draft[@"background"] isKindOfClass:NSNumber.class])valid=NO;
            }
            for(NSString *kind in @[@"routes",@"places",@"history"]){
                id rows=valid?root[kind]:nil;if(![rows isKindOfClass:NSArray.class] || [rows count]>1000){valid=NO;break;}
                for(id row in rows){
                    if(![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] || ![row[@"name"] isKindOfClass:NSString.class] || ![row[@"coordinates"] isKindOfClass:NSString.class] || ![row[@"speed"] isKindOfClass:NSNumber.class] || ![row[@"accuracy"] isKindOfClass:NSNumber.class] || ![row[@"createdAt"] isKindOfClass:NSNumber.class] || !BLDParseCoordinates(row[@"coordinates"],256,NULL) || !isfinite([row[@"speed"] doubleValue]) || [row[@"speed"] doubleValue]<0 || !isfinite([row[@"accuracy"] doubleValue]) || [row[@"accuracy"] doubleValue]<=0){valid=NO;break;}
                }
            }
            if(valid)_state=root;else _loadError=error?:BLDLibraryError(@"保存データを読み取れません。元ファイルは変更していません。");
        }
    }return self;
}
- (NSDictionary *)snapshot { @synchronized(self){NSData *data=[NSJSONSerialization dataWithJSONObject:self.state options:0 error:NULL];return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];} }
- (BOOL)commit:(NSDictionary *)state error:(NSError **)error {
    if(self.loadError){if(error)*error=self.loadError;return NO;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:error];if(!data || data.length>BLDImportLimit)return fail(error,@"保存データが2MBを超えています。");
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error])return NO;
    NSDataWritingOptions options=NSDataWritingAtomic;
#if TARGET_OS_IOS
    options|=NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
    if(![data writeToURL:self.url options:options error:error])return NO;
    [self.url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];self.state=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];return YES;
}
- (BOOL)saveDraft:(NSDictionary *)draft error:(NSError **)error {
    NSMutableDictionary *clean=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"coordinates",@"speed",@"accuracy"]){id value=draft[key];if(![value isKindOfClass:NSString.class] || [value length]>([key isEqual:@"coordinates"]?262144:64))return fail(error,@"入力の保存サイズを確認してください。");clean[key]=value;}
    clean[@"background"]=[draft[@"background"] isKindOfClass:NSNumber.class]?@([draft[@"background"] boolValue]):@YES;
    @synchronized(self){NSMutableDictionary *next=[self.state mutableCopy];next[@"draft"]=clean;return [self commit:next error:error];}
}
- (BOOL)addTo:(NSString *)collection name:(NSString *)name points:(NSArray *)points speed:(double)speed accuracy:(double)accuracy error:(NSError **)error {
    if(![@[@"routes",@"places",@"history"] containsObject:collection])return fail(error,@"保存先の種類が不正です。");
    name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!name.length || name.length>80 || points.count==0 || points.count>256 || !isfinite(speed) || speed<0 || !isfinite(accuracy) || accuracy<=0)return fail(error,@"名前は1〜80文字、経路は1〜256地点で保存してください。");
    if([collection isEqual:@"places"] && points.count!=1)return fail(error,@"地点保存は1地点を指定してください。");
    for(id pair in points)if(!validPair(pair))return fail(error,@"保存する緯度・経度を確認してください。");
    NSDictionary *item=@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"coordinates":BLDCoordinateText(points),@"speed":@(speed),@"accuracy":@(accuracy),@"createdAt":@(NSDate.date.timeIntervalSince1970)};
    @synchronized(self){NSMutableArray *rows=[self.state[collection] mutableCopy];if(![collection isEqual:@"history"] && rows.count>=1000)return fail(error,@"この種類の保存件数は1000件までです。");[rows insertObject:item atIndex:0];if([collection isEqual:@"history"] && rows.count>100)[rows removeObjectsInRange:NSMakeRange(100,rows.count-100)];NSMutableDictionary *next=[self.state mutableCopy];next[collection]=rows;return [self commit:next error:error];}
}
- (BOOL)removeFrom:(NSString *)collection identifier:(NSString *)identifier error:(NSError **)error {
    if(![@[@"routes",@"places",@"history"] containsObject:collection])return fail(error,@"削除する種類が不正です。");
    @synchronized(self){NSMutableArray *rows=[self.state[collection] mutableCopy];NSIndexSet *indices=[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger index,BOOL *stop){(void)index;(void)stop;return [row[@"id"] isEqual:identifier];}];if(!indices.count)return fail(error,@"削除対象が見つかりません。");[rows removeObjectsAtIndexes:indices];NSMutableDictionary *next=[self.state mutableCopy];next[collection]=rows;return [self commit:next error:error];}
}
@end

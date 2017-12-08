//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "TSYapDatabaseObject.h"
#import "TSStorageManager.h"
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSYapDatabaseObject ()

@property (atomic) BOOL hasEverBeenSaved;

@end

#pragma mark -

@implementation TSYapDatabaseObject

- (instancetype)init
{
    return [self initWithUniqueId:[[NSUUID UUID] UUIDString]];
}

- (instancetype)initWithUniqueId:(NSString *_Nullable)aUniqueId
{
    self = [super init];
    if (!self) {
        return self;
    }

    _uniqueId = aUniqueId;

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    self.hasEverBeenSaved = YES;

    return self;
}

- (void)saveWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [transaction setObject:self forKey:self.uniqueId inCollection:[[self class] collection]];

    self.hasEverBeenSaved = YES;
}

- (void)save
{
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self saveWithTransaction:transaction];
    }];
}

- (void)saveAsyncWithCompletionBlock:(void (^_Nullable)(void))completionBlock
{
    [[self dbReadWriteConnection] asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        [self saveWithTransaction:transaction];
    }
                                          completionBlock:completionBlock];
}

- (void)touchWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [transaction touchObjectForKey:self.uniqueId inCollection:[self.class collection]];
}

- (void)touch
{
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self touchWithTransaction:transaction];
    }];
}

- (void)removeWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [transaction removeObjectForKey:self.uniqueId inCollection:[[self class] collection]];
}

- (void)remove
{
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self removeWithTransaction:transaction];
    }];
}

- (YapDatabaseConnection *)dbReadConnection
{
    return [[self class] dbReadConnection];
}

- (YapDatabaseConnection *)dbReadWriteConnection
{
    return [[self class] dbReadWriteConnection];
}

- (TSStorageManager *)storageManager
{
    return [[self class] storageManager];
}

#pragma mark Class Methods

+ (MTLPropertyStorage)storageBehaviorForPropertyWithKey:(NSString *)propertyKey
{
    if ([propertyKey isEqualToString:@"TAG"]) {
        return MTLPropertyStorageNone;
    } else {
        return [super storageBehaviorForPropertyWithKey:propertyKey];
    }
}

+ (YapDatabaseConnection *)dbReadConnection
{
    // We use TSYapDatabaseObject's dbReadWriteConnection (not TSStorageManager's
    // dbReadConnection) for consistency, since we tend to [TSYapDatabaseObject
    // save] and want to write to the same connection we read from.  To get true
    // consistency, we'd want to update entities by reading & writing from within
    // the same transaction, but that'll be a big refactor.

    return self.dbReadWriteConnection;
}

+ (YapDatabaseConnection *)dbReadWriteConnection
{
    // Use a dedicated connection for model reads & writes.
    static YapDatabaseConnection *dbReadWriteConnection = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dbReadWriteConnection = [self storageManager].newDatabaseConnection;
    });
    return dbReadWriteConnection;
}

+ (TSStorageManager *)storageManager
{
    return [TSStorageManager sharedManager];
}

+ (NSString *)collection
{
    return NSStringFromClass([self class]);
}

+ (NSUInteger)numberOfKeysInCollection
{
    __block NSUInteger count;
    [[self dbReadConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        count = [self numberOfKeysInCollectionWithTransaction:transaction];
    }];
    return count;
}

+ (NSUInteger)numberOfKeysInCollectionWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [transaction numberOfKeysInCollection:[self collection]];
}

+ (NSArray *)allObjectsInCollection
{
    __block NSMutableArray *all = [[NSMutableArray alloc] initWithCapacity:[self numberOfKeysInCollection]];
    [self enumerateCollectionObjectsUsingBlock:^(id object, BOOL *stop) {
        [all addObject:object];
    }];
    return [all copy];
}

+ (void)enumerateCollectionObjectsUsingBlock:(void (^)(id object, BOOL *stop))block
{
    [[self dbReadConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        [self enumerateCollectionObjectsWithTransaction:transaction usingBlock:block];
    }];
}

+ (void)enumerateCollectionObjectsWithTransaction:(YapDatabaseReadTransaction *)transaction
                                       usingBlock:(void (^)(id object, BOOL *stop))block
{
    // Ignoring most of the YapDB parameters, and just passing through the ones we usually use.
    void (^yapBlock)(NSString *key, id object, id metadata, BOOL *stop)
        = ^void(NSString *key, id object, id metadata, BOOL *stop) {
              block(object, stop);
          };

    [transaction enumerateRowsInCollection:[self collection] usingBlock:yapBlock];
}

+ (void)removeAllObjectsInCollection
{
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [transaction removeAllObjectsInCollection:[self collection]];
    }];
}

+ (nullable instancetype)fetchObjectWithUniqueID:(NSString *)uniqueID
                                     transaction:(YapDatabaseReadTransaction *)transaction
{
    return [transaction objectForKey:uniqueID inCollection:[self collection]];
}

+ (nullable instancetype)fetchObjectWithUniqueID:(NSString *)uniqueID
{
    __block id _Nullable object = nil;
    [[self dbReadConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        object = [transaction objectForKey:uniqueID inCollection:[self collection]];
    }];
    return object;
}

#pragma mark Update With...

- (void)applyChangeToSelfAndLatestCopy:(YapDatabaseReadWriteTransaction *)transaction
                           changeBlock:(void (^)(id))changeBlock
{
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:changeBlock saveIfMissing:NO];
}

- (void)applyChangeToSelfAndLatestCopy:(YapDatabaseReadWriteTransaction *)transaction
                           changeBlock:(void (^)(id))changeBlock
                         saveIfMissing:(BOOL)saveIfMissing
{
    OWSAssert(transaction);

    changeBlock(self);

    NSString *collection = [[self class] collection];
    id latestInstance = [transaction objectForKey:self.uniqueId inCollection:collection];
    if (latestInstance) {
        changeBlock(latestInstance);
        [latestInstance saveWithTransaction:transaction];
    } else if (saveIfMissing) {
        [self saveWithTransaction:transaction];
    }
}

@end

NS_ASSUME_NONNULL_END

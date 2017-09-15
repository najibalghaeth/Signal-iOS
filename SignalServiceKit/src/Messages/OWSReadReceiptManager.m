//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "OWSReadReceiptManager.h"
#import "OWSMessageSender.h"
#import "OWSReadReceipt.h"
#import "OWSReadReceiptsForLinkedDevicesMessage.h"
#import "OWSReadReceiptsForSenderMessage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSContactThread.h"
#import "TSDatabaseView.h"
#import "TSIncomingMessage.h"
#import "TSStorageManager.h"
#import "TextSecureKitEnv.h"
#import "Threading.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const OWSReadReceiptManagerCollection = @"OWSReadReceiptManagerCollection";
NSString *const OWSReadReceiptManagerAreReadReceiptsEnabled = @"areReadReceiptsEnabled";

@interface OWSReadReceiptManager ()

@property (nonatomic, readonly) OWSMessageSender *messageSender;

@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;

// A map of "thread unique id"-to-"read receipt" for read receipts that
// we will send to our linked devices.
//
// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, OWSReadReceipt *> *toLinkedDevicesReadReceiptMap;

// A map of "recipient id"-to-"timestamp list" for read receipts that
// we will send to senders.
//
// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *toSenderReadReceiptMap;

// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic) BOOL isProcessing;

// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic) NSNumber *areReadReceiptsEnabledCached;

@end

#pragma mark -

@implementation OWSReadReceiptManager

+ (instancetype)sharedManager
{
    static OWSReadReceiptManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    OWSMessageSender *messageSender = [TextSecureKitEnv sharedEnv].messageSender;
    TSStorageManager *storageManager = [TSStorageManager sharedManager];

    return [self initWithMessageSender:messageSender storageManager:storageManager];
}

- (instancetype)initWithMessageSender:(OWSMessageSender *)messageSender
                       storageManager:(TSStorageManager *)storageManager
{
    self = [super init];

    if (!self) {
        return self;
    }

    _messageSender = messageSender;
    _dbConnection = storageManager.newDatabaseConnection;

    _toLinkedDevicesReadReceiptMap = [NSMutableDictionary new];
    _toSenderReadReceiptMap = [NSMutableDictionary new];

    OWSSingletonAssert();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(databaseViewRegistrationComplete)
                                                 name:kNSNotificationName_DatabaseViewRegistrationComplete
                                               object:nil];

    DDLogInfo(@"%@ areReadReceiptsEnabled: %d.", self.tag, self.areReadReceiptsEnabled);

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)databaseViewRegistrationComplete
{
    [self scheduleProcessing];
}

// Schedules a processing pass, unless one is already scheduled.
- (void)scheduleProcessing
{
    DispatchMainThreadSafe(^{
        @synchronized(self)
        {
            if ([TSDatabaseView hasPendingViewRegistrations]) {
                DDLogInfo(
                    @"%@ Deferring read receipt processing due to pending database view registrations.", self.tag);
                return;
            }
            if (self.isProcessing) {
                return;
            }

            self.isProcessing = YES;

            // Process read receipts every N seconds.
            //
            // We want a value high enough to allow us to effectively deduplicate,
            // read receipts without being so high that we risk not sending read
            // receipts due to app exit.
            const CGFloat kProcessingFrequencySeconds = 3.f;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProcessingFrequencySeconds * NSEC_PER_SEC)),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{
                    [self process];
                });
        }
    });
}

- (void)process
{
    @synchronized(self)
    {
        DDLogVerbose(@"%@ Processing read receipts.", self.tag);

        self.isProcessing = NO;

        NSArray<OWSReadReceipt *> *readReceiptsForLinkedDevices = [[self.toLinkedDevicesReadReceiptMap allValues] copy];
        [self.toLinkedDevicesReadReceiptMap removeAllObjects];
        if (readReceiptsForLinkedDevices.count > 0) {
            OWSReadReceiptsForLinkedDevicesMessage *message =
                [[OWSReadReceiptsForLinkedDevicesMessage alloc] initWithReadReceipts:readReceiptsForLinkedDevices];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.messageSender sendMessage:message
                    success:^{
                        DDLogInfo(@"%@ Successfully sent %zd read receipt to linked devices.",
                            self.tag,
                            readReceiptsForLinkedDevices.count);
                    }
                    failure:^(NSError *error) {
                        DDLogError(@"%@ Failed to send read receipt to linked devices with error: %@", self.tag, error);
                    }];
            });
        }

        NSArray<OWSReadReceipt *> *readReceiptsToSend = [[self.toLinkedDevicesReadReceiptMap allValues] copy];
        [self.toLinkedDevicesReadReceiptMap removeAllObjects];
        if (self.toSenderReadReceiptMap.count > 0) {
            for (NSString *recipientId in self.toSenderReadReceiptMap) {
                NSArray<NSNumber *> *timestamps = self.toSenderReadReceiptMap[recipientId];
                OWSAssert(timestamps.count > 0);

                TSThread *thread = [TSContactThread getOrCreateThreadWithContactId:recipientId];
                OWSReadReceiptsForSenderMessage *message =
                    [[OWSReadReceiptsForSenderMessage alloc] initWithThread:thread messageTimestamps:timestamps];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.messageSender sendMessage:message
                        success:^{
                            DDLogInfo(@"%@ Successfully sent %zd read receipts to sender.",
                                self.tag,
                                readReceiptsToSend.count);
                        }
                        failure:^(NSError *error) {
                            DDLogError(@"%@ Failed to send read receipts to sender with error: %@", self.tag, error);
                        }];
                });
            }
            [self.toSenderReadReceiptMap removeAllObjects];
        }
    }
}

- (void)messageWasReadLocally:(TSIncomingMessage *)message;
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(self)
        {
            NSString *threadUniqueId = message.thread.uniqueId;
            OWSAssert(threadUniqueId.length > 0);

            // Only groupthread sets authorId, thus this crappy code.
            // TODO Refactor so that ALL incoming messages have an authorId.
            NSString *messageAuthorId;
            if (message.authorId) {
                // Group Thread
                messageAuthorId = message.authorId;
            } else {
                // Contact Thread
                messageAuthorId = [TSContactThread contactIdFromThreadId:message.uniqueThreadId];
            }
            OWSAssert(messageAuthorId.length > 0);

            OWSReadReceipt *newReadReceipt =
                [[OWSReadReceipt alloc] initWithSenderId:messageAuthorId timestamp:message.timestamp];

            OWSReadReceipt *_Nullable oldReadReceipt = self.toLinkedDevicesReadReceiptMap[threadUniqueId];
            if (oldReadReceipt && oldReadReceipt.timestamp > newReadReceipt.timestamp) {
                // If there's an existing read receipt for the same thread with
                // a newer timestamp, discard the new read receipt.
                DDLogVerbose(@"%@ Ignoring redundant read receipt for linked devices.", self.tag);
            } else {
                DDLogVerbose(@"%@ Enqueuing read receipt for linked devices.", self.tag);
                self.toLinkedDevicesReadReceiptMap[threadUniqueId] = newReadReceipt;
            }

            if ([self areReadReceiptsEnabled]) {
                DDLogVerbose(@"%@ Enqueuing read receipt for sender.", self.tag);
                NSMutableArray<NSNumber *> *_Nullable timestamps = self.toSenderReadReceiptMap[messageAuthorId];
                if (!timestamps) {
                    timestamps = [NSMutableArray new];
                    self.toSenderReadReceiptMap[messageAuthorId] = timestamps;
                }
                [timestamps addObject:@(message.timestamp)];
            }

            [self scheduleProcessing];
        }
    });
}

#pragma mark - Read Receipts From Recipient

- (void)processReadReceiptsFromRecipient:(OWSSignalServiceProtosReceiptMessage *)receiptMessage
                                envelope:(OWSSignalServiceProtosEnvelope *)envelope
{
    OWSAssert(receiptMessage);
    OWSAssert(envelope);
    OWSAssert(receiptMessage.type == OWSSignalServiceProtosReceiptMessageTypeRead);

    if (![self areReadReceiptsEnabled]) {
        DDLogInfo(@"%@ Ignoring receipt message as read receipts are disabled.", self.tag);
        return;
    }

    NSString *recipientId = envelope.source;
    OWSAssert(recipientId.length > 0);

    PBArray *timestamps = receiptMessage.timestamp;
    for (int i = 0; i < timestamps.count; i++) {
        UInt64 timestamp = [timestamps uint64AtIndex:i];

        DDLogError(@"%@ timestamp: %llu", self.tag, timestamp);
    }
}

#pragma mark - Settings

- (BOOL)areReadReceiptsEnabled
{
    @synchronized(self)
    {
        if (!self.areReadReceiptsEnabledCached) {
            // Default to NO.
            self.areReadReceiptsEnabledCached =
                @([self.dbConnection boolForKey:OWSReadReceiptManagerAreReadReceiptsEnabled
                                   inCollection:OWSReadReceiptManagerCollection]);
        }

        return [self.areReadReceiptsEnabledCached boolValue];
    }
}

- (void)setAreReadReceiptsEnabled:(BOOL)value
{
    DDLogInfo(@"%@ areReadReceiptsEnabled: %d.", self.tag, value);

    @synchronized(self)
    {
        [self.dbConnection setBool:value
                            forKey:OWSReadReceiptManagerAreReadReceiptsEnabled
                      inCollection:OWSReadReceiptManagerCollection];
        self.areReadReceiptsEnabledCached = @(value);
    }
}

#pragma mark - Logging

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end

NS_ASSUME_NONNULL_END
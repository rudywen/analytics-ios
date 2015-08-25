//
//  ExpaProvider.m
//  Analytics
//
//  Created by Justin Ho on 3/19/14.
//  Copyright (c) 2014 Expa. All rights reserved.
//

#include <sys/sysctl.h>

#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "SEGAnalytics.h"
#import "SEGAnalyticsUtils.h"
#import "SEGAnalyticsRequest.h"
#import "SEGExpaIntegration.h"
#import "SEGBluetooth.h"
#import "SEGReachability.h"
#import "SEGLocation.h"

#define EXPA_API_URL_STRING @"https://changeme.collector.expa.com/expadata/clientcollector/changeme"

NSString *const kExpaAnalyticsDidSendRequestNotification    = @"ExpaAnalyticsDidSendRequest";
NSString *const kExpaAnalyticsRequestDidSucceedNotification = @"ExpaAnalyticsRequestDidSucceed";
NSString *const kExpaAnalyticsRequestDidFailNotification    = @"ExpaAnalyticsRequestDidFail";

static NSString *GenerateUUIDString() {
    CFUUIDRef theUUID = CFUUIDCreate(NULL);
    NSString *UUIDString = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, theUUID);
    CFRelease(theUUID);
    return UUIDString;
}

static NSString *GetAnonymousId(BOOL reset) {
    // We've chosen to generate a UUID rather than use the UDID (deprecated in iOS 5),
    // identifierForVendor (iOS6 and later, can't be changed on logout),
    // or MAC address (blocked in iOS 7). For more info see https://segment.io/libraries/ios#ids
    NSURL *url = SEGAnalyticsURLForFilename(@"expa.anonymousId");
    NSString *anonymousId = [[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (!anonymousId || reset) {
        anonymousId = GenerateUUIDString();
        SEGLog(@"New anonymousId: %@", anonymousId);
        [anonymousId writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return anonymousId;
}

static NSString *GetDeviceModel() {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char result[size];
    sysctlbyname("hw.machine", result, &size, NULL, 0);
    NSString *results = [NSString stringWithCString:result encoding:NSUTF8StringEncoding];
    return results;
}

static NSMutableDictionary *BuildStaticContext() {
    NSMutableDictionary *context = [[NSMutableDictionary alloc] init];
    
    context[@"library"] = @"analytics-ios-expa";
    context[@"library-version"] = SEGStringize(ANALYTICS_VERSION);
    
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    if (infoDictionary.count) {
        context[@"appName"]         = infoDictionary[@"CFBundleDisplayName"];
        context[@"appShortVersion"] = infoDictionary[@"CFBundleShortVersionString"];
        context[@"appVersion"]      = infoDictionary[@"CFBundleVersion"];
        context[@"appBundleId"]     = infoDictionary[@"CFBundleIdentifier"];
    }
    
    UIDevice *device = [UIDevice currentDevice];
    
    context[@"deviceManufacturer"] = @"Apple";
    context[@"deviceModel"] = GetDeviceModel();
    context[@"deviceId"] = [[device identifierForVendor] UUIDString];
    
    context[@"os"] = device.systemName;
    context[@"osVersion"] = device.systemVersion;
    
    CTCarrier *carrier = [[[CTTelephonyNetworkInfo alloc] init] subscriberCellularProvider];
    if (carrier.carrierName.length)
        context[@"carrier"] = carrier.carrierName;
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    context[@"screenWidth"] = @(screenSize.width);
    context[@"screenHeight"] = @(screenSize.height);
    
    return context;
}

static NSString *OrientationString(UIDeviceOrientation orientation)
{
    if      (orientation == UIDeviceOrientationUnknown)            { return @"unknown"; }
    else if (orientation == UIDeviceOrientationPortrait)           { return @"portrait"; }
    else if (orientation == UIDeviceOrientationPortraitUpsideDown) { return @"portraitUpsideDown"; }
    else if (orientation == UIDeviceOrientationLandscapeLeft)      { return @"landscapeLeft"; }
    else if (orientation == UIDeviceOrientationLandscapeRight)     { return @"landscapeRight"; }
    else if (orientation == UIDeviceOrientationFaceUp)             { return @"faceUp"; }
    else if (orientation == UIDeviceOrientationFaceDown)           { return @"faceDown"; }
    else                                                           { return @"error"; }
}

@interface SEGExpaIntegration ()

@property (nonatomic, strong) NSMutableArray *queue;
@property (nonatomic, strong) NSMutableDictionary *context;
@property (nonatomic, strong) NSArray *batch;
@property (nonatomic, strong) SEGAnalyticsRequest *request;
@property (nonatomic, assign) UIBackgroundTaskIdentifier flushTaskID;
@property (nonatomic, strong) SEGBluetooth *bluetooth;
@property (nonatomic, strong) SEGReachability *reachability;
@property (nonatomic, strong) SEGLocation *location;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic, strong) dispatch_queue_t serialQueue;
@property (nonatomic, strong) NSMutableDictionary *traits;

@end

@implementation SEGExpaIntegration

- (NSDictionary *)expaAddedProperties
{
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    UIDevice *device = [UIDevice currentDevice];
    properties[@"deviceOrientation"] = OrientationString([device orientation]);
    if (self.location.hasKnownLocation) {
        properties[@"location"] = self.location.locationDictionary;
    }
    return properties;
}

- (id)initWithConfiguration:(SEGAnalyticsConfiguration *)configuration {
    if (self = [super init]) {
        self.configuration = configuration;
        self.apiURL = [NSURL URLWithString:EXPA_API_URL_STRING];
        self.anonymousId = GetAnonymousId(NO);
        self.userId = [[NSString alloc] initWithContentsOfURL:self.userIDURL encoding:NSUTF8StringEncoding error:NULL];
        self.bluetooth = [[SEGBluetooth alloc] init];
        self.reachability = [SEGReachability reachabilityWithHostname:@"http://google.com"];
        self.context = BuildStaticContext();
        self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(flush) userInfo:nil repeats:YES];
        self.serialQueue = dispatch_queue_create("com.expa.analytics", DISPATCH_QUEUE_SERIAL);
        self.flushTaskID = UIBackgroundTaskInvalid;
        self.name = @"Expa";
//        self.settings = @{ @"writeKey": configuration.writeKey };
        [self validate];
        self.initialized = YES;
    }
    return self;
}

- (NSMutableDictionary *)liveContext {
    NSMutableDictionary *context = [[NSMutableDictionary alloc] init];
    
//    [context addEntriesFromDictionary:self.context];
    
    context[@"network"] = ({
        NSMutableDictionary *network = [[NSMutableDictionary alloc] init];
        
        if (self.bluetooth.hasKnownState)
            network[@"bluetooth"] = @(self.bluetooth.isEnabled);
        
        if (self.reachability.isReachable)
            network[@"wifi"] = @(self.reachability.isReachableViaWiFi);
        
        network;
    });
    
    context[@"traits"] = ({
        NSMutableDictionary *traits = [[NSMutableDictionary alloc] init];
        
        if (self.location.hasKnownLocation)
            traits[@"address"] = self.location.addressDictionary;
        
        traits;
    });
    
    return context;
}

- (void)dispatchBackground:(void(^)(void))block {
    dispatch_async(_serialQueue, block);
}

- (void)dispatchBackgroundAndWait:(void(^)(void))block {
    dispatch_sync(_serialQueue, block);
}

- (void)beginBackgroundTask {
    [self endBackgroundTask];
    
    self.flushTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self endBackgroundTask];
    }];
}

- (void)endBackgroundTask {
    [self dispatchBackgroundAndWait:^{
        if (self.flushTaskID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.flushTaskID];
            self.flushTaskID = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)validate {
    self.valid = ![[self.settings objectForKey:@"off"] boolValue]; //this will always evaluate to YES
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%p:%@>", self, self.class];
}

- (void)saveUserId:(NSString *)userId {
    [self dispatchBackground:^{
        self.userId = userId;
        [_userId writeToURL:self.userIDURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
}

- (void)addTraits:(NSDictionary *)traits {
    [self dispatchBackground:^{
        [_traits addEntriesFromDictionary:traits];
        [_traits writeToURL:self.traitsURL atomically:YES];
    }];
}

#pragma mark - Analytics API

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits options:(NSDictionary *)options {
    [self dispatchBackground:^{
        [self saveUserId:userId];
        [self addTraits:traits];
    }];
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:traits forKey:@"traits"];
    [dictionary addEntriesFromDictionary:[self expaAddedProperties]];
    
    [self enqueueAction:@"identify" dictionary:dictionary options:options];
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties options:(NSDictionary *)options {
    NSCParameterAssert(event.length > 0);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:event forKey:@"event"];
    [dictionary setValue:properties forKey:@"properties"];
    [dictionary addEntriesFromDictionary:[self expaAddedProperties]];
    
    [self enqueueAction:@"track" dictionary:dictionary options:options];
}

- (void)screen:(NSString *)screenTitle properties:(NSDictionary *)properties options:(NSDictionary *)options {
    NSCParameterAssert(screenTitle.length > 0);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:screenTitle forKey:@"name"];
    [dictionary setValue:properties forKey:@"properties"];
    [dictionary addEntriesFromDictionary:[self expaAddedProperties]];
    
    [self enqueueAction:@"screen" dictionary:dictionary options:options];
}

- (void)group:(NSString *)groupId traits:(NSDictionary *)traits options:(NSDictionary *)options {
    NSCParameterAssert(groupId.length > 0);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:groupId forKey:@"groupId"];
    [dictionary setValue:traits forKey:@"traits"];
    
    [self enqueueAction:@"group" dictionary:dictionary options:options];
}

- (void)registerForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSCParameterAssert(deviceToken != nil);
    
    const unsigned char *buffer = (const unsigned char *)[deviceToken bytes];
    if (!buffer) {
        return;
    }
    NSMutableString *token = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
    for (NSUInteger i = 0; i < deviceToken.length; i++) {
        [token appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)buffer[i]]];
    }
    [self.context[@"device"] setObject:[token copy] forKey:@"token"];
}

#pragma mark - Queueing

- (void)enqueueAction:(NSString *)action dictionary:(NSDictionary *)dictionary options:(NSDictionary *)options {
    // attach these parts of the payload outside since they are all synchronous
    // and the timestamp will be more accurate.
    NSMutableDictionary *payload = [dictionary mutableCopy];
    payload[@"action"] = action;
    payload[@"timestamp"] = [[NSDate date] description];
    payload[@"requestId"] = GenerateUUIDString();
    
    [self dispatchBackground:^{
        // attach userId and anonymousId inside the dispatch_async in case
        // they've changed (see identify function)
        [payload setValue:self.userId forKey:@"userId"];
        [payload setValue:self.anonymousId forKey:@"sessionId"];
        SEGLog(@"%@ Enqueueing action: %@", self, payload);
        
        [payload setValue:[self liveContext] forKey:@"liveContext"];
        
        [self queuePayload:payload];
    }];
}

- (void)queuePayload:(NSDictionary *)payload {
    [self.queue addObject:payload];
    [self flushQueueByLength];
}

- (void)flush {
    [self flushWithMaxSize:self.maxBatchSize];
}

- (void)flushWithMaxSize:(NSUInteger)maxBatchSize {
    [self dispatchBackground:^{
        if ([self.queue count] == 0) {
            SEGLog(@"%@ No queued API calls to flush.", self);
            return;
        } else if (self.request != nil) {
            SEGLog(@"%@ API request already in progress, not flushing again.", self);
            return;
        } else if ([self.queue count] >= maxBatchSize) {
            self.batch = [self.queue subarrayWithRange:NSMakeRange(0, maxBatchSize)];
        } else {
            self.batch = [NSArray arrayWithArray:self.queue];
        }
        
        SEGLog(@"%@ Flushing %lu of %lu queued API calls.", self, (unsigned long)self.batch.count, (unsigned long)self.queue.count);
        
        NSMutableDictionary *payloadDictionary = [NSMutableDictionary dictionary];
//        [payloadDictionary setObject:self.configuration.writeKey forKey:@"secret"];
        [payloadDictionary setObject:[[NSDate date] description] forKey:@"requestTimestamp"];
        [payloadDictionary setObject:self.context forKey:@"context"];
        [payloadDictionary setObject:self.batch forKey:@"batch"];
        
        SEGLog(@"Flushing payload %@", payloadDictionary);
        
        NSError *error = nil;
        NSData *payload = [NSJSONSerialization dataWithJSONObject:payloadDictionary
                                                          options:0 error:&error];
        if (error) {
            SEGLog(@"%@ Error serializing JSON: %@", self, error);
        }
        
        [self sendData:payload];
    }];
}

- (void)flushQueueByLength {
    [self dispatchBackground:^{
        SEGLog(@"%@ Length is %lu.", self, (unsigned long)self.queue.count);
        
        if (self.request == nil && [self.queue count] >= self.configuration.flushAt) {
            [self flush];
        }
    }];
}

- (void)reset {
    [self dispatchBackgroundAndWait:^{
        [[NSFileManager defaultManager] removeItemAtURL:self.userIDURL error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:self.traitsURL error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:self.queueURL error:NULL];
        self.userId = nil;
        self.queue = [NSMutableArray array];
        self.anonymousId = GetAnonymousId(YES);
        self.request.completion = nil;
        self.request = nil;
    }];
}

- (void)notifyForName:(NSString *)name userInfo:(id)userInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:self];
        SEGLog(@"sent notification %@", name);
    });
}

- (void)sendData:(NSData *)data {
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:self.apiURL];
    [urlRequest setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setHTTPMethod:@"POST"];
    [urlRequest setHTTPBody:data];
    
    SEGLog(@"%@ Sending batch API request.", self);
    self.request = [SEGAnalyticsRequest startWithURLRequest:urlRequest completion:^{
        [self dispatchBackground:^{
            if (self.request.error) {
                SEGLog(@"%@ API request had an error: %@", self, self.request.error);
                [self notifyForName:kExpaAnalyticsRequestDidFailNotification userInfo:self.batch];
            }
            else {
                SEGLog(@"%@ API request success 200", self);
                [self.queue removeObjectsInArray:self.batch];
                [self notifyForName:kExpaAnalyticsRequestDidSucceedNotification userInfo:self.batch];
            }
            
            self.batch = nil;
            self.request = nil;
            [self endBackgroundTask];
        }];
    }];
    [self notifyForName:kExpaAnalyticsDidSendRequestNotification userInfo:self.batch];
}

- (void)applicationDidEnterBackground {
    [self beginBackgroundTask];
    // We are gonna try to flush as much as we reasonably can when we enter background
    // since there is a chance that the user will never launch the app again.
    [self flush];
}

- (void)applicationWillTerminate {
    [self dispatchBackgroundAndWait:^{
        if (self.queue.count)
            [self.queue writeToURL:self.queueURL atomically:YES];
    }];
}

#pragma mark - Class Methods

+ (void)load {
    [SEGAnalytics registerIntegration:self withIdentifier:@"Expa"];
}

#pragma mark - Private

- (NSMutableArray *)queue {
    if (!_queue) {
        _queue = [NSMutableArray arrayWithContentsOfURL:self.queueURL] ?: [[NSMutableArray alloc] init];
    }
    return _queue;
}

- (NSMutableDictionary *)traits {
    if (!_traits) {
        _traits = [NSMutableDictionary dictionaryWithContentsOfURL:self.traitsURL] ?: [[NSMutableDictionary alloc] init];
    }
    return _traits;
}

- (NSUInteger)maxBatchSize {
    return 100;
}

- (NSURL *)userIDURL {
    return SEGAnalyticsURLForFilename(@"expa.userID");
}

- (NSURL *)queueURL {
    return SEGAnalyticsURLForFilename(@"expa.queue.plist");
}

- (NSURL *)traitsURL {
    return SEGAnalyticsURLForFilename(@"expa.traits.plist");
}

- (void)setConfiguration:(SEGAnalyticsConfiguration *)configuration {
    if (self.configuration) {
        [self.configuration removeObserver:self forKeyPath:@"shouldUseLocationServices"];
    }
    
    [super setConfiguration:configuration];
    [self.configuration addObserver:self forKeyPath:@"shouldUseLocationServices" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:NULL];
}

#pragma mark - Key value observing

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"shouldUseLocationServices"]) {
        self.location = [object shouldUseLocationServices] ? [SEGLocation new] : nil;
    } else if ([keyPath isEqualToString:@"flushAt"]) {
        [self flushQueueByLength];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end

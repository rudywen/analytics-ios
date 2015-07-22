//
//  ExpaProvider.h
//  Analytics
//
//  Created by Justin Ho on 3/19/14.
//  Copyright (c) 2014 Expa. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SEGAnalyticsIntegration.h"

extern NSString *const kExpaAnalyticsDidSendRequestNotification;
extern NSString *const kExpaAnalyticsRequestDidSucceedNotification;
extern NSString *const kExpaAnalyticsRequestDidFailNotification;

@interface SEGExpaIntegration : SEGAnalyticsIntegration

@property (nonatomic, copy) NSString *anonymousId;
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, strong) NSURL *apiURL;

- (void)flush;

@end

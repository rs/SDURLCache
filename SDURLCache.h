//
//  SDURLCache.h
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SDURLCache : NSURLCache
{
    @private
    NSString *diskCachePath;
    NSMutableDictionary *diskCacheInfo;
    BOOL diskCacheInfoDirty;
    NSUInteger diskCacheUsage;
    NSTimeInterval minCacheInterval;
    NSOperationQueue *ioQueue;
    NSTimer *periodicMaintenanceTimer;
    NSOperation *periodicMaintenanceOperation;
}

/*
 * Defines the minimum number of seconds between now and the expiration time of a cacheable response
 * in order for the response to be cached on disk. This prevent from spending time and storage capacity
 * for an entry which will certainly expire before behing read back from disk cache (memory cache is
 * best suited for short term cache). The default value is set to 5 minutes (300 seconds).
 */
@property (nonatomic, assign) NSTimeInterval minCacheInterval;

/*
 * Returns a default cache director path to be used at cache initialization. The generated path directory
 * will be located in the application's cache directory and thus won't be synced by iTunes.
 */
+ (NSString *)defaultCachePath;

@end

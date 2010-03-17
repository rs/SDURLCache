//
//  SDURLCache.m
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCache.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

static NSTimeInterval const kSDURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute
static NSString *const kSDURLCacheInfoFileName = @"cacheInfo.plist";
static NSString *const kSDURLCacheInfoDiskUsageKey = @"diskUsage";
static NSString *const kSDURLCacheInfoExpiresKey = @"expires";
static NSString *const kSDURLCacheInfoAccessesKey = @"accesses";
static NSString *const kSDURLCacheInfoSizesKey = @"sizes";

@implementation NSCachedURLResponse(NSCoder)

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDataObject:self.data];
    [coder encodeObject:self.response forKey:@"response"];
    [coder encodeObject:self.userInfo forKey:@"userInfo"];
    [coder encodeInt:self.storagePolicy forKey:@"storagePolicy"];
}

- (id)initWithCoder:(NSCoder *)coder
{
    return [self initWithResponse:[coder decodeObjectForKey:@"response"]
                             data:[coder decodeDataObject]
                         userInfo:[coder decodeObjectForKey:@"userInfo"]
                    storagePolicy:[coder decodeIntForKey:@"storagePolicy"]];
}

@end


@interface SDURLCache ()
@property (nonatomic, retain) NSString *diskCachePath;
@property (nonatomic, retain) NSDictionary *diskCacheInfo;
@property (nonatomic, retain) NSOperationQueue *cacheInQueue;
@end

@implementation SDURLCache

@synthesize diskCachePath, diskCacheInfo, minCacheInterval, cacheInQueue;

#pragma mark SDURLCache (private)

+ (NSString *)cacheKeyForURL:(NSURL *)url
{
    const char *str = [url.absoluteString UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, strlen(str), r);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
}

/*
 * This method tries to determine the expiration date based on a response headers dictionary.
 */
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers
{
    // Check Pragma: no-cache
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"])
    {
        // Uncacheable response
        return nil;
    }
        
    // Look at info from the Cache-Control: max-age=n header
    NSString *cacheControl = [headers objectForKey:@"Cache-Control"];
    if (cacheControl)
    {
        NSRange foundRange = [cacheControl rangeOfString:@"no-cache"];
        if (foundRange.length > 0)
        {
            // Can't be cached
            return nil;
        }

        NSInteger maxAge;
        foundRange = [cacheControl rangeOfString:@"max-age="];
        if (foundRange.length > 0)
        {
            NSScanner *cacheControlScanner = [NSScanner scannerWithString:cacheControl];
            [cacheControlScanner setScanLocation:foundRange.location + foundRange.length];
            if ([cacheControlScanner scanInteger:&maxAge])
            {
                if (maxAge > 0)
                {
                    return [NSDate dateWithTimeIntervalSinceNow:maxAge];
                }
                else
                {
                    return nil;
                }

            }
        }
    }
    
    // If not Cache-Control found, look at the Expires header
    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires)
    {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"EEE, MMM d, yyyy, h:mm a"];
        NSDate *expirationDate = [dateFormatter dateFromString:expires];
        [dateFormatter release];
        if ([expirationDate timeIntervalSinceNow] < 0)
        {
            return nil;
        }
        else
        {
            return expirationDate;
        }
    }

    return nil;
}

- (void)saveCacheInfo
{
    [diskCacheInfo writeToFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName] atomically:YES];
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSEnumerator *enumerator = [cacheKeys objectEnumerator];
    NSString *cacheKey;

    NSMutableDictionary *expirations = [diskCacheInfo objectForKey:kSDURLCacheInfoExpiresKey];
    NSMutableDictionary *accesses = [diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
    NSMutableDictionary *sizes = [diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];

    while (cacheKey = [enumerator nextObject])
    {
        NSMutableDictionary *cacheInfo = [diskCacheInfo objectForKey:cacheKey];
        
        if (cacheInfo)
        {
            NSNumber *cacheItemSize = [(NSMutableDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] objectForKey:cacheKey];
            [expirations removeObjectForKey:cacheKey];
            [accesses removeObjectForKey:cacheKey];
            [sizes removeObjectForKey:cacheKey];
            [[NSFileManager defaultManager] removeItemAtPath:[diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];
            diskCacheUsage -= [cacheItemSize unsignedIntegerValue];
            [diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];
        }        
    }

    [pool drain];
}

- (void)balanceDiskUsage
{
    // Clean all expired keys
    NSDictionary *expirations = [diskCacheInfo objectForKey:kSDURLCacheInfoExpiresKey];
    NSMutableArray *keysToRemove = [NSMutableArray array];

    NSArray *sortedKeys = [expirations keysSortedByValueUsingSelector:@selector(compare:)];
    NSEnumerator *enumerator = [sortedKeys objectEnumerator];
    NSString *cacheKey;    
    while ((cacheKey = [enumerator nextObject]) && [(NSDate *)[expirations objectForKey:cacheKey] timeIntervalSinceNow] < 0)
    {
        [keysToRemove addObject:cacheKey];
    }

    if ([keysToRemove count] > 0)
    {
        [self removeCachedResponseForCachedKeys:keysToRemove];

        if (diskCacheUsage < self.diskCapacity)
        {
            [self saveCacheInfo];
            return;
        }
    }
    else if(diskCacheUsage < self.diskCapacity)
    {
        return;
    }

    // Clean least recently used keys until disk usage outreach capacity
    NSDictionary *sizes = [diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];
    keysToRemove = [NSMutableArray array];

    NSInteger capacityToSave = diskCacheUsage - self.diskCapacity;
    sortedKeys = [(NSDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
    enumerator = [sortedKeys objectEnumerator];
    while (capacityToSave > 0 && (cacheKey = [enumerator nextObject]))
    {
        [keysToRemove addObject:cacheKey];
        capacityToSave -= [(NSNumber *)[sizes objectForKey:cacheKey] unsignedIntegerValue];
    }

    [self removeCachedResponseForCachedKeys:keysToRemove];
    [self saveCacheInfo];
}


- (void)storeToDisk:(NSDictionary *)context
{
    NSURLRequest *request = [context objectForKey:@"request"];
    NSCachedURLResponse *cachedResponse = [context objectForKey:@"cachedResponse"];
    NSDate *expirationDate = [context objectForKey:@"expirationDate"];
    
    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSString *cacheFilePath = [diskCachePath stringByAppendingPathComponent:cacheKey];
    
    // Archive the cached response on disk
    if (![NSKeyedArchiver archiveRootObject:cachedResponse toFile:cacheFilePath])
    {
        // Caching failed for some reason
        return;
    }
    
    // Update disk usage info
    NSNumber *cacheItemSize = [[[NSFileManager defaultManager] fileAttributesAtPath:cacheFilePath traverseLink:NO] objectForKey:NSFileSize];
    diskCacheUsage += [cacheItemSize unsignedIntegerValue];
    [diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];        
    
    
    // Update cache info for the stored item
    [(NSMutableDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoExpiresKey] setObject:expirationDate forKey:cacheKey];
    [(NSMutableDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
    [(NSMutableDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];
    
    if (diskCacheUsage > self.diskCapacity)
    {
        [self balanceDiskUsage];
    }
    else
    {
        [self saveCacheInfo];
    }
}

#pragma mark SDURLCache (notification handlers)

- (void)applicationWillTerminate
{
}

#pragma mark SDURLCache

+ (NSString *)defaultCachePath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"SDURLCache"];
}

#pragma mark NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path
{
    if ((self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path]))
    {
        self.minCacheInterval = kSDURLCacheInfoDefaultMinCacheInterval;
        self.diskCachePath = path;

        if (![[NSFileManager defaultManager] fileExistsAtPath:diskCachePath])
        {
            [[NSFileManager defaultManager] createDirectoryAtPath:diskCachePath attributes:nil];
        }

        self.diskCacheInfo = [NSMutableDictionary dictionaryWithContentsOfFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName]];
        if (!self.diskCacheInfo)
        {
            self.diskCacheInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                  [NSNumber numberWithUnsignedInt:0], kSDURLCacheInfoDiskUsageKey,
                                  [NSMutableDictionary dictionary], kSDURLCacheInfoExpiresKey,
                                  [NSMutableDictionary dictionary], kSDURLCacheInfoAccessesKey,
                                  [NSMutableDictionary dictionary], kSDURLCacheInfoSizesKey,
                                  nil];
        }

        // Init the operation queue
        self.cacheInQueue = [[[NSOperationQueue alloc] init] autorelease];
        cacheInQueue.maxConcurrentOperationCount = 1; // used to streamline operations in a separate thread        

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminate)
                                                     name:UIApplicationWillTerminateNotification  
                                                   object:nil];        
    }

    return self;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    [super storeCachedResponse:cachedResponse forRequest:request];

    if (cachedResponse.storagePolicy == NSURLCacheStorageAllowed
        && [cachedResponse.response isKindOfClass:[NSHTTPURLResponse self]]
        && cachedResponse.data.length < self.diskCapacity)
    {
        NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:[(NSHTTPURLResponse *)cachedResponse.response allHeaderFields]];
        if (!expirationDate || [expirationDate timeIntervalSinceNow] - minCacheInterval <= 0)
        {
            // This response is not cacheable, headers said
            return;
        }

        [cacheInQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self 
                                                                         selector:@selector(storeToDisk:)
                                                                           object:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                                   cachedResponse, @"cachedResponse",
                                                                                   request, @"request",
                                                                                   expirationDate, @"expirationDate",
                                                                                   nil]] autorelease]];
    }
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSDate *expirationDate = [(NSDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoExpiresKey] objectForKey:cacheKey];

    if (expirationDate && [expirationDate timeIntervalSinceNow] < 0)
    {
        [self removeCachedResponseForRequest:request];
        return [super cachedResponseForRequest:request];
    }

    NSCachedURLResponse *memoryResponse = [super cachedResponseForRequest:request];
    if (memoryResponse)
    {
        return memoryResponse;
    }

    NSCachedURLResponse *cachedResponse = [NSKeyedUnarchiver unarchiveObjectWithFile:[diskCachePath stringByAppendingPathComponent:cacheKey]];
    if (cachedResponse)
    {
        [(NSMutableDictionary *)[diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
        // Store the response to memory cache for potential future requests
        [super storeCachedResponse:cachedResponse forRequest:request];
        return cachedResponse;
    }

    return nil;
}

- (void)setDiskCapacity:(NSUInteger)diskCapacity
{
	[super setDiskCapacity:diskCapacity];

	if (diskCacheUsage > diskCapacity)
    {
        [cacheInQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self 
                                                                         selector:@selector(balanceDiskUsage)
                                                                           object:nil] autorelease]];
    }
}

- (NSUInteger)currentDiskUsage
{
    return diskCacheUsage;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    [super removeCachedResponseForRequest:request];
    [self removeCachedResponseForCachedKeys:[NSArray arrayWithObject:[SDURLCache cacheKeyForURL:request.URL]]];
    [self saveCacheInfo];
}

- (void)removeAllCachedResponses
{
    [super removeAllCachedResponses];
}

#pragma mark NSObject

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [diskCachePath release];
    [diskCacheInfo release];
    [cacheInQueue release];
    [super dealloc];
}


@end

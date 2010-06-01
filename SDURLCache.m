//
//  SDURLCache.m
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCache.h"
#import <CommonCrypto/CommonDigest.h>

static NSTimeInterval const kSDURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute
static NSString *const kSDURLCacheInfoFileName = @"cacheInfo.plist";
static NSString *const kSDURLCacheInfoDiskUsageKey = @"diskUsage";
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
@property (nonatomic, readonly) NSMutableDictionary *diskCacheInfo;
@property (nonatomic, retain) NSOperationQueue *ioQueue;
@property (retain) NSOperation *periodicMaintenanceOperation;
- (void)periodicMaintenance;
@end

@implementation SDURLCache

@synthesize diskCachePath, minCacheInterval, ioQueue, periodicMaintenanceOperation;
@dynamic diskCacheInfo;

#pragma mark SDURLCache (tools)

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

#pragma mark SDURLCache (private)

- (NSMutableDictionary *)diskCacheInfo
{
    if (!diskCacheInfo)
    {
        diskCacheInfo = [[NSMutableDictionary alloc] initWithContentsOfFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName]];
        if (!diskCacheInfo)
        {
            diskCacheInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                             [NSNumber numberWithUnsignedInt:0], kSDURLCacheInfoDiskUsageKey,
                             [NSMutableDictionary dictionary], kSDURLCacheInfoAccessesKey,
                             [NSMutableDictionary dictionary], kSDURLCacheInfoSizesKey,
                             nil];
        }
        diskCacheInfoDirty = NO;

        periodicMaintenanceTimer = [[NSTimer scheduledTimerWithTimeInterval:5
                                                                     target:self
                                                                   selector:@selector(periodicMaintenance)
                                                                   userInfo:nil
                                                                    repeats:YES] retain];
    }

    return diskCacheInfo;
}

- (void)createDiskCachePath
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:diskCachePath])
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:diskCachePath attributes:nil];
    }
}

- (void)saveCacheInfo
{
    [self createDiskCachePath];
    [self.diskCacheInfo writeToFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName] atomically:YES];
    diskCacheInfoDirty = NO;
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSEnumerator *enumerator = [cacheKeys objectEnumerator];
    NSString *cacheKey;

    NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
    NSMutableDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];

    while ((cacheKey = [enumerator nextObject]))
    {
        NSUInteger cacheItemSize = [[sizes objectForKey:cacheKey] unsignedIntegerValue];
        [accesses removeObjectForKey:cacheKey];
        [sizes removeObjectForKey:cacheKey];
        [[NSFileManager defaultManager] removeItemAtPath:[diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];
        diskCacheUsage -= cacheItemSize;
        [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];
    }

    [pool drain];
}

- (void)balanceDiskUsage
{
    if (diskCacheUsage < self.diskCapacity)
    {
        // Already done
        return;
    }

    // Apply LRU cache eviction algorithm while disk usage outreach capacity
    NSDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];
    NSMutableArray *keysToRemove = [NSMutableArray array];

    NSInteger capacityToSave = diskCacheUsage - self.diskCapacity;
    NSArray *sortedKeys = [(NSDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
    NSEnumerator *enumerator = [sortedKeys objectEnumerator];
    NSString *cacheKey;

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

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSString *cacheFilePath = [diskCachePath stringByAppendingPathComponent:cacheKey];

    [self createDiskCachePath];

    // Archive the cached response on disk
    if (![NSKeyedArchiver archiveRootObject:cachedResponse toFile:cacheFilePath])
    {
        // Caching failed for some reason
        return;
    }

    // Update disk usage info
    NSNumber *cacheItemSize = [[[NSFileManager defaultManager] fileAttributesAtPath:cacheFilePath traverseLink:NO] objectForKey:NSFileSize];
    diskCacheUsage += [cacheItemSize unsignedIntegerValue];
    [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];


    // Update cache info for the stored item
    [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
    [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];

    [self saveCacheInfo];
}

- (void)periodicMaintenance
{
    // If another same maintenance operation is already sceduled, cancel it so this new operation will be executed after other
    // operations of the queue, so we can group more work together
    [periodicMaintenanceOperation cancel];
    self.periodicMaintenanceOperation = nil;

    // If disk usage outrich capacity, run the cache eviction operation and if cacheInfo dictionnary is dirty, save it in an operation
    if (diskCacheUsage > self.diskCapacity)
    {
        self.periodicMaintenanceOperation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(balanceDiskUsage) object:nil] autorelease];
        [ioQueue addOperation:periodicMaintenanceOperation];
    }
    else if (diskCacheInfoDirty)
    {
        self.periodicMaintenanceOperation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(saveCacheInfo) object:nil] autorelease];
        [ioQueue addOperation:periodicMaintenanceOperation];
    }
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

        // Init the operation queue
        self.ioQueue = [[[NSOperationQueue alloc] init] autorelease];
        ioQueue.maxConcurrentOperationCount = 1; // used to streamline operations in a separate thread
    }

    return self;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    if (request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringCacheData)
    {
        // When cache is ignored for read, it's a good idea not to store the result as well as this option
        // have big chance to be used every times in the future for the same request.
        // NOTE: This is a change regarding default URLCache behavior
        return;
    }

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

        [ioQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self
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
    NSCachedURLResponse *memoryResponse = [super cachedResponseForRequest:request];
    if (memoryResponse)
    {
        return memoryResponse;
    }

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];

    // NOTE: We don't handle expiration here as even staled cache data is necessary for NSURLConnection to handle cache revalidation.
    //       Staled cache data is also needed for cachePolicies which force the use of the cache.
    NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
    if ([accesses objectForKey:cacheKey]) // OPTI: Check for cache-hit in a in-memory dictionnary before to hit the FS
    {
        NSCachedURLResponse *diskResponse = [NSKeyedUnarchiver unarchiveObjectWithFile:[diskCachePath stringByAppendingPathComponent:cacheKey]];
        if (diskResponse)
        {
            // OPTI: Log the entry last access time for LRU cache eviction algorithm but don't save the dictionary
            //       on disk now in order to save IO and time
            [accesses setObject:[NSDate date] forKey:cacheKey];
            diskCacheInfoDirty = YES;

            // OPTI: Store the response to memory cache for potential future requests
            [super storeCachedResponse:diskResponse forRequest:request];
            return diskResponse;
        }
    }

    return nil;
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
    [periodicMaintenanceTimer invalidate];
    [periodicMaintenanceTimer release], periodicMaintenanceTimer = nil;
    [periodicMaintenanceOperation release], periodicMaintenanceOperation = nil;
    [diskCachePath release], diskCachePath = nil;
    [diskCacheInfo release], diskCacheInfo = nil;
    [ioQueue release], ioQueue = nil;
    [super dealloc];
}


@end

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
static float const kSDURLCacheLastModFraction = 0.1f; // 10% since Last-Modified suggested by RFC2616 section 13.2.4
static float const kSDURLCacheDefault = 3600; // Default cache expiration delay if none defined (1 hour)

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
 * Parse HTTP Date: http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.3.1
 */
+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate
{
    NSDate *date = nil;

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"] autorelease]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];

    // RFC 1123 date format - Sun, 06 Nov 1994 08:49:37 GMT
    [dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss z"];
    date = [dateFormatter dateFromString:httpDate];
    if (!date)
    {
        // ANSI C date format - Sun Nov  6 08:49:37 1994
        [dateFormatter setDateFormat:@"EEE MMM d HH:mm:ss yyyy"];
        date = [dateFormatter dateFromString:httpDate];
        if (!date)
        {
            // RFC 850 date format - Sunday, 06-Nov-94 08:49:37 GMT
            [dateFormatter setDateFormat:@"EEEE, dd-MMM-yy HH:mm:ss z"];
            date = [dateFormatter dateFromString:httpDate];
        }
    }

    [dateFormatter release];

    return date;
}

/*
 * This method tries to determine the expiration date based on a response headers dictionary.
 */
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status
{
    if (status != 200 && status != 203 && status != 300 && status != 301 && status != 302 && status != 307 && status != 410)
    {
        // Uncacheable response status code
        return nil;
    }

    // Check Pragma: no-cache
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"])
    {
        // Uncacheable response
        return nil;
    }

    // Define "now" based on the request
    NSString *date = [headers objectForKey:@"Date"];
    NSDate *now;
    if (date)
    {
        now = [SDURLCache dateFromHttpDateString:date];
    }
    else
    {
        // If no Date: header, define now from local clock
        now = [NSDate date];
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
        NSTimeInterval expirationInterval = 0;
        NSDate *expirationDate = [SDURLCache dateFromHttpDateString:expires];
        if (expirationDate)
        {
            expirationInterval = [expirationDate timeIntervalSinceDate:now];
        }
        if (expirationInterval > 0)
        {
            // Convert remote expiration date to local expiration date
            return [NSDate dateWithTimeIntervalSinceNow:expirationInterval];
        }
        else
        {
            // If the Expires header can't be parsed or is expired, do not cache
            return nil;
        }
    }

    if (status == 302 || status == 307)
    {
        // If not explict cache control defined, do not cache those status
        return nil;
    }

    // If no cache control defined, try some heristic to determine an expiration date
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified)
    {
        NSTimeInterval age = 0;
        NSDate *lastModifiedDate = [SDURLCache dateFromHttpDateString:lastModified];
        if (lastModifiedDate)
        {
            // Define the age of the document by comparing the Date header with the Last-Modified header
            age = [now timeIntervalSinceDate:lastModifiedDate];
        }
        if (age > 0)
        {
            return [NSDate dateWithTimeIntervalSinceNow:(age * kSDURLCacheLastModFraction)];
        }
        else
        {
            return nil;
        }
    }

    // If nothing permitted to define the cache expiration delay nor to restrict its cacheability, use a default cache expiration delay
    return [[[NSDate alloc] initWithTimeInterval:kSDURLCacheDefault sinceDate:now] autorelease];

}

#pragma mark SDURLCache (private)

- (NSMutableDictionary *)diskCacheInfo
{
    if (!diskCacheInfo)
    {
        @synchronized(self)
        {
            if (!diskCacheInfo) // Check again, maybe another thread created it while waiting for the mutex
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
        }
    }

    return diskCacheInfo;
}

- (void)createDiskCachePath
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (![fileManager fileExistsAtPath:diskCachePath])
    {
        [fileManager createDirectoryAtPath:diskCachePath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
    }
    [fileManager release];
}

- (void)saveCacheInfo
{
    [self createDiskCachePath];
    @synchronized(self.diskCacheInfo)
    {
        [self.diskCacheInfo writeToFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName] atomically:YES];
        diskCacheInfoDirty = NO;
    }
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSEnumerator *enumerator = [cacheKeys objectEnumerator];
    NSString *cacheKey;

    @synchronized(self.diskCacheInfo)
    {
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
        NSMutableDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];
        NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];

        while ((cacheKey = [enumerator nextObject]))
        {
            NSUInteger cacheItemSize = [[sizes objectForKey:cacheKey] unsignedIntegerValue];
            [accesses removeObjectForKey:cacheKey];
            [sizes removeObjectForKey:cacheKey];
            [fileManager removeItemAtPath:[diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];
            diskCacheUsage -= cacheItemSize;
            @synchronized(self.diskCacheInfo)
            {
                [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];
            }
        }
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

    NSMutableArray *keysToRemove = [NSMutableArray array];

    @synchronized(self.diskCacheInfo)
    {
        // Apply LRU cache eviction algorithm while disk usage outreach capacity
        NSDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];

        NSInteger capacityToSave = diskCacheUsage - self.diskCapacity;
        NSArray *sortedKeys = [[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
        NSEnumerator *enumerator = [sortedKeys objectEnumerator];
        NSString *cacheKey;

        while (capacityToSave > 0 && (cacheKey = [enumerator nextObject]))
        {
            [keysToRemove addObject:cacheKey];
            capacityToSave -= [(NSNumber *)[sizes objectForKey:cacheKey] unsignedIntegerValue];
        }
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
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSNumber *cacheItemSize = [[fileManager attributesOfItemAtPath:cacheFilePath error:NULL] objectForKey:NSFileSize];
    [fileManager release];
    diskCacheUsage += [cacheItemSize unsignedIntegerValue];
    @synchronized(self.diskCacheInfo)
    {
        [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];


        // Update cache info for the stored item
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];
    }

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
        NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:[(NSHTTPURLResponse *)cachedResponse.response allHeaderFields]
                                                        withStatusCode:((NSHTTPURLResponse *)cachedResponse.response).statusCode];
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
    @synchronized(self.diskCacheInfo)
    {
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

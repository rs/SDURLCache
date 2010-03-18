On iPhone OS, Apple did remove on-disk cache support for unknown reason. Some will say it's to save
flash-drive life, others will arg it's to save disk capacity. As it is explained in the
NSURLCacheStoragePolicy, the NSURLCacheStorageAllowed constant is always treated as
NSURLCacheStorageAllowedInMemoryOnly and there is no way to force it back, the code is certainly
gone on this platform. For whatever reason Apple removed this feature, you may be interested by
having on-disk HTTP request caching in your application. SDURLCache gives back this feature to this
iPhone OS for you.

To use it, you just have create an instance, replace the default shared NSURLCache with it and
that's it, you instantly give on-disk HTTP request caching capability to your application.

    SDURLCache *urlCache = [[SDURLCache alloc] initWithMemoryCapacity:1024*1024   // 1MB mem cache
                                                         diskCapacity:1024*1024*5 // 5MB disk cache
                                                             diskPath:[SDURLCache defaultCachePath]];
    [NSURLCache setSharedURLCache:urlCache];
    [urlCache release];

To save flash drive, SDURLCache doesn't cache on disk responses if cache expiration delay is lower
than 5 minutes by default. You can change this behavior by changing the `minCacheInterval` property.

Cache eviction is done automatically when disk capacity is outreached in a periodic maintenance
thread. All disk write operations are done in a separated thread so they can't block the main run
loop.

To control the caching behavior, use the `NSURLRequest`'s `cachePolicy` property. If you want a
response not to be cached on disk but still in memory, you can implement the `NSURLConnection`
`connection:willCacheResponse:` delegate method and change the `NSURLCachedResponse` `storagePolicy`
property to `NSURLCacheStorageAllowedInMemoryOnly`. See example below:

    - (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                      willCacheResponse:(NSCachedURLResponse *)cachedResponse
    {
        NSCachedURLResponse *memOnlyCachedResponse =
            [[NSCachedURLResponse alloc] initWithResponse:cachedResponse.response
                                                     data:cachedResponse.data
                                                 userInfo:cachedResponse.userInfo
                                            storagePolicy:NSURLCacheStorageAllowedInMemoryOnly];
        return [memOnlyCachedResponse autorelease];
    }

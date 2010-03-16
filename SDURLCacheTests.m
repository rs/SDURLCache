//
//  SDURLCacheTests.m
//  SDURLCache
//
//  Created by Olivier Poitrey on 16/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCacheTests.h"
#import "SDURLCache.h"

@interface SDURLCache ()
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers;
@end

@implementation SDURLCacheTests

- (void)testExpirationDateFromHeader
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"EEE, MMM d, yyyy, h:mm a"];
    NSString *pastDate = [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-1000]];
    NSString *futureDate = [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:1000]];
    
    NSDate *expDate;

    // Pragma: no-cache
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"no-cache", @"Pragma", futureDate, @"Expires", nil]];
    
    STAssertNil(expDate, @"Pragma no-cache");
    
    // Expires in the past
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:pastDate, @"Expires", nil]];

    STAssertNil(expDate, @"Expires in the past");

    // Cache-Control: no-cache with Expires in the future
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"no-cache", @"Cache-Control", futureDate, @"Expires", nil]];
    STAssertNil(expDate, @"Cache-Control no-cache with Expires in the future");

    // Cache-Control with future date
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"public, max-age=1000", @"Cache-Control", nil]];
    STAssertNotNil(expDate, @"Cache-Control with future date");
    STAssertTrue([expDate timeIntervalSinceNow] > 0, @"Cache-Control with future date");

    // Cache-Control with max-age=0 and Expires future date
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"public, max-age=0", @"Cache-Control",
                                                     futureDate, @"Expires", nil]];
    STAssertNil(expDate, @"Cache-Control with max-age=0 and Expires future date");

    // Cache-Control with future date and Expires past date
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"public, max-age=1000", @"Cache-Control", pastDate, @"Expires", nil]];
    STAssertNotNil(expDate, @"Cache-Control with future date and Expires past date");
    STAssertTrue([expDate timeIntervalSinceNow] > 0, @"Cache-Control with future date and Expires past date");
}

- (void)testCaching
{
    // TODO
}

- (void)testCacheCapacity
{
    // TODO
}

@end

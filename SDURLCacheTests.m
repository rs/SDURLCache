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
+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate;
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers;
@end

@implementation SDURLCacheTests

- (void)testHttpDateParser
{
    NSDate *date;
    NSTimeInterval referenceTime = 784111777;

    // RFC 1123 date format
    date = [SDURLCache dateFromHttpDateString:@"Sun, 06 Nov 1994 08:49:37 GMT"];
    STAssertEquals([date timeIntervalSince1970], referenceTime, @"RFC 1123 date format");

    // ANSI C date format
    date = [SDURLCache dateFromHttpDateString:@"Sun Nov  6 08:49:37 1994"];
    STAssertEquals([date timeIntervalSince1970], referenceTime, @"ANSI C date format %f", [date timeIntervalSince1970]);

    // RFC 850 date format
    date = [SDURLCache dateFromHttpDateString:@"Sunday, 06-Nov-94 08:49:37 GMT"];
    STAssertEquals([date timeIntervalSince1970], referenceTime, @"RFC 850 date format");
}

- (void)testExpirationDateFromHeader
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss z"];
    NSDate *now = [NSDate date];
    NSString *pastDate = [dateFormatter stringFromDate:[NSDate dateWithTimeInterval:-1000 sinceDate:now]];
    NSString *nowDate = [dateFormatter stringFromDate:now];
    NSString *futureDate = [dateFormatter stringFromDate:[NSDate dateWithTimeInterval:1000 sinceDate:now]];

    NSDate *expDate;

    // No cache control
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:nowDate, @"Date", nil]];
    STAssertNotNil(expDate, @"No cache control returns a default expiration date");
    STAssertEqualsWithAccuracy([expDate timeIntervalSinceNow], (NSTimeInterval)3600, 1, @"Default expiration date is 1 hour");

    // No cache control but last-modified
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:pastDate, @"Last-Modified", nowDate, @"Date", nil]];
    STAssertNotNil(expDate, @"No cache control with last-modified header returns an expiration date");
    STAssertEqualsWithAccuracy([expDate timeIntervalSinceNow], (NSTimeInterval)100, 1, @"Expiration date relative to last-modified is 10%% of the age");

    // Pragma: no-cache
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:@"no-cache", @"Pragma", futureDate, @"Expires", nil]];
    STAssertNil(expDate, @"Pragma no-cache");

    // Expires in the past
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:pastDate, @"Expires", nil]];
    STAssertNil(expDate, @"Expires in the past");

    // Expires in the past
    expDate = [SDURLCache expirationDateFromHeaders:[NSDictionary dictionaryWithObjectsAndKeys:futureDate, @"Expires", nil]];
    STAssertTrue([expDate timeIntervalSinceNow] > 0, @"Expires in the future");

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

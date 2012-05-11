//
//  SDCachedURLResponse.h
//  SDURLCache
//
//  Created by Olivier Poitrey on 12/05/12.
//  Copyright (c) 2012 Dailymotion. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SDCachedURLResponse : NSObject <NSCoding, NSCopying>

@property (nonatomic, retain) NSCachedURLResponse *response;

+ (id)cachedURLResponseWithNSCachedURLResponse:(NSCachedURLResponse *)response;

@end

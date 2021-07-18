//
// --------------------------------------------------------------------------
// Actions.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import "Constants.h"

NS_ASSUME_NONNULL_BEGIN

@interface Actions : NSObject

+ (void)executeActionDict:(NSDictionary *)actionDict;
+ (void (^)(void))initModifyingActionWithDict:(NSDictionary *)actionDict
                 hasBeenUsedCallback:(void (^)(void))hasBeenUsedCallback;

@end

NS_ASSUME_NONNULL_END

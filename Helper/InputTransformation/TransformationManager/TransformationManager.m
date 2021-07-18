//
// --------------------------------------------------------------------------
// TransformationManager.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "TransformationManager.h"
#import "Utility_Transformation.h"
#import "SharedUtility.h"
#import "ButtonTriggerGenerator.h"
#import "Actions.h"
#import "ModifierManager.h"
#import "ModifiedDrag.h"
#import "NSArray+Additions.h"
#import "NSMutableDictionary+Additions.h"
#import "Constants.h"
#import "Config.h"
#import "SharedMessagePort.h"

@implementation TransformationManager

+ (void)load {
//    loadTestRemaps();
}

#pragma mark - Remaps dictionary and interface

NSDictionary *_remaps;

/// Always set remaps through this, so that the kMFNotifCenterNotificationNameRemapsChanged notification is posted
/// The notification is used by ModifierManager to update itself, whenever _remaps updates.
///  (Idk why we aren't just calling an update function instead of using a notification)
+ (void)setRemaps:(NSDictionary *)remapsDict {
    _remaps = remapsDict;
//    _remaps = self.testRemaps; // TESTING
    [NSNotificationCenter.defaultCenter postNotificationName:kMFNotifCenterNotificationNameRemapsChanged object:self];
    DDLogDebug(@"Set remaps to: %@", _remaps);
}

/// The main app uses an array of dicts (aka a table) to represent the remaps in a way that is easy to present in a table view.
/// The remaps are also stored to file in this format and therefore what ConfigFileInterface_App.config contains.
/// The helper was made to handle a dictionary format which should be more effictient among other perks.
/// This function takes the remaps in table format from config, then converts it to dict format and makes that available to all the other Input Transformation classes to base their behaviour off of through self.remaps.
+ (void)loadRemapsFromConfig {
    
    NSArray *remapsTable = [Config.config objectForKey:kMFConfigKeyRemaps];
    
    // Convert remaps table to remaps dict
    NSMutableDictionary *remapsDict = [NSMutableDictionary dictionary];
    for (NSDictionary *tableEntry in remapsTable) {
        // Get modification precondition section of keypath
        NSDictionary *modificationPrecondition = tableEntry[kMFRemapsKeyModificationPrecondition];
        // Get trigger section of keypath
        NSArray *triggerKeyArray;
        id trigger = tableEntry[kMFRemapsKeyTrigger];
        if ([trigger isKindOfClass:NSString.class]) {
            NSString *triggerStr = (NSString *)trigger;
            triggerKeyArray = @[triggerStr];
            NSAssert([triggerStr isEqualToString:kMFTriggerScroll] || [triggerStr isEqualToString:kMFTriggerDrag] , @"");
        } else if ([trigger isKindOfClass:NSDictionary.class]) {
            NSDictionary *triggerDict = (NSDictionary *)trigger;
            NSString *duration = triggerDict[kMFButtonTriggerKeyDuration];
            NSNumber *level = triggerDict[kMFButtonTriggerKeyClickLevel];
            NSNumber *buttonNum = triggerDict[kMFButtonTriggerKeyButtonNumber];
            triggerKeyArray = @[buttonNum, level, duration];
        } else NSAssert(NO, @"");
        // Get effect
        id effect = tableEntry[kMFRemapsKeyEffect]; // This is always dict
        if ([trigger isKindOfClass:NSDictionary.class]) {
            effect = @[effect];
            // ^ For some reason we built one shot effect handling code around _arrays_ of effects. So we need to wrap our effect in an array.
            //  This doesn't make sense. We should clean this up at some point and remove the array.
        }
        // Put it all together
        NSArray *keyArray = [@[modificationPrecondition] arrayByAddingObjectsFromArray:triggerKeyArray];
        [remapsDict setObject:effect forCoolKeyArray:keyArray];
    }
    
    [self setRemaps:remapsDict];
}
+ (NSDictionary *)remaps {
    return _remaps;
}

#pragma mark - AddMode

BOOL _addModeIsEnabled = NO;
+ (BOOL)addModeIsEnabled {
    return _addModeIsEnabled;
}

/// \discussion  Add mode configures the helper such that it remaps to "add mode feedback effects" instead of normal effects.
/// When "add mode feedback effects" are triggered, the helper will send information about how exactly the effect was triggered to the main app.
/// This allows us to capture triggers that the user performs and use them in the main app to add new rows to the remaps table view
/// The dataModel for the remaps table view is an array of dicts, where each dict is called a tableEntry.
/// Each table entry has 3 keys:
///     - kMFRemapsKeyTrigger
///     - kMFRemapsKeyModificationPrecondition
///     - kMFRemapsKeyEffect
/// Our feedback dicts we send to the main app during addMode use 3 - overlapping, but different - keys:
///     - kMFRemapsKeyTrigger
///     - kMFRemapsKeyModificationPrecondition
///     - kMFActionDictKeyType / kMFModifiedDragDictKeyType
/// kMFActionDictKeyType / kMFModifiedDragDictKeyType is added in this funciton and used so the helper knows how to process the dictionary, but it's removed before we send stuff off to the mainApp
/// kMFRemapsKeyTrigger is added in this function, and eventually sent off to the main app
/// kMFRemapsKeyModificationPrecondition has to be added right when the user actually triggers the actions
///     They are added in `executeClickOrHoldActionIfItExists` for the button actions, and in `reactToModifierChange` for the drag actions
/// So the final feedback dict we send to the main app contains values for the keys
///     - kMFRemapsKeyTrigger
///     - kMFRemapsKeyModificationPrecondition
/// So it's _almost_ a tableEntry which can be used by the mainApp's remap tableview's dataModel, it's just lacking the kMFRemapsKeyEffect key and values.
/// This makes sense, because The effect is then to be chosen by the user in the main app's GUI
///
/// It doesn't make sense to capture drag triggers (and scroll triggers, but that's not yet implemented at this point) when no modifier is present,
///     But if any modifier is present, we want to capture them, no matter what the modifier is specifically. We implemented this by using the new kMFAddModeModificationPrecondition key
///         and by making some changes to `ModifierManager` -> `reactToModifierChange()` to work with this new key.
///             I have a relatively strong suspicion, that we need to change around other stuff to really make this work, but I have no clue what exactly that could be.
///             With this complex intertwining code and everything depending on nested dictionaries with no compiler checks or anything so many things could break due to sth like this.
///             Let's just hope for the best!
///                 I just found sth that's broken! Capturing drags with only kb modifiers active doesn't work. I assume that's because the `ModifierManager` -> `toggleModifierEventTapBasedOnRemaps` broke somehow.
///                 Other places that I think probably don't work with this:
///                 - ButtonLandscapeAssessment code in ButtonTriggerHandler. Checking if button is used as modifier at a higher clicklevel and stuff is surelyyy broken. But that might not matter.
///                 -  `ModifierManager` -> `toggleModifierEventTapBasedOnRemaps` along with other functions from `ModifierManager` are probably broken, too.
+ (void)enableAddMode {
    _addModeIsEnabled = YES;
    NSMutableDictionary *triggerToEffectDict_DemandsMods = [NSMutableDictionary dictionary];
    // Fill out triggerToEffectDictWithNeedForModifier with all triggers that users can map to
    // String based triggers (Only one - drag - atm)
    triggerToEffectDict_DemandsMods[kMFTriggerDrag] = @{
        kMFModifiedDragDictKeyType: kMFModifiedDragTypeAddModeFeedback,
        kMFRemapsKeyTrigger: kMFTriggerDrag,
    };
    NSMutableDictionary *triggerToEffectDict_NoModsRequired = [NSMutableDictionary dictionary];
    // Button triggers (dict based)
    for (int btn = 1; btn <= kMFMaxButtonNumber; btn++) {
        for (int lvl = 1; lvl <= 3; lvl++) {
            for (NSString *dur in @[kMFButtonTriggerDurationClick, kMFButtonTriggerDurationHold]) {
                NSMutableDictionary *addModeFeedbackDict = @{
                    kMFActionDictKeyType: kMFActionDictTypeAddModeFeedback,
                    kMFRemapsKeyTrigger: @{
                        kMFButtonTriggerKeyButtonNumber: @(btn),
                        kMFButtonTriggerKeyClickLevel: @(lvl),
                        kMFButtonTriggerKeyDuration: dur,
                    }
                }.mutableCopy; // The key `kMFRemapsKeyModificationPrecondition` and corresponding values are added to `addModeFeedbackDict` in the function `executeClickOrHoldActionIfItExists`. That's also why we need to make this mutable.
                [triggerToEffectDict_NoModsRequired setObject:@[addModeFeedbackDict] forCoolKeyArray:@[@(btn),@(lvl),dur]];
                //  ^ We're wrapping `addModeFeedbackDict` in an array here because we started building helper with dicts of several effects in mind.
                //      This doesn't make sense though and we should remove it.
            }
        }
    }
    
    // Set _remaps to generated
    self.remaps = @{
        @{}: triggerToEffectDict_NoModsRequired,
        @{kMFAddModeModificationPrecondition:@YES}: triggerToEffectDict_DemandsMods,
    };
}
+ (void)disableAddMode {
    _addModeIsEnabled = NO;
    [self loadRemapsFromConfig];
}
+ (void)concludeAddModeWithPayload:(NSDictionary *)payload {
    [SharedMessagePort sendMessage:@"addModeFeedback" withPayload:payload expectingReply:NO];
//    [TransformationManager performSelector:@selector(disableAddMode) withObject:nil afterDelay:0.5];
    // ^ We did this to keep the remapping disabled for a little while after adding a new row, but it leads to adding several entries at once when trying to input button modification precondition, if you're not fast enough.
    [TransformationManager disableAddMode];
}

/// Using this to prevent payloads containing a modified drag with a keyboard-modifier-only precondition, or an empty precondition from being sent to the main app
/// Empty preconditions only happen when weird bugs occur so this is just an extra safety net for that
/// Keyboard-modifier-only modified drags work in principle but they cause some smaller bugs and issues in the mainApp UI. We don't wan't to polish that up so we're just disabling the ability to add them.
+ (BOOL)addModePayloadIsValid:(NSDictionary *)payload {
    if ([payload[kMFRemapsKeyTrigger] isEqual:kMFTriggerDrag]) {
        NSArray *buttonPreconds = payload[kMFRemapsKeyModificationPrecondition][kMFModificationPreconditionKeyButtons];
        if (buttonPreconds == nil || buttonPreconds.count == 0) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - keyCaptureMode

CFMachPortRef _keyCaptureEventTap;

+ (void)enableKeyCaptureMode {
    
    DDLogInfo(@"Enabling keyCaptureMode");
    
    if (_keyCaptureEventTap == nil) {
        _keyCaptureEventTap = [Utility_Transformation createEventTapWithLocation:kCGHIDEventTap mask:CGEventMaskBit(kCGEventKeyDown) option:kCGEventTapOptionDefault placement:kCGHeadInsertEventTap callback:keyCaptureModeCallback];
    }
    CGEventTapEnable(_keyCaptureEventTap, true);
}

+ (void)disableKeyCaptureMode {
    CGEventTapEnable(_keyCaptureEventTap, false);
}

CGEventRef  _Nullable keyCaptureModeCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags  = CGEventGetFlags(event);
    
    if (!keyCaptureModePayloadIsValidWithKeyCode(keyCode, flags)) return nil;
    
    NSDictionary *payload = @{
        @"keyCode": @(keyCode),
        @"flags": @(flags),
    };
    
    [SharedMessagePort sendMessage:@"keyCaptureModeFeedback" withPayload:payload expectingReply:NO];
    
    [TransformationManager disableKeyCaptureMode];
    return nil;
}
Boolean keyCaptureModePayloadIsValidWithKeyCode(CGKeyCode keyCode, CGEventFlags flags) {
    
    if (keyCode == 0) {
        return false;
    }
    return true;
}

#pragma mark - Dummy Data

+ (NSDictionary *)testRemaps {
    /// This fanned out dictionary representation of our remappings is what we based our helper code on.
    /// It's not super human readable, but it should be very fast, and makes some of the operations like overrides and on the fly 'assessment of the mapping landscape' pretty handy.
    /// Using this in Helper is definitely faster than the tableView oriented (-> array based) structure which the MainApp uses. That's because we can do a lot of O(1) dict accesses where we'd have to use O(n) array searches using the other structure. I suspect that performance gains are negligible though.
    /// Having these 2 data structures might very well not be worth the cost of having to think about both and write a conversion function between them. But we've already built helper around this, and mainApp needs the table based structure, so we're sticking with this double-structure approach.
    
    
    
    
    
    
    
    
    /// Post modifyingActions refactor
    
    
    return @{
        @{}:    /// Default remappings (empty -> applies with no modifiers active)
        @{
            @(3): @{                                                /// Button
                    @(1): @{                                            /// Level
                            kMFButtonTriggerDurationClick: @[@{
                                kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                                kMFActionDictKeyGenericVariant: @(kMFSHSpotlight),
                            }],
                            kMFButtonTriggerDurationModifiedDrag: @[@{
                                kMFModifiedDragDictKeyType: kMFModifiedDragTypeFakeDrag,
                                kMFModifiedDragDictKeyFakeDragVariantButtonNumber: @3,
                            }],
                            kMFButtonTriggerDurationModifiedScroll: @[@{
                                kMFModifiedScrollDictKeyType: kMFModifiedScrollTypeZoom,
                            }],
                    },
                    @(2): @{                                            // Key: level
                            kMFButtonTriggerDurationClick: @[
                                    @{
                                        kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                                        kMFActionDictKeyGenericVariant: @(kMFSHSiri),
                                    }
                            ],
                    },
            },
        }
    };
    
    
    
    
    
    
    
    /// Pre- modifyingActions refactor
    
    
    return @{
        @{}: @{                                                     // Key: modifier dict (empty -> no modifiers)
//                @(3): @{                                                // Key: button
//                        @(1): @{                                            // Key: level
//                                kMFButtonTriggerDurationClick: @[                                   // Key: click/hold, value: array of actions
//                                        @{
//                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
//                                            kMFActionDictKeyGenericVariant:@(kMFSHMissionControl)
//                                        },
//                                ],
//                                kMFButtonTriggerDurationHold: @[                                  // Key: click/hold, value: array of actions
//                                        @{
//                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
//                                            kMFActionDictKeyGenericVariant: @(kMFSHShowDesktop),
//                                        },
//                                ],
//
//                        },
////                        @(2): @{                                            // Key: level
////                                kMFButtonTriggerDurationClick: @[                                   // Key: click/hold, value: array of actions
////                                        @{
////                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
////                                            kMFActionDictKeyGenericVariant:@(kMFSHLookUp)
////                                        },
////                                ],
////                        }
//                },
//                @(4): @{                                                // Key: button
//                        @(1): @{                                            // Key: level
//                                kMFButtonTriggerDurationClick: @[
//                                        @{
//                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
//                                            kMFActionDictKeyGenericVariant: @(32),
//                                        }
//                                ],
//                                kMFButtonTriggerDurationHold: @[
//                                        @{
//                                            kMFActionDictKeyType: kMFActionDictTypeSmartZoom,
//                                        }
//                                ],
//                        },
////                        @(2): @{                                            // Key: level
////                                kMFButtonTriggerDurationClick: @[
////                                        @{
////                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
////                                            kMFActionDictKeyGenericVariant: @(36),
////                                        }
////                                ],
////                        },
//                },
                @(7)  : @{                                                // Key: button
                        @(1): @{                                            // Key: level
                                kMFButtonTriggerDurationClick: @[                                  // Key: click/hold, value: array of actions
                                        @{
                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                                            kMFActionDictKeyGenericVariant: @(kMFSHLaunchpad),
                                        },
                                ],
                        },
                },
                
        },
        
//        @{                                                          // Key: modifier dict
//            kMFModificationPreconditionKeyButtons: @[
//                    @{
//                        kMFButtonModificationPreconditionKeyButtonNumber: @(3),
//                        kMFButtonModificationPreconditionKeyClickLevel: @(2),
//                    }
//            ],
//        }: @{
//                kMFTriggerDrag: @{
//                        kMFModifiedDragDictKeyType: kMFModifiedDragTypeFakeDrag,
//                        kMFModifiedDragDictKeyFakeDragVariantButtonNumber: @3,
//                }
//        },
        
        @{
            kMFModificationPreconditionKeyButtons: @[
                    @{
                        kMFButtonModificationPreconditionKeyButtonNumber: @(4),
                        kMFButtonModificationPreconditionKeyClickLevel: @(1),
                    },
            ],
            
        }: @{
                kMFTriggerDrag: @{
                        kMFModifiedDragDictKeyType: kMFModifiedDragTypeThreeFingerSwipe,
                },
                @(3): @{                                                // Key: button
                        @(1): @{                                            // Key: level
                                kMFButtonTriggerDurationClick: @[
                                        @{
                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                                            kMFActionDictKeyGenericVariant: @(kMFSHSpotlight),
                                        }
                                ],
                        },
                        @(2): @{                                            // Key: level
                                kMFButtonTriggerDurationClick: @[
                                        @{
                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                                            kMFActionDictKeyGenericVariant: @(kMFSHSiri),
                                        }
                                ],
                        },
                },
        },
        @{
            //            kMFModificationPreconditionKeyButtons: @[
            //                    @{
            //                        kMFButtonModificationPreconditionKeyButtonNumber: @(4),
            //                        kMFButtonModificationPreconditionKeyClickLevel: @(2),
            //                    },
            //                    @{
            //                        kMFButtonModificationPreconditionKeyButtonNumber: @(3),
            //                        kMFButtonModificationPreconditionKeyClickLevel: @(1),
            //                    },
            //            ],
            kMFModificationPreconditionKeyKeyboard: @(NSShiftKeyMask | NSControlKeyMask)
        }: @{
                kMFTriggerDrag: @{
                        kMFModifiedDragDictKeyType: kMFModifiedDragTypeThreeFingerSwipe,
                }
        }
    };
}


@end

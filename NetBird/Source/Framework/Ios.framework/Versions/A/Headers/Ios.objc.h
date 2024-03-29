// Objective-C API for talking to github.com/netbirdio/netbird/client/ios Go package.
//   gobind -lang=objc github.com/netbirdio/netbird/client/ios
//
// File is generated by gobind. Do not edit.

#ifndef __Ios_H__
#define __Ios_H__

@import Foundation;
#include "ref.h"
#include "Universe.objc.h"


@class IosClient;

/**
 * Client struct manage the life circle of background service
 */
@interface IosClient : NSObject <goSeqRefInterface> {
}
@property(strong, readonly) _Nonnull id _ref;

- (nonnull instancetype)initWithRef:(_Nonnull id)ref;
/**
 * NewClient instantiate a new Client
 */
- (nullable instancetype)init:(NSString* _Nullable)cfgFile deviceName:(NSString* _Nullable)deviceName;
/**
 * Run start the internal client. It is a blocker function
 */
- (BOOL)run:(NSError* _Nullable* _Nullable)error;
/**
 * Stop the internal client and free the resources
 */
- (void)stop;
@end

/**
 * NewClient instantiate a new Client
 */
FOUNDATION_EXPORT IosClient* _Nullable IosNewClient(NSString* _Nullable cfgFile, NSString* _Nullable deviceName);

#endif

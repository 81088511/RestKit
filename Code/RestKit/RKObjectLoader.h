//
//  RKObjectLoader.h
//  RestKit
//
//  Created by Blake Watters on 8/8/09.
//  Copyright 2009 Two Toasters. All rights reserved.
//

#import <CoreData/CoreData.h>
#import "RKRequest.h"
#import "RKResponse.h"
#import "RKObjectMapper.h"

@protocol RKObjectLoaderDelegate <RKRequestDelegate>

/**
 * Invoked when a request sent through the resource manager loads a collection of objects. The model will be nil if the request was
 * not dispatched through an object
 */
// TODO: Do I need to send back the object??? Can I put the response onto the request to shorten the selector?? Maybe the object too?
- (void)request:(RKRequest*)request didLoadObjects:(NSArray*)objects response:(RKResponse*)response object:(id<RKObjectMappable>)object;

/**
 * Invoked when a request sent through the resource manager encounters an error. The model will be nil if the request was
 * not dispatched through an object
 */
- (void)request:(RKRequest*)request didFailWithError:(NSError*)error response:(RKResponse*)response object:(id<RKObjectMappable>)object;

@end

@interface RKObjectLoader : NSObject <RKRequestDelegate> {
	RKObjectMapper* _mapper;
	NSObject<RKObjectLoaderDelegate>* _delegate;
	SEL _callback;
	NSFetchRequest* _fetchRequest;
}

/**
 * The resource mapper this loader is working with
 */
@property (nonatomic, readonly) RKObjectMapper* mapper;

/**
 * The object to be invoked with the loaded models
 *
 * If this object implements life-cycle methods from the RKRequestDelegate protocol, 
 * events from the request will be forwarded back.
 */
@property (nonatomic, retain) NSObject<RKObjectLoaderDelegate>* delegate;

/**
 * The method to invoke to trigger model mappings. Used as the callback for a restful model mapping request
 */
@property (nonatomic, readonly) SEL callback;

/**
 * Fetch request for loading cached objects. This is used to remove objects from the local persistent store
 * when model mapping operations are completed.
 *
 * TODO: May belong in an inherited subclass to isolate persistent/non-persistent mapping in the future.
 */
@property (nonatomic, retain) NSFetchRequest* fetchRequest;

+ (id)loaderWithMapper:(RKObjectMapper*)mapper;

/**
 * Initialize a new model loader with a model mapper
 */
- (id)initWithMapper:(RKObjectMapper*)mapper;

@end

//
//  RKObjectLoader.m
//  RestKit
//
//  Created by Blake Watters on 8/8/09.
//  Copyright 2009 Two Toasters. All rights reserved.
//

#import <CoreData/CoreData.h>
#import "RKObjectLoader.h"
#import "RKResponse.h"
#import "RKObjectManager.h"
#import "Errors.h"
#import "RKManagedObject.h"

@implementation RKObjectLoader

@synthesize mapper = _mapper, delegate = _delegate, callback = _callback, fetchRequest = _fetchRequest;

+ (id)loaderWithMapper:(RKObjectMapper*)mapper {
	return [[[self alloc] initWithMapper:mapper] autorelease];
}

- (id)initWithMapper:(RKObjectMapper*)mapper {
	if (self = [self init]) {
		_mapper = [mapper retain];
	}
	
	return self;
}

- (void)dealloc {
	[_mapper release];
	[super dealloc];
}

- (SEL)callback {
	return @selector(loadObjectsFromResponse:);
}

- (BOOL)encounteredErrorWhileProcessingRequest:(RKResponse*)response {
	RKRequest* request = response.request;
	if ([response isFailure]) {
		[_delegate request:response.request didFailWithError:response.failureError response:response object:(id<RKObjectMappable>)request.userData];
		return YES;
	} else if ([response isError]) {
		NSString* errorMessage = nil;
		if ([response isJSON]) {
			errorMessage = [[[response bodyAsJSON] valueForKey:@"errors"] componentsJoinedByString:@", "];
		}
		if (nil == errorMessage) {
			errorMessage = [response bodyAsString];
		}
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
								  errorMessage, NSLocalizedDescriptionKey,
								  nil];		
		NSError *error = [NSError errorWithDomain:RKRestKitErrorDomain code:RKModelLoaderRemoteSystemError userInfo:userInfo];
		
		[_delegate request:response.request didFailWithError:error response:response object:(id<RKObjectMappable>)request.userData];
		return YES;
	}
	
	return NO;
}

- (void)informDelegateOfModelLoadWithInfoDictionary:(NSDictionary*)dictionary {
	RKResponse* response = [dictionary objectForKey:@"response"];
	NSArray* models = [dictionary objectForKey:@"models"];
	[dictionary release];
	
	// NOTE: The models dictionary may contain NSManagedObjectID's from persistent objects
	// that were model mapped on a background thread. We look up the objects by ID and then
	// notify the delegate that the operation has completed.
	NSMutableArray* objects = [NSMutableArray arrayWithCapacity:[models count]];
	for (id object in models) {
		if ([object isKindOfClass:[NSManagedObjectID class]]) {
			[objects addObject:[RKManagedObject objectWithID:(NSManagedObjectID*)object]];
		} else {
			[objects addObject:object];
		}
	}
	
	RKRequest* request = response.request;
	[_delegate request:request didLoadObjects:[NSArray arrayWithArray:objects] response:response object:(id<RKObjectMappable>)request.userData];
	
	// Release the response now that we have finished all our processing
	[response release];
}

- (void)informDelegateOfModelLoadErrorWithInfoDictionary:(NSDictionary*)dictionary {
	RKResponse* response = [dictionary objectForKey:@"response"];
	NSError* error = [dictionary objectForKey:@"error"];
	[dictionary release];
	
	NSLog(@"[RestKit] RKModelLoader: Error saving managed object context: error=%@ userInfo=%@", error, error.userInfo);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
							  [error localizedDescription], NSLocalizedDescriptionKey,
							  nil];		
	NSError *rkError = [NSError errorWithDomain:RKRestKitErrorDomain code:RKModelLoaderRemoteSystemError userInfo:userInfo];
	
	RKRequest* request = response.request;
	[_delegate request:response.request didFailWithError:rkError response:response object:(id<RKObjectMappable>)request.userData];
	
	// Release the response now that we have finished all our processing
	[response release];
}


- (void)processLoadModelsInBackground:(RKResponse *)response {
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];	
	RKManagedObjectStore* objectStore = [[RKObjectManager manager] objectStore]; // TODO: Should probably relax singleton...
	
	// If the request was sent through a model, we map the results back into that object
	// TODO: Note that this assumption may not work in all cases, other approaches?
	// The issue is that not specifying the object results in new objects being created
	// rather than mapping back into the original. This is a problem for create (POST) operations.
	NSArray* results = nil;
	id mainThreadModel = response.request.userData;	// The object dispatching the request
	if (mainThreadModel) {
		if ([mainThreadModel isKindOfClass:[NSManagedObject class]]) {
			NSManagedObjectID* modelID = [(NSManagedObject*)mainThreadModel objectID];
			NSManagedObject* backgroundThreadModel = [RKManagedObject objectWithID:modelID];
			[_mapper mapObject:backgroundThreadModel fromString:[response bodyAsString]];
			results = [NSArray arrayWithObject:backgroundThreadModel];
		} else {
			[_mapper mapObject:mainThreadModel fromString:[response bodyAsString]];
			results = [NSArray arrayWithObject:mainThreadModel];
		}
	} else {
		id result = [_mapper mapFromString:[response bodyAsString]];
		if ([result isKindOfClass:[NSArray class]]) {
			results = (NSArray*)result;
		} else {
			// Using arrayWithObjects: instead of arrayWithObject:
			// so that in the event result is nil, then we get empty array instead of exception for trying to insert nil.
			results = [NSArray arrayWithObjects:result, nil];
		}
		
		if (self.fetchRequest) {
			// TODO: Get rid of objectsWithRequest on 
			NSArray* cachedObjects = [RKManagedObject objectsWithRequest:self.fetchRequest];			
			for (id object in cachedObjects) {
				if ([object isKindOfClass:[RKManagedObject class]]) {
					if (NO == [results containsObject:object]) {
						[[objectStore managedObjectContext] deleteObject:object];
					}
				}
			}
		}
	}
	
	// Before looking up NSManagedObjectIDs, need to save to ensure we do not have
	// temporary IDs for new objects prior to handing the objectIDs across threads
	NSError* error = [[[RKObjectManager manager] objectStore] save];
	if (nil != error) {
		NSDictionary* infoDictionary = [[NSDictionary dictionaryWithObjectsAndKeys:response, @"response", error, @"error", nil] retain];
		[self performSelectorOnMainThread:@selector(informDelegateOfModelLoadErrorWithInfoDictionary:) withObject:infoDictionary waitUntilDone:NO];		
	} else {
		// NOTE: Passing Core Data objects across threads is not safe. 
		// Iterate over each model and coerce Core Data objects into ID's to pass across the threads.
		// The object ID's will be deserialized back into objects on the main thread before the delegate is called back
		NSMutableArray* models = [NSMutableArray arrayWithCapacity:[results count]];
		for (id object in results) {
			if ([object isKindOfClass:[NSManagedObject class]]) {
				[models addObject:[(NSManagedObject*)object objectID]];
			} else {
				[models addObject:object];			 
			}
		}		
		
		NSDictionary* infoDictionary = [[NSDictionary dictionaryWithObjectsAndKeys:response, @"response", models, @"models", nil] retain];
		[self performSelectorOnMainThread:@selector(informDelegateOfModelLoadWithInfoDictionary:) withObject:infoDictionary waitUntilDone:NO];
	}

	[pool release];
}

- (void)loadObjectsFromResponse:(RKResponse*)response {
	if (NO == [self encounteredErrorWhileProcessingRequest:response] && [response isSuccessful]) {
		// Retain the response to prevent this thread from dealloc'ing before we have finished processing
		[response retain];
		[self performSelectorInBackground:@selector(processLoadModelsInBackground:) withObject:response];
	} else {
		// TODO: What do we do if this is not a 200, 4xx or 5xx response? Need new delegate method...
	}
}

///////////////////////////////////////////////////////////////////////////////////////////////////
// RKRequestDelegate
//
// If our delegate responds to the messages, forward them back...

- (void)requestDidStartLoad:(RKRequest*)request {
	if ([_delegate respondsToSelector:@selector(requestDidStartLoad:)]) {
		[_delegate requestDidStartLoad:request];
	}
}

- (void)requestDidFinishLoad:(RKRequest*)request {
	if ([_delegate respondsToSelector:@selector(requestDidFinishLoad:)]) {
		[(NSObject<RKRequestDelegate>*)_delegate requestDidFinishLoad:request];
	}
}

- (void)request:(RKRequest*)request didFailLoadWithError:(NSError*)error {
	if ([_delegate respondsToSelector:@selector(request:didFailLoadWithError:)]) {
		[(NSObject<RKRequestDelegate>*)_delegate request:request didFailLoadWithError:error];
	}
}

- (void)requestDidCancelLoad:(RKRequest*)request {
	if ([_delegate respondsToSelector:@selector(requestDidCancelLoad:)]) {
		[(NSObject<RKRequestDelegate>*)_delegate requestDidCancelLoad:request];
	}
}

@end

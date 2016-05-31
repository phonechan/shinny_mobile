/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "CDVURLProtocol.h"
#import "CDVCommandQueue.h"
#import "CDVWhitelist.h"
#import "CDVViewController.h"

static CDVWhitelist* gWhitelist = nil;
// Contains a set of NSNumbers of addresses of controllers. It doesn't store
// the actual pointer to avoid retaining.
static NSMutableSet* gRegisteredControllers = nil;

NSString* const kCDVAssetsLibraryPrefixes = @"assets-library://";

// Returns the registered view controller that sent the given request.
// If the user-agent is not from a UIWebView, or if it's from an unregistered one,
// then nil is returned.
static CDVViewController *viewControllerForRequest(NSURLRequest* request)
{
    // The exec bridge explicitly sets the VC address in a header.
    // This works around the User-Agent not being set for file: URLs.
    NSString* addrString = [request valueForHTTPHeaderField:@"vc"];

    if (addrString == nil) {
        NSString* userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
        if (userAgent == nil) {
            return nil;
        }
        NSUInteger bracketLocation = [userAgent rangeOfString:@"(" options:NSBackwardsSearch].location;
        if (bracketLocation == NSNotFound) {
            return nil;
        }
        addrString = [userAgent substringFromIndex:bracketLocation + 1];
    }

    long long viewControllerAddress = [addrString longLongValue];
    @synchronized(gRegisteredControllers) {
        if (![gRegisteredControllers containsObject:[NSNumber numberWithLongLong:viewControllerAddress]]) {
            return nil;
        }
    }

    return (__bridge CDVViewController*)(void*)viewControllerAddress;
}

@implementation CDVURLProtocol

+ (void)registerPGHttpURLProtocol {}

+ (void)registerURLProtocol {}

// Called to register the URLProtocol, and to make it away of an instance of
// a ViewController.
+ (void)registerViewController:(CDVViewController*)viewController
{
    if (gRegisteredControllers == nil) {
        [NSURLProtocol registerClass:[CDVURLProtocol class]];
        gRegisteredControllers = [[NSMutableSet alloc] initWithCapacity:8];
        // The whitelist doesn't change, so grab the first one and store it.
        gWhitelist = viewController.whitelist;

        // Note that we grab the whitelist from the first viewcontroller for now - but this will change
        // when we allow a registered viewcontroller to have its own whitelist (e.g InAppBrowser)
        // Differentiating the requests will be through the 'vc' http header below as used for the js->objc bridge.
        //  The 'vc' value is generated by casting the viewcontroller object to a (long long) value (see CDVViewController::webViewDidFinishLoad)
        if (gWhitelist == nil) {
            NSLog(@"WARNING: NO whitelist has been set in CDVURLProtocol.");
        }
    }

    @synchronized(gRegisteredControllers) {
        [gRegisteredControllers addObject:[NSNumber numberWithLongLong:(long long)viewController]];
    }
}

+ (void)unregisterViewController:(CDVViewController*)viewController
{
    @synchronized(gRegisteredControllers) {
        [gRegisteredControllers removeObject:[NSNumber numberWithLongLong:(long long)viewController]];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest*)theRequest
{
    
    NSURL* theUrl = [theRequest URL];
    CDVViewController* viewController = viewControllerForRequest(theRequest);
    
    if ([[theUrl absoluteString] containsString:@"cordova"]
        || [[theUrl absoluteString] containsString:@"collectController"]
        || [[theUrl absoluteString] containsString:@"depositoryController"]
        || [[theUrl absoluteString] containsString:@"videoController"]
        || [[theUrl absoluteString] containsString:@"certController"]
        || [[theUrl absoluteString] containsString:@"protocolController"]
        || [[theUrl absoluteString] containsString:@"common"]
        || [[theUrl absoluteString] containsString:@"forge"]
        || [[theUrl absoluteString] containsString:@"profileView"]
        || [[theUrl absoluteString] containsString:@"profileController"]
        ) {
        NSLog(@"%@",theUrl.absoluteString);
        return YES;
    }
    

    if ([[theUrl absoluteString] hasPrefix:kCDVAssetsLibraryPrefixes]) {
        return YES;
    } else if (viewController != nil) {
        if ([[theUrl path] isEqualToString:@"/!gap_exec"]) {
            NSString* queuedCommandsJSON = [theRequest valueForHTTPHeaderField:@"cmds"];
            NSString* requestId = [theRequest valueForHTTPHeaderField:@"rc"];
            if (requestId == nil) {
                NSLog(@"!cordova request missing rc header");
                return NO;
            }
            BOOL hasCmds = [queuedCommandsJSON length] > 0;
            if (hasCmds) {
                SEL sel = @selector(enqueueCommandBatch:);
                [viewController.commandQueue performSelectorOnMainThread:sel withObject:queuedCommandsJSON waitUntilDone:NO];
                [viewController.commandQueue performSelectorOnMainThread:@selector(executePending) withObject:nil waitUntilDone:NO];
            } else {
                SEL sel = @selector(processXhrExecBridgePoke:);
                [viewController.commandQueue performSelectorOnMainThread:sel withObject:[NSNumber numberWithInteger:[requestId integerValue]] waitUntilDone:NO];
            }
            // Returning NO here would be 20% faster, but it spams WebInspector's console with failure messages.
            // If JS->Native bridge speed is really important for an app, they should use the iframe bridge.
            // Returning YES here causes the request to come through canInitWithRequest two more times.
            // For this reason, we return NO when cmds exist.
            return !hasCmds;
        }
        // we only care about http and https connections.
        // CORS takes care of http: trying to access file: URLs.
        if ([gWhitelist schemeIsAllowed:[theUrl scheme]]) {
            // if it FAILS the whitelist, we return TRUE, so we can fail the connection later
            return ![gWhitelist URLIsAllowed:theUrl];
        }
    }

    return NO;
}

+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request
{
//     NSLog(@"%@ received %@", self, NSStringFromSelector(_cmd));
    return request;
}

- (void)startLoading
{
//     NSLog(@"%@ received %@ - start", self, NSStringFromSelector(_cmd));
    NSURL* url = [[self request] URL];
    
    if ([[url path] containsString:@"cordova"] ) {
        id <NSURLProtocolClient> client = self.client;
        
        NSURLRequest *request = self.request;
        
//        NSLog(@"startLoading %@", request.URL);
        
        NSDictionary *headers = @{ @"Content-Type": @"text/javascript"};
        // 获得文件名（不带后缀）
        NSString *fileName = [[url path] stringByDeletingPathExtension];
//        NSLog(@"fileName %@",fileName);
        // 获得文件名（带后缀）
        // NSString *fileNameWithExtension = [[url path] lastPathComponent];
        // NSLog(@"%@",fileNameWithExtension);
        
        // 获得文件的后缀名（不带'.'）
        NSString *pathExtension = [[url path] pathExtension];
        
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *thepath = [mainBundle pathForResource:[@"www" stringByAppendingString:fileName] ofType: pathExtension];
        
//        NSLog(@"目录：%@", thepath);
        NSFileManager* fm = [NSFileManager defaultManager];
        NSData* data = [[NSData alloc] init];
        data = [fm contentsAtPath: thepath];
        // NSLog(@"内容：%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:headers];
        [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [client URLProtocol:self didLoadData:data];
        [client URLProtocolDidFinishLoading:self];
        return;
    } else if ([[url path] containsString:@"common"]
               || [[url path] containsString:@"collectController"]
               || [[url path] containsString:@"depositoryController"]
               || [[url path] containsString:@"videoController"]
               || [[url path] containsString:@"certController"]
               || [[url path] containsString:@"protocolController"]
               || [[url path] containsString:@"forge"]
               || [[url path] containsString:@"profileView"]
               || [[url path] containsString:@"profileController"]
               ) {
        id <NSURLProtocolClient> client = self.client;
        
        NSURLRequest *request = self.request;
        
        NSLog(@"startLoading %@", request.URL);
        NSDictionary *headers = @{ @"Content-Type": @"text/javascript"};
        // 获得文件名（不带后缀）
        NSString *fileName = [[url path] stringByDeletingPathExtension];
        NSLog(@"fileName %@",fileName);
        // 获得文件名（带后缀）
        // NSString *fileNameWithExtension = [[url path] lastPathComponent];
        // NSLog(@"%@",fileNameWithExtension);
        
        // 获得文件的后缀名（不带'.'）
        NSString *pathExtension = [[url path] pathExtension];
        
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *thepath = [mainBundle pathForResource:[fileName stringByReplacingOccurrencesOfString:@"/template/future" withString:@"www"] ofType: pathExtension];
        
        NSLog(@"目录：%@", thepath);
        NSFileManager* fm = [NSFileManager defaultManager];
        NSData* data = [[NSData alloc] init];
        data = [fm contentsAtPath: thepath];
        // NSLog(@"内容：%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:headers];
        [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [client URLProtocol:self didLoadData:data];
        [client URLProtocolDidFinishLoading:self];
        return;

    }

    if ([[url path] isEqualToString:@"/!gap_exec"]) {
        [self sendResponseWithResponseCode:200 data:nil mimeType:nil];
        return;
    } else if ([[url absoluteString] hasPrefix:kCDVAssetsLibraryPrefixes]) {
        ALAssetsLibraryAssetForURLResultBlock resultBlock = ^(ALAsset* asset) {
            if (asset) {
                // We have the asset!  Get the data and send it along.
                ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                NSString* MIMEType = (__bridge_transfer NSString*)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)[assetRepresentation UTI], kUTTagClassMIMEType);
                Byte* buffer = (Byte*)malloc((unsigned long)[assetRepresentation size]);
                NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:0.0 length:(NSUInteger)[assetRepresentation size] error:nil];
                NSData* data = [NSData dataWithBytesNoCopy:buffer length:bufferSize freeWhenDone:YES];
                [self sendResponseWithResponseCode:200 data:data mimeType:MIMEType];
            } else {
                // Retrieving the asset failed for some reason.  Send an error.
                [self sendResponseWithResponseCode:404 data:nil mimeType:nil];
            }
        };
        ALAssetsLibraryAccessFailureBlock failureBlock = ^(NSError* error) {
            // Retrieving the asset failed for some reason.  Send an error.
            [self sendResponseWithResponseCode:401 data:nil mimeType:nil];
        };

        ALAssetsLibrary* assetsLibrary = [[ALAssetsLibrary alloc] init];
        [assetsLibrary assetForURL:url resultBlock:resultBlock failureBlock:failureBlock];
        return;
    }

    NSString* body = [gWhitelist errorStringForURL:url];
    [self sendResponseWithResponseCode:401 data:[body dataUsingEncoding:NSASCIIStringEncoding] mimeType:nil];
}

- (void)stopLoading
{
    // do any cleanup here
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest*)requestA toRequest:(NSURLRequest*)requestB
{
    return NO;
}

- (void)sendResponseWithResponseCode:(NSInteger)statusCode data:(NSData*)data mimeType:(NSString*)mimeType
{
    if (mimeType == nil) {
        mimeType = @"text/plain";
    }

    NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type" : mimeType}];

    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data != nil) {
        [[self client] URLProtocol:self didLoadData:data];
    }
    [[self client] URLProtocolDidFinishLoading:self];
}

@end
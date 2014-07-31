/*
 This file belongs to the OCFWebServer project. OCFWebServer is a fork of GCDWebServer (originally developed by
 Pierre-Olivier Latour). We have forked GCDWebServer because we made extensive and incompatible changes to it.
 To find out more have a look at README.md.
 
 Copyright (c) 2013, Christian Kienle / chris@objective-cloud.com
 All rights reserved.
 
 Original Copyright Statement:
 Copyright (c) 2012-2013, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the <organization> nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OCFWebServerPrivate.h"
#import "OCFWebServerRequest.h"
#import "OCFWebServerResponse.h"

typedef NS_ENUM(long, OCFWebServerConnectionDataTag) {
  OCFWebServerConnectionDataTagHeaders,
  OCFWebServerConnectionDataTagBody
};

#define kBodyWriteBufferSize (32 * 1024)

typedef void (^WriteBufferCompletionBlock)(BOOL success);
typedef void (^WriteDataCompletionBlock)(BOOL success);
typedef void (^WriteHeadersCompletionBlock)(BOOL success);
typedef void (^WriteBodyCompletionBlock)(BOOL success);

static NSData* _separatorData = nil;
static NSData* _continueData = nil;
static NSDateFormatter* _dateFormatter = nil;
static dispatch_queue_t _formatterQueue = NULL;

@interface OCFWebServerConnection () {
  dispatch_queue_t _queue;
  NSMutableDictionary *_writeCompletionBlocks;
  long _writeTag;
}

#pragma mark - Properties
@property (nonatomic, weak, readwrite) OCFWebServer* server;
@property (nonatomic, copy, readwrite) NSData *address;  // struct sockaddr
@property (nonatomic, readwrite) NSUInteger totalBytesRead;
@property (nonatomic, readwrite) NSUInteger totalBytesWritten;
@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic) int socketFD;
@property (nonatomic, assign) CFHTTPMessageRef requestMessage;
@property (nonatomic, strong) OCFWebServerRequest *request;
@property (nonatomic, strong) OCFWebServerHandler *handler;
@property (nonatomic, assign) CFHTTPMessageRef responseMessage;
@property (nonatomic, strong) OCFWebServerResponse *response;
@property (nonatomic, copy) OCFWebServerConnectionCompletionHandler completionHandler;

@end

@implementation OCFWebServerConnection (Write)

- (void)_writeData:(NSData *)data withCompletionBlock:(WriteDataCompletionBlock)block {
  _writeCompletionBlocks[@(_writeTag)] = block;
  [self.socket writeData:data withTimeout:-1 tag:_writeTag];
  LOG_DEBUG(@"Connection sent %i bytes on socket %i", [data length], self.socketFD);
  self.totalBytesWritten += [data length];
  _writeTag++;
}

- (void)_writeHeadersWithCompletionBlock:(WriteHeadersCompletionBlock)block {
  DCHECK(self.responseMessage);
  CFDataRef message = CFHTTPMessageCopySerializedMessage(self.responseMessage);
  NSData *data = (__bridge_transfer NSData *)message;
  [self _writeData:data withCompletionBlock:block];
}

- (void)_writeBodyWithCompletionBlock:(WriteBodyCompletionBlock)block {
  DCHECK([self.response hasBody]);
  NSMutableData *data = [[NSMutableData alloc] initWithLength:kBodyWriteBufferSize];
  NSInteger result = [self.response read:data.mutableBytes maxLength:kBodyWriteBufferSize];
  if (result > 0) {
    [data setLength:result];
    [self _writeData:data withCompletionBlock:^(BOOL success) {
      if (success) {
        [self _writeBodyWithCompletionBlock:block];
      } else {
        block(NO);
      }
    }];
  } else if (result < 0) {
    LOG_ERROR(@"Failed reading response body on socket %i (error %i)", self.socketFD, (int)result);
    block(NO);
  } else {
    block(YES);
  }
}

@end

@implementation OCFWebServerConnection

+ (void)initialize {
  DCHECK([NSThread isMainThread]);  // NSDateFormatter should be initialized on main thread
  if (_separatorData == nil) {
    _separatorData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
    DCHECK(_separatorData);
  }
  if (_continueData == nil) {
    CFHTTPMessageRef message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 100, NULL, kCFHTTPVersion1_1);
    _continueData = (NSData*)CFBridgingRelease(CFHTTPMessageCopySerializedMessage(message));
    CFRelease(message);
    DCHECK(_continueData);
  }
  if (_dateFormatter == nil) {
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    _dateFormatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
    _dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    DCHECK(_dateFormatter);
  }
  if (_formatterQueue == NULL) {
    _formatterQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    DCHECK(_formatterQueue);
  }
}

- (void)_initializeResponseHeadersWithStatusCode:(NSInteger)statusCode {
  self.responseMessage = CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1);
  CFHTTPMessageSetHeaderFieldValue(self.responseMessage, CFSTR("Connection"), CFSTR("Close"));
  CFHTTPMessageSetHeaderFieldValue(self.responseMessage, CFSTR("Server"), (__bridge CFStringRef)[[self.server class] serverName]);
  dispatch_sync(_formatterQueue, ^{
    NSString* date = [_dateFormatter stringFromDate:[NSDate date]];
    CFStringRef cfDate = (CFStringRef)CFBridgingRetain(date);
    CFHTTPMessageSetHeaderFieldValue(self.responseMessage, CFSTR("Date"), cfDate);
    CFRelease(cfDate);
  });
}

- (void)_abortWithStatusCode:(NSUInteger)statusCode {
  DCHECK(self.responseMessage == NULL);
  DCHECK((statusCode >= 400) && (statusCode < 600));
  [self _initializeResponseHeadersWithStatusCode:statusCode];
  [self _writeHeadersWithCompletionBlock:^(BOOL success) {
    [self close];
  }];
  LOG_DEBUG(@"Connection aborted with status code %i on socket %i", statusCode, self.socketFD);
}

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
// This method is already called on the dispatch queue of the web server so there is no need to dispatch again.
- (void)_processRequest {
  DCHECK(self.responseMessage == NULL);
  @try {
    __typeof__(self) __weak weakSelf = self;
    self.request.responseBlock = ^(OCFWebServerResponse *response) {
      if (![response hasBody] || [response open]) {
        weakSelf.response = response;
      }
      if (weakSelf.response) {
        [weakSelf _initializeResponseHeadersWithStatusCode:weakSelf.response.statusCode];
        NSUInteger maxAge = weakSelf.response.cacheControlMaxAge;
        if (maxAge > 0) {
          CFHTTPMessageSetHeaderFieldValue(weakSelf.responseMessage, CFSTR("Cache-Control"), (__bridge CFStringRef)[NSString stringWithFormat:@"max-age=%i, public", (int)maxAge]);
        } else {
          CFHTTPMessageSetHeaderFieldValue(weakSelf.responseMessage, CFSTR("Cache-Control"), CFSTR("no-cache"));
        }
        [weakSelf.response.additionalHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL* stop) {
          CFHTTPMessageSetHeaderFieldValue(weakSelf.responseMessage, (__bridge CFStringRef)(key), (__bridge CFStringRef)(obj));
        }];
        
        if ([weakSelf.response hasBody]) {
          CFHTTPMessageSetHeaderFieldValue(weakSelf.responseMessage, CFSTR("Content-Type"), (__bridge CFStringRef)weakSelf.response.contentType);
          CFHTTPMessageSetHeaderFieldValue(weakSelf.responseMessage, CFSTR("Content-Length"), (__bridge CFStringRef)[NSString stringWithFormat:@"%i", (int)weakSelf.response.contentLength]);
        }
        [weakSelf _writeHeadersWithCompletionBlock:^(BOOL success) {
          if (success) {
            if ([weakSelf.response hasBody]) {
              [weakSelf _writeBodyWithCompletionBlock:^(BOOL success) {
                [weakSelf.response close];  // Can't do anything with result anyway
                [weakSelf close];
              }];
            }
          } else if ([weakSelf.response hasBody]) {
            [weakSelf.response close];  // Can't do anything with result anyway
            [weakSelf close];
          }
        }];
      } else {
        [weakSelf _abortWithStatusCode:500];
      }
    };
    self.handler.processBlock(self.request);
  }
  @catch (NSException* exception) {
    LOG_EXCEPTION(exception);
    [self _abortWithStatusCode:500];
  }
  @finally {
    
  }
}

- (void)_readRequestBody:(NSData*)initialData {
  if ([self.request open]) {
    if (initialData.length) {
      [self _processBodyData:initialData];
    }
    [self.socket readDataToLength:self.request.contentLength withTimeout:-1 tag:OCFWebServerConnectionDataTagBody];
  } else {
    [self _abortWithStatusCode:500];
  }
}

- (void)_processBodyData:(NSData *)data {
  NSInteger length = self.request.contentLength;
  NSInteger result = [self.request write:data.bytes maxLength:data.length];
  if (result == data.length) {
    length -= data.length;
    DCHECK(length >= 0);
  } else {
    LOG_ERROR(@"Failed writing request body on socket %i (error %i)", self.socketFD, (int)result);
    length = -1;
  }
  if (length == 0) {
    if ([self.request close]) {
      [self _processRequest];
    } else {
      [self _abortWithStatusCode:500];
    }
  }
}

- (void)_readRequestHeaders {
  self.requestMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true);
  [self.socket readDataToData:_separatorData withTimeout:-1 maxLength:SIZE_T_MAX tag:OCFWebServerConnectionDataTagHeaders];
}

- (void)_processHeaderData:(NSData *)data {
  NSData *extraData = nil;
  if (CFHTTPMessageAppendBytes(self.requestMessage, data.bytes, data.length)) {
    if (CFHTTPMessageIsHeaderComplete(self.requestMessage)) {
      NSString* requestMethod = [(id)CFBridgingRelease(CFHTTPMessageCopyRequestMethod(self.requestMessage)) uppercaseString];
      DCHECK(requestMethod);
      NSURL* requestURL = (id)CFBridgingRelease(CFHTTPMessageCopyRequestURL(self.requestMessage));
      DCHECK(requestURL);
      NSString* requestPath = OCFWebServerUnescapeURLString((id)CFBridgingRelease(CFURLCopyPath((CFURLRef)requestURL)));  // Don't use -[NSURL path] which strips the ending slash
      if(requestPath == nil) {
        requestPath = @"/";
      }
      DCHECK(requestPath);
      NSDictionary* requestQuery = nil;
      NSString* queryString = (id)CFBridgingRelease(CFURLCopyQueryString((CFURLRef)requestURL, NULL));  // Don't use -[NSURL query] to make sure query is not unescaped;
      if (queryString.length) {
        requestQuery = OCFWebServerParseURLEncodedForm(queryString);
        DCHECK(requestQuery);
      }
      NSDictionary* requestHeaders = (id)CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(self.requestMessage));
      DCHECK(requestHeaders);
      for (OCFWebServerHandler *handler in self.server.handlers) {
        self.request = handler.matchBlock(requestMethod, requestURL, requestHeaders, requestPath, requestQuery);
        if (self.request) {
          self.handler = handler;
          break;
        }
      }
      if (self.request) {
        if (self.request.hasBody) {
          if (extraData.length <= self.request.contentLength) {
            NSString* expectHeader = (id)CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(self.requestMessage, CFSTR("Expect")));
            if (expectHeader) {
              if ([expectHeader caseInsensitiveCompare:@"100-continue"] == NSOrderedSame) {
                [self _writeData:_continueData withCompletionBlock:^(BOOL success) {
                  if (success) {
                    [self _readRequestBody:extraData];
                  }
                }];
              } else {
                LOG_ERROR(@"Unsupported 'Expect' / 'Content-Length' header combination on socket %i", self.socketFD);
                [self _abortWithStatusCode:417];
              }
            } else {
              [self _readRequestBody:extraData];
            }
          } else {
            LOG_ERROR(@"Unexpected 'Content-Length' header value on socket %i", self.socketFD);
            [self _abortWithStatusCode:400];
          }
        } else {
          [self _processRequest];
        }
      } else {
        [self _abortWithStatusCode:405];
      }
    } else {
      LOG_ERROR(@"Failed parsing request headers from socket %i", self.socketFD);
      return;
    }
  } else {
    LOG_ERROR(@"Failed appending request headers data from socket %i", self.socketFD);
    return;
  }
}

- (instancetype)initWithServer:(OCFWebServer *)server address:(NSData *)address socket:(GCDAsyncSocket *)socket {
  if((self = [super init])) {
    _writeCompletionBlocks = [[NSMutableDictionary alloc] init];
    NSString *queueLabel = [NSString stringWithFormat:@"%@.queue.%p", [self class], self];
    _queue = dispatch_queue_create([queueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
    _server = server;
    _address = address;
    _socket = socket;
    [socket setDelegate:self delegateQueue:_queue];
    [socket performBlock:^{
      _socketFD = socket.socketFD;
    }];
  }
  return self;
}

- (void)dealloc {
  if(self.requestMessage) {
    CFRelease(self.requestMessage);
  }
  if(self.responseMessage) {
    CFRelease(self.responseMessage);
  }
}

#pragma mark - GCD Async Socket Delegate

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
  self.totalBytesRead += [data length];

  switch (tag) {
    case OCFWebServerConnectionDataTagHeaders:
      [self _processHeaderData:data];
      break;

    case OCFWebServerConnectionDataTagBody:
      [self _processBodyData:data];
      break;
  }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
  NSNumber *writeTag = @(tag);
  WriteDataCompletionBlock block = _writeCompletionBlocks[writeTag];
  if (block) {
    [_writeCompletionBlocks removeObjectForKey:writeTag];
    block(YES);
  }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
  [self close];
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock {
  LOG_DEBUG(@"Socket %i did secure", self.socketFD);
  [self _readRequestHeaders];
}

@end

@implementation OCFWebServerConnection (Subclassing)

- (void)openWithCompletionHandler:(OCFWebServerConnectionCompletionHandler)completionHandler {
  LOG_DEBUG(@"Did open connection on socket %i", self.socketFD);
  self.completionHandler = completionHandler;
  NSDictionary *TLSSettings = self.server.TLSSettings;
  if (TLSSettings) {
    [self.socket startTLS:TLSSettings];
  } else {
    [self _readRequestHeaders];
  }
}

- (void)close {
  [self.socket disconnectAfterWriting];
  LOG_DEBUG(@"Will close connection on socket %i", self.socketFD);
  if (self.completionHandler) {
    self.completionHandler();
    self.completionHandler = nil;
  }
}

@end

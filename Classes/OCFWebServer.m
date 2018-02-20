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

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <MobileCoreServices/MobileCoreServices.h>
#endif

#import <netinet/in.h>

#import "OCFWebServerPrivate.h"
#import "OCFWebServerResponse.h"

static BOOL _run;

NSString* OCFWebServerGetMimeTypeForExtension(NSString* extension) {
  NSString* mimeType = nil;
  extension = [extension lowercaseString];
  if (extension.length) {
    CFStringRef cfExtension = CFBridgingRetain(extension);
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, cfExtension, NULL);
    CFRelease(cfExtension);
    if (uti) {
      mimeType = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType));
      CFRelease(uti);
    }
  }
  return mimeType;
}

NSString* OCFWebServerUnescapeURLString(NSString* string) {
  return CFBridgingRelease(CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault, (CFStringRef)string, CFSTR(""), kCFStringEncodingUTF8));
}

NSDictionary* OCFWebServerParseURLEncodedForm(NSString* form) {
  NSMutableDictionary* parameters = [NSMutableDictionary dictionary];
  NSScanner* scanner = [[NSScanner alloc] initWithString:form];
  [scanner setCharactersToBeSkipped:nil];
  while (1) {
    NSString* key = nil;
    if (![scanner scanUpToString:@"=" intoString:&key] || [scanner isAtEnd]) {
      break;
    }
    [scanner setScanLocation:([scanner scanLocation] + 1)];
    
    NSString* value = nil;
    if (![scanner scanUpToString:@"&" intoString:&value]) {
      break;
    }
    
    key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    parameters[OCFWebServerUnescapeURLString(key)] = OCFWebServerUnescapeURLString(value);
    
    if ([scanner isAtEnd]) {
      break;
    }
    [scanner setScanLocation:([scanner scanLocation] + 1)];
  }
  return parameters;
}

static void _SignalHandler(int signal) {
  _run = NO;
  printf("\n");
}


@interface OCFWebServerHandler ()

#pragma mark - Properties
@property (nonatomic, copy, readwrite) OCFWebServerMatchBlock matchBlock;
@property (nonatomic, copy, readwrite) OCFWebServerProcessBlock processBlock;

@end

@implementation OCFWebServerHandler

#pragma mark - Creating
- (instancetype)initWithMatchBlock:(OCFWebServerMatchBlock)matchBlock processBlock:(OCFWebServerProcessBlock)processBlock {
  self = [super init];
  if (self) {
    self.matchBlock = matchBlock;
    self.processBlock = processBlock;
  }
  return self;
}


@end

@interface OCFWebServer () <GCDAsyncSocketDelegate>

#pragma mark - Properties
@property (nonatomic, readwrite) NSUInteger port;
@end

@implementation OCFWebServer {
  dispatch_queue_t _queue;
  GCDAsyncSocket *_socket;
  CFNetServiceRef _service;
  NSMutableArray *_handlers;
  NSMutableArray *_connections;
}

#pragma mark - Properties

- (void)setHandlers:(NSArray *)handlers {
  _handlers = [handlers mutableCopy];
}

- (NSArray *)handlers {
  return _handlers;
}

- (NSArray *)SSLCertificates {
#ifdef GCDAsyncSocketSSLIsServer
  return _TLSSettings[GCDAsyncSocketSSLCertificates];
#else
  return _TLSSettings[(id)kCFStreamSSLCertificates];
#endif
}

- (void)setSSLCertificates:(NSArray *)SSLCertificates {
#ifdef GCDAsyncSocketSSLIsServer
  _TLSSettings = SSLCertificates ? @{GCDAsyncSocketSSLIsServer: @YES,
                                     GCDAsyncSocketSSLCertificates: [SSLCertificates copy]} : nil;
#else
  _TLSSettings = SSLCertificates ? @{(id)kCFStreamSSLIsServer: @YES,
                                     (id)kCFStreamSSLCertificates: [SSLCertificates copy],
                                     (id)kCFStreamSSLLevel: (id)kCFStreamSocketSecurityLevelNegotiatedSSL} : nil;
#endif
}

+ (void)initialize {
  [OCFWebServerConnection class];  // Initialize class immediately to make sure it happens on the main thread
}

#pragma mark - Creating
- (instancetype)init {
  self = [super init];
  if (self) {
    NSString *queueLabel = [NSString stringWithFormat:@"%@.queue.%p", [self class], self];
    _queue = dispatch_queue_create([queueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
    self.handlers = @[];
    _connections = [NSMutableArray new];
    [self setupHeaderLogging];
  }
  return self;
}

- (void)setupHeaderLogging {
  NSProcessInfo *processInfo = [NSProcessInfo processInfo];
  NSDictionary *environment = processInfo.environment;
  NSString *headerLoggingEnabledString = environment[@"OCFWS_HEADER_LOGGING_ENABLED"];
  if (headerLoggingEnabledString == nil) {
    self.headerLoggingEnabled = NO;
    return;
  }
  if ([headerLoggingEnabledString.uppercaseString isEqualToString:@"YES"]) {
    self.headerLoggingEnabled = YES;
    return;
  }
  self.headerLoggingEnabled = NO;
}

#pragma mark - NSObject
- (void)dealloc {
  if (_socket) {
    [self stop];
  }
}

#pragma mark - OCFWebServer
- (void)addHandlerWithMatchBlock:(OCFWebServerMatchBlock)matchBlock processBlock:(OCFWebServerProcessBlock)handlerBlock {
  DCHECK(_socket == NULL);
  OCFWebServerHandler *handler = [[OCFWebServerHandler alloc] initWithMatchBlock:matchBlock processBlock:handlerBlock];
  [_handlers insertObject:handler atIndex:0];
}

- (void)removeAllHandlers {
  DCHECK(_socket == NULL);
  [_handlers removeAllObjects];
}

- (BOOL)start {
  return [self startWithPort:8080 bonjourName:@""];
}

static void _NetServiceClientCallBack(CFNetServiceRef service, CFStreamError* error, void* info) {
  @autoreleasepool {
    if (error->error) {
      LOG_ERROR(@"Bonjour error %i (domain %i)", error->error, (int)error->domain);
    } else {
      LOG_VERBOSE(@"Registered Bonjour service \"%@\" with type '%@' on port %i", CFNetServiceGetName(service), CFNetServiceGetType(service), CFNetServiceGetPortNumber(service));
    }
  }
}

- (BOOL)startWithPort:(NSUInteger)port bonjourName:(NSString *)name {
  DCHECK(_socket == NULL);

  _socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_queue];
  NSError *error = nil;
  if (![_socket acceptOnPort:port error:&error]) {
    LOG_ERROR(@"Failed starting server: %@", error);
    return NO;
  }

  _port = [_socket localPort];

  if (name) {
    CFStringRef cfName = CFBridgingRetain(name);
    _service = CFNetServiceCreate(kCFAllocatorDefault, CFSTR("local."), CFSTR("_http._tcp"), cfName, (SInt32)_port);
    CFRelease(cfName);
    if (_service) {
      CFNetServiceClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
      CFNetServiceSetClient(_service, _NetServiceClientCallBack, &context);
      CFNetServiceScheduleWithRunLoop(_service, CFRunLoopGetMain(), kCFRunLoopCommonModes);
      CFStreamError error = {0};
      CFNetServiceRegisterWithOptions(_service, 0, &error);
    } else {
      LOG_ERROR(@"Failed creating CFNetService");
    }
  }

  return YES;
}

- (BOOL)isRunning {
  return (_socket ? YES : NO);
}

- (void)stop {
  DCHECK(_socket != nil);
  if (_socket) {
    if (_service) {
      CFNetServiceUnscheduleFromRunLoop(_service, CFRunLoopGetMain(), kCFRunLoopCommonModes);
      CFNetServiceSetClient(_service, NULL, NULL);
      CFRelease(_service);
      _service = NULL;
    }

    [_socket setDelegate:nil];
    [_socket disconnect];
    _socket = nil;
    LOG_VERBOSE(@"%@ stopped", [self class]);
  }
  self.port = 0;
}

#pragma mark - GCD Async Socket Delegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
  Class connectionClass = [[self class] connectionClass];
  OCFWebServerConnection *connection = [[connectionClass alloc] initWithServer:self address:newSocket.connectedAddress socket:newSocket];
  @synchronized(_connections) {
    [_connections addObject:connection];
    LOG_DEBUG(@"Number of connections: %lu", _connections.count);
  }
  __typeof__(connection) __weak weakConnection = connection;
  [connection openWithCompletionHandler:^{
    @synchronized(_connections) {
      if (weakConnection != nil) {
        [_connections removeObject:weakConnection];
        LOG_DEBUG(@"Number of connections: %lu", _connections.count);
      }
    }
  }];
}

@end

@implementation OCFWebServer (Subclassing)

+ (Class)connectionClass {
  return [OCFWebServerConnection class];
}

+ (NSString *)serverName {
  return NSStringFromClass(self);
}

@end

@implementation OCFWebServer (Extensions)

- (BOOL)runWithPort:(NSUInteger)port {
  BOOL success = NO;
  _run = YES;
  void* handler = signal(SIGINT, _SignalHandler);
  if (handler != SIG_ERR) {
    if ([self startWithPort:port bonjourName:@""]) {
      while (_run) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
      }
      [self stop];
      success = YES;
    }
    signal(SIGINT, handler);
  }
  return success;
}

@end

@implementation OCFWebServer (Handlers)

- (void)addDefaultHandlerForMethod:(NSString*)method requestClass:(Class)class processBlock:(OCFWebServerProcessBlock)block {
  [self addHandlerWithMatchBlock:^OCFWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {

    if (![requestMethod isEqualToString:method]) {
      return nil;
    }

    return [[class alloc] initWithMethod:requestMethod URL:requestURL headers:requestHeaders path:urlPath query:urlQuery];
  } processBlock:block];
}

- (OCFWebServerResponse*)_responseWithContentsOfFile:(NSString*)path {
  return [OCFWebServerFileResponse responseWithFile:path];
}

- (OCFWebServerResponse*)_responseWithContentsOfDirectory:(NSString*)path {
  NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager] enumeratorAtPath:path];
  if (enumerator == nil) {
    return nil;
  }
  NSMutableString* html = [NSMutableString string];
  [html appendString:@"<html><body>\n"];
  [html appendString:@"<ul>\n"];
  for (NSString* file in enumerator) {
    if (![file hasPrefix:@"."]) {
      NSString* type = [enumerator fileAttributes][NSFileType];
      NSString* escapedFile = [file stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
      DCHECK(escapedFile);
      if ([type isEqualToString:NSFileTypeRegular]) {
        [html appendFormat:@"<li><a href=\"%@\">%@</a></li>\n", escapedFile, file];
      } else if ([type isEqualToString:NSFileTypeDirectory]) {
        [html appendFormat:@"<li><a href=\"%@/\">%@/</a></li>\n", escapedFile, file];
      }
    }
    [enumerator skipDescendents];
  }
  [html appendString:@"</ul>\n"];
  [html appendString:@"</body></html>\n"];
  return [OCFWebServerDataResponse responseWithHTML:html];
}

- (void)addHandlerForBasePath:(NSString*)basePath localPath:(NSString*)localPath indexFilename:(NSString*)indexFilename cacheAge:(NSUInteger)cacheAge {
  __typeof__(self) __weak weakSelf = self;
  if ([basePath hasPrefix:@"/"] && [basePath hasSuffix:@"/"]) {
    [self addHandlerWithMatchBlock:^OCFWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {
      
      if (![requestMethod isEqualToString:@"GET"]) {
        return nil;
      }
      if (![urlPath hasPrefix:basePath]) {
        return nil;
      }
      return [[OCFWebServerRequest alloc] initWithMethod:requestMethod URL:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      
    } processBlock:^(OCFWebServerRequest* request) {
      OCFWebServerResponse* response = nil;
      NSString* filePath = [localPath stringByAppendingPathComponent:[request.path substringFromIndex:basePath.length]];
      BOOL isDirectory;
      if ([[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDirectory]) {
        if (isDirectory) {
          if (indexFilename) {
            NSString* indexPath = [filePath stringByAppendingPathComponent:indexFilename];
            if ([[NSFileManager defaultManager] fileExistsAtPath:indexPath isDirectory:&isDirectory] && !isDirectory) {
              response = [weakSelf _responseWithContentsOfFile:indexPath];
            }
          }
          if (!response) {
            response = [weakSelf _responseWithContentsOfDirectory:filePath];
          }
        } else {
          response = [weakSelf _responseWithContentsOfFile:filePath];
        }
      }
      if (response) {
        response.cacheControlMaxAge = cacheAge;
      } else {
        response = [OCFWebServerResponse responseWithStatusCode:404];
      }
      [request respondWith:response];
    }];
  } else {
    DNOT_REACHED();
  }
}

- (void)addHandlerForMethod:(NSString*)method path:(NSString*)path requestClass:(Class)class processBlock:(OCFWebServerProcessBlock)block {
  if ([path hasPrefix:@"/"] && [class isSubclassOfClass:[OCFWebServerRequest class]]) {
    [self addHandlerWithMatchBlock:^OCFWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {
      
      if (![requestMethod isEqualToString:method]) {
        return nil;
      }
      if ([urlPath caseInsensitiveCompare:path] != NSOrderedSame) {
        return nil;
      }
      return [[class alloc] initWithMethod:requestMethod URL:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      
    } processBlock:block];
  } else {
    DNOT_REACHED();
  }
}

- (void)addHandlerForMethod:(NSString*)method pathRegex:(NSString*)regex requestClass:(Class)class processBlock:(OCFWebServerProcessBlock)block {
  NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionCaseInsensitive error:NULL];
  if (expression && [class isSubclassOfClass:[OCFWebServerRequest class]]) {
    [self addHandlerWithMatchBlock:^OCFWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {
      
      if (![requestMethod isEqualToString:method]) {
        return nil;
      }
      if ([expression firstMatchInString:urlPath options:0 range:NSMakeRange(0, urlPath.length)] == nil) {
        return nil;
      }
      return [[class alloc] initWithMethod:requestMethod URL:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      
    } processBlock:block];
  } else {
    DNOT_REACHED();
  }
}

@end

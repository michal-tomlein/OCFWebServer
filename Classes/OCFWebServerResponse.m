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

#import <sys/stat.h>

#import "OCFWebServerPrivate.h"
#import "OCFWebServerResponse.h"


@interface OCFWebServerResponse ()

#pragma mark - Properties
@property(nonatomic, copy, readwrite) NSString *contentType;
@property(nonatomic, readwrite) NSUInteger contentLength;
//@property(nonatomic, readwrite) NSInteger statusCode;  // Default is 200
@property(nonatomic, readwrite, copy) NSDictionary *additionalHeaders;

@end

@implementation OCFWebServerResponse {
  NSMutableDictionary *_additionalHeaders;
}

#pragma mark - Properties
- (void)setAdditionalHeaders:(NSDictionary *)additionalHeaders {
  _additionalHeaders = [additionalHeaders mutableCopy];
}

- (NSDictionary *)additionalHeaders {
  return [_additionalHeaders copy];
}

#pragma mark - Creating
+ (instancetype) response {
  return [[[self class] alloc] init];
}

- (instancetype)init {
  return [self initWithContentType:nil contentLength:0];
}

- (instancetype)initWithContentType:(NSString*)contentType contentLength:(NSUInteger)length {
  if ((self = [super init])) {
    self.contentType = contentType;
    self.contentLength = length;
    self.statusCode = 200;
    self.cacheControlMaxAge = 0;
    self.additionalHeaders = @{};
    
    if ((self.contentLength > 0) && (self.contentType == nil)) {
      self.contentType = [kOCFWebServerDefaultMimeType copy];
    }
  }
  return self;
}

#pragma mark - Working with the Response
- (void)setValue:(NSString*)value forAdditionalHeader:(NSString*)header {
  _additionalHeaders[header] = value;
}

- (BOOL)hasBody {
  return self.contentType ? YES : NO;
}

@end

@implementation OCFWebServerResponse (Subclassing)

- (BOOL)open {
  [self doesNotRecognizeSelector:_cmd];
  return NO;
}

- (NSInteger)read:(void*)buffer maxLength:(NSUInteger)length {
  [self doesNotRecognizeSelector:_cmd];
  return -1;
}

- (BOOL)close {
  [self doesNotRecognizeSelector:_cmd];
  return NO;
}

@end

@implementation OCFWebServerResponse (Extensions)

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode {
  return [[self alloc] initWithStatusCode:statusCode];
}

+ (instancetype)responseWithRedirect:(NSURL*)location permanent:(BOOL)permanent {
  return [[self alloc] initWithRedirect:location permanent:permanent];
}

- (instancetype)initWithStatusCode:(NSInteger)statusCode {
  if ((self = [self initWithContentType:nil contentLength:0])) {
    self.statusCode = statusCode;
  }
  return self;
}

- (instancetype)initWithRedirect:(NSURL*)location permanent:(BOOL)permanent {
  if ((self = [self initWithContentType:nil contentLength:0])) {
    self.statusCode = permanent ? 301 : 307;
    [self setValue:[location absoluteString] forAdditionalHeader:@"Location"];
  }
  return self;
}

@end

@interface OCFWebServerDataResponse () {
  NSData *_data;
  NSInteger _offset;
}

@end

@implementation OCFWebServerDataResponse

+ (instancetype)responseWithData:(NSData*)data contentType:(NSString*)type {
  return [[[self class] alloc] initWithData:data contentType:type];
}

- (instancetype)initWithData:(NSData*)data contentType:(NSString*)type {
  if (data == nil) {
    DNOT_REACHED();
    return nil;
  }
  
  if ((self = [super initWithContentType:type contentLength:data.length])) {
    _data = data;
    _offset = -1;
  }
  return self;
}

- (void)dealloc {
  DCHECK(_offset < 0);
}

- (BOOL)open {
  DCHECK(_offset < 0);
  _offset = 0;
  return YES;
}

- (NSInteger)read:(void *)buffer maxLength:(NSUInteger)length {
  DCHECK(_offset >= 0);
  NSInteger size = 0;
  if (_offset < [_data length]) {
    size = MIN([_data length] - _offset, length);
    // the original author used the following snippet here and I do not know why
    // bcopy((char*)self.data.bytes + self.offset, buffer, size);
    NSRange range = NSMakeRange(_offset, size);
    [_data getBytes:buffer range:range];
    _offset += size;
  }
  return size;
}

- (BOOL)close {
  DCHECK(_offset >= 0);
  _offset = -1;
  return YES;
}

@end

@implementation OCFWebServerDataResponse (Extensions)

+ (instancetype)responseWithText:(NSString*)text {
  return [[self alloc] initWithText:text];
}

+ (instancetype)responseWithHTML:(NSString*)html {
  return [[self alloc] initWithHTML:html];
}

+ (instancetype)responseWithHTMLTemplate:(NSString*)path variables:(NSDictionary*)variables {
  return [[self alloc] initWithHTMLTemplate:path variables:variables];
}

- (instancetype)initWithText:(NSString*)text {
  NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    DNOT_REACHED();
    return nil;
  }
  return [self initWithData:data contentType:@"text/plain; charset=utf-8"];
}

- (instancetype)initWithHTML:(NSString*)html {
  NSData* data = [html dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    DNOT_REACHED();
    return nil;
  }
  return [self initWithData:data contentType:@"text/html; charset=utf-8"];
}

- (instancetype)initWithHTMLTemplate:(NSString*)path variables:(NSDictionary*)variables {
  NSMutableString* html = [[NSMutableString alloc] initWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  [variables enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* value, BOOL* stop) {
    [html replaceOccurrencesOfString:[NSString stringWithFormat:@"%%%@%%", key] withString:value options:0 range:NSMakeRange(0, html.length)];
  }];
  id response = [self initWithHTML:html];
  return response;
}

@end

@interface OCFWebServerFileResponse () {
  NSString *_path;
  NSUInteger _offset;
  NSUInteger _size;
  int _file;
}

@end

@implementation OCFWebServerFileResponse

#pragma mark - Creating
+ (instancetype)responseWithFile:(NSString*)path {
  return [[[self class] alloc] initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO];
}

+ (instancetype)responseWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [[[self class] alloc] initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range {
  return [[[self class] alloc] initWithFile:path byteRange:range isAttachment:NO];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
  return [[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment];
}

- (instancetype)initWithFile:(NSString*)path {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO];
}

- (instancetype)initWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range {
  return [self initWithFile:path byteRange:range isAttachment:NO];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
  struct stat info;
  if (lstat([path fileSystemRepresentation], &info) || !(info.st_mode & S_IFREG)) {
    DNOT_REACHED();
    return nil;
  }
  NSString* type = OCFWebServerGetMimeTypeForExtension([path pathExtension]);
  if (type == nil) {
    type = kOCFWebServerDefaultMimeType;
  }

  NSUInteger fileSize = (NSUInteger)info.st_size;

  BOOL hasByteRange = ((range.location != NSUIntegerMax) || (range.length > 0));
  if (hasByteRange) {
    if (range.location != NSUIntegerMax) {
      range.location = MIN(range.location, fileSize);
      range.length = MIN(range.length, fileSize - range.location);
    } else {
      range.length = MIN(range.length, fileSize);
      range.location = fileSize - range.length;
    }
    if (range.length == 0) {
      return nil;  // TODO: Return 416 status code and "Content-Range: bytes */{file length}" header
    }
  } else {
    range.location = 0;
    range.length = fileSize;
  }
  
  if ((self = [super initWithContentType:type contentLength:range.length])) {
    _path = [path copy];
    _offset = range.location;
    _size = range.length;

    if (hasByteRange) {
      self.statusCode = 206;
      [self setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), (unsigned long)fileSize] forAdditionalHeader:@"Content-Range"];
      LOG_DEBUG(@"Using content bytes range [%lu-%lu] for file \"%@\"", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), path);
    }

    if (attachment) {  // TODO: Use http://tools.ietf.org/html/rfc5987 to encode file names with special characters instead of using lossy conversion to ISO 8859-1
      NSData* data = [[path lastPathComponent] dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
      NSString* fileName = data ? [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] : nil;
      if (fileName) {
        [self setValue:[NSString stringWithFormat:@"attachment; filename=\"%@\"", fileName] forAdditionalHeader:@"Content-Disposition"];
      } else {
        DNOT_REACHED();
      }
    }
  }
  return self;
}

- (void)dealloc {
  DCHECK(_file <= 0);
}

- (BOOL)open {
  DCHECK(_file <= 0);
  _file = open([_path fileSystemRepresentation], O_NOFOLLOW | O_RDONLY);
  if (_file <= 0) {
    return NO;
  }
  if (lseek(_file, _offset, SEEK_SET) != (off_t)_offset) {
    close(_file);
    return NO;
  }
  return YES;
}

- (NSInteger)read:(void*)buffer maxLength:(NSUInteger)length {
  DCHECK(_file > 0);
  ssize_t outLength = read(_file, buffer, MIN(_size, length));
  _size = outLength >= _size ? 0 : (_size - outLength);
  return outLength;
}

- (BOOL)close {
  DCHECK(_file > 0);
  int result = close(_file);
  _file = 0;
  return result == 0;
}

@end

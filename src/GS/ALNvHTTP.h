#import <Foundation/Foundation.h>

// One HTTP/1.1 request to a GameStream host (Sunshine, Apollo): plain TCP for port 47989, TLS 1.2 (mbedTLS) with our
// client certificate for port 47984. Blocking - run it on a background thread; -cancel works from any thread.
@interface ALNvRequest : NSObject

- (instancetype)initWithAddress:(NSString *)address port:(int)port tls:(BOOL)tls pathAndQuery:(NSString *)path;

@property (nonatomic, copy) NSString *method;               // GET (default) or POST
@property (nonatomic, strong) NSData *body;                 // POST body
@property (nonatomic, copy) NSString *contentType;          // for the body, "text/plain" by default
@property (nonatomic, strong) NSData *pinnedCertificate;    // DER; with TLS the host must present exactly this one
@property (nonatomic) NSTimeInterval connectTimeout;        // seconds, default 5
@property (nonatomic) NSTimeInterval readTimeout;           // seconds, default 10; 0 = wait as long as it takes

// The body (nil on failure). status receives the HTTP status. Errors: ALErrorConnect/Timeout/TLS/Certificate/
// Cancelled/BadResponse/Network.
- (NSData *)runWithStatus:(NSInteger *)status error:(NSError **)error;
- (void)cancel;
@property (atomic, readonly) BOOL isCancelled;

@end

// The XML answers of the host: <root status_code="200" status_message="..."> with simple child elements, and
// <App> groups for /applist.
@interface ALNvXML : NSObject
+ (instancetype)parse:(NSData *)data;                       // nil when it is not XML
@property (nonatomic, readonly) NSInteger statusCode;       // the root's status_code (-1 when missing)
@property (nonatomic, copy, readonly) NSString *statusMessage;
- (NSString *)string:(NSString *)tag;                       // the first element with this name (any depth outside <App>)
- (NSArray *)strings:(NSString *)tag;                       // every one of them
@property (nonatomic, readonly) NSArray *apps;              // NSDictionary per <App>: AppTitle, ID, UUID, IDX, IsHdrSupported
// An NSError for a status other than 200 (code = the status, message = the host's), nil when fine
- (NSError *)statusError;
@end

// Cleans up what the client certificate setup keeps (after the identity was reset)
void ALNvResetTLSIdentity(void);

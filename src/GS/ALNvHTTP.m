#import "ALNvHTTP.h"
#import "ALCrypto.h"
#import "ALCommon.h"

#include "mbedtls/build_info.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/pk.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/error.h"
#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

#define AL_MAX_RESPONSE (24 * 1024 * 1024)
#define AL_IO_CANCELLED  (-0x7F01)    // our own codes for the I/O callbacks (outside mbedTLS' ranges in use)
#define AL_IO_TIMEOUT    (-0x7F02)

#pragma mark - The shared TLS client configuration (our certificate and key)

static pthread_mutex_t g_tlsLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_tlsReady;
static mbedtls_ssl_config g_conf;
static mbedtls_x509_crt g_ownCert;
static mbedtls_pk_context g_ownKey;

static BOOL ALNvSetUpTLS(void)
{
    pthread_mutex_lock(&g_tlsLock);
    if (g_tlsReady) { pthread_mutex_unlock(&g_tlsLock); return YES; }
    ALIdentity *identity = [ALIdentity shared];
    if (!identity.isReady) { pthread_mutex_unlock(&g_tlsLock); return NO; }
    mbedtls_x509_crt_init(&g_ownCert);
    mbedtls_pk_init(&g_ownKey);
    mbedtls_ssl_config_init(&g_conf);
    NSMutableData *cert = [identity.certificatePEM mutableCopy];
    [cert appendBytes:"" length:1];
    NSMutableData *key = [identity.privateKeyPEM mutableCopy];
    [key appendBytes:"" length:1];
    int rc = mbedtls_x509_crt_parse(&g_ownCert, cert.bytes, cert.length);
    if (rc == 0) rc = mbedtls_pk_parse_key(&g_ownKey, key.bytes, key.length, NULL, 0, mbedtls_ctr_drbg_random, ALCryptoRNG());
    if (rc == 0) rc = mbedtls_ssl_config_defaults(&g_conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (rc == 0) {
        // the host's certificate is self-signed: we pin it ourselves after the handshake (see -handshake)
        mbedtls_ssl_conf_authmode(&g_conf, MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_rng(&g_conf, mbedtls_ctr_drbg_random, ALCryptoRNG());
        rc = mbedtls_ssl_conf_own_cert(&g_conf, &g_ownCert, &g_ownKey);
    }
    if (rc != 0) {
        ALLog(@"TLS: client setup failed (-0x%04x)", -rc);
        mbedtls_ssl_config_free(&g_conf);
        mbedtls_pk_free(&g_ownKey);
        mbedtls_x509_crt_free(&g_ownCert);
        pthread_mutex_unlock(&g_tlsLock);
        return NO;
    }
    g_tlsReady = YES;
    pthread_mutex_unlock(&g_tlsLock);
    return YES;
}

void ALNvResetTLSIdentity(void)
{
    pthread_mutex_lock(&g_tlsLock);
    if (g_tlsReady) {
        mbedtls_ssl_config_free(&g_conf);
        mbedtls_pk_free(&g_ownKey);
        mbedtls_x509_crt_free(&g_ownCert);
        g_tlsReady = NO;
    }
    pthread_mutex_unlock(&g_tlsLock);
}

#pragma mark - Request

@interface ALNvRequest ()
@property (atomic) BOOL isCancelled;
@end

@implementation ALNvRequest {
    NSString *_address;
    int _port;
    BOOL _tls;
    NSString *_path;
    volatile int _fd;
    int _ioError;           // AL_IO_* or errno-based failure seen by the callbacks
}

- (instancetype)initWithAddress:(NSString *)address port:(int)port tls:(BOOL)tls pathAndQuery:(NSString *)path
{
    if ((self = [super init])) {
        _address = [address copy];
        _port = port;
        _tls = tls;
        _path = [path copy];
        _method = @"GET";
        _contentType = @"text/plain";
        _connectTimeout = 5;
        _readTimeout = 10;
        _fd = -1;
    }
    return self;
}

- (void)cancel
{
    self.isCancelled = YES;
    int fd = _fd;
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
}

#pragma mark Socket

// Waits until fd is readable/writable: 1 ready, 0 timeout, -1 cancelled or broken. timeoutMs <= 0 = no limit.
- (int)waitFd:(int)fd events:(short)events timeoutMs:(int)timeoutMs
{
    uint64_t deadline = timeoutMs > 0 ? ALMonotonicMicros() + (uint64_t)timeoutMs * 1000 : 0;
    while (1) {
        if (self.isCancelled) return -1;
        int slice = 250;
        if (deadline) {
            uint64_t now = ALMonotonicMicros();
            if (now >= deadline) return 0;
            uint64_t left = (deadline - now) / 1000;
            if (left < (uint64_t)slice) slice = (int)left + 1;
        }
        struct pollfd p = { fd, events, 0 };
        int r = poll(&p, 1, slice);
        if (r > 0) return (p.revents & (POLLERR | POLLNVAL)) && !(p.revents & (POLLIN | POLLOUT)) ? -1 : 1;
        if (r < 0 && errno != EINTR) return -1;
    }
}

- (int)connectWithError:(NSError **)error
{
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    char port[8];
    snprintf(port, sizeof(port), "%d", _port);
    int gai = getaddrinfo([_address UTF8String], port, &hints, &res);
    if (gai != 0 || !res) {
        if (error) *error = ALMakeError(ALErrorDNS, [NSString stringWithFormat:L(@"The address %@ could not be found."), _address]);
        return -1;
    }
    int fd = -1;
    BOOL timedOut = NO;
    for (struct addrinfo *ai = res; ai && fd < 0 && !self.isCancelled; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
        int one = 1;
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
        _fd = s;
        int rc = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            int w = [self waitFd:s events:POLLOUT timeoutMs:(int)(self.connectTimeout * 1000)];
            if (w == 1) {
                int err = 0;
                socklen_t len = sizeof(err);
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len);
                rc = err == 0 ? 0 : -1;
            } else {
                if (w == 0) timedOut = YES;
                rc = -1;
            }
        }
        if (rc == 0) {
            fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) & ~O_NONBLOCK);
            struct timeval tv = { 15, 0 };
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            fd = s;
        } else {
            _fd = -1;
            close(s);
        }
    }
    freeaddrinfo(res);
    if (fd < 0 && error) {
        if (self.isCancelled) *error = ALMakeError(ALErrorCancelled, L(@"Cancelled."));
        else if (timedOut) *error = ALMakeError(ALErrorTimeout, [NSString stringWithFormat:L(@"%@ did not answer."), _address]);
        else *error = ALMakeError(ALErrorConnect, [NSString stringWithFormat:L(@"Could not connect to %@ (port %d)."), _address, _port]);
    }
    return fd;
}

// Plain or TLS reads/writes. Return > 0 bytes, 0 = closed, < 0 = error (_ioError tells which)
static int ALNvSend(void *ctx, const unsigned char *buf, size_t len)
{
    ALNvRequest *self = (__bridge ALNvRequest *)ctx;
    if (self.isCancelled) { self->_ioError = AL_IO_CANCELLED; return AL_IO_CANCELLED; }
    ssize_t n = send(self->_fd, buf, len, 0);
    if (n < 0) {
        if (errno == EINTR) return MBEDTLS_ERR_SSL_WANT_WRITE;
        self->_ioError = self.isCancelled ? AL_IO_CANCELLED : (errno == EAGAIN ? AL_IO_TIMEOUT : -errno);
        return self->_ioError == AL_IO_CANCELLED || self->_ioError == AL_IO_TIMEOUT ? self->_ioError : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    }
    return (int)n;
}

static int ALNvRecv(void *ctx, unsigned char *buf, size_t len)
{
    ALNvRequest *self = (__bridge ALNvRequest *)ctx;
    int w = [self waitFd:self->_fd events:POLLIN timeoutMs:(int)(self.readTimeout * 1000)];
    if (w == 0) { self->_ioError = AL_IO_TIMEOUT; return AL_IO_TIMEOUT; }
    if (w < 0) { self->_ioError = self.isCancelled ? AL_IO_CANCELLED : -EPIPE; return self.isCancelled ? AL_IO_CANCELLED : MBEDTLS_ERR_SSL_INTERNAL_ERROR; }
    ssize_t n = recv(self->_fd, buf, len, 0);
    if (n < 0) {
        if (errno == EINTR || errno == EAGAIN) return MBEDTLS_ERR_SSL_WANT_READ;
        self->_ioError = self.isCancelled ? AL_IO_CANCELLED : -errno;
        return self.isCancelled ? AL_IO_CANCELLED : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    }
    return (int)n;   // 0 = the peer closed
}

- (NSError *)ioErrorWithFallback:(NSString *)what
{
    if (self.isCancelled || _ioError == AL_IO_CANCELLED) return ALMakeError(ALErrorCancelled, L(@"Cancelled."));
    if (_ioError == AL_IO_TIMEOUT) return ALMakeError(ALErrorTimeout, [NSString stringWithFormat:L(@"%@ did not answer."), _address]);
    return ALMakeError(ALErrorNetwork, what);
}

#pragma mark Run

- (NSData *)requestBytes
{
    BOOL v6 = [_address rangeOfString:@":"].location != NSNotFound;
    NSString *host = v6 ? [NSString stringWithFormat:@"[%@]:%d", _address, _port] : [NSString stringWithFormat:@"%@:%d", _address, _port];
    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: Artlight/1.0 (iOS)\r\nAccept: */*\r\nConnection: close\r\n",
                             self.method ?: @"GET", _path, host];
    if (self.body || [self.method isEqualToString:@"POST"]) {
        [head appendFormat:@"Content-Type: %@\r\nContent-Length: %lu\r\n", self.contentType ?: @"text/plain", (unsigned long)self.body.length];
    }
    [head appendString:@"\r\n"];
    NSMutableData *d = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (self.body) [d appendData:self.body];
    return d;
}

// Is a complete response in the buffer? (headers + Content-Length bytes, or a finished chunked body)
static BOOL ALNvResponseComplete(NSData *data)
{
    const char *b = data.bytes;
    NSUInteger n = data.length;
    const char *end = NULL;
    for (NSUInteger i = 0; i + 3 < n; i++) if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n') { end = b + i + 4; break; }
    if (!end) return NO;
    NSString *head = [[NSString alloc] initWithBytes:b length:(NSUInteger)(end - b) encoding:NSISOLatin1StringEncoding];
    NSUInteger bodyLen = n - (NSUInteger)(end - b);
    for (NSString *line in [[head lowercaseString] componentsSeparatedByString:@"\r\n"]) {
        if ([line hasPrefix:@"content-length:"]) return bodyLen >= (NSUInteger)[[line substringFromIndex:15] longLongValue];
        if ([line hasPrefix:@"transfer-encoding:"] && [line rangeOfString:@"chunked"].location != NSNotFound) {
            return bodyLen >= 5 && memcmp(b + n - 5, "0\r\n\r\n", 5) == 0;
        }
    }
    return NO;   // read until the host closes
}

- (NSData *)parseResponse:(NSData *)data status:(NSInteger *)status error:(NSError **)error
{
    const char *b = data.bytes;
    NSUInteger n = data.length, headEnd = NSNotFound;
    for (NSUInteger i = 0; i + 3 < n; i++) if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n') { headEnd = i; break; }
    if (headEnd == NSNotFound) {
        if (error) *error = ALMakeError(ALErrorBadResponse, L(@"The host sent an incomplete answer."));
        return nil;
    }
    NSString *head = [[NSString alloc] initWithBytes:b length:headEnd encoding:NSISOLatin1StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *statusParts = [lines.firstObject componentsSeparatedByString:@" "];
    NSInteger code = statusParts.count >= 2 ? [statusParts[1] integerValue] : 0;
    if (status) *status = code;
    BOOL chunked = NO;
    long long contentLength = -1;
    for (NSString *line in lines) {
        NSString *l = [line lowercaseString];
        if ([l hasPrefix:@"content-length:"]) contentLength = [[l substringFromIndex:15] longLongValue];
        if ([l hasPrefix:@"transfer-encoding:"] && [l rangeOfString:@"chunked"].location != NSNotFound) chunked = YES;
    }
    NSData *body = [data subdataWithRange:NSMakeRange(headEnd + 4, n - headEnd - 4)];
    if (chunked) {
        NSMutableData *out = [NSMutableData data];
        const char *p = body.bytes, *e = p + body.length;
        while (p < e) {
            const char *crlf = p;
            while (crlf + 1 < e && !(crlf[0] == '\r' && crlf[1] == '\n')) crlf++;
            if (crlf + 1 >= e) break;
            unsigned long size = strtoul(p, NULL, 16);
            p = crlf + 2;
            if (size == 0 || p + size > e) break;
            [out appendBytes:p length:size];
            p += size + 2;
        }
        body = out;
    } else if (contentLength >= 0 && (NSUInteger)contentLength < body.length) {
        body = [body subdataWithRange:NSMakeRange(0, (NSUInteger)contentLength)];
    }
    return body;
}

- (NSData *)runWithStatus:(NSInteger *)status error:(NSError **)error
{
    if (status) *status = 0;
    if (_tls && !ALNvSetUpTLS()) {
        if (error) *error = ALMakeError(ALErrorTLS, L(@"The client certificate is not ready yet."));
        return nil;
    }
    int fd = [self connectWithError:error];
    if (fd < 0) return nil;
    NSData *request = [self requestBytes];
    NSMutableData *response = [NSMutableData data];
    NSError *failure = nil;
    unsigned char *buf = malloc(16384);
    if (!_tls) {
        const uint8_t *p = request.bytes;
        NSUInteger left = request.length;
        while (left && !failure) {
            int n = ALNvSend((__bridge void *)self, p, left);
            if (n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n <= 0) failure = [self ioErrorWithFallback:L(@"Sending to the host failed.")];
            else { p += n; left -= (NSUInteger)n; }
        }
        while (!failure) {
            int n = ALNvRecv((__bridge void *)self, buf, 16384);
            if (n == MBEDTLS_ERR_SSL_WANT_READ) continue;
            if (n == 0) break;
            if (n < 0) { failure = [self ioErrorWithFallback:L(@"The connection to the host broke.")]; break; }
            [response appendBytes:buf length:(NSUInteger)n];
            if (response.length > AL_MAX_RESPONSE) { failure = ALMakeError(ALErrorBadResponse, L(@"The host's answer is too large.")); break; }
            if (ALNvResponseComplete(response)) break;
        }
    } else {
        mbedtls_ssl_context ssl;
        mbedtls_ssl_init(&ssl);
        int rc = mbedtls_ssl_setup(&ssl, &g_conf);
        if (rc == 0) rc = mbedtls_ssl_set_hostname(&ssl, NULL);
        mbedtls_ssl_set_bio(&ssl, (__bridge void *)self, ALNvSend, ALNvRecv, NULL);
        while (rc == 0 && (rc = mbedtls_ssl_handshake(&ssl)) != 0) {
            if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) rc = 0;
            else break;
        }
        if (rc != 0) {
            if (rc == AL_IO_CANCELLED || rc == AL_IO_TIMEOUT || _ioError) failure = [self ioErrorWithFallback:L(@"The secure connection to the host failed.")];
            else {
                char text[128];
                mbedtls_strerror(rc, text, sizeof(text));
                ALLog(@"TLS: handshake with %@:%d failed: %s (-0x%04x)", _address, _port, text, -rc);
                failure = ALMakeError(ALErrorTLS, L(@"The secure connection to the host failed."));
            }
        } else if (self.pinnedCertificate.length) {
            const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&ssl);
            if (!peer || peer->raw.len != self.pinnedCertificate.length || memcmp(peer->raw.p, self.pinnedCertificate.bytes, peer->raw.len) != 0) {
                failure = ALMakeError(ALErrorCertificate, L(@"The PC presented a different certificate than when it was paired. Pair it again."));
            }
        }
        const uint8_t *p = request.bytes;
        NSUInteger left = request.length;
        while (!failure && left) {
            int n = mbedtls_ssl_write(&ssl, p, left);
            if (n == MBEDTLS_ERR_SSL_WANT_WRITE || n == MBEDTLS_ERR_SSL_WANT_READ) continue;
            if (n <= 0) { failure = [self ioErrorWithFallback:L(@"Sending to the host failed.")]; break; }
            p += n;
            left -= (NSUInteger)n;
        }
        while (!failure) {
            int n = mbedtls_ssl_read(&ssl, buf, 16384);
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || n == MBEDTLS_ERR_SSL_CONN_EOF) break;
            if (n < 0) {
                // some hosts drop the connection without close_notify once everything was sent
                if (ALNvResponseComplete(response) || (response.length && !_ioError)) break;
                failure = [self ioErrorWithFallback:L(@"The connection to the host broke.")];
                break;
            }
            [response appendBytes:buf length:(NSUInteger)n];
            if (response.length > AL_MAX_RESPONSE) { failure = ALMakeError(ALErrorBadResponse, L(@"The host's answer is too large.")); break; }
            if (ALNvResponseComplete(response)) break;
        }
        if (!failure) mbedtls_ssl_close_notify(&ssl);
        mbedtls_ssl_free(&ssl);
    }
    free(buf);
    _fd = -1;
    close(fd);
    if (!failure && self.isCancelled) failure = ALMakeError(ALErrorCancelled, L(@"Cancelled."));
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    return [self parseResponse:response status:status error:error];
}

@end

#pragma mark - XML

@interface ALNvXML () <NSXMLParserDelegate>
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, copy) NSString *statusMessage;
@property (nonatomic, strong) NSMutableDictionary *values;   // tag -> NSMutableArray of strings
@property (nonatomic, strong) NSMutableArray *appList;
@end

@implementation ALNvXML {
    NSMutableArray *_stack;
    NSMutableString *_text;
    NSMutableDictionary *_currentApp;
}

+ (instancetype)parse:(NSData *)data
{
    if (!data.length) return nil;
    ALNvXML *x = [[ALNvXML alloc] init];
    x.statusCode = -1;
    x.values = [NSMutableDictionary dictionary];
    x.appList = [NSMutableArray array];
    x->_stack = [NSMutableArray array];
    x->_text = [NSMutableString string];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = x;
    BOOL ok = [parser parse];
    if (!ok && x.statusCode == -1) return nil;
    return x;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)attributes
{
    if ([name isEqualToString:@"root"]) {
        NSString *code = attributes[@"status_code"];
        // GFE sometimes says 0xFFFFFFFF: as a 32-bit signed number that is -1
        if (code) self.statusCode = (NSInteger)(int32_t)(uint32_t)[code longLongValue];
        self.statusMessage = attributes[@"status_message"];
    } else if ([name isEqualToString:@"App"]) {
        _currentApp = [NSMutableDictionary dictionary];
    }
    [_stack addObject:name];
    [_text setString:@""];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q
{
    if ([name isEqualToString:@"App"]) {
        if (_currentApp) [self.appList addObject:_currentApp];
        _currentApp = nil;
    } else if (![name isEqualToString:@"root"]) {
        NSString *value = [_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (_currentApp) {
            _currentApp[name] = value;
        } else {
            NSMutableArray *list = self.values[name];
            if (!list) { list = [NSMutableArray array]; self.values[name] = list; }
            [list addObject:value];
        }
    }
    [_text setString:@""];
    if (_stack.count) [_stack removeLastObject];
}

- (NSString *)string:(NSString *)tag
{
    return [self.values[tag] firstObject];
}

- (NSArray *)strings:(NSString *)tag
{
    return self.values[tag] ?: @[];
}

- (NSArray *)apps
{
    return self.appList;
}

- (NSError *)statusError
{
    if (self.statusCode == 200) return nil;
    NSString *message = self.statusMessage.length ? self.statusMessage : [NSString stringWithFormat:L(@"The host answered with error %ld."), (long)self.statusCode];
    return ALMakeError(self.statusCode, message);
}

@end

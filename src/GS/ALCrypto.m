#define MBEDTLS_ALLOW_PRIVATE_ACCESS 1
#import "ALCrypto.h"
#import "ALUtils.h"
#import "ALCommon.h"

#include "mbedtls/build_info.h"
#include "mbedtls/pk.h"
#include "mbedtls/rsa.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/sha256.h"
#include "mbedtls/sha1.h"
#include "mbedtls/aes.h"
#include "psa/crypto.h"
#include <pthread.h>
#include <sys/stat.h>
#include <Security/SecRandom.h>

#pragma mark - Random numbers

static mbedtls_entropy_context g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static BOOL g_drbgReady;

// One DRBG for the process (mbedTLS locks it itself: MBEDTLS_THREADING_C)
static mbedtls_ctr_drbg_context *ALDrbg(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mbedtls_entropy_init(&g_entropy);
        mbedtls_ctr_drbg_init(&g_drbg);
        const char *personal = "artlight-gamestream";
        int rc = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy, (const unsigned char *)personal, strlen(personal));
        g_drbgReady = rc == 0;
        if (rc) ALLog(@"Crypto: DRBG seed failed (-0x%04x)", -rc);
    });
    return g_drbgReady ? &g_drbg : NULL;
}

NSData *ALRandomBytes(NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithLength:count];
    if (count && SecRandomCopyBytes(kSecRandomDefault, count, d.mutableBytes) != 0) {
        mbedtls_ctr_drbg_context *drbg = ALDrbg();
        if (!drbg || mbedtls_ctr_drbg_random(drbg, d.mutableBytes, count) != 0) {
            uint8_t *b = d.mutableBytes;
            for (NSUInteger i = 0; i < count; i++) b[i] = (uint8_t)arc4random_uniform(256);
        }
    }
    return d;
}

#pragma mark - Hashes and AES

NSData *ALSHA256(NSData *data)
{
    unsigned char out[32];
    mbedtls_sha256(data.bytes, data.length, out, 0);
    return [NSData dataWithBytes:out length:sizeof(out)];
}

NSData *ALSHA1(NSData *data)
{
    unsigned char out[20];
    mbedtls_sha1(data.bytes, data.length, out);
    return [NSData dataWithBytes:out length:sizeof(out)];
}

NSData *ALAESECB(NSData *data, NSData *key, BOOL encrypt)
{
    if (key.length < 16) return nil;
    NSUInteger n = (data.length + 15) / 16 * 16;
    NSMutableData *in = [NSMutableData dataWithLength:n];
    memcpy(in.mutableBytes, data.bytes, data.length);
    NSMutableData *out = [NSMutableData dataWithLength:n];
    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    int rc = encrypt ? mbedtls_aes_setkey_enc(&aes, key.bytes, 128) : mbedtls_aes_setkey_dec(&aes, key.bytes, 128);
    for (NSUInteger off = 0; rc == 0 && off < n; off += 16) {
        rc = mbedtls_aes_crypt_ecb(&aes, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
                                   (const unsigned char *)in.bytes + off, (unsigned char *)out.mutableBytes + off);
    }
    mbedtls_aes_free(&aes);
    return rc == 0 ? out : nil;
}

void *ALCryptoRNG(void)
{
    return ALDrbg();
}

void ALCryptoInit(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        psa_status_t st = psa_crypto_init();
        if (st != PSA_SUCCESS) ALLog(@"Crypto: psa_crypto_init failed (%d)", (int)st);
        ALDrbg();
    });
}

#pragma mark - Certificates

@interface ALCertificate ()
@property (nonatomic, strong) NSData *der;
@property (nonatomic, strong) NSData *signature;
@end

@implementation ALCertificate {
    mbedtls_x509_crt _crt;
    BOOL _parsed;
}

+ (instancetype)certificateWithData:(NSData *)pemOrDer
{
    if (!pemOrDer.length) return nil;
    ALCertificate *c = [[ALCertificate alloc] init];
    mbedtls_x509_crt_init(&c->_crt);
    // PEM must be NUL-terminated and its length must count the NUL
    NSMutableData *buf = [pemOrDer mutableCopy];
    const uint8_t *b = pemOrDer.bytes;
    BOOL pem = pemOrDer.length > 10 && memcmp(b, "-----", 5) == 0;
    if (pem && b[pemOrDer.length - 1] != 0) [buf appendBytes:"" length:1];
    int rc = mbedtls_x509_crt_parse(&c->_crt, buf.bytes, buf.length);
    if (rc != 0) {
        ALLog(@"Crypto: certificate does not parse (-0x%04x)", -rc);
        mbedtls_x509_crt_free(&c->_crt);
        return nil;
    }
    c->_parsed = YES;
    c.der = [NSData dataWithBytes:c->_crt.raw.p length:c->_crt.raw.len];
    c.signature = [NSData dataWithBytes:c->_crt.sig.p length:c->_crt.sig.len];
    return c;
}

- (void)dealloc
{
    if (_parsed) mbedtls_x509_crt_free(&_crt);
}

- (BOOL)verifySHA256Signature:(NSData *)signature ofData:(NSData *)data
{
    if (!_parsed || !signature.length) return NO;
    unsigned char hash[32];
    mbedtls_sha256(data.bytes, data.length, hash, 0);
    int rc = mbedtls_pk_verify(&_crt.pk, MBEDTLS_MD_SHA256, hash, sizeof(hash), signature.bytes, signature.length);
    if (rc != 0) ALLog(@"Crypto: signature check failed (-0x%04x)", -rc);
    return rc == 0;
}

@end

#pragma mark - Identity

@interface ALIdentity ()
@property (nonatomic) BOOL isReady;
@property (nonatomic, strong) NSData *certificatePEM;
@property (nonatomic, strong) NSData *certificateDER;
@property (nonatomic, strong) NSData *certificateSignature;
@property (nonatomic, strong) NSData *privateKeyPEM;
@end

@implementation ALIdentity {
    mbedtls_pk_context _key;
    BOOL _keyLoaded;
    pthread_mutex_t _lock;
    NSMutableArray *_waiting;
    BOOL _working;
}

+ (instancetype)shared
{
    static ALIdentity *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ALIdentity alloc] init]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutex_init(&_lock, NULL);
        mbedtls_pk_init(&_key);
        _waiting = [NSMutableArray array];
    }
    return self;
}

+ (NSString *)folder
{
    NSString *dir = [[ALUtils appDataPath] stringByAppendingPathComponent:@"identity"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

- (void)prepareWithCompletion:(void (^)(NSError *error))completion
{
    if (self.isReady) { if (completion) completion(nil); return; }
    if (completion) [_waiting addObject:[completion copy]];
    if (_working) return;
    _working = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL ok = [self loadFromDisk] || [self generateWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_working = NO;
            self.isReady = ok;
            NSArray *waiting = [self->_waiting copy];
            [self->_waiting removeAllObjects];
            for (void (^block)(NSError *) in waiting) block(ok ? nil : (error ?: ALMakeError(ALErrorTLS, L(@"Could not create the client certificate."))));
        });
    });
}

- (BOOL)adoptKeyPEM:(NSData *)keyPEM certPEM:(NSData *)certPEM
{
    ALCertificate *cert = [ALCertificate certificateWithData:certPEM];
    if (!cert) return NO;
    NSMutableData *k = [keyPEM mutableCopy];
    [k appendBytes:"" length:1];
    mbedtls_ctr_drbg_context *drbg = ALDrbg();
    pthread_mutex_lock(&_lock);
    if (_keyLoaded) { mbedtls_pk_free(&_key); mbedtls_pk_init(&_key); _keyLoaded = NO; }
    int rc = mbedtls_pk_parse_key(&_key, k.bytes, k.length, NULL, 0, mbedtls_ctr_drbg_random, drbg);
    _keyLoaded = rc == 0;
    pthread_mutex_unlock(&_lock);
    if (rc != 0) { ALLog(@"Identity: key does not parse (-0x%04x)", -rc); return NO; }
    NSData *pemNoNul = certPEM;
    if (certPEM.length && ((const char *)certPEM.bytes)[certPEM.length - 1] == 0) pemNoNul = [certPEM subdataWithRange:NSMakeRange(0, certPEM.length - 1)];
    self.certificatePEM = pemNoNul;
    self.certificateDER = cert.der;
    self.certificateSignature = cert.signature;
    self.privateKeyPEM = keyPEM;
    return YES;
}

- (BOOL)loadFromDisk
{
    NSString *dir = [ALIdentity folder];
    NSData *key = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"client.key"]];
    NSData *cert = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"client.crt"]];
    if (!key.length || !cert.length) return NO;
    BOOL ok = [self adoptKeyPEM:key certPEM:cert];
    if (ok) ALLog(@"Identity: loaded");
    return ok;
}

- (BOOL)generateWithError:(NSError **)error
{
    uint64_t t0 = ALMonotonicMicros();
    mbedtls_ctr_drbg_context *drbg = ALDrbg();
    if (!drbg) { if (error) *error = ALMakeError(ALErrorTLS, @"no random numbers"); return NO; }
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    mbedtls_x509write_cert crt;
    mbedtls_x509write_crt_init(&crt);
    unsigned char *buf = malloc(16384);
    int rc = buf ? 0 : -1;
    NSData *keyPEM = nil, *certPEM = nil;
    if (rc == 0) rc = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
    if (rc == 0) rc = mbedtls_rsa_gen_key(mbedtls_pk_rsa(pk), mbedtls_ctr_drbg_random, drbg, 2048, 65537);
    if (rc == 0) {
        ALLog(@"Identity: RSA-2048 key made in %.1f s", (ALMonotonicMicros() - t0) / 1e6);
        mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&crt, &pk);
        mbedtls_x509write_crt_set_issuer_key(&crt, &pk);
        unsigned char serial[8];
        mbedtls_ctr_drbg_random(drbg, serial, sizeof(serial));
        serial[0] &= 0x7f;   // a positive number
        serial[0] |= 0x01;
        rc = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial));
    }
    if (rc == 0) rc = mbedtls_x509write_crt_set_subject_name(&crt, "CN=NVIDIA GameStream Client");
    if (rc == 0) rc = mbedtls_x509write_crt_set_issuer_name(&crt, "CN=NVIDIA GameStream Client");
    if (rc == 0) rc = mbedtls_x509write_crt_set_validity(&crt, "20240101000000", "20491231235959");
    if (rc == 0) rc = mbedtls_x509write_crt_pem(&crt, buf, 16384, mbedtls_ctr_drbg_random, drbg);
    if (rc == 0) {
        certPEM = [NSData dataWithBytes:buf length:strlen((const char *)buf)];
        rc = mbedtls_pk_write_key_pem(&pk, buf, 16384);
    }
    if (rc == 0) keyPEM = [NSData dataWithBytes:buf length:strlen((const char *)buf)];
    if (buf) { memset(buf, 0, 16384); free(buf); }
    mbedtls_x509write_crt_free(&crt);
    mbedtls_pk_free(&pk);
    if (rc != 0 || !keyPEM || !certPEM) {
        ALLog(@"Identity: generation failed (-0x%04x)", -rc);
        if (error) *error = ALMakeError(ALErrorTLS, [NSString stringWithFormat:L(@"Could not create the client certificate (error %d)."), rc]);
        return NO;
    }
    NSString *dir = [ALIdentity folder];
    NSString *keyPath = [dir stringByAppendingPathComponent:@"client.key"], *certPath = [dir stringByAppendingPathComponent:@"client.crt"];
    [keyPEM writeToFile:keyPath atomically:YES];
    [certPEM writeToFile:certPath atomically:YES];
    chmod([keyPath fileSystemRepresentation], 0600);
    ALLog(@"Identity: certificate made in %.1f s", (ALMonotonicMicros() - t0) / 1e6);
    return [self adoptKeyPEM:keyPEM certPEM:certPEM];
}

- (NSData *)signSHA256:(NSData *)data
{
    unsigned char hash[32];
    mbedtls_sha256(data.bytes, data.length, hash, 0);
    unsigned char sig[MBEDTLS_PK_SIGNATURE_MAX_SIZE];
    size_t len = 0;
    pthread_mutex_lock(&_lock);
    int rc = _keyLoaded ? mbedtls_pk_sign(&_key, MBEDTLS_MD_SHA256, hash, sizeof(hash), sig, sizeof(sig), &len, mbedtls_ctr_drbg_random, ALDrbg()) : -1;
    pthread_mutex_unlock(&_lock);
    if (rc != 0) { ALLog(@"Identity: signing failed (-0x%04x)", -rc); return nil; }
    return [NSData dataWithBytes:sig length:len];
}

- (void)reset
{
    NSString *dir = [ALIdentity folder];
    [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"client.key"] error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"client.crt"] error:NULL];
    pthread_mutex_lock(&_lock);
    if (_keyLoaded) { mbedtls_pk_free(&_key); mbedtls_pk_init(&_key); _keyLoaded = NO; }
    pthread_mutex_unlock(&_lock);
    self.isReady = NO;
    self.certificatePEM = self.certificateDER = self.certificateSignature = self.privateKeyPEM = nil;
}

@end

#pragma mark - Self test

NSString *ALCryptoSelfTest(void)
{
    NSMutableArray *lines = [NSMutableArray array];
    // SHA-256("abc")
    NSData *h = ALSHA256([@"abc" dataUsingEncoding:NSUTF8StringEncoding]);
    BOOL shaOK = [ALHexString(h) isEqualToString:@"BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"];
    [lines addObject:[NSString stringWithFormat:@"SHA-256 %@", shaOK ? @"OK" : @"FAILED"]];
    // FIPS-197 AES-128 known answer
    NSData *key = ALDataFromHex(@"000102030405060708090A0B0C0D0E0F");
    NSData *pt = ALDataFromHex(@"00112233445566778899AABBCCDDEEFF");
    NSData *ct = ALAESECB(pt, key, YES);
    BOOL aesOK = [ALHexString(ct) isEqualToString:@"69C4E0D86A7B0430D8CDB78070B4C55A"] && [ALAESECB(ct, key, NO) isEqualToData:pt];
    [lines addObject:[NSString stringWithFormat:@"AES-128-ECB %@", aesOK ? @"OK" : @"FAILED"]];
    ALIdentity *identity = [ALIdentity shared];
    if (identity.isReady) {
        NSData *msg = ALRandomBytes(16);
        NSData *sig = [identity signSHA256:msg];
        ALCertificate *mine = [ALCertificate certificateWithData:identity.certificatePEM];
        BOOL rsaOK = sig && [mine verifySHA256Signature:sig ofData:msg];
        [lines addObject:[NSString stringWithFormat:@"RSA sign/verify %@ (sig %lu bytes, cert sig %lu bytes)", rsaOK ? @"OK" : @"FAILED",
                          (unsigned long)sig.length, (unsigned long)identity.certificateSignature.length]];
    } else {
        [lines addObject:@"identity not ready"];
    }
    return [lines componentsJoinedByString:@", "];
}

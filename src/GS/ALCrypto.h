#import <Foundation/Foundation.h>

// The client's GameStream identity and the crypto the pairing needs, on top of mbedTLS.
//
// The identity is an RSA-2048 key with a self-signed X.509 certificate (CN "NVIDIA GameStream Client", the name
// every Moonlight-family client uses), made once on the device and kept in Library/Application Support/Artlight.
// Hosts (Sunshine, Apollo) remember the certificate when pairing and know us by it afterwards.
@interface ALIdentity : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isReady;
// Loads the identity, or makes a new one (RSA key generation takes seconds to a minute on an A5) on a background
// thread. The completion runs on the main thread; error is nil on success.
- (void)prepareWithCompletion:(void (^)(NSError *error))completion;

@property (nonatomic, readonly) NSData *certificatePEM;        // without a trailing NUL
@property (nonatomic, readonly) NSData *certificateDER;
@property (nonatomic, readonly) NSData *certificateSignature;  // the signature value inside our certificate
@property (nonatomic, readonly) NSData *privateKeyPEM;

// RSA PKCS#1 v1.5 signature of SHA-256(data) with our key (nil on failure)
- (NSData *)signSHA256:(NSData *)data;
// Removes the identity: every host has to be paired again
- (void)reset;

@end

// Helpers (thread safe)
NSData *ALSHA256(NSData *data);
NSData *ALSHA1(NSData *data);
NSData *ALRandomBytes(NSUInteger count);
// AES-128-ECB without padding (the length must be a multiple of 16; a shorter tail is zero-padded first)
NSData *ALAESECB(NSData *data, NSData *key, BOOL encrypt);

// A certificate given as PEM (as the host sends it while pairing) or DER
@interface ALCertificate : NSObject
+ (instancetype)certificateWithData:(NSData *)pemOrDer;    // nil when it does not parse
@property (nonatomic, readonly) NSData *der;
@property (nonatomic, readonly) NSData *signature;          // the signature value of the certificate itself
- (BOOL)verifySHA256Signature:(NSData *)signature ofData:(NSData *)data;
@end

// The PSA crypto layer moonlight-common-c uses; call once before streaming (idempotent)
void ALCryptoInit(void);
// The process-wide mbedTLS CTR-DRBG (an mbedtls_ctr_drbg_context *, for mbedtls_ctr_drbg_random), NULL if unseeded
void *ALCryptoRNG(void);
// Self test for the debug command: hashes, AES-ECB known answers; returns a short report
NSString *ALCryptoSelfTest(void);

/* SPDX-License-Identifier: BSD-2-Clause */
/* The Security.framework calls asString() makes, for the FreeBSD build (no Security headers in the tree there). */
#ifndef LSS_SECURITY_H
#define LSS_SECURITY_H
#include <CoreFoundation/CoreFoundation.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct __SecIdentity *SecIdentityRef;
typedef struct __SecCertificate *SecCertificateRef;
typedef struct __SecKey *SecKeyRef;
CFTypeID SecIdentityGetTypeID(void);
CFTypeID SecCertificateGetTypeID(void);
CFTypeID SecKeyGetTypeID(void);
OSStatus SecIdentityCopyCertificate(SecIdentityRef identity, SecCertificateRef *certificate);
OSStatus SecIdentityCopyPrivateKey(SecIdentityRef identity, SecKeyRef *key);
CFStringRef SecCertificateCopySubjectSummary(SecCertificateRef certificate);
#ifdef __cplusplus
}
#endif
#endif

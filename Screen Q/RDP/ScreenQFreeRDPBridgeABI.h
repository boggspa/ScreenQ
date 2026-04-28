//
//  ScreenQFreeRDPBridgeABI.h
//  Screen Q
//
//  C ABI expected by FreeRDPEngine.swift. A production bridge should wrap
//  FreeRDP behind these functions and copy all config/input strings before
//  returning from sq_freerdp_connect or sq_freerdp_send_input.
//

#ifndef SCREENQ_FREERDP_BRIDGE_ABI_H
#define SCREENQ_FREERDP_BRIDGE_ABI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum SQFreeRDPCertificateTrust {
    SQFreeRDPCertificateTrustNone = 0,
    SQFreeRDPCertificateTrustOnce = 1,
    SQFreeRDPCertificateTrustAlways = 2,
    SQFreeRDPCertificateTrustReject = 3,
} SQFreeRDPCertificateTrust;

typedef enum SQFreeRDPEventKind {
    SQFreeRDPEventConnecting = 1,
    SQFreeRDPEventCredentialsRequired = 2,
    SQFreeRDPEventCertificateTrustRequired = 3,
    SQFreeRDPEventSecurityNegotiated = 4,
    SQFreeRDPEventConnected = 5,
    SQFreeRDPEventFrame = 6,
    SQFreeRDPEventDisconnected = 7,
    SQFreeRDPEventError = 8,
} SQFreeRDPEventKind;

typedef enum SQFreeRDPInputKind {
    SQFreeRDPInputPointerMove = 1,
    SQFreeRDPInputPointerDown = 2,
    SQFreeRDPInputPointerUp = 3,
    SQFreeRDPInputScroll = 4,
    SQFreeRDPInputKeyDown = 5,
    SQFreeRDPInputKeyUp = 6,
    SQFreeRDPInputTextInput = 7,
} SQFreeRDPInputKind;

typedef struct SQFreeRDPConfig {
    const char *host;
    uint16_t port;
    const char *username;
    const char *password;
    const char *domain;
    const char *gatewayHost;
    const char *gatewayUsername;
    int32_t desktopWidth;
    int32_t desktopHeight;
    int32_t dynamicResolution;
    int32_t administrativeSession;
    int32_t connectToConsole;
    int32_t redirectClipboard;
    int32_t redirectAudio;
    int32_t allowFontSmoothing;
    int32_t certificateTrust;
    const char *trustedCertificateFingerprintSHA256;
} SQFreeRDPConfig;

typedef struct SQFreeRDPInputEvent {
    int32_t kind;
    double x;
    double y;
    int32_t button;
    double deltaX;
    double deltaY;
    const char *keyName;
    const char *text;
    uint32_t modifiers;
} SQFreeRDPInputEvent;

typedef struct SQFreeRDPEvent {
    int32_t kind;
    int32_t statusCode;
    const char *message;
    const char *host;
    const char *username;
    const char *domain;

    int32_t width;
    int32_t height;
    int32_t bytesPerRow;
    const void *frameData;
    size_t frameDataLength;

    const char *tlsProtocol;
    int32_t nlaSucceeded;
    int32_t transportEncrypted;
    int32_t authenticated;
    int32_t identityVerified;

    const char *certificateSubject;
    const char *certificateIssuer;
    const char *certificateFingerprintSHA256;
    const char *certificateHost;
    double certificateValidFromUnix;
    double certificateValidUntilUnix;
} SQFreeRDPEvent;

typedef void (*SQFreeRDPEventCallback)(void *context, const SQFreeRDPEvent *event);

void *sq_freerdp_create_session(void);
void sq_freerdp_destroy_session(void *session);
void sq_freerdp_set_event_callback(void *session, SQFreeRDPEventCallback callback, void *context);
int32_t sq_freerdp_connect(void *session, const SQFreeRDPConfig *config);
void sq_freerdp_disconnect(void *session);
int32_t sq_freerdp_send_input(void *session, const SQFreeRDPInputEvent *input);
int32_t sq_freerdp_resize(void *session, int32_t width, int32_t height, double scale);
const char *sq_freerdp_last_error(void *session);

#ifdef __cplusplus
}
#endif

#endif

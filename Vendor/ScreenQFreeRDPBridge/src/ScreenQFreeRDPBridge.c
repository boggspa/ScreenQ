#include "ScreenQFreeRDPBridgeABI.h"

#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/settings_keys.h>
#include <freerdp/update.h>

#include <ctype.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct SQBridgeSession SQBridgeSession;

typedef struct SQBridgeContext {
    rdpContext context;
    SQBridgeSession *session;
} SQBridgeContext;

struct SQBridgeSession {
    pthread_mutex_t lock;
    pthread_t thread;
    bool threadStarted;
    bool stopRequested;

    freerdp *instance;
    bool gdiInitialized;

    SQFreeRDPEventCallback callback;
    void *callbackContext;

    char *host;
    uint16_t port;
    char *username;
    char *password;
    char *domain;
    char *gatewayHost;
    char *gatewayUsername;
    char *trustedCertificateFingerprint;
    int32_t desktopWidth;
    int32_t desktopHeight;
    int32_t dynamicResolution;
    int32_t administrativeSession;
    int32_t connectToConsole;
    int32_t redirectClipboard;
    int32_t redirectAudio;
    int32_t allowFontSmoothing;
    int32_t certificateTrust;

    int32_t currentWidth;
    int32_t currentHeight;
    uint64_t lastFrameHash;
    uint64_t lastFrameEmitUsec;
    bool certificateReviewPending;
    bool trustedCertificateMatched;
    char *lastError;
};

typedef struct SQKeyMap {
    const char *name;
    uint8_t scanCode;
    uint16_t flags;
} SQKeyMap;

enum {
    SQKeyModifierShift = 1u << 0,
    SQKeyModifierControl = 1u << 1,
    SQKeyModifierOption = 1u << 2,
    SQKeyModifierCommand = 1u << 3,
};

static char *sq_strdup_or_null(const char *value) {
    if (!value || value[0] == '\0') {
        return NULL;
    }
    return strdup(value);
}

static void sq_free_string(char **value) {
    if (*value) {
        free(*value);
        *value = NULL;
    }
}

static void sq_set_last_error(SQBridgeSession *session, const char *message) {
    if (!session) {
        return;
    }

    pthread_mutex_lock(&session->lock);
    sq_free_string(&session->lastError);
    session->lastError = sq_strdup_or_null(message);
    pthread_mutex_unlock(&session->lock);
}

static void sq_set_last_errorf(SQBridgeSession *session, const char *prefix, const char *detail) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "%s%s%s", prefix ? prefix : "", detail ? ": " : "", detail ? detail : "");
    sq_set_last_error(session, buffer);
}

static void sq_emit(SQBridgeSession *session, const SQFreeRDPEvent *event) {
    if (!session || !event) {
        return;
    }

    SQFreeRDPEventCallback callback = NULL;
    void *context = NULL;

    pthread_mutex_lock(&session->lock);
    callback = session->callback;
    context = session->callbackContext;
    pthread_mutex_unlock(&session->lock);

    if (callback) {
        callback(context, event);
    }
}

static void sq_emit_simple(SQBridgeSession *session, SQFreeRDPEventKind kind, const char *message) {
    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = kind;
    event.message = message;
    event.host = session ? session->host : NULL;
    event.username = session ? session->username : NULL;
    event.domain = session ? session->domain : NULL;
    sq_emit(session, &event);
}

static void sq_emit_error(SQBridgeSession *session, int32_t statusCode, const char *message) {
    char *messageCopy = sq_strdup_or_null(message);
    sq_set_last_error(session, messageCopy ? messageCopy : message);
    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = SQFreeRDPEventError;
    event.statusCode = statusCode;
    event.message = messageCopy ? messageCopy : message;
    event.host = session ? session->host : NULL;
    sq_emit(session, &event);
    sq_free_string(&messageCopy);
}

static void sq_emit_connected(SQBridgeSession *session) {
    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = SQFreeRDPEventConnected;
    event.host = session->host;
    event.width = session->currentWidth;
    event.height = session->currentHeight;
    sq_emit(session, &event);
}

static void sq_emit_security(SQBridgeSession *session, bool identityVerified) {
    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = SQFreeRDPEventSecurityNegotiated;
    event.host = session->host;
    event.tlsProtocol = "FreeRDP negotiated";
    event.transportEncrypted = 1;
    event.authenticated = 1;
    event.nlaSucceeded = 0;
    event.identityVerified = identityVerified ? 1 : 0;
    sq_emit(session, &event);
}

static uint64_t sq_now_usec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return ((uint64_t)tv.tv_sec * 1000000u) + (uint64_t)tv.tv_usec;
}

static uint64_t sq_hash_frame(const void *data, size_t length) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = 1469598103934665603ull;
    for (size_t index = 0; index < length; index++) {
        hash ^= (uint64_t)bytes[index];
        hash *= 1099511628211ull;
    }
    hash ^= (uint64_t)length;
    hash *= 1099511628211ull;
    return hash;
}

static bool sq_emit_frame(SQBridgeSession *session, rdpContext *context) {
    if (!session || !context || !context->gdi || !context->gdi->primary_buffer) {
        return false;
    }

    rdpGdi *gdi = context->gdi;
    if (gdi->width <= 0 || gdi->height <= 0 || gdi->stride <= 0) {
        return false;
    }

    session->currentWidth = gdi->width;
    session->currentHeight = gdi->height;
    size_t frameLength = (size_t)gdi->stride * (size_t)gdi->height;
    uint64_t frameHash = sq_hash_frame(gdi->primary_buffer, frameLength);
    uint64_t nowUsec = sq_now_usec();
    if (session->lastFrameHash == frameHash &&
        session->lastFrameEmitUsec != 0 &&
        nowUsec - session->lastFrameEmitUsec < 250000u) {
        return true;
    }
    session->lastFrameHash = frameHash;
    session->lastFrameEmitUsec = nowUsec;

    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = SQFreeRDPEventFrame;
    event.host = session->host;
    event.width = gdi->width;
    event.height = gdi->height;
    event.bytesPerRow = (int32_t)gdi->stride;
    event.frameData = gdi->primary_buffer;
    event.frameDataLength = frameLength;
    sq_emit(session, &event);
    return true;
}

static bool sq_copy_config(SQBridgeSession *session, const SQFreeRDPConfig *config) {
    if (!session || !config || !config->host || config->host[0] == '\0') {
        sq_set_last_error(session, "RDP host is required.");
        return false;
    }

    sq_free_string(&session->host);
    sq_free_string(&session->username);
    sq_free_string(&session->password);
    sq_free_string(&session->domain);
    sq_free_string(&session->gatewayHost);
    sq_free_string(&session->gatewayUsername);
    sq_free_string(&session->trustedCertificateFingerprint);

    session->host = sq_strdup_or_null(config->host);
    session->username = sq_strdup_or_null(config->username);
    session->password = sq_strdup_or_null(config->password);
    session->domain = sq_strdup_or_null(config->domain);
    session->gatewayHost = sq_strdup_or_null(config->gatewayHost);
    session->gatewayUsername = sq_strdup_or_null(config->gatewayUsername);
    session->trustedCertificateFingerprint = sq_strdup_or_null(config->trustedCertificateFingerprintSHA256);
    session->port = config->port == 0 ? 3389 : config->port;
    session->desktopWidth = config->desktopWidth > 0 ? config->desktopWidth : 1440;
    session->desktopHeight = config->desktopHeight > 0 ? config->desktopHeight : 900;
    session->dynamicResolution = config->dynamicResolution;
    session->administrativeSession = config->administrativeSession;
    session->connectToConsole = config->connectToConsole;
    session->redirectClipboard = config->redirectClipboard;
    session->redirectAudio = config->redirectAudio;
    session->allowFontSmoothing = config->allowFontSmoothing;
    session->certificateTrust = config->certificateTrust;
    session->currentWidth = session->desktopWidth;
    session->currentHeight = session->desktopHeight;
    session->lastFrameHash = 0;
    session->lastFrameEmitUsec = 0;
    session->certificateReviewPending = false;
    session->trustedCertificateMatched = false;

    if (!session->host) {
        sq_set_last_error(session, "Failed to copy RDP host.");
        return false;
    }
    return true;
}

static bool sq_set_string_setting(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
    if (!value) {
        return true;
    }
    return freerdp_settings_set_string(settings, key, value) ? true : false;
}

static bool sq_apply_settings(SQBridgeSession *session, rdpSettings *settings) {
    if (!settings) {
        sq_set_last_error(session, "FreeRDP settings were unavailable.");
        return false;
    }

    bool ok = true;
    ok = ok && sq_set_string_setting(settings, FreeRDP_ServerHostname, session->host);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, session->port);
    ok = ok && sq_set_string_setting(settings, FreeRDP_Username, session->username);
    ok = ok && sq_set_string_setting(settings, FreeRDP_Password, session->password);
    ok = ok && sq_set_string_setting(settings, FreeRDP_Domain, session->domain);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (uint32_t)session->desktopWidth);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (uint32_t)session->desktopHeight);
    ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, session->dynamicResolution != 0);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_ConsoleSession,
                                         session->connectToConsole != 0 || session->administrativeSession != 0);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, session->redirectClipboard != 0);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, session->redirectAudio != 0);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_AllowFontSmoothing, session->allowFontSmoothing != 0);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, FALSE);

    if (session->gatewayHost) {
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE);
        ok = ok && sq_set_string_setting(settings, FreeRDP_GatewayHostname, session->gatewayHost);
        ok = ok && sq_set_string_setting(settings, FreeRDP_GatewayUsername, session->gatewayUsername ? session->gatewayUsername : session->username);
        ok = ok && sq_set_string_setting(settings, FreeRDP_GatewayPassword, session->password);
        ok = ok && sq_set_string_setting(settings, FreeRDP_GatewayDomain, session->domain);
    }

    if (!ok) {
        sq_set_last_error(session, "Failed to apply FreeRDP settings.");
    }
    return ok;
}

static SQBridgeSession *sq_session_from_instance(freerdp *instance) {
    if (!instance || !instance->context) {
        return NULL;
    }
    SQBridgeContext *context = (SQBridgeContext *)instance->context;
    return context->session;
}

static BOOL sq_pre_connect(freerdp *instance) {
    SQBridgeSession *session = sq_session_from_instance(instance);
    if (!session) {
        return FALSE;
    }
    sq_emit_simple(session, SQFreeRDPEventConnecting, "Negotiating RDP transport.");
    return TRUE;
}

static BOOL sq_begin_paint(rdpContext *context) {
    (void)context;
    return TRUE;
}

static BOOL sq_end_paint(rdpContext *context) {
    if (!context) {
        return FALSE;
    }
    SQBridgeSession *session = ((SQBridgeContext *)context)->session;
    return sq_emit_frame(session, context) ? TRUE : TRUE;
}

static BOOL sq_desktop_resize(rdpContext *context) {
    if (!context) {
        return FALSE;
    }
    SQBridgeSession *session = ((SQBridgeContext *)context)->session;
    if (context->gdi) {
        session->currentWidth = context->gdi->width;
        session->currentHeight = context->gdi->height;
    }
    sq_emit_connected(session);
    sq_emit_frame(session, context);
    return TRUE;
}

static BOOL sq_post_connect(freerdp *instance) {
    SQBridgeSession *session = sq_session_from_instance(instance);
    if (!session || !instance || !instance->context || !instance->context->update) {
        return FALSE;
    }

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        sq_set_last_error(session, "FreeRDP failed to initialize the GDI framebuffer.");
        return FALSE;
    }

    session->gdiInitialized = true;
    if (instance->context->gdi) {
        session->currentWidth = instance->context->gdi->width;
        session->currentHeight = instance->context->gdi->height;
    }

    rdpUpdate *update = instance->context->update;
    update->BeginPaint = sq_begin_paint;
    update->EndPaint = sq_end_paint;
    update->DesktopResize = sq_desktop_resize;

    sq_emit_security(session, session->trustedCertificateMatched ||
                                  session->certificateTrust == SQFreeRDPCertificateTrustOnce ||
                                  session->certificateTrust == SQFreeRDPCertificateTrustAlways);
    sq_emit_connected(session);
    sq_emit_frame(session, instance->context);
    return TRUE;
}

static BOOL sq_authenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    (void)reason;
    SQBridgeSession *session = sq_session_from_instance(instance);
    if (!session) {
        return FALSE;
    }

    if (!session->username || !session->password) {
        SQFreeRDPEvent event;
        memset(&event, 0, sizeof(event));
        event.kind = SQFreeRDPEventCredentialsRequired;
        event.message = "Windows credentials are required.";
        event.host = session->host;
        event.username = session->username;
        event.domain = session->domain;
        sq_emit(session, &event);
        sq_set_last_error(session, "Windows credentials are required.");
        return FALSE;
    }

    if (username) {
        free(*username);
        *username = strdup(session->username ? session->username : "");
    }
    if (password) {
        free(*password);
        *password = strdup(session->password ? session->password : "");
    }
    if (domain) {
        free(*domain);
        *domain = strdup(session->domain ? session->domain : "");
    }
    return TRUE;
}

static int sq_hex_value(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    c = (char)tolower((unsigned char)c);
    if (c >= 'a' && c <= 'f') {
        return 10 + (c - 'a');
    }
    return -1;
}

static bool sq_fingerprint_equal(const char *lhs, const char *rhs) {
    if (!lhs || !rhs) {
        return false;
    }

    while (*lhs || *rhs) {
        while (*lhs && sq_hex_value(*lhs) < 0) {
            lhs++;
        }
        while (*rhs && sq_hex_value(*rhs) < 0) {
            rhs++;
        }
        int left = sq_hex_value(*lhs);
        int right = sq_hex_value(*rhs);
        if (left < 0 || right < 0) {
            return left == right;
        }
        if (left != right) {
            return false;
        }
        lhs++;
        rhs++;
    }
    return true;
}

static DWORD sq_certificate_result(SQBridgeSession *session, const char *fingerprint) {
    if (!session) {
        return 0;
    }

    bool trustedFingerprintMatched = sq_fingerprint_equal(session->trustedCertificateFingerprint, fingerprint);

    switch (session->certificateTrust) {
    case SQFreeRDPCertificateTrustOnce:
        if (session->trustedCertificateFingerprint && !trustedFingerprintMatched) {
            break;
        }
        return 2;
    case SQFreeRDPCertificateTrustAlways:
        if (session->trustedCertificateFingerprint && !trustedFingerprintMatched) {
            break;
        }
        return 1;
    case SQFreeRDPCertificateTrustReject:
        return 0;
    case SQFreeRDPCertificateTrustNone:
    default:
        break;
    }

    if (trustedFingerprintMatched) {
        session->trustedCertificateMatched = true;
        return 2;
    }

    return 0;
}

static DWORD sq_verify_certificate(freerdp *instance,
                                   const char *host,
                                   UINT16 port,
                                   const char *commonName,
                                   const char *subject,
                                   const char *issuer,
                                   const char *fingerprint,
                                   DWORD flags) {
    (void)port;
    (void)commonName;
    (void)flags;
    SQBridgeSession *session = sq_session_from_instance(instance);
    DWORD result = sq_certificate_result(session, fingerprint);
    if (result != 0) {
        return result;
    }

    SQFreeRDPEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = SQFreeRDPEventCertificateTrustRequired;
    event.message = "The Windows PC presented an RDP certificate that has not been trusted yet.";
    event.host = session ? session->host : host;
    event.certificateSubject = subject ? subject : commonName;
    event.certificateIssuer = issuer;
    event.certificateFingerprintSHA256 = fingerprint;
    event.certificateHost = host;
    sq_emit(session, &event);
    if (session) {
        session->certificateReviewPending = true;
    }
    sq_set_last_error(session, "The RDP certificate was not trusted.");
    return 0;
}

static DWORD sq_verify_changed_certificate(freerdp *instance,
                                           const char *host,
                                           UINT16 port,
                                           const char *commonName,
                                           const char *subject,
                                           const char *issuer,
                                           const char *newFingerprint,
                                           const char *oldSubject,
                                           const char *oldIssuer,
                                           const char *oldFingerprint,
                                           DWORD flags) {
    (void)oldSubject;
    (void)oldIssuer;
    (void)oldFingerprint;
    return sq_verify_certificate(instance, host, port, commonName, subject, issuer, newFingerprint, flags);
}

static void sq_post_disconnect(freerdp *instance) {
    (void)instance;
}

static void *sq_connection_thread(void *argument) {
    SQBridgeSession *session = (SQBridgeSession *)argument;
    freerdp *instance = freerdp_new();
    if (!instance) {
        sq_emit_error(session, 0, "FreeRDP failed to allocate a client instance.");
        return NULL;
    }

    instance->ContextSize = sizeof(SQBridgeContext);
    instance->PreConnect = sq_pre_connect;
    instance->PostConnect = sq_post_connect;
    instance->PostDisconnect = sq_post_disconnect;
    instance->AuthenticateEx = sq_authenticate;
    instance->VerifyCertificateEx = sq_verify_certificate;
    instance->VerifyChangedCertificateEx = sq_verify_changed_certificate;

    if (!freerdp_context_new(instance)) {
        sq_emit_error(session, 0, "FreeRDP failed to allocate a client context.");
        freerdp_free(instance);
        return NULL;
    }

    SQBridgeContext *context = (SQBridgeContext *)instance->context;
    context->session = session;

    pthread_mutex_lock(&session->lock);
    session->instance = instance;
    pthread_mutex_unlock(&session->lock);

    if (!sq_apply_settings(session, instance->context->settings)) {
        sq_emit_error(session, 0, sq_freerdp_last_error(session));
        goto cleanup;
    }

    sq_emit_simple(session, SQFreeRDPEventConnecting, "Connecting to Windows Remote Desktop.");

    if (!freerdp_connect(instance)) {
        UINT32 code = freerdp_get_last_error(instance->context);
        const char *detail = freerdp_get_last_error_string(code);
        sq_set_last_errorf(session, "FreeRDP failed to connect", detail);
        if (!session->certificateReviewPending) {
            sq_emit_error(session, (int32_t)code, sq_freerdp_last_error(session));
        }
        goto cleanup;
    }

    while (true) {
        pthread_mutex_lock(&session->lock);
        bool stopRequested = session->stopRequested;
        pthread_mutex_unlock(&session->lock);

        if (stopRequested || freerdp_shall_disconnect_context(instance->context)) {
            break;
        }

        if (!freerdp_check_event_handles(instance->context)) {
            UINT32 code = freerdp_get_last_error(instance->context);
            const char *detail = freerdp_get_last_error_string(code);
            sq_set_last_errorf(session, "FreeRDP event handling failed", detail);
            sq_emit_error(session, (int32_t)code, sq_freerdp_last_error(session));
            break;
        }

        usleep(8000);
    }

cleanup:
    if (session->gdiInitialized) {
        gdi_free(instance);
        session->gdiInitialized = false;
    }
    freerdp_disconnect(instance);
    freerdp_context_free(instance);
    freerdp_free(instance);

    pthread_mutex_lock(&session->lock);
    session->instance = NULL;
    bool stoppedByRequest = session->stopRequested;
    bool certificateReviewPending = session->certificateReviewPending;
    pthread_mutex_unlock(&session->lock);

    if (!certificateReviewPending) {
        sq_emit_simple(session, SQFreeRDPEventDisconnected, stoppedByRequest ? "Disconnected." : sq_freerdp_last_error(session));
    }
    return NULL;
}

void *sq_freerdp_create_session(void) {
    SQBridgeSession *session = (SQBridgeSession *)calloc(1, sizeof(SQBridgeSession));
    if (!session) {
        return NULL;
    }

    pthread_mutex_init(&session->lock, NULL);
    session->port = 3389;
    session->desktopWidth = 1440;
    session->desktopHeight = 900;
    session->currentWidth = 1440;
    session->currentHeight = 900;
    return session;
}

void sq_freerdp_destroy_session(void *rawSession) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session) {
        return;
    }

    sq_freerdp_disconnect(session);
    sq_free_string(&session->host);
    sq_free_string(&session->username);
    sq_free_string(&session->password);
    sq_free_string(&session->domain);
    sq_free_string(&session->gatewayHost);
    sq_free_string(&session->gatewayUsername);
    sq_free_string(&session->trustedCertificateFingerprint);
    sq_free_string(&session->lastError);
    pthread_mutex_destroy(&session->lock);
    free(session);
}

void sq_freerdp_set_event_callback(void *rawSession, SQFreeRDPEventCallback callback, void *context) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session) {
        return;
    }

    pthread_mutex_lock(&session->lock);
    session->callback = callback;
    session->callbackContext = context;
    pthread_mutex_unlock(&session->lock);
}

int32_t sq_freerdp_connect(void *rawSession, const SQFreeRDPConfig *config) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session || !config) {
        return -1;
    }

    pthread_mutex_lock(&session->lock);
    bool alreadyRunning = session->threadStarted;
    pthread_mutex_unlock(&session->lock);
    if (alreadyRunning) {
        sq_set_last_error(session, "An RDP session is already running.");
        return -1;
    }

    if (!sq_copy_config(session, config)) {
        return -1;
    }

    pthread_mutex_lock(&session->lock);
    session->stopRequested = false;
    session->threadStarted = true;
    pthread_mutex_unlock(&session->lock);

    int result = pthread_create(&session->thread, NULL, sq_connection_thread, session);
    if (result != 0) {
        pthread_mutex_lock(&session->lock);
        session->threadStarted = false;
        pthread_mutex_unlock(&session->lock);
        sq_set_last_error(session, "Failed to start the RDP worker thread.");
        return -1;
    }

    return 0;
}

void sq_freerdp_disconnect(void *rawSession) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session) {
        return;
    }

    pthread_mutex_lock(&session->lock);
    bool threadStarted = session->threadStarted;
    pthread_t thread = session->thread;
    freerdp *instance = session->instance;
    session->stopRequested = true;
    pthread_mutex_unlock(&session->lock);

    if (instance && instance->context) {
        freerdp_abort_connect_context(instance->context);
    }

    if (threadStarted && !pthread_equal(pthread_self(), thread)) {
        pthread_join(thread, NULL);
        pthread_mutex_lock(&session->lock);
        session->threadStarted = false;
        pthread_mutex_unlock(&session->lock);
    }
}

static uint16_t sq_button_flag(int32_t button) {
    switch (button) {
    case 2:
        return PTR_FLAGS_BUTTON2;
    case 3:
        return PTR_FLAGS_BUTTON3;
    case 1:
    default:
        return PTR_FLAGS_BUTTON1;
    }
}

static uint16_t sq_scaled_coord(double value, int32_t extent) {
    if (extent <= 1) {
        return 0;
    }
    if (value < 0) {
        value = 0;
    } else if (value > 1) {
        value = 1;
    }
    return (uint16_t)(value * (double)(extent - 1));
}

static bool sq_lookup_key(const char *keyName, SQKeyMap *map) {
    static const SQKeyMap keys[] = {
        { "returnKey", 0x1C, 0 },
        { "escape", 0x01, 0 },
        { "tab", 0x0F, 0 },
        { "backspace", 0x0E, 0 },
        { "delete", 0x53, KBD_FLAGS_EXTENDED },
        { "arrowUp", 0x48, KBD_FLAGS_EXTENDED },
        { "arrowDown", 0x50, KBD_FLAGS_EXTENDED },
        { "arrowLeft", 0x4B, KBD_FLAGS_EXTENDED },
        { "arrowRight", 0x4D, KBD_FLAGS_EXTENDED },
        { "spacebar", 0x39, 0 },
        { "home", 0x47, KBD_FLAGS_EXTENDED },
        { "end", 0x4F, KBD_FLAGS_EXTENDED },
        { "pageUp", 0x49, KBD_FLAGS_EXTENDED },
        { "pageDown", 0x51, KBD_FLAGS_EXTENDED },
        { "a", 0x1E, 0 },
        { "c", 0x2E, 0 },
        { "d", 0x20, 0 },
        { "f", 0x21, 0 },
        { "h", 0x23, 0 },
        { "l", 0x26, 0 },
        { "m", 0x32, 0 },
        { "q", 0x10, 0 },
        { "v", 0x2F, 0 },
        { "w", 0x11, 0 },
        { "x", 0x2D, 0 },
        { "z", 0x2C, 0 },
        { "f1", 0x3B, 0 },
        { "f2", 0x3C, 0 },
        { "f3", 0x3D, 0 },
        { "f4", 0x3E, 0 },
        { "f5", 0x3F, 0 },
        { "f6", 0x40, 0 },
        { "f7", 0x41, 0 },
        { "f8", 0x42, 0 },
        { "f9", 0x43, 0 },
        { "f10", 0x44, 0 },
        { "f11", 0x57, 0 },
        { "f12", 0x58, 0 },
    };

    if (!keyName || !map) {
        return false;
    }
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        if (strcmp(keys[index].name, keyName) == 0) {
            *map = keys[index];
            return true;
        }
    }
    return false;
}

static bool sq_send_keyboard_scan(rdpInput *input, uint8_t scanCode, uint16_t baseFlags, bool down) {
    uint16_t flags = baseFlags;
    if (!down) {
        flags |= KBD_FLAGS_RELEASE;
    }
    return freerdp_input_send_keyboard_event(input, flags, scanCode) ? true : false;
}

static bool sq_send_key(rdpInput *input, const SQKeyMap *map, bool down) {
    if (!input || !map) {
        return false;
    }
    return sq_send_keyboard_scan(input, map->scanCode, map->flags, down);
}

static bool sq_send_modifier(rdpInput *input, uint32_t modifiers, uint32_t modifier, uint8_t scanCode, uint16_t flags, bool down) {
    if ((modifiers & modifier) == 0) {
        return true;
    }
    return sq_send_keyboard_scan(input, scanCode, flags, down);
}

static bool sq_send_modifiers(rdpInput *input, uint32_t modifiers, bool down) {
    if (down) {
        return sq_send_modifier(input, modifiers, SQKeyModifierShift, 0x2A, 0, true) &&
               sq_send_modifier(input, modifiers, SQKeyModifierControl, 0x1D, 0, true) &&
               sq_send_modifier(input, modifiers, SQKeyModifierOption, 0x38, 0, true) &&
               sq_send_modifier(input, modifiers, SQKeyModifierCommand, 0x5B, KBD_FLAGS_EXTENDED, true);
    }
    return sq_send_modifier(input, modifiers, SQKeyModifierCommand, 0x5B, KBD_FLAGS_EXTENDED, false) &&
           sq_send_modifier(input, modifiers, SQKeyModifierOption, 0x38, 0, false) &&
           sq_send_modifier(input, modifiers, SQKeyModifierControl, 0x1D, 0, false) &&
           sq_send_modifier(input, modifiers, SQKeyModifierShift, 0x2A, 0, false);
}

static bool sq_send_key_with_modifiers(rdpInput *input, const SQKeyMap *map, uint32_t modifiers, bool down) {
    if (down) {
        return sq_send_modifiers(input, modifiers, true) && sq_send_key(input, map, true);
    }
    return sq_send_key(input, map, false) && sq_send_modifiers(input, modifiers, false);
}

static bool sq_send_utf8_text(rdpInput *input, const char *text) {
    if (!input || !text) {
        return false;
    }

    const unsigned char *cursor = (const unsigned char *)text;
    while (*cursor) {
        uint32_t codepoint = 0;
        if ((*cursor & 0x80) == 0) {
            codepoint = *cursor++;
        } else if ((*cursor & 0xE0) == 0xC0 && cursor[1]) {
            codepoint = ((*cursor & 0x1F) << 6) | (cursor[1] & 0x3F);
            cursor += 2;
        } else if ((*cursor & 0xF0) == 0xE0 && cursor[1] && cursor[2]) {
            codepoint = ((*cursor & 0x0F) << 12) | ((cursor[1] & 0x3F) << 6) | (cursor[2] & 0x3F);
            cursor += 3;
        } else {
            cursor++;
            continue;
        }

        if (codepoint <= 0xFFFF) {
            if (!freerdp_input_send_unicode_keyboard_event(input, 0, (uint16_t)codepoint)) {
                return false;
            }
            if (!freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE, (uint16_t)codepoint)) {
                return false;
            }
        }
    }
    return true;
}

int32_t sq_freerdp_send_input(void *rawSession, const SQFreeRDPInputEvent *inputEvent) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session || !inputEvent) {
        return -1;
    }

    pthread_mutex_lock(&session->lock);
    freerdp *instance = session->instance;
    int32_t width = session->currentWidth;
    int32_t height = session->currentHeight;
    pthread_mutex_unlock(&session->lock);

    if (!instance || !instance->context || !instance->context->input) {
        sq_set_last_error(session, "The RDP input channel is not ready.");
        return -1;
    }

    rdpInput *input = instance->context->input;
    uint16_t x = sq_scaled_coord(inputEvent->x, width);
    uint16_t y = sq_scaled_coord(inputEvent->y, height);
    bool ok = true;

    switch (inputEvent->kind) {
    case SQFreeRDPInputPointerMove:
        ok = freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y) ? true : false;
        break;
    case SQFreeRDPInputPointerDown:
        ok = sq_send_modifiers(input, inputEvent->modifiers, true) &&
             (freerdp_input_send_mouse_event(input, PTR_FLAGS_DOWN | sq_button_flag(inputEvent->button), x, y) ? true : false);
        break;
    case SQFreeRDPInputPointerUp:
        ok = (freerdp_input_send_mouse_event(input, sq_button_flag(inputEvent->button), x, y) ? true : false) &&
             sq_send_modifiers(input, inputEvent->modifiers, false);
        break;
    case SQFreeRDPInputScroll: {
        int wheel = inputEvent->deltaY < 0 ? -120 : 120;
        uint16_t flags = PTR_FLAGS_WHEEL | (uint16_t)(abs(wheel) & WheelRotationMask);
        if (wheel < 0) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        }
        ok = sq_send_modifiers(input, inputEvent->modifiers, true) &&
             (freerdp_input_send_mouse_event(input, flags, x, y) ? true : false) &&
             sq_send_modifiers(input, inputEvent->modifiers, false);
        break;
    }
    case SQFreeRDPInputKeyDown:
    case SQFreeRDPInputKeyUp: {
        SQKeyMap key;
        if (!sq_lookup_key(inputEvent->keyName, &key)) {
            sq_set_last_error(session, "Unsupported RDP key name.");
            return -1;
        }
        ok = sq_send_key_with_modifiers(input, &key, inputEvent->modifiers, inputEvent->kind == SQFreeRDPInputKeyDown);
        break;
    }
    case SQFreeRDPInputTextInput:
        ok = sq_send_utf8_text(input, inputEvent->text);
        break;
    default:
        sq_set_last_error(session, "Unsupported RDP input event.");
        return -1;
    }

    if (!ok) {
        sq_set_last_error(session, "FreeRDP rejected the input event.");
        return -1;
    }
    return 0;
}

int32_t sq_freerdp_resize(void *rawSession, int32_t width, int32_t height, double scale) {
    (void)scale;
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session || width <= 0 || height <= 0) {
        return -1;
    }

    pthread_mutex_lock(&session->lock);
    session->currentWidth = width;
    session->currentHeight = height;
    freerdp *instance = session->instance;
    pthread_mutex_unlock(&session->lock);

    if (instance && instance->context && instance->context->gdi) {
        gdi_resize(instance->context->gdi, (uint32_t)width, (uint32_t)height);
    }
    return 0;
}

const char *sq_freerdp_last_error(void *rawSession) {
    SQBridgeSession *session = (SQBridgeSession *)rawSession;
    if (!session || !session->lastError) {
        return "";
    }
    return session->lastError;
}

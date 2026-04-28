//
//  FreeRDPBridgeRuntime.swift
//  Screen Q
//
//  Dynamic loader for the ScreenQFreeRDPBridge C ABI. This keeps the app
//  target independent from FreeRDP headers while still allowing production
//  builds to bundle a native bridge.
//

import Foundation
import Darwin

private typealias SQFreeRDPCreateSessionFn = @convention(c) () -> UnsafeMutableRawPointer?
private typealias SQFreeRDPDestroySessionFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias SQFreeRDPSetEventCallbackFn = @convention(c) (UnsafeMutableRawPointer?, SQFreeRDPEventCallback?, UnsafeMutableRawPointer?) -> Void
private typealias SQFreeRDPConnectFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Int32
private typealias SQFreeRDPDisconnectFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias SQFreeRDPSendInputFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Int32
private typealias SQFreeRDPResizeFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Double) -> Int32
private typealias SQFreeRDPLastErrorFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

nonisolated final class FreeRDPBridgeRuntime {
    private let libraryHandle: UnsafeMutableRawPointer
    private let createSessionFn: SQFreeRDPCreateSessionFn
    private let destroySessionFn: SQFreeRDPDestroySessionFn
    private let setEventCallbackFn: SQFreeRDPSetEventCallbackFn
    private let connectFn: SQFreeRDPConnectFn
    private let disconnectFn: SQFreeRDPDisconnectFn
    private let sendInputFn: SQFreeRDPSendInputFn
    private let resizeFn: SQFreeRDPResizeFn
    private let lastErrorFn: SQFreeRDPLastErrorFn?

    private init(
        libraryHandle: UnsafeMutableRawPointer,
        createSessionFn: @escaping SQFreeRDPCreateSessionFn,
        destroySessionFn: @escaping SQFreeRDPDestroySessionFn,
        setEventCallbackFn: @escaping SQFreeRDPSetEventCallbackFn,
        connectFn: @escaping SQFreeRDPConnectFn,
        disconnectFn: @escaping SQFreeRDPDisconnectFn,
        sendInputFn: @escaping SQFreeRDPSendInputFn,
        resizeFn: @escaping SQFreeRDPResizeFn,
        lastErrorFn: SQFreeRDPLastErrorFn?
    ) {
        self.libraryHandle = libraryHandle
        self.createSessionFn = createSessionFn
        self.destroySessionFn = destroySessionFn
        self.setEventCallbackFn = setEventCallbackFn
        self.connectFn = connectFn
        self.disconnectFn = disconnectFn
        self.sendInputFn = sendInputFn
        self.resizeFn = resizeFn
        self.lastErrorFn = lastErrorFn
    }

    deinit {
        dlclose(libraryHandle)
    }

    static func load() -> Result<FreeRDPBridgeRuntime, FreeRDPBridgeLoadFailure> {
        var attempted: [String] = []

        for candidate in libraryCandidates {
            attempted.append(candidate)
            guard let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard
                let create: SQFreeRDPCreateSessionFn = symbol("sq_freerdp_create_session", in: handle),
                let destroy: SQFreeRDPDestroySessionFn = symbol("sq_freerdp_destroy_session", in: handle),
                let setCallback: SQFreeRDPSetEventCallbackFn = symbol("sq_freerdp_set_event_callback", in: handle),
                let connect: SQFreeRDPConnectFn = symbol("sq_freerdp_connect", in: handle),
                let disconnect: SQFreeRDPDisconnectFn = symbol("sq_freerdp_disconnect", in: handle),
                let sendInput: SQFreeRDPSendInputFn = symbol("sq_freerdp_send_input", in: handle),
                let resize: SQFreeRDPResizeFn = symbol("sq_freerdp_resize", in: handle)
            else {
                let message = lastDynamicLoaderError() ?? "Unknown dynamic loader error."
                dlclose(handle)
                return .failure(FreeRDPBridgeLoadFailure(
                    detail: "ScreenQFreeRDPBridge was found but does not expose the required ABI symbols. \(message)"
                ))
            }

            let lastError: SQFreeRDPLastErrorFn? = symbol("sq_freerdp_last_error", in: handle)
            return .success(FreeRDPBridgeRuntime(
                libraryHandle: handle,
                createSessionFn: create,
                destroySessionFn: destroy,
                setEventCallbackFn: setCallback,
                connectFn: connect,
                disconnectFn: disconnect,
                sendInputFn: sendInput,
                resizeFn: resize,
                lastErrorFn: lastError
            ))
        }

        return .failure(FreeRDPBridgeLoadFailure(detail: """
        The native FreeRDP bridge is not bundled. Add ScreenQFreeRDPBridge.framework to the app's Frameworks folder, or bundle libScreenQFreeRDPBridge.dylib in the app resources. Tried: \(attempted.joined(separator: ", ")).
        """))
    }

    func createSession() -> UnsafeMutableRawPointer? {
        createSessionFn()
    }

    func destroySession(_ session: UnsafeMutableRawPointer?) {
        destroySessionFn(session)
    }

    func setEventCallback(_ session: UnsafeMutableRawPointer?, _ callback: SQFreeRDPEventCallback?, _ context: UnsafeMutableRawPointer?) {
        setEventCallbackFn(session, callback, context)
    }

    func connect(_ session: UnsafeMutableRawPointer?, _ config: UnsafePointer<SQFreeRDPConfig>?) -> Int32 {
        connectFn(session, UnsafeRawPointer(config))
    }

    func disconnect(_ session: UnsafeMutableRawPointer?) {
        disconnectFn(session)
    }

    func sendInput(_ session: UnsafeMutableRawPointer?, _ input: UnsafePointer<SQFreeRDPInputEvent>?) -> Int32 {
        sendInputFn(session, UnsafeRawPointer(input))
    }

    func resize(_ session: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32, _ scale: Double) -> Int32 {
        resizeFn(session, width, height, scale)
    }

    func lastErrorMessage(_ session: UnsafeMutableRawPointer?) -> String? {
        guard let pointer = lastErrorFn?(session) else { return nil }
        let message = String(cString: pointer)
        return message.isEmpty ? nil : message
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func lastDynamicLoaderError() -> String? {
        guard let pointer = dlerror() else { return nil }
        return String(cString: pointer)
    }

    private static var libraryCandidates: [String] {
        var candidates: [String] = []

        if let explicitPath = ProcessInfo.processInfo.environment["SCREENQ_FREERDP_BRIDGE_PATH"],
           !explicitPath.isEmpty {
            candidates.append(explicitPath)
        }

        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            candidates.append((privateFrameworksPath as NSString)
                .appendingPathComponent("ScreenQFreeRDPBridge.framework/ScreenQFreeRDPBridge"))
            #if os(macOS)
            candidates.append((privateFrameworksPath as NSString)
                .appendingPathComponent("libScreenQFreeRDPBridge.dylib"))
            #endif
        }

        #if os(macOS)
        if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append((executablePath as NSString).appendingPathComponent("libScreenQFreeRDPBridge.dylib"))
        }

        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("libScreenQFreeRDPBridge.dylib"))
        }
        #endif

        candidates.append("ScreenQFreeRDPBridge.framework/ScreenQFreeRDPBridge")
        #if os(macOS)
        candidates.append("libScreenQFreeRDPBridge.dylib")
        #endif
        return candidates
    }
}

nonisolated struct FreeRDPBridgeLoadFailure: LocalizedError, Sendable {
    var detail: String

    var errorDescription: String? {
        detail
    }
}

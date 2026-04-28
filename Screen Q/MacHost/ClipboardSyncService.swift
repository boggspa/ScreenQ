//
//  ClipboardSyncService.swift
//  Screen Q
//
//  Bidirectional clipboard sync between host and viewer. Monitors the local
//  pasteboard for changes and sends ClipboardOffer messages. On receiving a
//  ClipboardRequest, reads the requested data type and sends it back.
//

#if os(macOS)
import Foundation
import AppKit

@MainActor
final class ClipboardSyncService {

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var sendOffer: ((ClipboardOfferMessage) -> Void)?
    private var sendData: ((ClipboardDataMessage) -> Void)?
    var enabled: Bool = true

    func start(
        onOffer: @escaping (ClipboardOfferMessage) -> Void,
        onSendData: @escaping (ClipboardDataMessage) -> Void
    ) {
        stop()
        self.sendOffer = onOffer
        self.sendData = onSendData
        self.lastChangeCount = NSPasteboard.general.changeCount

        // Poll pasteboard every 500ms (Apple doesn't provide a notification for general pasteboard).
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sendOffer = nil
        sendData = nil
    }

    private func checkPasteboard() {
        guard enabled else { return }
        let cc = NSPasteboard.general.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        let types = NSPasteboard.general.types?.map { $0.rawValue } ?? []
        guard !types.isEmpty else { return }

        let offer = ClipboardOfferMessage(changeCount: cc, availableTypes: types)
        sendOffer?(offer)
    }

    /// Handle a clipboard request from the remote side.
    func handleRequest(_ request: ClipboardRequestMessage) {
        guard enabled else { return }
        let ptype = NSPasteboard.PasteboardType(request.requestedType)
        guard let data = NSPasteboard.general.data(forType: ptype) else { return }

        let msg = ClipboardDataMessage(
            type: request.requestedType,
            base64Data: data.base64EncodedString()
        )
        sendData?(msg)
    }

    /// Apply clipboard data received from the remote side.
    func applyRemoteClipboard(_ msg: ClipboardDataMessage) {
        guard enabled else { return }
        guard let data = Data(base64Encoded: msg.base64Data) else { return }
        let ptype = NSPasteboard.PasteboardType(msg.type)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: ptype)
        // Update our change count so we don't echo it back.
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Apply a remote clipboard offer by requesting plain text if available.
    func handleRemoteOffer(_ offer: ClipboardOfferMessage, requestSender: (ClipboardRequestMessage) -> Void) {
        guard enabled else { return }
        // Prefer plain text, then RTF, then HTML.
        let preferred = ["public.utf8-plain-text", "public.rtf", "public.html"]
        for ptype in preferred {
            if offer.availableTypes.contains(ptype) {
                requestSender(ClipboardRequestMessage(requestedType: ptype))
                return
            }
        }
        // Fall back to first available type.
        if let first = offer.availableTypes.first {
            requestSender(ClipboardRequestMessage(requestedType: first))
        }
    }
}
#endif

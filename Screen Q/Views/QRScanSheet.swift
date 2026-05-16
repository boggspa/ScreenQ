//
//  QRScanSheet.swift
//  Screen Q
//
//  iOS-only QR scanner used by the Connection Hub for one-tap launches
//  of `screenq://` quick-connect links. Wraps an AVCaptureSession in a
//  UIViewControllerRepresentable, decodes via AVMetadataMachineReadable
//  with `.qr` filter, then hands the parsed URL back to the caller. The
//  caller is responsible for routing it through the app's external-URL
//  handler.
//
//  Visual treatment matches the rest of the Screen Q theme — cinematic
//  backdrop, reticle with corner brackets in cosmicCyan, hairline caption
//  copy, and the Cancel button uses SQHaptics.tap() for parity with the
//  rest of the iOS surface.
//

#if os(iOS)

import SwiftUI
import AVFoundation
import UIKit

struct QRScanSheet: View {

    /// Called when a recognized `screenq://` (or `sq://`) URL is decoded.
    var onResult: (URL) -> Void
    /// Called when the user dismisses without scanning.
    var onCancel: () -> Void

    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var torchOn: Bool = false
    @State private var transientError: String?
    @State private var hideTransientErrorTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            ScreenQTheme.cinematicBackdrop
                .ignoresSafeArea()

            switch authorization {
            case .authorized:
                authorizedBody
            case .notDetermined:
                permissionRequestBody
            default:
                deniedBody
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshAuthorization() }
    }

    // MARK: - Authorized: live preview + reticle

    private var authorizedBody: some View {
        ZStack {
            QRCameraPreview(
                torchOn: torchOn,
                onCode: handleCode(_:)
            )
            .ignoresSafeArea()

            scrim
            reticle
                .padding(.horizontal, 40)

            VStack {
                topBar
                Spacer()
                bottomCaption
                Spacer().frame(height: 18)
                cancelButton
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 24)

            if let transientError {
                VStack {
                    Spacer()
                    SQErrorRecovery(
                        title: "Unrecognized QR",
                        message: transientError
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 120)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Permission states

    private var permissionRequestBody: some View {
        VStack {
            Spacer()
            SQEmptyState(
                icon: "camera.viewfinder",
                title: "Allow camera access",
                message: "Screen Q uses the camera only to read QR codes — frames never leave your device.",
                tint: ScreenQTheme.cosmicCyan,
                primary: .init("Allow", systemImage: "checkmark.circle.fill") {
                    SQHaptics.tap()
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        DispatchQueue.main.async {
                            authorization = granted ? .authorized : .denied
                        }
                    }
                },
                secondary: .init("Cancel", systemImage: "xmark") {
                    SQHaptics.tap()
                    onCancel()
                }
            )
            .screenQCard(tint: ScreenQTheme.cosmicCyan)
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    private var deniedBody: some View {
        VStack {
            Spacer()
            SQEmptyState(
                icon: "camera.fill",
                title: "Camera permission needed",
                message: "Allow camera access in Settings to scan QR codes.",
                tint: ScreenQTheme.cosmicAmber,
                primary: .init("Open Settings", systemImage: "gear") {
                    SQHaptics.tap()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                },
                secondary: .init("Cancel", systemImage: "xmark") {
                    SQHaptics.tap()
                    onCancel()
                }
            )
            .screenQCard(tint: ScreenQTheme.cosmicAmber)
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    // MARK: - Chrome bits

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan to Connect")
                    .font(.sqHeadline)
                    .foregroundColor(.white)
                Text("Point at a Screen Q QR code")
                    .font(.sqCaption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Button {
                SQHaptics.tap()
                torchOn.toggle()
            } label: {
                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundColor(torchOn ? ScreenQTheme.cosmicAmber : .white.opacity(0.85))
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(torchOn ? "Turn off torch" : "Turn on torch")
        }
        .padding(.top, 6)
    }

    private var bottomCaption: some View {
        Text("Align the QR code inside the frame")
            .font(.sqCaption)
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var cancelButton: some View {
        Button {
            SQHaptics.tap()
            onCancel()
        } label: {
            Text("Cancel")
                .font(.sqHeadline)
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(
                    Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel scan")
    }

    private var scrim: some View {
        Color.black.opacity(0.35).ignoresSafeArea()
    }

    private var reticle: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.72
            let corner: CGFloat = 22
            let stroke: CGFloat = 3
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(ScreenQTheme.cosmicCyan.opacity(0.7), lineWidth: 1.2)
                    .frame(width: side, height: side)
                ZStack {
                    CornerBracket(corner: .topLeading)
                        .stroke(ScreenQTheme.cosmicCyan, lineWidth: stroke)
                    CornerBracket(corner: .topTrailing)
                        .stroke(ScreenQTheme.cosmicCyan, lineWidth: stroke)
                    CornerBracket(corner: .bottomLeading)
                        .stroke(ScreenQTheme.cosmicCyan, lineWidth: stroke)
                    CornerBracket(corner: .bottomTrailing)
                        .stroke(ScreenQTheme.cosmicCyan, lineWidth: stroke)
                }
                .frame(width: side, height: side)
                .shadow(color: ScreenQTheme.cosmicCyan.opacity(0.45), radius: 8, x: 0, y: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Logic

    private func refreshAuthorization() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func handleCode(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            flashError("That QR didn't contain a usable link.")
            return
        }
        let allowed: Set<String> = ["screenq", "sq", "vnc", "screens", "rdp"]
        guard allowed.contains(scheme) else {
            flashError("Unsupported scheme: \(scheme)")
            return
        }
        SQHaptics.success()
        onResult(url)
    }

    private func flashError(_ message: String) {
        SQHaptics.warning()
        withAnimation(.easeIn(duration: 0.15)) {
            transientError = message
        }
        hideTransientErrorTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) {
                transientError = nil
            }
        }
        hideTransientErrorTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }
}

// MARK: - Corner brackets used by the reticle

private struct CornerBracket: Shape {
    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let armLength: CGFloat = min(rect.width, rect.height) * 0.18
        switch corner {
        case .topLeading:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + armLength))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + armLength, y: rect.minY))
        case .topTrailing:
            p.move(to: CGPoint(x: rect.maxX - armLength, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + armLength))
        case .bottomLeading:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY - armLength))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + armLength, y: rect.maxY))
        case .bottomTrailing:
            p.move(to: CGPoint(x: rect.maxX - armLength, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - armLength))
        }
        return p
    }
}

// MARK: - Camera preview (AVCaptureSession via UIViewController)

private struct QRCameraPreview: UIViewControllerRepresentable {

    var torchOn: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> CameraController {
        let controller = CameraController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: CameraController, context: Context) {
        controller.setTorchOn(torchOn)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private var lastEmittedAt: Date = .distantPast
        private var lastEmittedValue: String = ""

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  first.type == .qr,
                  let value = first.stringValue,
                  !value.isEmpty else { return }
            // Debounce repeat scans of the same code within 1.5s.
            let now = Date()
            if value == lastEmittedValue, now.timeIntervalSince(lastEmittedAt) < 1.5 {
                return
            }
            lastEmittedValue = value
            lastEmittedAt = now
            DispatchQueue.main.async { self.onCode(value) }
        }
    }

    final class CameraController: UIViewController {
        weak var coordinator: Coordinator?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            startSessionIfNeeded()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopSession()
            setTorchOn(false)
        }

        private func configureSession() {
            session.beginConfiguration()
            session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            if let coordinator {
                output.setMetadataObjectsDelegate(coordinator, queue: DispatchQueue.main)
            }
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        private func startSessionIfNeeded() {
            guard !session.isRunning else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        private func stopSession() {
            guard session.isRunning else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }

        func setTorchOn(_ on: Bool) {
            guard let device = AVCaptureDevice.default(for: .video),
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if on, device.isTorchModeSupported(.on) {
                    try? device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                // Best-effort — torch isn't required for scanning.
            }
        }
    }
}

#endif

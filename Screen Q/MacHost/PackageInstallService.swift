//
//  PackageInstallService.swift
//  Screen Q
//
//  Installs .pkg files on the host Mac via the `installer` CLI.
//  Requires the .packageInstall permission flag. The package must
//  already be present in the download directory (transferred via
//  FileTransferService).
//

#if os(macOS)
import Foundation

@MainActor
final class PackageInstallService {

    let downloadDirectory: URL

    init(downloadDirectory: URL? = nil) {
        self.downloadDirectory = downloadDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func install(_ request: PackageInstallRequestMessage) async -> PackageInstallResultMessage {
        let pkgURL = downloadDirectory.appendingPathComponent(request.fileName)

        guard FileManager.default.fileExists(atPath: pkgURL.path) else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Package file not found: \(request.fileName)"
            )
        }

        guard pkgURL.pathExtension == "pkg" else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Not a .pkg file: \(request.fileName)"
            )
        }

        Logger.shared.info("PackageInstall: installing \(request.fileName) to \(request.targetVolume)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", pkgURL.path, "-target", request.targetVolume, "-verboseR"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let success = process.terminationStatus == 0

            if success {
                Logger.shared.info("PackageInstall: success for \(request.fileName)")
            } else {
                Logger.shared.error("PackageInstall: failed (\(process.terminationStatus)) for \(request.fileName)")
            }

            return PackageInstallResultMessage(
                installID: request.installID,
                success: success,
                output: output
            )
        } catch {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Failed to launch installer: \(error.localizedDescription)"
            )
        }
    }
}
#endif

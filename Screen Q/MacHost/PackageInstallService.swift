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
        guard let safeFileName = FileTransferService.sanitizedFileName(request.fileName) else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Invalid package file name"
            )
        }

        guard request.targetVolume == "/" else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Unsupported install target: \(request.targetVolume)"
            )
        }

        let downloadsRoot = downloadDirectory.resolvingSymlinksInPath().standardizedFileURL
        let pkgURL = downloadDirectory
            .appendingPathComponent(safeFileName, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard pkgURL.deletingLastPathComponent() == downloadsRoot else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Package must be inside the managed download directory"
            )
        }

        guard FileManager.default.fileExists(atPath: pkgURL.path) else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Package file not found: \(safeFileName)"
            )
        }

        guard pkgURL.pathExtension.lowercased() == "pkg" else {
            return PackageInstallResultMessage(
                installID: request.installID,
                success: false,
                output: "Not a .pkg file: \(safeFileName)"
            )
        }

        Logger.shared.info("PackageInstall: installing \(safeFileName) to \(request.targetVolume)")

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
                Logger.shared.info("PackageInstall: success for \(safeFileName)")
            } else {
                Logger.shared.error("PackageInstall: failed (\(process.terminationStatus)) for \(safeFileName)")
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

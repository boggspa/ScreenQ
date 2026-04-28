//
//  SystemReportCollector.swift
//  Screen Q
//
//  Collects comprehensive hardware and software information from the
//  host Mac for remote audit / reporting, similar to ARD's system info.
//

#if os(macOS)
import Foundation
import IOKit

@MainActor
final class SystemReportCollector {

    func collect(requestID: UUID) -> SystemReportMessage {
        return SystemReportMessage(
            requestID: requestID,
            hostname: ProcessInfo.processInfo.hostName,
            macOSVersion: macOSVersion(),
            buildNumber: buildNumber(),
            hardwareModel: hardwareModel(),
            serialNumber: serialNumber(),
            cpuType: cpuType(),
            cpuCoreCount: ProcessInfo.processInfo.processorCount,
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            diskTotalGB: diskSpace().total,
            diskFreeGB: diskSpace().free,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            ipAddresses: localIPAddresses(),
            installedApps: installedApplications()
        )
    }

    // MARK: - Private helpers

    private func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func buildNumber() -> String {
        shellOutput("/usr/bin/sw_vers", args: ["-buildVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func serialNumber() -> String? {
        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let cfSerial = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)
        return cfSerial?.takeRetainedValue() as? String
    }

    private func cpuType() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let s = String(cString: brand)
        return s.isEmpty ? "Apple Silicon" : s
    }

    private func diskSpace() -> (total: Double, free: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free = attrs[.systemFreeSize] as? Int64 else {
            return (0, 0)
        }
        return (Double(total) / 1_073_741_824, Double(free) / 1_073_741_824)
    }

    private func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) || sa.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            addresses.append(String(cString: hostname))
        }
        return addresses
    }

    private func installedApplications() -> [SystemReportMessage.InstalledApp] {
        let appsDir = URL(fileURLWithPath: "/Applications")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: appsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> SystemReportMessage.InstalledApp? in
            guard url.pathExtension == "app" else { return nil }
            let plistURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return SystemReportMessage.InstalledApp(name: url.deletingPathExtension().lastPathComponent, version: nil, bundleID: nil)
            }
            return SystemReportMessage.InstalledApp(
                name: plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                version: plist["CFBundleShortVersionString"] as? String,
                bundleID: plist["CFBundleIdentifier"] as? String
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func shellOutput(_ path: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
#endif

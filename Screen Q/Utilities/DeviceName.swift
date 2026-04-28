//
//  DeviceName.swift
//  Screen Q
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

enum DeviceName {

    /// Sanitised, advertised-on-the-network name for this device.
    /// We strip control characters and clamp the length.
    static func localDeviceName() -> String {
        let raw: String = {
            #if os(macOS)
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            #elseif os(iOS) || os(visionOS)
            return UIDevice.current.name
            #else
            return ProcessInfo.processInfo.hostName
            #endif
        }()

        return sanitise(raw)
    }

    static func sanitise(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        var s = String(String.UnicodeScalarView(stripped))
        if s.count > 60 {
            s = String(s.prefix(60))
        }
        if s.isEmpty { s = "Screen Q Device" }
        return s
    }
}

//
//  XTScanCodeMap.swift
//  Screen Q
//
//  Maps X11 keysyms to XT (PS/2 set 1) scan codes for use with the
//  QEMU Extended Key Event RFB extension.  Only the most common keys
//  are covered; unmapped keysyms fall back to the legacy KeyEvent path.
//

import Foundation

enum XTScanCodeMap {

    /// XT/PS-2 set 1 scan codes. Multi-byte codes are encoded with the
    /// high byte holding the prefix (0xE0 for extended keys).
    static func scanCode(forKeysym keysym: UInt32) -> UInt32? {
        // ASCII printable
        switch keysym {
        case 0x0061...0x007A: // a..z
            return lowercaseAlpha[Int(keysym - 0x0061)]
        case 0x0041...0x005A: // A..Z (same scan codes as lowercase, server tracks shift state)
            return lowercaseAlpha[Int(keysym - 0x0041)]
        case 0x0030...0x0039: // 0..9
            // 1=0x02, 2=0x03, ..., 9=0x0A, 0=0x0B
            if keysym == 0x0030 { return 0x0B }
            return UInt32(keysym - 0x0030 + 0x01)
        default:
            break
        }
        return specialMap[keysym]
    }

    private static let lowercaseAlpha: [UInt32] = [
        0x1E, // a
        0x30, // b
        0x2E, // c
        0x20, // d
        0x12, // e
        0x21, // f
        0x22, // g
        0x23, // h
        0x17, // i
        0x24, // j
        0x25, // k
        0x26, // l
        0x32, // m
        0x31, // n
        0x18, // o
        0x19, // p
        0x10, // q
        0x13, // r
        0x1F, // s
        0x14, // t
        0x16, // u
        0x2F, // v
        0x11, // w
        0x2D, // x
        0x15, // y
        0x2C  // z
    ]

    private static let specialMap: [UInt32: UInt32] = [
        // Whitespace / control
        0x0020: 0x39,           // Space
        0xFF08: 0x0E,           // Backspace
        0xFF09: 0x0F,           // Tab
        0xFF0D: 0x1C,           // Return
        0xFF1B: 0x01,           // Escape
        0xFFFF: 0xE053,         // Delete (forward)

        // Navigation
        0xFF50: 0xE047,         // Home
        0xFF51: 0xE04B,         // Left
        0xFF52: 0xE048,         // Up
        0xFF53: 0xE04D,         // Right
        0xFF54: 0xE050,         // Down
        0xFF55: 0xE049,         // PageUp
        0xFF56: 0xE051,         // PageDown
        0xFF57: 0xE04F,         // End
        0xFF63: 0xE052,         // Insert

        // Function
        0xFFBE: 0x3B, 0xFFBF: 0x3C, 0xFFC0: 0x3D, 0xFFC1: 0x3E,  // F1-F4
        0xFFC2: 0x3F, 0xFFC3: 0x40, 0xFFC4: 0x41, 0xFFC5: 0x42,  // F5-F8
        0xFFC6: 0x43, 0xFFC7: 0x44, 0xFFC8: 0x57, 0xFFC9: 0x58,  // F9-F12

        // Modifiers
        0xFFE1: 0x2A,           // ShiftL
        0xFFE2: 0x36,           // ShiftR
        0xFFE3: 0x1D,           // ControlL
        0xFFE4: 0xE01D,         // ControlR
        0xFFE5: 0x3A,           // CapsLock
        0xFFE7: 0xE05B,         // MetaL (Cmd)
        0xFFE8: 0xE05C,         // MetaR
        0xFFE9: 0x38,           // AltL
        0xFFEA: 0xE038,         // AltR
        0xFFEB: 0xE05B,         // SuperL (Win/Cmd)
        0xFFEC: 0xE05C,         // SuperR

        // Punctuation (US layout)
        0x002D: 0x0C,           // -
        0x003D: 0x0D,           // =
        0x005B: 0x1A,           // [
        0x005D: 0x1B,           // ]
        0x005C: 0x2B,           // \
        0x003B: 0x27,           // ;
        0x0027: 0x28,           // '
        0x0060: 0x29,           // `
        0x002C: 0x33,           // ,
        0x002E: 0x34,           // .
        0x002F: 0x35,           // /
    ]
}

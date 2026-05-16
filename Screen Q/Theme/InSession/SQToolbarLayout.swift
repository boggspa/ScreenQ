//
//  SQToolbarLayout.swift
//  Screen Q  ·  Theme / In-Session
//
//  Stateless geometry helpers for the floating/docked in-session toolbar.
//  Lives here so RDP, VNC, and Screen Q native viewers can all use the
//  same clamping / placement maths without copy-pasting.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum SQToolbarLayout {

    static func placement(for value: ViewerToolbarPlacement) -> SQInSessionToolbarPlacement {
        switch value {
        case .top:      return .top
        case .bottom:   return .bottom
        case .leading:  return .leading
        case .trailing: return .trailing
        }
    }

    static func usesFloatingToolbar(style: ViewerToolbarStyle, isPad: Bool) -> Bool {
        switch style {
        case .floating:        return true
        case .docked, .native: return false
        case .dockedFloating:  return isPad
        }
    }

    static func resolvedPlacement(
        style: ViewerToolbarStyle,
        placement: ViewerToolbarPlacement,
        size: CGSize,
        isPad: Bool
    ) -> ViewerToolbarPlacement {
        if style == .dockedFloating, !isPad, size.width > size.height {
            return .leading
        }
        return placement
    }

    static func footprint(condensed: Bool, vertical: Bool, in size: CGSize, isPad: Bool) -> CGSize {
        if condensed {
            return vertical ? CGSize(width: 58, height: 126) : CGSize(width: 126, height: 58)
        }
        if vertical {
            return CGSize(width: 80, height: min(max(size.height - 20, 80), 660))
        }
        return CGSize(width: min(max(size.width - 20, 126), isPad ? 940 : 760), height: 70)
    }

    static func basePosition(
        placement: ViewerToolbarPlacement,
        condensed: Bool,
        in size: CGSize,
        isPad: Bool
    ) -> CGPoint {
        if condensed {
            let vertical = placement == .leading || placement == .trailing
            let footprint = footprint(condensed: true, vertical: vertical, in: size, isPad: isPad)
            let x = 10 + min(footprint.width / 2, max(0, size.width / 2 - 10))
            switch placement {
            case .top:                return CGPoint(x: x, y: 68)
            case .bottom:             return CGPoint(x: x, y: size.height - 68)
            case .leading, .trailing: return CGPoint(x: x, y: size.height / 2)
            }
        }
        switch placement {
        case .top:      return CGPoint(x: size.width / 2, y: 68)
        case .bottom:   return CGPoint(x: size.width / 2, y: size.height - 68)
        case .leading:  return CGPoint(x: 58, y: size.height / 2)
        case .trailing: return CGPoint(x: size.width - 58, y: size.height / 2)
        }
    }

    static func clampedOffset(
        _ offset: CGSize,
        in size: CGSize,
        base: CGPoint,
        vertical: Bool,
        condensed: Bool,
        isPad: Bool
    ) -> CGSize {
        let edge: CGFloat = 10
        let footprintSize = footprint(condensed: condensed, vertical: vertical, in: size, isPad: isPad)
        let halfWidth  = min(footprintSize.width  / 2, max(0, size.width  / 2 - edge))
        let halfHeight = min(footprintSize.height / 2, max(0, size.height / 2 - edge))
        let minCenterX = edge + halfWidth
        let maxCenterX = max(minCenterX, size.width  - edge - halfWidth)
        let minCenterY = edge + halfHeight
        let maxCenterY = max(minCenterY, size.height - edge - halfHeight)
        return CGSize(
            width:  min(max(offset.width,  minCenterX - base.x), maxCenterX - base.x),
            height: min(max(offset.height, minCenterY - base.y), maxCenterY - base.y)
        )
    }

    static func dockedAlignment(for placement: ViewerToolbarPlacement, condensed: Bool) -> Alignment {
        if condensed {
            switch placement {
            case .top:                return .topLeading
            case .bottom:             return .bottomLeading
            case .leading, .trailing: return .leading
            }
        }
        switch placement {
        case .top:      return .top
        case .bottom:   return .bottom
        case .leading:  return .leading
        case .trailing: return .trailing
        }
    }

    static func dockedPadding(for placement: ViewerToolbarPlacement, condensed: Bool) -> EdgeInsets {
        if condensed {
            switch placement {
            case .top:                return EdgeInsets(top: 10, leading: 10, bottom: 0,  trailing: 0)
            case .bottom:             return EdgeInsets(top: 0,  leading: 10, bottom: 10, trailing: 0)
            case .leading, .trailing: return EdgeInsets(top: 10, leading: 8,  bottom: 10, trailing: 0)
            }
        }
        switch placement {
        case .top:      return EdgeInsets(top: 10, leading: 10, bottom: 0,  trailing: 10)
        case .bottom:   return EdgeInsets(top: 0,  leading: 10, bottom: 10, trailing: 10)
        case .leading:  return EdgeInsets(top: 10, leading: 8,  bottom: 10, trailing: 0)
        case .trailing: return EdgeInsets(top: 10, leading: 0,  bottom: 10, trailing: 8)
        }
    }
}

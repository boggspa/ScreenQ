//
//  BroadcastInstructions.swift
//  Screen Q
//
//  Static text content for the iOS / iPadOS view-only host screen and the
//  "Apple-native alternatives" page. Kept separate from the views so the
//  copy is easy to localise / audit.
//

import Foundation

enum BroadcastInstructions {

    static let viewOnlyTitle = "iPhone / iPad screens are share-only"

    static let viewOnlyBody = """
    Screen Q can share this device's screen using Apple's ReplayKit. Apple does \
    not expose any third-party API for injecting touches, key presses, or pointer \
    events into iOS or iPadOS — so a viewer on the other side will see your screen \
    but cannot operate it.

    For real remote control of an iPhone or iPad, use Apple-native flows:
      • FaceTime SharePlay Remote Control (one-to-one FaceTime call where available)
      • iPhone Mirroring on a nearby Mac (where available)
      • Switch Control / platform switching (accessibility)

    Screen Q always respects these platform limits — no private APIs, no \
    jailbreak assumptions, no MDM-only tricks.
    """

    static let broadcastSteps = [
        "Tap the broadcast button below.",
        "Pick a Screen Q broadcast extension from the system sheet.",
        "Tap Start Broadcasting. iOS counts down 3-2-1 then begins capture.",
        "To end the broadcast, tap the red status pill in the status bar."
    ]
}

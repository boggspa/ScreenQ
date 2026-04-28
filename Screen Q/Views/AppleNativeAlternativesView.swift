//
//  AppleNativeAlternativesView.swift
//  Screen Q
//
//  Help page that points users at first-party Apple workflows so they don't
//  expect Screen Q to do things only OS-owned subsystems can do.
//

import SwiftUI

struct AppleNativeAlternativesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(items) { item in
                    AlternativeCard(item: item)
                }
                footer
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Apple-native alternatives")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use the right tool for the job")
                .font(.title2).bold()
            Text("Screen Q implements what third-party apps can do safely. For everything else, Apple ships first-party flows that are more powerful and more private.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Screen Q never tries to reimplement private Apple system behaviour. We point you at the OS-owned flow.")
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    fileprivate struct Item: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let summary: String
        let steps: [String]
    }

    private let items: [Item] = [
        Item(
            title: "Mac → Mac native Screen Sharing",
            symbol: "macwindow.on.rectangle",
            summary: "Built-in Mac Screen Sharing / Remote Management uses Apple's RFB-based system. Use it if you don't need Screen Q's pairing flow.",
            steps: [
                "On the host Mac, open System Settings → General → Sharing.",
                "Enable Screen Sharing or Remote Management.",
                "On the viewer Mac, open Finder → Go → Connect to Server… and enter vnc://hostname.",
                "Or use Screen Sharing.app directly with the host's Apple ID."
            ]
        ),
        Item(
            title: "FaceTime SharePlay Remote Control",
            symbol: "person.2.wave.2",
            summary: "In a one-to-one FaceTime call, you can ask to take control of the other person's screen.",
            steps: [
                "Start a FaceTime call.",
                "Tap the share / SharePlay button.",
                "Choose Share my screen, or request control of theirs (where available).",
                "The OS — not Screen Q — manages this completely."
            ]
        ),
        Item(
            title: "iPhone Mirroring on Mac",
            symbol: "iphone.and.arrow.forward",
            summary: "On supported macOS / iOS versions, a Mac can mirror and interact with a nearby iPhone.",
            steps: [
                "On the Mac, open the iPhone Mirroring app.",
                "Authenticate with Face ID / Touch ID / passcode on the iPhone.",
                "Use the Mac's keyboard, mouse, and trackpad to drive the iPhone.",
                "Apple-only; not something a third-party app can replicate."
            ]
        ),
        Item(
            title: "Universal Control",
            symbol: "rectangle.connected.to.line.below",
            summary: "Use one keyboard and mouse across a Mac and an iPad sitting next to it.",
            steps: [
                "Place the iPad next to the Mac, on the same Apple ID.",
                "Glide the cursor to the edge of the Mac display until it crosses to the iPad.",
                "Adjust positions in System Settings → Displays."
            ]
        ),
        Item(
            title: "Switch Control / Accessibility",
            symbol: "accessibility",
            summary: "Apple's built-in Switch Control and Platform Switching are first-class accessibility features for navigating and controlling devices.",
            steps: [
                "Open Settings → Accessibility → Switch Control.",
                "Configure your switch source (camera, external switch, etc.).",
                "Use platform switching to drive a paired Apple TV / iPad / Mac with the same switches."
            ]
        ),
        Item(
            title: "Tailscale (network reachability)",
            symbol: "lock.shield",
            summary: "Screen Q is LAN-first. Use Tailscale on both ends to reach a host across networks privately, then connect by MagicDNS name or 100.x address.",
            steps: [
                "Install Tailscale on both devices and sign in to the same tailnet.",
                "Look up the host's MagicDNS name (e.g. mac-mini.tailnet.ts.net).",
                "In Screen Q's manual connect form, enter that name and the Screen Q port.",
                "Tailscale is the network layer — Screen Q does not vendor or modify it."
            ]
        )
    ]
}

private struct AlternativeCard: View {
    let item: AppleNativeAlternativesView.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: item.symbol)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(item.title)
                    .font(.headline)
            }
            Text(item.summary)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(Array(item.steps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(idx + 1).").bold()
                    Text(step)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

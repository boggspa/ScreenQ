//
//  AppleNativeAlternativesView.swift
//  Screen Q
//
//  Help page that points users at first-party Apple workflows so they don't
//  expect Screen Q to do things only OS-owned subsystems can do.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
        .navigationTitle("Apple-native alternatives")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ScreenQBrandMark(size: 38)
                Text("Use the right tool for the job")
                    .font(.sqTitle)
                    .foregroundColor(.primary)
            }
            Text("Screen Q implements what third-party apps can do safely. For everything else, Apple ships first-party flows that are more powerful and more private.")
                .font(.sqBody)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Screen Q never tries to reimplement private Apple system behaviour. We point you at the OS-owned flow.")
            .font(.sqCaption)
            .foregroundColor(.secondary)
    }

    fileprivate struct Item: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let summary: String
        let steps: [String]
        let openTitle: String?
        let openURL: URL?
    }

    private var items: [Item] {
        #if os(macOS)
        let openScreenSharingURL: URL? = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Screen Sharing.app")
        let openScreenSharingTitle: String? = "Open Screen Sharing"
        #else
        let openScreenSharingURL: URL? = nil
        let openScreenSharingTitle: String? = nil
        #endif
        return [
            Item(
                title: "Mac → Mac native Screen Sharing",
                symbol: "macwindow.on.rectangle",
                summary: "Built-in Mac Screen Sharing / Remote Management uses Apple's RFB-based system. Use it if you don't need Screen Q's pairing flow.",
                steps: [
                    "On the host Mac, open System Settings → General → Sharing.",
                    "Enable Screen Sharing or Remote Management.",
                    "On the viewer Mac, open Finder → Go → Connect to Server… and enter vnc://hostname.",
                    "Or use Screen Sharing.app directly with the host's Apple ID."
                ],
                openTitle: openScreenSharingTitle,
                openURL: openScreenSharingURL
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
                ],
                openTitle: nil,
                openURL: nil
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
                ],
                openTitle: nil,
                openURL: nil
            ),
            Item(
                title: "Universal Control",
                symbol: "rectangle.connected.to.line.below",
                summary: "Use one keyboard and mouse across a Mac and an iPad sitting next to it.",
                steps: [
                    "Place the iPad next to the Mac, on the same Apple ID.",
                    "Glide the cursor to the edge of the Mac display until it crosses to the iPad.",
                    "Adjust positions in System Settings → Displays."
                ],
                openTitle: nil,
                openURL: nil
            ),
            Item(
                title: "Switch Control / Accessibility",
                symbol: "accessibility",
                summary: "Apple's built-in Switch Control and Platform Switching are first-class accessibility features for navigating and controlling devices.",
                steps: [
                    "Open Settings → Accessibility → Switch Control.",
                    "Configure your switch source (camera, external switch, etc.).",
                    "Use platform switching to drive a paired Apple TV / iPad / Mac with the same switches."
                ],
                openTitle: nil,
                openURL: nil
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
                ],
                openTitle: nil,
                openURL: nil
            )
        ]
    }
}

private struct AlternativeCard: View {
    let item: AppleNativeAlternativesView.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ScreenQTheme.accent(ScreenQTheme.cosmicViolet))
                        .frame(width: 42, height: 42)
                        .shadow(color: ScreenQTheme.cosmicViolet.opacity(0.35), radius: 8, x: 0, y: 4)
                    Image(systemName: item.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                }
                Text(item.title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            Text(item.summary)
                .font(.sqBody)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(item.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.sqCallout)
                            .foregroundColor(ScreenQTheme.cosmicViolet)
                            .frame(width: 18, alignment: .leading)
                        Text(step)
                            .font(.sqCallout)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let title = item.openTitle, let url = item.openURL {
                Button {
                    SQHaptics.tap()
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityHidden(true)
                        Text(title)
                    }
                    .font(.sqHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicViolet)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenQCard(tint: ScreenQTheme.cosmicViolet)
    }

    private func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}

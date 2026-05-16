//
//  SQToolbarCustomizationSheet.swift
//  Screen Q  ·  Theme / In-Session
//
//  Customization + gesture-help sheets extracted from the iOS session
//  surface. Hosted here so other viewers (RDP, VNC) can reuse the same
//  configuration UI without copy-pasting.
//

#if os(iOS)
import SwiftUI

struct SQToolbarCustomizationSheet: View {

    @ObservedObject var preferences: ViewerControlPreferences
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Placement") {
                    Picker("Style", selection: $preferences.toolbarStyle) {
                        Text(ViewerToolbarStyle.dockedFloating.label).tag(ViewerToolbarStyle.dockedFloating)
                        Text(ViewerToolbarStyle.docked.label).tag(ViewerToolbarStyle.docked)
                        Text(ViewerToolbarStyle.floating.label).tag(ViewerToolbarStyle.floating)
                    }
                    Picker("Position", selection: $preferences.toolbarPlacement) {
                        ForEach(ViewerToolbarPlacement.allCases) { placement in
                            Label(placement.label, systemImage: placement.icon).tag(placement)
                        }
                    }
                    Button("Reset Floating Position") { preferences.toolbarOffset = .zero }
                }
                Section("Cursor") {
                    Toggle("Show Overlay Cursor", isOn: $preferences.showCursorOverlay)
                }
                Section("Density") {
                    Toggle("Condensed Toolbar", isOn: $preferences.toolbarCondensed)
                }
                Section("Modifiers") {
                    Toggle("Sticky on long-press", isOn: $preferences.stickyModifierOnLongPress)
                    HStack {
                        Text("Auto-release after")
                        Spacer()
                        Stepper(value: $preferences.modifierAutoReleaseSeconds, in: 1.0...30.0, step: 0.5) {
                            Text("\(preferences.modifierAutoReleaseSeconds, specifier: "%.1f")s")
                                .monospacedDigit()
                        }
                    }
                }
                Section("Stats HUD") {
                    Toggle("Collapsed", isOn: $preferences.statsHUDCollapsed)
                    Button("Reset Position") { preferences.statsHUDAnchor = .zero }
                }
                Section("Toolbar Items") {
                    ForEach(preferences.toolbarItems) { item in
                        HStack(spacing: 12) {
                            Label(item.label, systemImage: item.icon)
                            Spacer()
                            if item.isRequired {
                                Text("Required").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Toggle(
                                    item.label,
                                    isOn: Binding(
                                        get: { preferences.isToolbarItemVisible(item) },
                                        set: { preferences.setToolbarItem(item, visible: $0) }
                                    )
                                )
                                .labelsHidden()
                            }
                        }
                    }
                    .onMove { source, destination in
                        preferences.moveToolbarItems(from: source, to: destination)
                    }
                }
                Section {
                    Button("Reset Default Toolbar") { preferences.resetToolbarItems() }
                }
            }
            .navigationTitle("Customize Toolbar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

struct SQGestureHelpSheet: View {

    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Touch") {
                    Label("Tap clicks where you touch.",        systemImage: "hand.tap")
                    Label("Double tap sends a double click.",   systemImage: "hand.tap.fill")
                    Label("Long press starts a drag.",          systemImage: "cursorarrow.motionlines")
                    Label("Two-finger tap right-clicks.",       systemImage: "contextualmenu.and.cursorarrow")
                    Label("Three-finger tap middle-clicks.",    systemImage: "circle.grid.cross")
                }
                Section("Viewport") {
                    Label("Two-finger pinch zooms the local view.",   systemImage: "plus.magnifyingglass")
                    Label("Two-finger drag scrolls the remote Mac.",  systemImage: "scroll")
                    Label("Two-finger double tap hides or shows controls.", systemImage: "slider.horizontal.3")
                }
                Section("Modifiers") {
                    Label("Tap a modifier for the next action.", systemImage: "shift")
                    Label("Long-press a modifier to lock it.",   systemImage: "lock")
                }
            }
            .navigationTitle("Gestures")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

#endif

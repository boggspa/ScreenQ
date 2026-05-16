//
//  FleetSidebarView.swift
//  Screen Q
//
//  A sidebar for managing groups and computers, similar to ARD's computer
//  list panel. Supports adding/removing computers, creating groups,
//  scanning IP ranges, and showing online/offline status.
//

import SwiftUI

struct FleetSidebarView: View {

    @ObservedObject var store: ComputerListStore
    @Binding var selectedComputerIDs: Set<UUID>
    var onConnect: (ComputerEntry) -> Void

    @State private var showAddGroup = false
    @State private var newGroupName = ""
    @State private var showAddComputer = false
    @State private var showScanSheet = false
    @State private var scanBase = "192.168.1"
    @State private var scanStart = 1
    @State private var scanEnd = 254
    @State private var isScanning = false

    var body: some View {
        Group {
            if store.groups.isEmpty && store.computers.isEmpty {
                emptyFleet
            } else {
                fleetList
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Add Computer…") {
                        SQHaptics.tap()
                        showAddComputer = true
                    }
                    Button("New Group…") {
                        SQHaptics.tap()
                        showAddGroup = true
                    }
                    Divider()
                    Button("Scan IP Range…") {
                        SQHaptics.tap()
                        showScanSheet = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(isPresented: $showAddGroup) { addGroupSheet }
        .sheet(isPresented: $showAddComputer) { addComputerSheet }
        .sheet(isPresented: $showScanSheet) { scanSheet }
    }

    // MARK: - Empty

    private var emptyFleet: some View {
        ZStack {
            ScreenQTheme.heroBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                SQEmptyState(
                    icon: "rectangle.stack.person.crop",
                    title: "No computers yet",
                    message: "Add a Mac, scan an IP range, or create a group to organise your fleet.",
                    tint: ScreenQTheme.cosmicCyan,
                    primary: .init("Add Computer", systemImage: "plus") {
                        SQHaptics.tap()
                        showAddComputer = true
                    },
                    secondary: .init("Scan Network", systemImage: "antenna.radiowaves.left.and.right") {
                        SQHaptics.tap()
                        showScanSheet = true
                    }
                )
                .screenQCard(tint: ScreenQTheme.cosmicCyan)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: 360)
        }
    }

    // MARK: - List

    private var fleetList: some View {
        List(selection: $selectedComputerIDs) {
            if !store.groups.isEmpty {
                Section {
                    ForEach(store.groups) { group in
                        DisclosureGroup {
                            ForEach(store.computers(in: group)) { computer in
                                computerRow(computer)
                            }
                        } label: {
                            Label(group.name, systemImage: group.icon)
                                .font(.sqHeadline)
                        }
                    }
                } header: {
                    Text("Groups")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
            }

            Section {
                ForEach(store.computers) { computer in
                    computerRow(computer)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.computers[$0].id }
                    ids.forEach { store.removeComputer($0) }
                }
            } header: {
                Text("All Computers (\(store.computers.count))")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Row

    private func computerRow(_ computer: ComputerEntry) -> some View {
        HStack(spacing: 10) {
            LiveStatusDot(
                color: statusColor(computer.lastStatus),
                active: computer.lastStatus == .online
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.displayName)
                    .font(.sqBody)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(computer.host):\(computer.port)")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                SQHaptics.tap()
                onConnect(computer)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(ScreenQTheme.cosmicCyan)
            }
            .buttonStyle(.plain)
            .help("Connect")
            .accessibilityLabel("Connect to \(computer.displayName)")
        }
        .padding(.vertical, 4)
        .tag(computer.id)
    }

    private func statusColor(_ status: ComputerEntry.MachineStatus) -> Color {
        switch status {
        case .online:   return ScreenQTheme.cosmicMint
        case .offline:  return ScreenQTheme.cosmicRose
        case .sleeping: return ScreenQTheme.cosmicAmber
        case .unknown:  return Color.secondary
        }
    }

    // MARK: - Add Group

    private var addGroupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ScreenQBrandMark(size: 30)
                Text("New Group")
                    .font(.sqTitle)
                Spacer()
            }
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .font(.sqBody)
            HStack {
                Button("Cancel") {
                    SQHaptics.tap()
                    showAddGroup = false
                }
                .buttonStyle(.plain)
                .font(.sqCallout)
                .foregroundColor(.secondary)
                Spacer()
                Button {
                    SQHaptics.success()
                    store.addGroup(name: newGroupName)
                    newGroupName = ""
                    showAddGroup = false
                } label: {
                    Text("Create")
                        .font(.sqHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                newGroupName.isEmpty
                                    ? Color.secondary.opacity(0.18)
                                    : ScreenQTheme.cosmicCyan
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(newGroupName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    // MARK: - Add Computer

    @State private var newHost = ""
    @State private var newPort: String = "38745"
    @State private var newName = ""
    @State private var newMACAddress = ""

    private var addComputerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScreenQBrandMark(size: 30)
                Text("Add Computer")
                    .font(.sqTitle)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Display name", text: $newName)
                TextField("Host / IP", text: $newHost)
                TextField("Port", text: $newPort)
                TextField("Wake MAC address (optional)", text: $newMACAddress)
            }
            .textFieldStyle(.roundedBorder)
            .font(.sqBody)

            HStack {
                Button("Cancel") {
                    SQHaptics.tap()
                    showAddComputer = false
                }
                .buttonStyle(.plain)
                .font(.sqCallout)
                .foregroundColor(.secondary)
                Spacer()
                Button {
                    SQHaptics.success()
                    let port = UInt16(newPort) ?? 38745
                    let entry = ComputerEntry(
                        displayName: newName.isEmpty ? newHost : newName,
                        host: newHost,
                        port: port,
                        macAddress: WakeOnLAN.normalizedMACString(newMACAddress)
                    )
                    store.addComputer(entry)
                    showAddComputer = false
                    newHost = ""; newPort = "38745"; newName = ""; newMACAddress = ""
                } label: {
                    Text("Add")
                        .font(.sqHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                newHost.isEmpty
                                    ? Color.secondary.opacity(0.18)
                                    : ScreenQTheme.cosmicCyan
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(newHost.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    // MARK: - Scan

    private var scanSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScreenQBrandMark(size: 30)
                Text("Scan IP Range")
                    .font(.sqTitle)
                Spacer()
            }
            HStack {
                TextField("Base (e.g. 192.168.1)", text: $scanBase)
                    .textFieldStyle(.roundedBorder)
                    .font(.sqBody)
                Text(".\(scanStart)–\(scanEnd)")
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
            }
            HStack {
                Stepper("Start: \(scanStart)", value: $scanStart, in: 1...254)
                    .font(.sqCallout)
                Stepper("End: \(scanEnd)", value: $scanEnd, in: 1...254)
                    .font(.sqCallout)
            }
            HStack {
                Button("Cancel") {
                    SQHaptics.tap()
                    showScanSheet = false
                }
                .buttonStyle(.plain)
                .font(.sqCallout)
                .foregroundColor(.secondary)
                Spacer()
                if isScanning {
                    ScreenQActivityTrail(tint: ScreenQTheme.cosmicCyan)
                }
                Button {
                    SQHaptics.bump()
                    isScanning = true
                    Task {
                        await store.scanIPRange(base: scanBase, start: scanStart, end: scanEnd)
                        isScanning = false
                        showScanSheet = false
                    }
                } label: {
                    Text(isScanning ? "Scanning…" : "Scan")
                        .font(.sqHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                (isScanning || scanBase.isEmpty)
                                    ? Color.secondary.opacity(0.18)
                                    : ScreenQTheme.cosmicCyan
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isScanning || scanBase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }
}

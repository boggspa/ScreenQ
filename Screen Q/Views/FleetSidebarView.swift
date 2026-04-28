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
        List(selection: $selectedComputerIDs) {
            Section(header: Text("Groups")) {
                ForEach(store.groups) { group in
                    DisclosureGroup {
                        ForEach(store.computers(in: group)) { computer in
                            computerRow(computer)
                        }
                    } label: {
                        Label(group.name, systemImage: group.icon)
                    }
                }
            }

            Section(header: Text("All Computers (\(store.computers.count))")) {
                ForEach(store.computers) { computer in
                    computerRow(computer)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.computers[$0].id }
                    ids.forEach { store.removeComputer($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Add Computer…") { showAddComputer = true }
                    Button("New Group…") { showAddGroup = true }
                    Divider()
                    Button("Scan IP Range…") { showScanSheet = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddGroup) { addGroupSheet }
        .sheet(isPresented: $showAddComputer) { addComputerSheet }
        .sheet(isPresented: $showScanSheet) { scanSheet }
    }

    // MARK: - Row

    private func computerRow(_ computer: ComputerEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(computer.lastStatus))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.displayName)
                    .font(.body)
                Text("\(computer.host):\(computer.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                onConnect(computer)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .help("Connect")
        }
        .tag(computer.id)
    }

    private func statusColor(_ status: ComputerEntry.MachineStatus) -> Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .sleeping: return .orange
        case .unknown: return .gray
        }
    }

    // MARK: - Add Group

    private var addGroupSheet: some View {
        VStack(spacing: 16) {
            Text("New Group").font(.headline)
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showAddGroup = false }
                Spacer()
                Button("Create") {
                    store.addGroup(name: newGroupName)
                    newGroupName = ""
                    showAddGroup = false
                }
                .buttonStyle(.bordered)
                .disabled(newGroupName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // MARK: - Add Computer

    @State private var newHost = ""
    @State private var newPort: String = "38745"
    @State private var newName = ""

    private var addComputerSheet: some View {
        VStack(spacing: 12) {
            Text("Add Computer").font(.headline)
            TextField("Display name", text: $newName)
            TextField("Host / IP", text: $newHost)
            TextField("Port", text: $newPort)
            HStack {
                Button("Cancel") { showAddComputer = false }
                Spacer()
                Button("Add") {
                    let port = UInt16(newPort) ?? 38745
                    let entry = ComputerEntry(
                        displayName: newName.isEmpty ? newHost : newName,
                        host: newHost,
                        port: port
                    )
                    store.addComputer(entry)
                    showAddComputer = false
                    newHost = ""; newPort = "38745"; newName = ""
                }
                .buttonStyle(.bordered)
                .disabled(newHost.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Scan

    private var scanSheet: some View {
        VStack(spacing: 12) {
            Text("Scan IP Range").font(.headline)
            HStack {
                TextField("Base (e.g. 192.168.1)", text: $scanBase)
                Text(".\(scanStart)–\(scanEnd)")
                    .foregroundColor(.secondary)
            }
            HStack {
                Stepper("Start: \(scanStart)", value: $scanStart, in: 1...254)
                Stepper("End: \(scanEnd)", value: $scanEnd, in: 1...254)
            }
            HStack {
                Button("Cancel") { showScanSheet = false }
                Spacer()
                if isScanning {
                    ProgressView().controlSize(.small)
                }
                Button("Scan") {
                    isScanning = true
                    Task {
                        await store.scanIPRange(base: scanBase, start: scanStart, end: scanEnd)
                        isScanning = false
                        showScanSheet = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isScanning || scanBase.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 400)
    }
}

import SwiftUI
import Subscription
import Diagnostics

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusCard(state: model.state, lastError: model.lastError)
            HStack(spacing: 16) {
                InfoCard(title: "Mode", value: model.mode.rawValue)
                InfoCard(title: "Node", value: model.activeNode?.name ?? "None")
                InfoCard(title: "Ports", value: "S\(model.settings.socksPort) / H\(model.settings.httpPort)")
            }
            HStack(spacing: 16) {
                InfoCard(title: "Connections", value: "\(model.stats.activeConnections)")
                InfoCard(title: "Up/Down", value: "\(model.stats.uploadBytes / 1024) KB / \(model.stats.downloadBytes / 1024) KB")
            }
            if let error = model.lastError {
                DisclosureGroup("最近错误") {
                    Text(error)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }
}

struct DashboardDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
            Button("Import Sample Subscription") {
                model.importSample()
            }
            Button("Export Diagnostics") {
                model.exportDiagnostics()
            }
            Spacer()
        }
        .padding()
    }
}

struct NodesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var searchText: String
    @State private var showingImport = false
    @State private var importText = ""
    @State private var selection = Set<ProxyNode.ID>()

    var filteredNodes: [ProxyNode] {
        if searchText.isEmpty { return model.nodes }
        return model.nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.host.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Import Sample") { model.importSample() }
                Button("Import Text") { showingImport = true }
                Button("Import File") { model.importFile() }
            }
            Table(filteredNodes, selection: $selection) {
                TableColumn("Name") { node in
                    Text(node.name)
                }
            TableColumn("Type") { node in
                Text(node.type.rawValue)
            }
            TableColumn("Host") { node in
                Text(node.host)
            }
            TableColumn("Port") { node in
                Text("\(node.port)")
            }
            TableColumn("Latency") { node in
                Text(node.lastLatencyMs.map { "\($0) ms" } ?? "--")
            }
            }
            .contextMenu(forSelectionType: ProxyNode.ID.self) { selection in
                if let node = model.nodes.first(where: { $0.id == selection }) {
                    Button("Set Active") { model.activeNode = node }
                    Button("Test") { model.testNode(node) }
                }
            } primaryAction: { selection in
                if let node = model.nodes.first(where: { $0.id == selection }) {
                    model.selectedNode = node
                }
            }
            .onChange(of: selection) { _, newValue in
                if let id = newValue.first, let node = model.nodes.first(where: { $0.id == id }) {
                    model.selectedNode = node
                }
            }
        }
        .sheet(isPresented: $showingImport) {
            VStack(alignment: .leading) {
                Text("Paste subscription lines")
                    .font(.headline)
                TextEditor(text: $importText)
                    .frame(minHeight: 200)
                HStack {
                    Button("Cancel") { showingImport = false }
                    Spacer()
                    Button("Import") {
                        model.importText(importText)
                        showingImport = false
                    }
                }
            }
            .padding()
            .frame(width: 400)
        }
        .padding()
    }
}

struct NodeDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let node = model.selectedNode {
                Text(node.name)
                    .font(.title2)
                Text("\(node.type.rawValue.uppercased()) · \(node.host):\(node.port)")
                    .foregroundColor(.secondary)
                HStack {
                    Button("Test") { model.testNode(node) }
                    Button("Set Active") { model.activeNode = node }
                }
            } else {
                Text("Select a node")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var directDomains: String = ""
    @State private var directKeywords: String = ""

    var body: some View {
        Form {
            Toggle("Enable Rule Mode", isOn: Binding(
                get: { model.mode == .rule },
                set: { model.applyMode($0 ? .rule : .global) }
            ))
            Section("DIRECT Domains (suffix per line)") {
                TextEditor(text: $directDomains)
                    .frame(minHeight: 120)
                Text("CIDR ranges are simplified in PAC; use domain suffix/keyword for best results.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("DIRECT Keywords") {
                TextEditor(text: $directKeywords)
                    .frame(minHeight: 120)
            }
            Toggle("Bypass local/private networks", isOn: Binding(
                get: { model.pacRules.bypassLocalNetworks },
                set: { model.pacRules.bypassLocalNetworks = $0 }
            ))
            Button("Apply Rules") {
                model.pacRules.directDomains = directDomains.split(separator: "\n").map { String($0) }
                model.pacRules.directKeywords = directKeywords.split(separator: "\n").map { String($0) }
                model.applyMode(.rule)
            }
        }
        .onAppear {
            directDomains = model.pacRules.directDomains.joined(separator: "\n")
            directKeywords = model.pacRules.directKeywords.joined(separator: "\n")
        }
        .padding()
    }
}

struct RulesDetailView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("PAC Preview")
                .font(.headline)
            Text("Rules will generate PAC content and serve via local PAC server.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var levelFilter: LogLevel = .info

    var filteredLogs: [LogEntry] {
        model.logs.filter { $0.level == levelFilter }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Level", selection: $levelFilter) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized)
                }
            }
            .pickerStyle(.segmented)
            List(filteredLogs) { entry in
                VStack(alignment: .leading) {
                    Text(entry.message)
                    Text(entry.date, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

struct LogsDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Diagnostics")
                .font(.headline)
            Button("Export Diagnostics") {
                model.exportDiagnostics()
            }
            Spacer()
        }
        .padding()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var subName: String = ""
    @State private var subURL: String = ""

    var body: some View {
        Form {
            Section("Ports") {
                Stepper("SOCKS \(model.settings.socksPort)", value: $model.settings.socksPort, in: 1000...65535)
                Stepper("HTTP \(model.settings.httpPort)", value: $model.settings.httpPort, in: 1000...65535)
                Stepper("PAC \(model.settings.pacPort)", value: $model.settings.pacPort, in: 1000...65535)
            }
            Section("Subscription") {
                Stepper("Auto refresh \(model.settings.refreshIntervalHours)h", value: $model.settings.refreshIntervalHours, in: 1...48)
                HStack {
                    TextField("Name", text: $subName)
                    TextField("URL", text: $subURL)
                    Button("Add") {
                        model.addSubscription(name: subName.isEmpty ? "Subscription" : subName, url: subURL)
                        subName = ""
                        subURL = ""
                    }
                }
                ForEach(model.subscriptions) { subscription in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(subscription.name)
                            Text(subscription.url)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { model.refreshSubscriptions() }
                        Button("Remove", role: .destructive) { model.removeSubscription(subscription) }
                    }
                }
            }
            Section("Network Services") {
                Toggle("Automatically detect active services", isOn: $model.settings.useAutomaticServices)
                if !model.settings.useAutomaticServices {
                    ForEach(model.availableServices, id: \.self) { service in
                        Toggle(service, isOn: Binding(
                            get: { model.settings.selectedServices.contains(service) },
                            set: { isOn in
                                if isOn {
                                    model.settings.selectedServices.append(service)
                                } else {
                                    model.settings.selectedServices.removeAll { $0 == service }
                                }
                            }
                        ))
                    }
                }
            }
            Section("Bypass") {
                TextEditor(text: Binding(
                    get: { model.settings.bypassList.joined(separator: "\n") },
                    set: { model.settings.bypassList = $0.split(separator: "\n").map { String($0) } }
                ))
                .frame(minHeight: 120)
            }
            Toggle("Auto Connect on Launch", isOn: $model.settings.autoConnect)
            Button("Save Settings") { model.saveSettings() }
        }
        .padding()
    }
}

struct SettingsDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System")
                .font(.headline)
            Button("Repair System Proxy") {
                model.repairSystemProxy()
            }
            Spacer()
        }
        .padding()
    }
}

struct StatusCard: View {
    var state: AppModel.ConnectionState
    var lastError: String?

    var body: some View {
        HStack {
            Text(state.rawValue.capitalized)
                .font(.title2)
            Spacer()
            if state == .starting || state == .stopping {
                ProgressView()
            }
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

struct InfoCard: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

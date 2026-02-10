import SwiftUI
import Subscription

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case nodes = "Nodes"
    case rules = "Rules"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "speedometer"
        case .nodes: return "server.rack"
        case .rules: return "list.bullet.rectangle"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .dashboard
    @State private var searchText: String = ""

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationTitle("TahoeProxy")
        } content: {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView()
            case .nodes:
                NodesView(searchText: $searchText)
            case .rules:
                RulesView()
            case .logs:
                LogsView()
            case .settings:
                SettingsView()
            }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardDetailView()
            case .nodes:
                NodeDetailView()
            case .rules:
                RulesDetailView()
            case .logs:
                LogsDetailView()
            case .settings:
                SettingsDetailView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                connectionButton
                Text(model.state.rawValue.capitalized)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .cornerRadius(10)
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.ProxyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.mode) { _, newMode in
                    model.applyMode(newMode)
                }
                Menu {
                    ForEach(model.nodes) { node in
                        Button(node.name) { model.activeNode = node }
                    }
                } label: {
                    Label(model.activeNode?.name ?? "Select Node", systemImage: "arrowtriangle.down.circle")
                }
                .disabled(model.nodes.isEmpty)
                if selection == .nodes {
                    SearchField(text: $searchText)
                }
            }
        }
        .alert("需要修复系统代理", isPresented: $model.needsRepair) {
            Button("修复", role: .destructive) { model.repairSystemProxy() }
        } message: {
            Text("检测到系统代理仍指向本地端口，但代理内核未运行。")
        }
    }

    private var connectionButton: some View {
        Button {
            if model.state == .connected {
                model.disconnect()
            } else {
                model.connect()
            }
        } label: {
            Label(model.state == .connected ? "Disconnect" : "Connect", systemImage: model.state == .connected ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        TextField("Search", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
    }
}

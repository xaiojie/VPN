import Foundation
import SwiftUI
import Diagnostics
import ProxyCore
import Subscription
import SystemProxy
import Persistence
import Network
import AppKit

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: String {
        case idle
        case starting
        case connected
        case stopping
        case error
    }

    enum ProxyMode: String, CaseIterable, Identifiable {
        case global = "Global"
        case rule = "Rule"
        case direct = "Direct"

        var id: String { rawValue }
    }

    @Published var state: ConnectionState = .idle
    @Published var mode: ProxyMode = .global
    @Published var settings: StoredSettings = .default
    @Published var nodes: [ProxyNode] = []
    @Published var activeNode: ProxyNode?
    @Published var selectedNode: ProxyNode?
    @Published var subscriptions: [Subscription] = []
    @Published var pacRules: PacRules = .default
    @Published var stats: ProxyStats = ProxyStats()
    @Published var logs: [LogEntry] = []
    @Published var lastError: String?
    @Published var needsRepair: Bool = false
    @Published var availableServices: [String] = []

    private let store = SubscriptionStore()
    private let systemProxy = SystemProxyManager()
    private var statsTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?

    init() {
        loadSettings()
        Task { await loadNodes() }
        availableServices = systemProxy.detectActiveServices()
        startLogPolling()
        detectResidualProxy()
        startNetworkMonitoring()
        if settings.autoConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.connect()
            }
        }
    }

    func loadNodes() async {
        nodes = await store.nodes
        subscriptions = await store.subscriptions
    }

    func loadSettings() {
        if let loaded = try? JSONStore.load(StoredSettings.self, from: AppPaths.fileURL("settings.json")) {
            settings = loaded
        }
    }

    func saveSettings() {
        try? JSONStore.save(settings, to: AppPaths.fileURL("settings.json"))
    }

    func connect() {
        guard state == .idle else { return }
        guard let activeNode else {
            lastError = "请选择一个节点"
            state = .error
            return
        }
        state = .starting
        Task {
            do {
                let services = proxyServices()
                _ = try systemProxy.captureSnapshot(services: services)
                await ProxyCore.shared.configurePorts(socks: settings.socksPort, http: settings.httpPort, pac: settings.pacPort)
                await ProxyCore.shared.activeNode = activeNode
                await ProxyCore.shared.pacContent = PacGenerator.generate(rules: pacRules, socksPort: settings.socksPort, httpPort: settings.httpPort)
                try await ProxyCore.shared.start()
                let socksPort = await ProxyCore.shared.socksPort
                let httpPort = await ProxyCore.shared.httpPort
                let pacPort = await ProxyCore.shared.pacPort
                settings.socksPort = socksPort
                settings.httpPort = httpPort
                settings.pacPort = pacPort
                saveSettings()
                switch mode {
                case .global:
                    try systemProxy.applyManualProxy(services: services, httpPort: httpPort, socksPort: socksPort, bypassList: settings.bypassList)
                case .rule:
                    let pacURL = URL(string: "http://127.0.0.1:\(pacPort)/proxy.pac")!
                    try systemProxy.applyPAC(services: services, pacURL: pacURL, bypassList: settings.bypassList)
                case .direct:
                    break
                }
                state = .connected
                startStatsPolling()
            } catch {
                lastError = error.localizedDescription
                state = .error
            }
        }
    }

    func disconnect() {
        guard state == .connected else { return }
        state = .stopping
        Task {
            defer { state = .idle }
            await ProxyCore.shared.stop()
            if let snapshot = systemProxy.loadSnapshot() {
                try? systemProxy.restore(snapshot: snapshot)
            }
            stopStatsPolling()
            stats = ProxyStats()
        }
    }

    func applyMode(_ newMode: ProxyMode) {
        mode = newMode
        if state == .connected {
            Task {
                do {
                    let services = proxyServices()
                    switch mode {
                    case .global:
                        try systemProxy.applyManualProxy(services: services, httpPort: settings.httpPort, socksPort: settings.socksPort, bypassList: settings.bypassList)
                    case .rule:
                        await updatePacContent()
                        let pacURL = URL(string: "http://127.0.0.1:\(settings.pacPort)/proxy.pac")!
                        try systemProxy.applyPAC(services: services, pacURL: pacURL, bypassList: settings.bypassList)
                    case .direct:
                        if let snapshot = systemProxy.loadSnapshot() {
                            try systemProxy.restore(snapshot: snapshot)
                        }
                    }
                } catch {
                    lastError = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    func importSample() {
        let sample = """
        socks5://127.0.0.1:1080#LocalSocks
        http://127.0.0.1:3128#LocalHttp
        """
        Task {
            try? await store.importText(sample, group: "Sample")
            await loadNodes()
        }
    }

    func importText(_ text: String) {
        Task {
            try? await store.importText(text, group: "Manual")
            await loadNodes()
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url) {
            importText(content)
        }
    }

    func addSubscription(name: String, url: String) {
        Task {
            try? await store.addSubscription(name: name, url: url)
            await loadNodes()
        }
    }

    func refreshSubscriptions() {
        Task {
            try? await store.refreshAll()
            await loadNodes()
        }
    }

    func removeSubscription(_ subscription: Subscription) {
        Task {
            try? await store.removeSubscription(subscription)
            await loadNodes()
        }
    }

    func updatePacContent() async {
        let content = PacGenerator.generate(rules: pacRules, socksPort: settings.socksPort, httpPort: settings.httpPort)
        await ProxyCore.shared.pacContent = content
    }

    func testNode(_ node: ProxyNode) {
        Task.detached {
            let latency = await NodeTester.measure(node: node)
            await MainActor.run {
                if let index = self.nodes.firstIndex(of: node) {
                    self.nodes[index].lastLatencyMs = latency
                }
            }
        }
    }

    func exportDiagnostics() {
        let logEntries = AppLogger.shared.entries(limit: 2000)
        let folder = AppPaths.appSupport.appendingPathComponent("Diagnostics-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONStore.save(settings, to: folder.appendingPathComponent("settings.json"))
            if let snapshot = systemProxy.loadSnapshot() {
                try JSONStore.save(snapshot, to: folder.appendingPathComponent("system_proxy_snapshot.json"))
            }
            try JSONStore.save(logEntries, to: folder.appendingPathComponent("logs.json"))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func repairSystemProxy() {
        if let snapshot = systemProxy.loadSnapshot() {
            try? systemProxy.restore(snapshot: snapshot)
            needsRepair = false
        }
    }

    private func startLogPolling() {
        Task {
            while true {
                logs = AppLogger.shared.entries(limit: 2000)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task {
            while !Task.isCancelled {
                let newStats = await ProxyCore.shared.stats
                await MainActor.run {
                    self.stats = newStats
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func detectResidualProxy() {
        let services = proxyServices()
        let pointed = systemProxy.isProxyPointingToLocal(services: services, httpPort: settings.httpPort, socksPort: settings.socksPort)
        if pointed && state == .idle {
            needsRepair = true
        }
    }

    private func proxyServices() -> [String] {
        if settings.useAutomaticServices || settings.selectedServices.isEmpty {
            return systemProxy.detectActiveServices()
        }
        return settings.selectedServices
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.state == .connected {
                    self.needsRepair = true
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
        pathMonitor = monitor
    }
}

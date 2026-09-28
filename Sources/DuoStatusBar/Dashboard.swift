import AppKit
import SwiftUI

@MainActor
func renderDuoPreview(to path: String, snapshot: StatusSnapshot = StatusSnapshot(batteryPercent: 88, isCharging: true, externalPowerConnected: true, connection: .wifi(name: "Wi-Fi", level: 4), volumePercent: 60, localIPAddress: "192.0.2.42", cpuPercent: 34, memoryPercent: 68, memoryBytes: 8_200_000_000, chargingWatts: 24.5), showingOutputs: Bool = false, previewMode: Bool = false) throws {
    let model = DashboardModel(snapshot, .overview)
    let sleepPreventionStatus = SleepPrevention.readStatus()
    model.sleepPreventionStatus = sleepPreventionStatus
    model.sleepPreventionVerifiedAt = sleepPreventionStatus.isEnabled == nil ? nil : Date()
    model.showingOutputs = showingOutputs
    let renderer = ImageRenderer(content: DuoPanel(model: model, previewMode: previewMode))
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DuoPreview", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

enum DashboardTarget: String, CaseIterable {
    case overview, battery, network, volume
    var title: String {
        switch self {
        case .overview: return "ホーム"
        case .battery: return "バッテリー"
        case .network: return "ネットワーク"
        case .volume: return "音量"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .battery: return "battery.100percent"
        case .network: return "wifi"
        case .volume: return "speaker.wave.2.fill"
        }
    }
}
enum DashboardLayout {
    static let width: CGFloat = 380
    static let height: CGFloat = 650
    static let heightWithAIUsage: CGFloat = height

    static func size(aiUsageEnabled: Bool) -> NSSize {
        NSSize(width: width, height: aiUsageEnabled ? heightWithAIUsage : height)
    }
}
enum PanelTheme: String, CaseIterable, Identifiable {
    case lavender, blue, mint, rose, amber
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lavender: return "ラベンダー"
        case .blue: return "ブルー"
        case .mint: return "ミント"
        case .rose: return "ローズ"
        case .amber: return "アンバー"
        }
    }
    var hue: Double {
        switch self {
        case .lavender: return 0.73
        case .blue: return 0.60
        case .mint: return 0.43
        case .rose: return 0.94
        case .amber: return 0.10
        }
    }
    var base: Color { Color(hue: hue, saturation: 0.09, brightness: 0.98) }
    var tile: Color { Color(hue: hue, saturation: 0.18, brightness: 0.94) }
    var light: Color { Color(hue: hue, saturation: 0.04, brightness: 0.99) }
    var ink: Color { Color(hue: hue, saturation: 0.50, brightness: 0.27) }
    var primary: Color { Color(hue: hue, saturation: 0.48, brightness: 0.53) }
}
final class DashboardModel: NSObject, ObservableObject {
    @Published var snapshot: StatusSnapshot
    @Published var target: DashboardTarget
    @Published var error: String?
    @Published var outputs: [AudioOutput] = []
    @Published var outputID: UInt32 = 0
    @Published var showingOutputs = false
    @Published var showingThemes = false
    @Published var showingAISettings = false
    @Published var changingPowerMode = false
    @Published var changingNetwork = false
    @Published var sleepPreventionStatus: SleepPrevention.Status = .checking
    @Published var sleepPreventionVerifiedAt: Date?
    @Published var isRefreshingSleepPrevention = false
    @Published var changingSleepPrevention = false
    @Published var sleepPreventionError: String?
    private var sleepPreventionPanelVisible = false
    private var lastSleepPreventionRead = Date.distantPast

    func setSleepPreventionPanelVisible(_ visible: Bool) {
        sleepPreventionPanelVisible = visible
        if visible { refreshSleepPrevention(force: true) }
    }

    func refreshSleepPrevention(force: Bool = false) {
        guard sleepPreventionPanelVisible,
              !isRefreshingSleepPrevention,
              !changingSleepPrevention else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSleepPreventionRead) >= 1 else { return }

        lastSleepPreventionRead = now
        isRefreshingSleepPrevention = true
        if force {
            sleepPreventionStatus = .checking
            sleepPreventionVerifiedAt = nil
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = SleepPrevention.readStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sleepPreventionStatus = status
                self.sleepPreventionVerifiedAt = status.isEnabled == nil ? nil : Date()
                self.isRefreshingSleepPrevention = false
            }
        }
    }

    func setSleepPreventionEnabled(_ enabled: Bool) {
        guard !changingSleepPrevention,
              !isRefreshingSleepPrevention,
              let currentValue = sleepPreventionStatus.isEnabled else {
            refreshSleepPrevention(force: true)
            return
        }
        guard currentValue != enabled else {
            refreshSleepPrevention(force: true)
            return
        }

        changingSleepPrevention = true
        sleepPreventionStatus = .checking
        sleepPreventionVerifiedAt = nil
        sleepPreventionError = nil
        SleepPrevention.setEnabled(enabled) { [weak self] result in
            guard let self else { return }
            self.sleepPreventionStatus = result.status
            self.sleepPreventionVerifiedAt = result.status.isEnabled == nil ? nil : Date()
            self.sleepPreventionError = result.message
            self.changingSleepPrevention = false
            self.lastSleepPreventionRead = Date()
        }
    }

    func toggleLowPowerMode() {
        guard !changingPowerMode else { return }
        changingPowerMode = true
        error = nil
        LowPowerMode.setEnabled(!snapshot.lowPowerMode) { [self] message in
            changingPowerMode = false
            error = message
            snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
    func toggleNetwork() {
        guard !changingNetwork else { return }
        let target: NetworkTransport = snapshot.connection.transport == .ethernet ? .wifi : .ethernet
        guard let setNetwork else {
            error = "接続を切り替えられませんでした。"
            return
        }
        changingNetwork = true
        error = nil
        let changed = setNetwork(target)
        changingNetwork = false
        if !changed { error = "接続を切り替えられませんでした。" }
    }
    func refreshOutputs() {
        let devices = AudioOutputs.list()
        if outputs != devices { outputs = devices }
        let id = AudioOutputs.current()
        if outputID != id { outputID = id }
    }
    var appearanceChanged: (() -> Void)?
    var settings: ((DashboardTarget) -> Void)?
    var aiUsageSettingsChanged: ((Bool, AIUsageProvider) -> Void)?
    var aiUsageDisplayModeChanged: (() -> Void)?
    var setVolume: ((Double) -> Bool)?
    var setNetwork: ((NetworkTransport) -> Bool)?
    func showOutputMenu() {
        refreshOutputs()
        showingThemes = false
        showingAISettings = false
        showingOutputs = true
        error = nil
    }
    func showThemeSettings() {
        showingOutputs = false
        showingAISettings = false
        showingThemes = true
    }
    func showAIUsageSettings() {
        showingOutputs = false
        showingThemes = false
        showingAISettings = true
    }
    func selectOutput(_ id: UInt32) {
        error = AudioOutputs.select(id) ? nil : "出力先を変更できませんでした。"
        refreshOutputs()
    }
    init(_ snapshot: StatusSnapshot, _ target: DashboardTarget) {
        self.snapshot = snapshot
        self.target = target
        super.init()
        refreshOutputs()
    }
}
final class DuoDashboardViewController: NSHostingController<DuoPanel> {
    let model: DashboardModel
    var target: DashboardTarget { model.target }
    var onOpenSettings: ((DashboardTarget) -> Void)? {
        get { model.settings }
        set { model.settings = newValue }
    }
    var onAIUsageSettingsChanged: ((Bool, AIUsageProvider) -> Void)? {
        get { model.aiUsageSettingsChanged }
        set { model.aiUsageSettingsChanged = newValue }
    }
    var onAIUsageDisplayModeChanged: (() -> Void)? {
        get { model.aiUsageDisplayModeChanged }
        set { model.aiUsageDisplayModeChanged = newValue }
    }
    var onSetVolume: ((Double) -> Bool)? {
        get { model.setVolume }
        set { model.setVolume = newValue }
    }
    var onSetNetwork: ((NetworkTransport) -> Bool)? {
        get { model.setNetwork }
        set { model.setNetwork = newValue }
    }
    init(snapshot: StatusSnapshot, target: DashboardTarget) {
        model = DashboardModel(snapshot, target)
        super.init(rootView: DuoPanel(model: model))
        preferredContentSize = DashboardLayout.size(
            aiUsageEnabled: UserDefaults.standard.bool(forKey: "aiUsageEnabled")
        )
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    func updateAIUsageLayout(enabled: Bool) {
        preferredContentSize = DashboardLayout.size(aiUsageEnabled: enabled)
    }
    func update(with snapshot: StatusSnapshot) {
        model.refreshSleepPrevention()
        model.refreshOutputs()
        if model.snapshot != snapshot { model.snapshot = snapshot }
    }
    func setSleepPreventionPanelVisible(_ visible: Bool) {
        model.setSleepPreventionPanelVisible(visible)
    }
    func select(_ target: DashboardTarget) {
        model.target = target
        model.showingOutputs = false
        model.showingThemes = false
        model.showingAISettings = false
    }
}
struct DuoPanel: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let previewMode: Bool
    init(model: DashboardModel, previewMode: Bool = false) {
        self.model = model
        self.previewMode = previewMode
    }
    @AppStorage("panelAppearance") private var appearance = PanelAppearance.classic.rawValue
    private var glass: Bool { !previewMode && PanelAppearance.supportsGlass && appearance == PanelAppearance.liquidGlass.rawValue }
    private var ink: Color { glass ? .primary : palette.ink }
    private func foreground(_ classic: Color) -> Color { glass ? .primary : classic }
    @AppStorage("panelTheme") private var themeName = PanelTheme.lavender.rawValue
    @AppStorage("statusMetric") private var metricName = StatusMetric.cpu.rawValue
    @AppStorage("aiUsageEnabled") private var aiUsageEnabled = false
    @AppStorage("aiUsageProvider") private var aiUsageProviderName = AIUsageProvider.codex.rawValue
    @AppStorage("aiUsageDisplayMode") private var aiUsageDisplayModeName = AIUsageDisplayMode.used.rawValue
    @AppStorage("showBatteryNumber") private var showBatteryNumber = true
    private var aiUsageProvider: AIUsageProvider {
        AIUsageProvider(rawValue: aiUsageProviderName) ?? .codex
    }
    private var aiUsageDisplayMode: AIUsageDisplayMode {
        AIUsageDisplayMode(rawValue: aiUsageDisplayModeName) ?? .used
    }
    private var metric: StatusMetric {
        guard !previewMode else { return .cpu }
        let selected = StatusMetric(rawValue: metricName) ?? .cpu
        return selected == .aiUsage && !aiUsageEnabled ? .cpu : selected
    }
    private var selectableMetrics: [StatusMetric] {
        aiUsageEnabled ? [.cpu, .memory, .volume, .aiUsage] : [.cpu, .memory, .volume]
    }
    private var showsAIUsageTile: Bool { aiUsageEnabled && !previewMode }
    private var panelHeight: CGFloat {
        DashboardLayout.size(aiUsageEnabled: showsAIUsageTile).height
    }
    private var palette: PanelTheme { previewMode ? .lavender : PanelTheme(rawValue: themeName) ?? .lavender }
    private var panelBackground: Color {
        guard glass else { return palette.base }
        return reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear
    }
    @State private var editing = false
    @State private var draft = 0.0
    @State private var showingSleepPreventionWarning = false
    private var s: StatusSnapshot { model.snapshot }
    private var volume: Double { editing ? draft : Double(s.volumePercent ?? 0) / 100 }
    private var glassVolumeBinding: Binding<Double> {
        Binding(
            get: { volume },
            set: { value in
                guard s.volumePercent != nil else { return }
                editing = true
                draft = min(1, max(0, value))
                if model.setVolume?(draft) == false {
                    model.error = "この出力機器では音量を変更できません。"
                }
            }
        )
    }
    private var networkName: String {
        switch s.connection {
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .offline: return "未接続"
        }
    }
    private var sleepPreventionStatusDescription: String {
        switch model.sleepPreventionStatus {
        case .checking: return "pmsetを照合中 · 状態未確定"
        case .enabled: return "SleepDisabled=1 · バッテリー注意"
        case .disabled: return "SleepDisabled=0 · 抑止なし"
        case .unavailable: return "状態不明 · オン／オフは非表示"
        }
    }
    private var sleepPreventionVerificationDescription: String {
        if let error = model.sleepPreventionError { return error }
        guard let verifiedAt = model.sleepPreventionVerifiedAt else { return "" }
        let time = verifiedAt.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
        return "pmset最終確認 \(time)"
    }
    private func handleSleepPreventionTap() {
        guard let isEnabled = model.sleepPreventionStatus.isEnabled else {
            model.refreshSleepPrevention(force: true)
            return
        }
        if isEnabled {
            model.setSleepPreventionEnabled(false)
        } else {
            showingSleepPreventionWarning = true
        }
    }
    var body: some View {
        Group {
            if model.showingOutputs {
                outputSelector
            } else if model.showingThemes {
                themeSelector
            } else if model.showingAISettings {
                aiUsageSettings
            } else {
                dashboardContent
            }
        }
        .frame(width: DashboardLayout.width, height: panelHeight)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .preferredColorScheme(glass ? nil : .light)
        // Only the active page participates in glass compositing. Combining
        // hidden dashboard cards with a settings page makes their glass shapes
        // merge and appear to overlap.
        .panelGlassContainer(enabled: glass)
        .panelBackdrop(
            enabled: glass,
            reduceTransparency: reduceTransparency,
            fallback: panelBackground,
            tint: palette.primary,
            cornerRadius: 30
        )
        .alert("スリープ抑止を有効にしますか？", isPresented: $showingSleepPreventionWarning) {
            Button("有効にする", role: .destructive) {
                model.setSleepPreventionEnabled(true)
            }
            Button("キャンセル", role: .cancel) {
                model.refreshSleepPrevention(force: true)
            }
        } message: {
            Text("有効にすると通常のスリープが抑止されます。蓋を閉じた状態でも動作が続き、特にバッテリー駆動中は残量切れや発熱につながることがあります。")
        }
        .onChange(of: appearance) { model.appearanceChanged?() }
        .onChange(of: aiUsageEnabled) { _, enabled in
            if enabled {
                metricName = StatusMetric.aiUsage.rawValue
            } else if metricName == StatusMetric.aiUsage.rawValue {
                metricName = StatusMetric.cpu.rawValue
            }
            model.aiUsageSettingsChanged?(enabled, aiUsageProvider)
        }
        .onChange(of: aiUsageProviderName) { _, _ in
            model.aiUsageSettingsChanged?(aiUsageEnabled, aiUsageProvider)
        }
        .onChange(of: aiUsageDisplayModeName) { _, _ in
            model.aiUsageDisplayModeChanged?()
        }
    }

    private var dashboardContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        Text(context.date, format: .dateTime.month().day().weekday(.wide))
                            .font(.system(size: 11, weight: .medium)).opacity(0.75)
                            .lineLimit(1)
                    }
                }.panelSurface(.clear, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                Button { model.showThemeSettings() } label: {
                    Image(systemName: "paintpalette.fill").frame(width: 38, height: 38)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle)
                    .help("外観とテーマの色").accessibilityLabel("外観とテーマの色")
                Button { model.settings?(model.target) } label: {
                    Image(systemName: "gearshape.fill").frame(width: 38, height: 38)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle)
                    .help("システム設定を開く")
                Button { model.showAIUsageSettings() } label: {
                    Image(systemName: "chart.bar.xaxis").frame(width: 38, height: 38)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle)
                    .help("AI使用量の設定").accessibilityLabel("AI使用量の設定")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 38, height: 38)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle)
                    .help("アプリを終了")
            }
            HStack(spacing: 12) {
                Group {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(selectableMetrics) { item in
                                Button { metricName = item.rawValue } label: {
                                    Text(item.title).font(.system(size: 10, weight: .semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                                        .foregroundStyle(metric == item ? Color.white : ink)
                                        .panelSurface(metric == item ? palette.primary : palette.light, in: Capsule(), accented: metric == item)
                                }.accessibilityLabel("\(item.title)を表示")
                            }
                        }
                        Text(metric.displayValue(s))
                            .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.8).lineLimit(1).foregroundStyle(metricTextColor)
                        if metric == .aiUsage {
                            if let usage = s.aiUsage, !usage.windows.isEmpty {
                                VStack(spacing: 2) {
                                    Text(usage.provider.title)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(ink.opacity(0.62))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(usage.windows.prefix(2)) { window in
                                        TimelineView(.periodic(from: .now, by: 60)) { context in
                                            HStack(spacing: 4) {
                                                Text(window.title)
                                                Spacer(minLength: 2)
                                                Text("\(window.displayPercent(for: aiUsageDisplayMode))%")
                                                    .monospacedDigit()
                                                if let resetsAt = window.resetsAt {
                                                    Text(aiResetCountdown(until: resetsAt, now: context.date))
                                                        .monospacedDigit()
                                                } else if let description = window.resetDescription, !description.isEmpty {
                                                    Text(description).lineLimit(1)
                                                }
                                            }
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(ink.opacity(0.76))
                                        }
                                    }
                                }
                            } else if let error = s.aiUsage?.error {
                                Text(error)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("取得中…")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(ink.opacity(0.68))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
                .frame(width: 168, height: 164)
                .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 30), usesNativeGlass: true)
                .help(metric == .memory ? "物理メモリに対する使用量（ファイルキャッシュを除く概算）" : "メニューバーに表示する項目を選択")
                    VStack(spacing: 7) {
                        if previewMode {
                            HStack(spacing: 6) {
                                Text("残量数値")
                                Capsule().fill(palette.primary).frame(width: 32, height: 18)
                                    .overlay(alignment: .trailing) {
                                        Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                                    }
                            }.font(.system(size: 11, weight: .semibold)).fixedSize()
                        } else {
                            Toggle("残量数値", isOn: $showBatteryNumber)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 11, weight: .semibold))
                                .fixedSize()
                                .help("メニューバーの残量数値を表示。オフでは通信アイコンを拡大")
                        }
                        ZStack {
                            ForEach(0..<24) { i in
                                Capsule().fill(batteryGaugeColor.opacity(Double(i) < Double(s.batteryPercent ?? 0) / 100 * 24 ? 0.98 : 0.18))
                                    .frame(width: 6, height: 11)
                                    .offset(y: -34).rotationEffect(.degrees(Double(i) * 15))
                            }
                            VStack(spacing: 1) {
                            Text(s.batteryPercent.map { "\($0)%" } ?? "—")
                                .font(.system(size: 21, weight: .bold, design: .rounded)).monospacedDigit()
                            if s.isCharging {
                                Text(s.chargingWatts.map { String(format: "約%.1fW", $0) } ?? "充電中")
                                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                    .help("バッテリー充電電力の概算。15秒ごとに更新。充電器の定格やコンセント消費電力とは異なります")
                            } else if s.externalPowerConnected {
                                Text("電源接続")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            }
                        }.frame(width: 84, height: 84)
                        Button { model.toggleLowPowerMode() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "leaf.fill")
                                Text(model.changingPowerMode ? "変更中…" : "低電力 \(s.lowPowerMode ? "オン" : "オフ")")
                                Image(systemName: s.lowPowerMode ? "checkmark.circle.fill" : "circle")
                            }.font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .foregroundStyle(glass
                                    ? (s.lowPowerMode ? palette.primary : Color.primary)
                                    : (s.lowPowerMode ? palette.primary : Color.white))
                                .panelSurface(s.lowPowerMode ? Color.white : Color.white.opacity(0.18), in: Capsule(), accented: s.lowPowerMode)
                        }.disabled(model.changingPowerMode)
                            .accessibilityLabel("低電力モード、\(s.lowPowerMode ? "オン" : "オフ")")
                            .help("全電源の低電力モードを切り替え")
                    }.frame(maxWidth: .infinity).frame(height: 164)
                        .foregroundStyle(foreground(.white))
                        .panelSurface(
                            palette.primary,
                            in: RoundedRectangle(cornerRadius: model.target == .battery ? 22 : 34),
                            usesNativeGlass: true
                        )
            }
            HStack(spacing: 12) {
                sleepPreventionTile
                aiUsageTile
            }
            HStack(spacing: 8) {
                Button { model.settings?(.network) } label: {
                    HStack(spacing: 14) {
                        Group {
                            if s.connection == .ethernet {
                                Image(nsImage: ethernetImage(color: glass ? .labelColor : .white)).resizable().frame(width: 24, height: 24)
                            } else {
                                Image(systemName: s.connection == .offline ? "wifi.slash" : "wifi")
                            }
                        }
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 50, height: 50)
                            .panelSurface(palette.primary, in: Circle(), accented: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(networkName).font(.system(size: 17, weight: .semibold))
                            Text(s.localIPAddress ?? "—")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.68))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("ネットワーク設定")
                Button { model.toggleNetwork() } label: {
                    VStack(spacing: 3) {
                        if networkTarget == .ethernet {
                            Image(nsImage: ethernetImage(color: glass ? .labelColor : .white)).resizable().scaledToFit()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "wifi")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text(model.changingNetwork ? "…" : networkToggleTitle)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: 54, height: 54)
                    .foregroundStyle(.white)
                    .panelSurface(palette.primary, in: RoundedRectangle(cornerRadius: 20), accented: true)
                }
                .disabled(model.changingNetwork)
                .accessibilityLabel(networkToggleLabel)
                .help("有線とWi-Fiをワンタップで切り替え")
            }
            .padding(12)
            .panelSurface(
                palette.tile,
                in: RoundedRectangle(cornerRadius: 38),
                usesNativeGlass: true,
                interactiveGlass: true
            )
            VStack(spacing: 9) {
                HStack {
                    Text("音量").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(s.volumePercent.map { "\($0)%" } ?? "調整非対応")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    ForEach(0..<5) { i in
                        Circle().fill(palette.primary.opacity(Double(i) < volume * 5 ? 1 : 0.20))
                            .frame(width: 5, height: 5)
                    }
                }
                Group {
                    if glass {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22)
                            Slider(value: glassVolumeBinding, in: 0...1, onEditingChanged: { isEditing in
                                if isEditing {
                                    draft = Double(s.volumePercent ?? 0) / 100
                                }
                                editing = isEditing
                            })
                            .tint(.accentColor)
                            .accessibilityLabel("音量")
                            .accessibilityValue(s.volumePercent.map { "\($0)パーセント" } ?? "調整非対応")
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                    } else {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Color.clear.panelSurface(palette.tile, in: Capsule())
                                Capsule().fill(palette.primary).frame(width: max(44, g.size.width * volume))
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.white).padding(.leading, 14)
                            }
                            .contentShape(Capsule())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                guard s.volumePercent != nil else { return }
                                editing = true
                                draft = min(1, max(0, value.location.x / g.size.width))
                                if model.setVolume?(draft) == false { model.error = "この出力機器では音量を変更できません。" }
                            }.onEnded { _ in editing = false })
                            .accessibilityElement()
                            .accessibilityLabel("音量")
                            .accessibilityValue(s.volumePercent.map { "\($0)パーセント" } ?? "調整非対応")
                            .accessibilityAdjustableAction { direction in
                                let delta = direction == .increment ? 0.05 : -0.05
                                _ = model.setVolume?(min(1, max(0, volume + delta)))
                            }
                        }
                        .frame(height: 44)
                    }
                }
                .opacity(s.volumePercent == nil ? 0.4 : 1)
            }.padding(.horizontal, 4)
                .panelSurface(.clear, in: RoundedRectangle(cornerRadius: 22), usesNativeGlass: true)
            Button { model.showOutputMenu() } label: {
                HStack {
                    Image(systemName: "hifispeaker.fill")
                    Text(previewMode ? "内蔵スピーカー" : model.outputs.first(where: { $0.id == model.outputID })?.name ?? "出力先を選択")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }.font(.system(size: 12, weight: .medium))
                    .padding(14)
                    .background(glass ? Color.clear : palette.tile, in: Capsule())
            }
            .panelGlassButton(enabled: glass, shape: .capsule)
            .help("オーディオの出力先")
            if let error = model.error { Text(error).font(.system(size: 10)) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .padding(16)
        .frame(width: DashboardLayout.width, height: panelHeight)
    }
    private var themeSelector: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { model.showingThemes = false } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle).accessibilityLabel("戻る")
                Text("外観").font(.system(size: 22, weight: .semibold, design: .rounded))
                    .panelSurface(.clear, in: Capsule())
                Spacer()
            }
            Picker("外観", selection: $appearance) {
                Text("Classic").tag(PanelAppearance.classic.rawValue)
                if PanelAppearance.supportsGlass {
                    Text("Liquid Glass").tag(PanelAppearance.liquidGlass.rawValue)
                }
            }.pickerStyle(.segmented)
            ScrollView {
              VStack(spacing: 16) {
              ForEach(PanelTheme.allCases) { theme in
                Button {
                    themeName = theme.rawValue
                    model.showingThemes = false
                } label: {
                    HStack(spacing: 14) {
                        Circle().fill(theme.primary).frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 2))
                        Text(theme.title).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Image(systemName: palette == theme ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                    }.padding(14)
                        .foregroundStyle(foreground(palette == theme ? Color.white : ink))
                        .panelSurface(
                            palette == theme ? palette.primary : palette.tile,
                            in: RoundedRectangle(cornerRadius: 24),
                            accented: palette == theme,
                            usesNativeGlass: true,
                            interactiveGlass: true
                        )
                }.accessibilityLabel(theme.title + (palette == theme ? "、選択中" : ""))
            }
              }
            }
        }.padding(18).frame(width: DashboardLayout.width, height: panelHeight)
            .background(panelBackground).foregroundStyle(ink).buttonStyle(.plain)
    }
    private var outputSelector: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { model.showingOutputs = false; model.error = nil } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle).accessibilityLabel("戻る")
                Text("音声の出力先").font(.system(size: 22, weight: .semibold, design: .rounded))
                    .panelSurface(.clear, in: Capsule())
                Spacer()
            }
            Text("このMacで再生するデバイスを選択")
                .font(.system(size: 12)).opacity(0.7)
                .panelSurface(.clear, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.outputs.count <= 5 {
                outputRows
                Spacer(minLength: 0)
            } else {
                ScrollView { outputRows }.frame(maxHeight: .infinity)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(ink) }
        }.padding(18).frame(width: DashboardLayout.width, height: panelHeight)
            .background(panelBackground).foregroundStyle(ink).buttonStyle(.plain)
    }
    private var aiUsageSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { model.showingAISettings = false } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(glass ? Color.clear : palette.tile, in: Circle())
                }.panelGlassButton(enabled: glass, shape: .circle).accessibilityLabel("戻る")
                Text("AI使用量").font(.system(size: 22, weight: .semibold, design: .rounded))
                    .panelSurface(.clear, in: Capsule())
                Spacer()
            }
            Toggle("AI使用量を表示", isOn: $aiUsageEnabled)
                .toggleStyle(.switch)
                .tint(palette.primary)
                .font(.system(size: 14, weight: .semibold))
                .padding(14)
                .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 20), usesNativeGlass: true)
            Text("利用状況はメニューとメニューバーに表示されます。初期状態では無効です。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Text("サービス").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(AIUsageProvider.allCases) { provider in
                    let selected = aiUsageProvider == provider
                    Button { aiUsageProviderName = provider.rawValue } label: {
                        VStack(spacing: 6) {
                            Text(provider.title).font(.system(size: 12, weight: .semibold))
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                        }
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .foregroundStyle(foreground(selected ? Color.white : ink))
                        .panelSurface(
                            selected ? palette.primary : palette.tile,
                            in: RoundedRectangle(cornerRadius: 18),
                            accented: selected,
                            usesNativeGlass: true,
                            interactiveGlass: true
                        )
                    }.accessibilityLabel(provider.title + (selected ? "、選択中" : ""))
                }
            }
            Text("表示方法").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(AIUsageDisplayMode.allCases) { mode in
                    let selected = aiUsageDisplayMode == mode
                    Button { aiUsageDisplayModeName = mode.rawValue } label: {
                        Text(mode.title).font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .foregroundStyle(foreground(selected ? Color.white : ink))
                            .panelSurface(
                                selected ? palette.primary : palette.tile,
                                in: Capsule(),
                                accented: selected,
                                usesNativeGlass: true,
                                interactiveGlass: true
                            )
                    }.accessibilityLabel(mode.title + (selected ? "、選択中" : ""))
                }
            }
            if aiUsageEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    if let usage = s.aiUsage, !usage.windows.isEmpty {
                        ForEach(usage.windows.prefix(2)) { window in
                            HStack(spacing: 8) {
                                Text(window.title).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 4)
                                Text("\(window.displayPercent(for: aiUsageDisplayMode))%")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                                if let resetsAt = window.resetsAt {
                                    Text(aiResetCountdown(until: resetsAt))
                                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                        .foregroundStyle(ink.opacity(0.72))
                                }
                            }
                        }
                    } else if let error = s.aiUsage?.error {
                        Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(aiUsageProvider.title)の使用量を取得中…")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.72))
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 20), usesNativeGlass: true)
            }
            Spacer(minLength: 0)
            Text("更新は5分ごとです。CodexBar CLIのログイン状態を使用します。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ink.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: DashboardLayout.width, height: panelHeight)
        .background(panelBackground)
        .foregroundStyle(ink).buttonStyle(.plain)
        .environment(\.locale, Locale(identifier: "ja_JP"))
    }
    private var sleepPreventionTile: some View {
        let isEnabled = model.sleepPreventionStatus == .enabled
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(glass ? .primary : (isEnabled ? Color.orange : palette.primary))
                    .frame(width: 28, height: 28)
                    .panelSurface(palette.light, in: Circle())
                Text("スリープ抑止")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            Button(action: handleSleepPreventionTap) {
                Group {
                    if model.sleepPreventionStatus == .checking {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("状態を確認中")
                        }
                    } else if model.sleepPreventionStatus == .unavailable {
                        Label("再確認", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        HStack(spacing: 8) {
                            Text(isEnabled ? "オン" : "オフ")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                            ZStack(alignment: isEnabled ? .trailing : .leading) {
                                Capsule().fill(isEnabled ? Color.white.opacity(0.28) : ink.opacity(0.18))
                                Circle().fill(Color.white)
                                    .frame(width: 18, height: 18)
                                    .padding(3)
                            }
                            .frame(width: 42, height: 26)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .padding(.horizontal, 10)
                .foregroundStyle(glass ? (isEnabled ? Color.black : .primary) : (isEnabled ? .white : ink))
                .panelSurface(isEnabled ? .orange : palette.light, in: Capsule(), accented: isEnabled)
            }
            .buttonStyle(.plain)
            .disabled(model.changingSleepPrevention || model.sleepPreventionStatus == .checking)
            .frame(height: 42)
            .accessibilityLabel("スリープ抑止、状態 \(model.sleepPreventionStatus.title)")
            .accessibilityHint(model.sleepPreventionStatus == .enabled
                ? "タップすると抑止を解除します"
                : "有効にするとバッテリーを消費する場合があります")
            .help("SleepDisabledの実値を確認。オンはバッテリー消費に注意")

            Text(sleepPreventionStatusDescription)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(isEnabled ? Color.orange : ink.opacity(0.68))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(sleepPreventionVerificationDescription.isEmpty ? "確認時刻 —" : sleepPreventionVerificationDescription)
                .font(.system(size: 7, weight: .regular))
                .foregroundStyle(model.sleepPreventionError == nil ? ink.opacity(0.56) : Color.red)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 164)
        .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 30), usesNativeGlass: true)
    }
    private var aiUsageTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glass ? .primary : palette.primary)
                    .frame(width: 28, height: 28)
                    .panelSurface(palette.light, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(showsAIUsageTile ? "AI使用量" : "AI設定")
                        .font(.system(size: 11, weight: .semibold))
                    Text(showsAIUsageTile ? (s.aiUsage?.provider ?? aiUsageProvider).title : "利用状況は非表示")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ink.opacity(0.62))
                }
                Spacer(minLength: 2)
                Button { model.showAIUsageSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .panelSurface(palette.light, in: Circle())
                }
                .accessibilityLabel("AI使用量の設定")
                .help("AI使用量の設定")
            }

            if showsAIUsageTile, let usage = s.aiUsage, !usage.windows.isEmpty {
                VStack(spacing: 4) {
                    ForEach(usage.windows.prefix(2)) { window in
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Text(window.title)
                                    .foregroundStyle(ink.opacity(0.72))
                                Spacer(minLength: 2)
                                Text("\(window.displayPercent(for: aiUsageDisplayMode))%")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                if let resetsAt = window.resetsAt {
                                    Text("· \(aiResetCountdown(until: resetsAt))")
                                        .foregroundStyle(ink.opacity(0.62))
                                        .monospacedDigit()
                                } else if let description = window.resetDescription, !description.isEmpty {
                                    Text("· \(description)")
                                        .foregroundStyle(ink.opacity(0.62))
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 9, weight: .medium))
                            GeometryReader { geometry in
                                let percent = CGFloat(window.displayPercent(for: aiUsageDisplayMode)) / 100
                                ZStack(alignment: .leading) {
                                    Capsule().fill(palette.tile)
                                    Capsule().fill(palette.primary)
                                        .frame(width: geometry.size.width * min(1, max(0, percent)))
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .panelSurface(palette.light, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if showsAIUsageTile, let error = s.aiUsage?.error {
                Text(error).font(.system(size: 9, weight: .medium)).foregroundStyle(.red)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if showsAIUsageTile {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("使用量を取得中…")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ink.opacity(0.68))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(palette.primary)
                    Text("AI使用量はオフです")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ink.opacity(0.7))
                    Button { model.showAIUsageSettings() } label: {
                        Text("設定を開く")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .panelSurface(palette.primary, in: Capsule(), accented: true)
                    }
                    .accessibilityLabel("AI使用量の設定を開く")
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }

            if showsAIUsageTile {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(AIUsageDisplayMode.allCases) { mode in
                        let selected = aiUsageDisplayMode == mode
                        Button { aiUsageDisplayModeName = mode.rawValue } label: {
                            Text(mode.title)
                                .font(.system(size: 9, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .foregroundStyle(selected ? Color.white : ink)
                                .panelSurface(selected ? palette.primary : palette.light, in: Capsule(), accented: selected)
                        }
                        .accessibilityLabel(mode.title + (selected ? "、選択中" : ""))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 164)
        .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 30), usesNativeGlass: true)
    }
    private var outputRows: some View {
                VStack(spacing: 8) {
                    ForEach(model.outputs) { output in
                        let selected = output.id == model.outputID
                        Button { model.selectOutput(output.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "hifispeaker.fill")
                                    .frame(width: 36, height: 36)
                                    .background((selected ? Color.white : palette.primary).opacity(0.15), in: Circle())
                                Text(output.name).font(.system(size: 13, weight: .semibold))
                                    .multilineTextAlignment(.leading).lineLimit(2)
                                Spacer(minLength: 4)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(foreground(selected ? Color.white : ink))
                                .panelSurface(
                                    selected ? palette.primary : palette.tile,
                                    in: RoundedRectangle(cornerRadius: selected ? 26 : 18),
                                    accented: selected,
                                    usesNativeGlass: true,
                                    interactiveGlass: true
                                )
                        }.accessibilityLabel(output.name + (selected ? "、選択中" : ""))
                    }
                    if model.outputs.isEmpty { Text("利用できる出力先がありません").padding() }
            }
    }
    private var networkTarget: NetworkTransport {
        s.connection.transport == .ethernet ? .wifi : .ethernet
    }
    private var networkToggleTitle: String {
        networkTarget == .wifi ? "Wi-Fiへ" : "有線へ"
    }
    private var networkToggleLabel: String {
        "接続を\(networkTarget.title)に切り替える"
    }
    private var metricTextColor: Color {
        guard metric == .memory else { return ink }
        switch s.memoryPressure {
        case .normal: return ink
        case .warning: return .yellow
        case .critical: return .red
        }
    }
    private var batteryGaugeColor: Color {
        s.lowPowerMode ? .yellow : s.externalPowerConnected ? .green : foreground(.white)
    }
}

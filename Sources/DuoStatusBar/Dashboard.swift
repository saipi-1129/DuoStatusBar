import AppKit
import SwiftUI

@MainActor
func renderDuoPreview(to path: String, snapshot: StatusSnapshot = StatusSnapshot(batteryPercent: 88, isCharging: false, connection: .wifi(name: "Wi-Fi", level: 4), volumePercent: 60), showingOutputs: Bool = false) throws {
    let model = DashboardModel(snapshot, .overview)
    model.showingOutputs = showingOutputs
    let renderer = ImageRenderer(content: DuoPanel(model: model))
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
    @Published var changingPowerMode = false
    @Published var changingNetwork = false
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
    var setVolume: ((Double) -> Bool)?
    var setNetwork: ((NetworkTransport) -> Bool)?
    func showOutputMenu() {
        refreshOutputs()
        showingOutputs = true
        error = nil
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
        preferredContentSize = NSSize(width: 380, height: 492)
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    func update(with snapshot: StatusSnapshot) {
        model.refreshOutputs()
        if model.snapshot != snapshot { model.snapshot = snapshot }
    }
    func select(_ target: DashboardTarget) { model.target = target; model.showingOutputs = false; model.showingThemes = false }
}
struct DuoPanel: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("panelAppearance") private var appearance = PanelAppearance.classic.rawValue
    private var glass: Bool { PanelAppearance.supportsGlass && appearance == PanelAppearance.liquidGlass.rawValue }
    private var ink: Color { glass ? .primary : palette.ink }
    private func foreground(_ classic: Color) -> Color { glass ? .primary : classic }
    @AppStorage("panelTheme") private var themeName = PanelTheme.lavender.rawValue
    @AppStorage("statusMetric") private var metricName = StatusMetric.cpu.rawValue
    @AppStorage("showBatteryNumber") private var showBatteryNumber = true
    private var metric: StatusMetric { StatusMetric(rawValue: metricName) ?? .cpu }
    private var palette: PanelTheme { PanelTheme(rawValue: themeName) ?? .lavender }
    @State private var editing = false
    @State private var draft = 0.0
    private var s: StatusSnapshot { model.snapshot }
    private var volume: Double { editing ? draft : Double(s.volumePercent ?? 0) / 100 }
    private var networkName: String {
        switch s.connection {
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .offline: return "未接続"
        }
    }
    var body: some View {
        VStack(spacing: 14) {
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
                Button { model.showingThemes = true } label: {
                    Image(systemName: "paintpalette.fill").frame(width: 38, height: 38)
                        .panelSurface(palette.tile, in: Circle())
                }.help("外観とテーマの色").accessibilityLabel("外観とテーマの色")
                Button { model.settings?(model.target) } label: {
                    Image(systemName: "gearshape.fill").frame(width: 38, height: 38)
                        .panelSurface(palette.tile, in: Circle())
                }.help("システム設定を開く")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 38, height: 38)
                        .panelSurface(palette.tile, in: Circle())
                }.help("アプリを終了")
            }
            HStack(spacing: 12) {
                Group {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(StatusMetric.allCases) { item in
                                Button { metricName = item.rawValue } label: {
                                    Text(item.title).font(.system(size: 10, weight: .semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                                        .foregroundStyle(foreground(metric == item ? Color.white : ink))
                                        .panelSurface(metric == item ? palette.primary : palette.light, in: Capsule(), accented: metric == item)
                                }.accessibilityLabel("\(item.title)を表示")
                            }
                        }
                        Text(metric.displayValue(s))
                            .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.8).lineLimit(1).foregroundStyle(metricTextColor)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
                .frame(width: 168, height: 164)
                .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 30))
                .help(metric == .memory ? "物理メモリに対する使用量（ファイルキャッシュを除く概算）" : "メニューバーに表示する項目を選択")
                    VStack(spacing: 7) {
                        Toggle("残量数値", isOn: $showBatteryNumber)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize()
                            .help("メニューバーの残量数値を表示。オフでは通信アイコンを拡大")
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
                                .foregroundStyle(foreground(s.lowPowerMode ? palette.primary : Color.white))
                                .panelSurface(s.lowPowerMode ? Color.white : Color.white.opacity(0.18), in: Capsule(), accented: s.lowPowerMode)
                        }.disabled(model.changingPowerMode)
                            .accessibilityLabel("低電力モード、\(s.lowPowerMode ? "オン" : "オフ")")
                            .help("全電源の低電力モードを切り替え")
                    }.frame(maxWidth: .infinity).frame(height: 164)
                        .foregroundStyle(foreground(.white))
                        .panelSurface(palette.primary, in: RoundedRectangle(cornerRadius: model.target == .battery ? 22 : 34))
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
                            .foregroundStyle(foreground(.white)).frame(width: 50, height: 50)
                            .panelSurface(palette.primary, in: Circle())
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
                    .foregroundStyle(foreground(.white))
                    .panelSurface(palette.primary, in: RoundedRectangle(cornerRadius: 20))
                }
                .disabled(model.changingNetwork)
                .accessibilityLabel(networkToggleLabel)
                .help("有線とWi-Fiをワンタップで切り替え")
            }
            .padding(12)
            .panelSurface(palette.tile, in: RoundedRectangle(cornerRadius: 38))
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
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Color.clear.panelSurface(palette.tile, in: Capsule())
                        Capsule().fill(glass ? Color.accentColor.opacity(0.35) : palette.primary).frame(width: max(44, g.size.width * volume))
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(foreground(.white)).padding(.leading, 14)
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
                }.frame(height: 44).opacity(s.volumePercent == nil ? 0.4 : 1)
            }.padding(.horizontal, 4)
                .panelSurface(.clear, in: RoundedRectangle(cornerRadius: 22))
            Button { model.showOutputMenu() } label: {
                HStack {
                    Image(systemName: "hifispeaker.fill")
                    Text(model.outputs.first(where: { $0.id == model.outputID })?.name ?? "出力先を選択")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }.font(.system(size: 12, weight: .medium))
                    .padding(14).panelSurface(palette.tile, in: Capsule())
            }.help("オーディオの出力先")
            if let error = model.error { Text(error).font(.system(size: 10)) }
        }
        .opacity(model.showingOutputs || model.showingThemes ? 0 : 1)
        .allowsHitTesting(!model.showingOutputs && !model.showingThemes)
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .padding(18)
        .frame(width: 380, height: 492)
        .background(glass ? Color.clear : palette.base)
        .overlay {
            if model.showingOutputs { outputSelector }
            if model.showingThemes { themeSelector }
        }
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .preferredColorScheme(glass ? nil : .light)
        .onChange(of: appearance) { model.appearanceChanged?() }
    }
    private var themeSelector: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { model.showingThemes = false } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42).panelSurface(palette.tile, in: Circle())
                }.accessibilityLabel("戻る")
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
                        .panelSurface(palette == theme ? palette.primary : palette.tile, in: RoundedRectangle(cornerRadius: 24), accented: palette == theme)
                }.accessibilityLabel(theme.title + (palette == theme ? "、選択中" : ""))
            }
              }
            }
        }.padding(18).frame(width: 380, height: 492)
            .background(glass ? Color.clear : palette.base).foregroundStyle(ink).buttonStyle(.plain)
    }
    private var outputSelector: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { model.showingOutputs = false; model.error = nil } label: {
                    Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42).panelSurface(palette.tile, in: Circle())
                }.accessibilityLabel("戻る")
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
        }.padding(18).frame(width: 380, height: 492)
            .background(glass ? Color.clear : palette.base).foregroundStyle(ink).buttonStyle(.plain)
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
                                .panelSurface(selected ? palette.primary : palette.tile, in: RoundedRectangle(cornerRadius: selected ? 26 : 18), accented: selected)
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

import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import IOKit.ps
import Network

struct StatusSnapshot: Equatable {
    enum Connection: Equatable {
        case wifi(name: String, level: Int)
        case ethernet
        case offline

        var label: String {
            switch self {
            case let .wifi(name, _):
                return name
            case .ethernet:
                return "Ethernet"
            case .offline:
                return "Not connected"
            }
        }

        var detail: String {
            switch self {
            case let .wifi(_, level):
                return "Wi-Fi signal \(level)/5"
            case .ethernet:
                return "Ethernet connected"
            case .offline:
                return "Network unavailable"
            }
        }

        var transport: NetworkTransport? {
            switch self {
            case .wifi: return .wifi
            case .ethernet: return .ethernet
            case .offline: return nil
            }
        }
    }

    var batteryPercent: Int?
    var isCharging: Bool
    let connection: Connection
    let volumePercent: Int?
    var localIPAddress: String? = nil
    var cpuPercent: Int? = nil
    var memoryPercent: Int? = nil
    var memoryBytes: UInt64? = nil
    var lowPowerMode: Bool = false
    var memoryPressure: MemoryPressureLevel = .normal
    var chargingWatts: Double? = nil
}

final class SystemMonitor {
    private let metrics = SystemMetrics()
    private let chargingPower = ChargingPower()
    private let wifiClient = CWWiFiClient.shared()
    private let routeSwitcher = NetworkRouteSwitcher()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.synex.DuoStatusBar.network")
    private var currentPath: NWPath?
    private var cachedInterface: (transport: NetworkTransport, name: String)?

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func snapshot() -> StatusSnapshot {
        let battery = readBattery()
        let connection = readConnection()
        let volume = readOutputVolume()
        let performance = metrics.sample(for: StatusMetric.selected)
        let localIPAddress = readLocalIPAddress(for: connection)

        return StatusSnapshot(
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            connection: connection,
            volumePercent: volume,
            localIPAddress: localIPAddress,
            cpuPercent: performance.cpu,
            memoryPercent: performance.memory,
            memoryBytes: metrics.memoryBytes,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: metrics.memoryPressure,
            chargingWatts: chargingPower.sample(isCharging: battery.isCharging)
        )
    }

    func refreshBattery(in previous: StatusSnapshot) -> StatusSnapshot {
        let battery = readBattery()
        var next = previous
        next.batteryPercent = battery.percent
        next.isCharging = battery.isCharging
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.chargingWatts = chargingPower.sample(isCharging: battery.isCharging)
        return next
    }

    private func readBattery() -> (percent: Int?, isCharging: Bool) {
        let powerSourcesInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo).takeRetainedValue() as NSArray

        for source in powerSources {
            guard let description = IOPSGetPowerSourceDescription(
                powerSourcesInfo,
                source as CFTypeRef
            )?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey as String] as? Int
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int
            // Read live charging state independently of the 15-second watt cache.
            let charging = ChargingPower.isCharging()
                ?? (description[kIOPSIsChargingKey as String] as? Bool ?? false)

            if let current, let maximum, maximum > 0 {
                let percent = max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
                return (percent, charging)
            }
        }

        return (nil, false)
    }

    private func readConnection() -> StatusSnapshot.Connection {
        if let currentPath,
           currentPath.status == .satisfied,
           currentPath.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        }

        guard let interface = wifiClient.interface(),
              interface.powerOn() else {
            return .offline
        }

        let rssi = interface.rssiValue()
        guard rssi != 0 else {
            return .offline
        }

        let level = wifiLevel(fromRSSI: rssi)
        return .wifi(name: interface.ssid() ?? "Wi-Fi", level: level)
    }

    func switchNetwork(to transport: NetworkTransport) -> Bool {
        routeSwitcher.switchTo(transport)
    }

    private func readLocalIPAddress(for connection: StatusSnapshot.Connection) -> String? {
        guard let transport = connection.transport else {
            cachedInterface = nil
            return nil
        }

        let interfaceName: String
        if let cachedInterface, cachedInterface.transport == transport {
            interfaceName = cachedInterface.name
        } else if let resolvedName = routeSwitcher.interfaceBSDName(for: transport) {
            cachedInterface = (transport, resolvedName)
            interfaceName = resolvedName
        } else {
            return nil
        }

        return LocalNetworkAddress.ipv4(forInterface: interfaceName)
    }

    private func wifiLevel(fromRSSI rssi: Int) -> Int {
        if rssi >= -50 { return 5 }
        if rssi >= -60 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }


    func setOutputVolume(_ value: Double) -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var changed = false
        for element: UInt32 in [0, 1, 2] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var scalar = Float32(max(0, min(1, value)))
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr {
                changed = true
                if element == 0 { break }
            }
        }
        return changed
    }

    private func readOutputVolume() -> Int? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )

        guard defaultDeviceStatus == noErr, deviceID != 0 else {
            return nil
        }

        let elements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            1,
            2
        ]

        var values: [Float32] = []
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var scalar = Float32(0)
            var scalarSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &scalarSize,
                &scalar
            )

            if status == noErr, scalar.isFinite {
                values.append(max(0, min(1, scalar)))
            }
        }

        guard let value = values.first else {
            return nil
        }
        return max(0, min(100, Int((value * 100).rounded())))
    }
}

final class StatusBarView: NSView {
    static let preferredSize = NSSize(width: 88, height: 28)
    static let volumeDotCount = 4
    var onInteraction: ((DashboardTarget) -> Void)?
    var usesSystemRendering = false
    private var isDimmed = false
    private var lastRenderedMetric: StatusMetric?
    private var lastRenderedSize: NSSize?
    private var showsBatteryNumber = UserDefaults.standard.object(forKey: "showBatteryNumber") as? Bool ?? true
    private var snapshot = StatusSnapshot(batteryPercent: nil, isCharging: false, connection: .offline, volumePercent: nil)
    override var intrinsicContentSize: NSSize { Self.preferredSize }
    func update(with snapshot: StatusSnapshot) {
        let showNumber = UserDefaults.standard.object(forKey: "showBatteryNumber") as? Bool ?? true
        let imageChanged = self.snapshot != snapshot || lastRenderedMetric != StatusMetric.selected || lastRenderedSize != bounds.size || showsBatteryNumber != showNumber
        showsBatteryNumber = showNumber
        self.snapshot = snapshot
        toolTip = "CPU · メモリ · バッテリー · ネットワーク · 音量"
        if usesSystemRendering, let button = superview as? NSStatusBarButton, imageChanged || button.image == nil {
            button.image = makeTemplateImage()
            lastRenderedMetric = StatusMetric.selected
            lastRenderedSize = bounds.size
        }
        needsDisplay = true
    }
    func setDimmed(_ dimmed: Bool) {
        guard isDimmed != dimmed else { return }
        isDimmed = dimmed
        guard usesSystemRendering, let button = superview as? NSStatusBarButton else { return }
        button.image = makeTemplateImage()
        lastRenderedMetric = StatusMetric.selected
        lastRenderedSize = bounds.size
    }
    func makeTemplateImage(for selectedMetric: StatusMetric = StatusMetric.selected) -> NSImage {
        // Freeze the drawing state for this image; AppKit rasterizes it at the
        // display's backing scale and applies the native active/inactive tint.
        let renderer = StatusBarView(frame: NSRect(origin: .zero, size: bounds.size))
        renderer.snapshot = snapshot
        renderer.isDimmed = isDimmed
        renderer.showsBatteryNumber = showsBatteryNumber
        let metric = selectedMetric
        // Keep the same subtle inactive treatment as the other menu-bar extras.
        // A lower value makes this custom rasterized item look disconnected from
        // the native items, especially on a dark menu bar.
        let alpha = isDimmed ? CGFloat(0.70) : 1
        let image = NSImage(size: bounds.size, flipped: false) { _ in
            let color = NSColor.labelColor.withAlphaComponent(alpha)
            renderer.drawIndicator(color: color, metric: metric)
            return true
        }
        // Template images receive the native menu-bar tint. Accented states
        // must remain multicolor, so those states are rendered with a matching
        // explicit inactive alpha instead.
        image.isTemplate = !snapshot.lowPowerMode && !snapshot.isCharging && (metric != .memory || snapshot.memoryPressure == .normal)
        return image
    }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let scale = min(1, bounds.width / 88, bounds.height / 28)
        let p = NSPoint(x: (local.x - (bounds.width - 88 * scale) / 2) / scale,
                        y: (local.y - (bounds.height - 28 * scale) / 2) / scale)
        if p.y < 6 && p.x > 28 && p.x < 57 { onInteraction?(.volume) }
        else if p.y > 18 { onInteraction?(.battery) }
        else if p.x > 58 { onInteraction?(.network) }
        else { onInteraction?(.overview) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "アプリを終了", action: #selector(terminateApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func terminateApp() { NSApp.terminate(nil) }
    override func draw(_ dirtyRect: NSRect) {
        // In the live app this view handles clicks only, leaving rendering to
        // NSStatusBarButton so it participates in native menu-bar dimming.
        guard !usesSystemRendering else { return }
        drawIndicator(color: .labelColor, metric: StatusMetric.selected)
    }
    private func drawIndicator(color: NSColor, metric: StatusMetric) {
        // Scale both axes equally; never flatten the capsule on shorter menu bars.
        let scale = min(1, bounds.width / 88, bounds.height / 28)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: (bounds.width - 88 * scale) / 2, y: (bounds.height - 28 * scale) / 2)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        defer { NSGraphicsContext.current?.cgContext.restoreGState() }
        // Keep the number and volume dots on the outline, masking their areas.
        // The charge fraction still uses the full continuous perimeter.
        NSGraphicsContext.current?.saveGraphicsState()
        // BatteryOutline creates rounded gaps directly in its stroke.
        let gaugeColor: NSColor = snapshot.lowPowerMode
            ? .systemYellow.withAlphaComponent(color.alphaComponent)
            : snapshot.isCharging ? .systemGreen.withAlphaComponent(color.alphaComponent) : color
        BatteryOutline.draw(snapshot.batteryPercent, color: gaugeColor, showsNumber: showsBatteryNumber)
        NSGraphicsContext.current?.restoreGraphicsState()
        func text(_ value: String, _ rect: NSRect, _ size: CGFloat, _ textColor: NSColor) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (value as NSString).draw(in: rect, withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                .foregroundColor: textColor, .paragraphStyle: style
            ])
        }
        let metricColor: NSColor
        if metric == .memory {
            switch snapshot.memoryPressure {
            case .normal: metricColor = color
            case .warning: metricColor = .systemYellow.withAlphaComponent(color.alphaComponent)
            case .critical: metricColor = .systemRed.withAlphaComponent(color.alphaComponent)
            }
        } else {
            metricColor = color
        }
        let metricY: CGFloat = metric == .memory ? 5 : 7
        text(metric.displayValue(snapshot), NSRect(x: 14, y: metricY, width: 41, height: 17), metric == .memory ? 12 : 13, metricColor)
        if showsBatteryNumber {
            text(snapshot.batteryPercent.map(String.init) ?? "—", NSRect(x: 58, y: 18, width: 17, height: 11), 9, color)
        }
        NSGraphicsContext.current?.cgContext.saveGState()
        if !showsBatteryNumber {
            NSGraphicsContext.current?.cgContext.translateBy(x: 66, y: 14)
            NSGraphicsContext.current?.cgContext.scaleBy(x: 1.45, y: 1.45)
            NSGraphicsContext.current?.cgContext.translateBy(x: -66, y: -14)
        }
        switch snapshot.connection {
        case .ethernet:
            ethernetImage(color: color).draw(in: NSRect(x: 60, y: 8, width: 12, height: 12))
        case let .wifi(_, level):
            drawWiFi(level, color)
        case .offline: drawWiFi(0, color)
        }
        NSGraphicsContext.current?.cgContext.restoreGState()
        let dotSpacing: CGFloat = 6
        let firstDotCenter: CGFloat = 35
        for i in 0..<Self.volumeDotCount {
            let center = firstDotCenter + CGFloat(i) * dotSpacing
            let opacity = Self.volumeDotOpacity(index: i, volumePercent: snapshot.volumePercent)
            color.withAlphaComponent(color.alphaComponent * opacity).setFill()
            NSBezierPath(ovalIn: NSRect(x: center - 1.25, y: 0.75, width: 2.5, height: 2.5)).fill()
        }
    }
    static func volumeDotOpacity(index: Int, volumePercent: Int?) -> CGFloat {
        guard let volumePercent else { return 0 }
        let volume = CGFloat(max(0, min(100, volumePercent)))
        guard volume > 0 else { return 0 }
        let bucketSize = 100 / CGFloat(volumeDotCount)
        let progress = max(0, min(1, (volume - CGFloat(index) * bucketSize) / bucketSize))
        return progress > 0 ? 0.42 + 0.58 * progress : 0
    }
    private func drawWiFi(_ level: Int, _ color: NSColor) {
        let count = level == 0 ? 0 : Int(ceil(Double(level) * 3 / 5))
        let center = NSPoint(x: 66, y: 9)
        for i in 0..<3 {
            let arc = NSBezierPath()
            arc.lineWidth = 1.6; arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: 2 + CGFloat(i) * 2.5, startAngle: 42, endAngle: 138)
            color.withAlphaComponent(color.alphaComponent * (i < count ? 1 : 0.2)).setStroke(); arc.stroke()
        }
        color.withAlphaComponent(color.alphaComponent * (level > 0 ? 1 : 0.2)).setFill()
        NSBezierPath(ovalIn: NSRect(x: 64.8, y: 7.8, width: 2.4, height: 2.4)).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = SystemMonitor()
    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private var refreshTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var dashboardPopover: NSPopover?
    private var glassPanel: GlassDashboardPanel?
    private var dashboardShown: Bool { dashboardPopover?.isShown == true || glassPanel?.isVisible == true }
    private var dashboardController: DuoDashboardViewController?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var menuTrackingDepth = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--show-dashboard") ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: StatusBarView.preferredSize.width * min(1, NSStatusBar.system.thickness / 28))
        statusView = StatusBarView(frame: NSRect(origin: .zero, size: StatusBarView.preferredSize))
        statusView.setAccessibilityElement(true)
        statusView.onInteraction = { [weak self] target in
            self?.showDashboard(for: target)
        }
        if let button = statusItem.button {
            statusView.usesSystemRendering = true
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
            syncDimmedAppearance()
        }
        statusItem.menu = nil
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closeDashboard), name: NSApplication.didResignActiveNotification, object: NSApp)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resync(_:)),
            name: Notification.Name.NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resync(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(resync(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        refresh()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().refreshBatteryImmediately()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        // Sample metrics and redraw the selected metric every half second.
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        // Opt-in manual UI verification; ordinary launches remain menu-bar only.
        if CommandLine.arguments.contains("--show-dashboard") {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.showDashboard(for: .overview)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeClickMonitors()
        refreshTimer?.invalidate()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        dashboardPopover?.performClose(nil)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private var latestSnapshot: StatusSnapshot?

    private func refreshBatteryImmediately() {
        guard let latestSnapshot else { refresh(); return }
        let snapshot = monitor.refreshBattery(in: latestSnapshot)
        self.latestSnapshot = snapshot
        statusView?.update(with: snapshot)
        // Don't enumerate audio devices or query the network on the power event.
        dashboardController?.model.snapshot = snapshot
        statusItem.button?.displayIfNeeded()
    }

    @objc private func refresh() {
        let snapshot = monitor.snapshot()
        latestSnapshot = snapshot
        statusView?.update(with: snapshot)
        dashboardController?.update(with: snapshot)
    }

    @objc private func resync(_ notification: Notification) {
        refresh()
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        let application = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            ?? NSWorkspace.shared.frontmostApplication
        let currentPID = NSRunningApplication.current.processIdentifier
        guard let application else { return }
        statusView?.setDimmed(application.processIdentifier != currentPID)
    }

    private func syncDimmedAppearance() {
        guard let application = NSWorkspace.shared.frontmostApplication else { return }
        statusView?.setDimmed(application.processIdentifier != NSRunningApplication.current.processIdentifier)
    }

    @objc private func menuBegan() { menuTrackingDepth += 1 }
    @objc private func menuEnded() { menuTrackingDepth = max(0, menuTrackingDepth - 1) }
    @objc private func closeDashboard() {
        dashboardPopover?.performClose(nil)
        glassPanel?.orderOut(nil)
        removeClickMonitors()
        syncDimmedAppearance()
    }
    func popoverDidClose(_ notification: Notification) {
        guard glassPanel?.isVisible != true else { return }
        removeClickMonitors()
        syncDimmedAppearance()
    }
    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }
    private func installClickMonitors() {
        removeClickMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.closeDashboard()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self, self.dashboardShown else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeDashboard()
                return nil
            }
            if event.type == .keyDown { return event }
            // Native audio-device menus must finish handling their own selection.
            guard self.menuTrackingDepth == 0 else { return event }
            let point = NSEvent.mouseLocation
            let insidePanel = self.dashboardController?.view.window?.frame.contains(point) ?? false
            let insideStatus = self.statusView.window.map {
                $0.convertToScreen(self.statusView.convert(self.statusView.bounds, to: nil)).contains(point)
            } ?? false
            if !insidePanel && !insideStatus { self.closeDashboard() }
            return event
        }
    }

    private func showDashboard(for target: DashboardTarget) {
        let snapshot = monitor.snapshot()

        if dashboardShown, let dashboardController {
            dashboardController.update(with: snapshot)
            dashboardController.select(target)
            return
        }

        let controller = DuoDashboardViewController(snapshot: snapshot, target: target)
        controller.onSetVolume = { [weak self] value in
            guard let self else { return false }
            let result = self.monitor.setOutputVolume(value)
            self.refresh()
            return result
        }
        controller.onSetNetwork = { [weak self] transport in
            guard let self else { return false }
            let result = self.monitor.switchNetwork(to: transport)
            self.refresh()
            return result
        }
        controller.onOpenSettings = { [weak self] target in
            self?.openSettings(for: target)
        }
        controller.model.appearanceChanged = { [weak self, weak controller] in
            DispatchQueue.main.async {
                guard let self, let controller, self.dashboardShown else { return }
                // Transfer the same hosting controller only after the old popover closes.
                self.dashboardPopover?.animates = false
                self.closeDashboard()
                self.presentDashboard(controller)
            }
        }

        presentDashboard(controller)
    }

    private func presentDashboard(_ controller: DuoDashboardViewController) {
        dashboardController = controller
        if PanelAppearance.usesGlass {
            dashboardPopover?.contentViewController = nil
            let panel = GlassDashboardPanel()
            if #available(macOS 26.0, *) {
                controller.sizingOptions = []
            }
            panel.contentViewController = controller
            panel.setContentSize(controller.preferredContentSize)
            if let window = statusView.window {
                let anchor = window.convertToScreen(statusView.convert(statusView.bounds, to: nil))
                let screen = window.screen?.visibleFrame ?? anchor
                let x = max(screen.minX, min(anchor.midX - 190, screen.maxX - 380))
                panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 492 - 8))
            }
            glassPanel = panel
            panel.makeKeyAndOrderFront(nil)
            statusView.setDimmed(false)
            installClickMonitors()
            return
        }
        glassPanel?.contentViewController = nil
        glassPanel = nil
        let popover = NSPopover()
        popover.delegate = self
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = controller.preferredContentSize

        dashboardController = controller
        dashboardPopover = popover
        popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
        statusView.setDimmed(false)
        installClickMonitors()
    }

    private func openSettings(for target: DashboardTarget) {
        let identifiers: [String]
        switch target {
        case .network:
            identifiers = [
                monitor.snapshot().connection == .ethernet ? "com.apple.Network-Settings.extension" : "com.apple.wifi-settings-extension",
                "com.apple.Network-Settings.extension",
                "com.apple.preference.network"
            ]
        case .battery:
            identifiers = [
                "com.apple.Battery-Settings.extension",
                "com.apple.preference.battery"
            ]
        case .volume:
            identifiers = [
                "com.apple.Sound-Settings.extension",
                "com.apple.preference.sound"
            ]
        case .overview:
            identifiers = []
        }

        for identifier in identifiers {
            if let url = URL(string: "x-apple.systempreferences:\(identifier)"), NSWorkspace.shared.open(url) {
                closeDashboard()
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

if CommandLine.arguments.contains("--test-metrics") {
    precondition(SystemMetrics.cpuUsage(previous: [0, 0, 0, 0], current: [20, 10, 70, 0]) == 30)
    precondition(SystemMetrics.cpuUsage(previous: [0, 0, 0, 0], current: [0, 0, 100, 0]) == 0)
    precondition(SystemMetrics.cpuUsage(previous: [0, 0, 0, 0], current: [100, 0, 0, 0]) == 100)
    precondition(SystemMetrics.cpuUsage(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]) == nil)
    precondition(SystemMetrics.usedMemoryPages(
        physicalPages: 1_000,
        freePages: 100,
        speculativePages: 10,
        purgeablePages: 20,
        externalPages: 30
    ) == 860)
    precondition(MemoryPressureLevel.from(.normal) == .normal)
    precondition(MemoryPressureLevel.from(.warning) == .warning)
    precondition(MemoryPressureLevel.from(.critical) == .critical)
    let metrics = SystemMetrics()
    let memory = metrics.sample(for: .memory)
    precondition(memory.cpu == nil && memory.memory != nil)
    precondition(metrics.cpuReadCount == 0 && metrics.memoryReadCount == 1)
    let cachedMemory = metrics.sample(for: .memory)
    precondition(cachedMemory == memory, "Metrics must stay cached within three seconds")
    precondition(metrics.cpuReadCount == 0 && metrics.memoryReadCount == 1)
    let volume = metrics.sample(for: .volume)
    precondition(volume.cpu == nil && volume.memory == nil)
    precondition(metrics.cpuReadCount == 0 && metrics.memoryReadCount == 1)
    let firstCPU = metrics.sample(for: .cpu)
    precondition(firstCPU.cpu == nil && firstCPU.memory == nil)
    precondition(metrics.cpuReadCount == 1 && metrics.memoryReadCount == 1)
    Thread.sleep(forTimeInterval: SystemMetrics.updateInterval + 0.1)
    let actual = metrics.sample(for: .cpu)
    precondition(actual.cpu.map { (0...100).contains($0) } == true)
    precondition(actual.memory == nil)
    precondition(metrics.cpuReadCount == 2 && metrics.memoryReadCount == 1)
    let fixture = StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, cpuPercent: 23, memoryPercent: 68)
    precondition(StatusMetric.cpu.value(fixture) == 23)
    precondition(StatusMetric.memory.value(fixture) == 68)
    precondition(StatusMetric.volume.value(fixture) == 40)
    print("PASS CPU deltas, selected-only reads, live CPU=\(actual.cpu!)%, memory=not-read")
    exit(0)
}
if CommandLine.arguments.contains("--test-indicators") {
    precondition(StatusBarView.volumeDotCount == 4)
    precondition(StatusBarView.volumeDotOpacity(index: 0, volumePercent: 0) == 0)
    precondition(StatusBarView.volumeDotOpacity(index: 0, volumePercent: 1) > StatusBarView.volumeDotOpacity(index: 0, volumePercent: 0))
    precondition(StatusBarView.volumeDotOpacity(index: 0, volumePercent: 100) == 1)
    precondition(BatteryOutline.segments.count == 1)
    precondition(BatteryOutline.segments[0].first == BatteryOutline.segments[0].last)
    precondition(BatteryOutline.segments[0].first == NSPoint(x: 58, y: 2))
    let ninetyEnd = BatteryOutline.prefix(0.9).last!.last!
    precondition(ninetyEnd.x > 70 && ninetyEnd.y < 14, "90% must end on the lower-right curve")
    for percent in [0, 1, 10, 50, 90, 99, 100] {
        let expected = BatteryOutline.length(BatteryOutline.segments) * Double(percent) / 100
        let actual = BatteryOutline.length(BatteryOutline.prefix(Double(percent) / 100))
        precondition(abs(expected - actual) < 0.00001, "Gauge length mismatch")
        print("PASS gauge \(percent)%")
    }
    let outputs = AudioOutputs.list()
    print("outputs=\(outputs.count), currentListed=\(outputs.contains { $0.id == AudioOutputs.current() })")
    exit(0)
}
if CommandLine.arguments.contains("--test-charging") {
    precondition(ChargingPower.watts(millivolts: 12_000, milliamps: 2_000) == 24)
    precondition(ChargingPower.watts(millivolts: 12_000, milliamps: 0) == 0)
    precondition(ChargingPower.watts(millivolts: 12_000, milliamps: -2_000) == nil)
    precondition(ChargingPower.watts(millivolts: 12_000, milliamps: Double(UInt64.max)) == nil)
    precondition(ChargingPower.watts(millivolts: .nan, milliamps: 2_000) == nil)
    let reader = ChargingPower()
    let first = reader.sample(isCharging: true, now: 100)
    precondition(reader.sample(isCharging: true, now: 101) == first)
    precondition(reader.sample(isCharging: false, now: 102) == nil)
    print("PASS charging watts conversion, invalid values, cache, disconnect; live=\(first.map { String(format: "%.1fW", $0) } ?? "unavailable")")
    exit(0)
}
if CommandLine.arguments.contains("--test-memory") {
    let metrics = SystemMetrics()
    let reading = metrics.sample(for: .memory)
    let bytes = metrics.memoryBytes ?? 0
    print(String(format: "used=%.2fG, percent=%d%%", Double(bytes) / 1_073_741_824, reading.memory ?? -1))
    exit(0)
}
if CommandLine.arguments.contains("--test-network-services") {
    print(NetworkRouteSwitcher().serviceDiagnostics())
    exit(0)
}
if CommandLine.arguments.contains("--test-local-address") {
    let routeSwitcher = NetworkRouteSwitcher()
    for transport in [NetworkTransport.wifi, .ethernet] {
        let interfaceName = routeSwitcher.interfaceBSDName(for: transport)
        let address = interfaceName.flatMap { LocalNetworkAddress.ipv4(forInterface: $0) }
        print("\(transport.title): interface=\(interfaceName ?? "none"), ipv4=\(address ?? "none")")
    }
    exit(0)
}
let application = NSApplication.shared
if CommandLine.arguments.contains("--test-template") {
    for height: CGFloat in [22, 28] {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 88 * height / 28, height: height))
        bar.update(with: StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, cpuPercent: 23))
        let template = bar.makeTemplateImage()
        precondition(template.isTemplate)
        precondition(template.size == bar.bounds.size)
        guard let tiff = template.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            fatalError("Template cannot be rendered")
        }
        var hasInk = false
        var hasClear = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                hasInk = hasInk || alpha > 0.9
                hasClear = hasClear || alpha < 0.01
            }
        }
        precondition(hasInk && hasClear, "Template must have both glyphs and a transparent background")
        print("PASS template at \(height)pt")
    }
    let warningView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 28))
    warningView.update(with: StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, memoryPercent: 88, memoryPressure: .warning))
    precondition(!warningView.makeTemplateImage(for: .memory).isTemplate)
    let criticalView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 28))
    criticalView.update(with: StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, memoryPercent: 98, memoryPressure: .critical))
    precondition(!criticalView.makeTemplateImage(for: .memory).isTemplate)
    let lowPowerView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 28))
    lowPowerView.update(with: StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, lowPowerMode: true))
    precondition(!lowPowerView.makeTemplateImage(for: .cpu).isTemplate)
    print("PASS warning/critical metric colors and low-power gauge accent")
    exit(0)
}
if CommandLine.arguments.count == 3, ["--render-live", "--render-outputs"].contains(CommandLine.arguments[1]) {
    let monitor = SystemMonitor()
    _ = monitor.snapshot()
    RunLoop.main.run(until: Date().addingTimeInterval(SystemMetrics.updateInterval + 0.1))
    let snapshot = monitor.snapshot()
    try MainActor.assumeIsolated {
        try renderDuoPreview(to: CommandLine.arguments[2], snapshot: snapshot, showingOutputs: CommandLine.arguments[1] == "--render-outputs")
    }
    print("battery=\(snapshot.batteryPercent.map(String.init) ?? "unavailable"), volume=\(snapshot.volumePercent.map(String.init) ?? "unavailable"), network=\(snapshot.connection.detail)")
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-bar" {
    let bar = StatusBarView(frame: NSRect(origin: .zero, size: StatusBarView.preferredSize))
    bar.appearance = NSAppearance(named: .darkAqua)
    bar.update(with: StatusSnapshot(batteryPercent: 90, isCharging: false, connection: .ethernet, volumePercent: 40, cpuPercent: 23, memoryPercent: 68))
    let image = NSImage(size: NSSize(width: 352, height: 112))
    image.lockFocus()
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 352, height: 112).fill()
    NSGraphicsContext.current?.cgContext.scaleBy(x: 4, y: 4)
    bar.appearance?.performAsCurrentDrawingAppearance { bar.draw(bar.bounds) }
    image.unlockFocus()
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" {
    try MainActor.assumeIsolated { try renderDuoPreview(to: CommandLine.arguments[2]) }
    exit(0)
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()

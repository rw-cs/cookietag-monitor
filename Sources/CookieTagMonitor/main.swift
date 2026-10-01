import AppKit
import CoreBluetooth
import ServiceManagement
import UserNotifications

private let samsungFindUUID = CBUUID(string: "FD5A")
private let scanDuration: TimeInterval = 45
private let scheduledHour = 11

@main
final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var lastSeenLabel: NSTextField!
    private var central: CBCentralManager!
    private var scanTimer: Timer?
    private var dailyTimer: Timer?
    private var sightings: [UUID: Sighting] = [:]
    private var isScanning = false

    private let defaults = UserDefaults.standard
    private let lastSeenKey = "lastSuccessfulScan"
    private let welcomeShownKey = "welcomeShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMenuBar()
        configureWindow()
        configureNotifications()
        configureLaunchAtLogin()
        central = CBCentralManager(delegate: self, queue: .main)
        scheduleNextDailyScan()
        refreshMenu()
        showWelcomeIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify(
                title: "Enable CookieTag at login",
                body: "Open System Settings → General → Login Items and enable CookieTag Monitor so the daily check can run."
            )
        }
    }

    private func scheduleNextDailyScan() {
        dailyTimer?.invalidate()
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = scheduledHour
        components.minute = 0
        components.second = 0
        guard let next = calendar.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        ) else { return }

        dailyTimer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.startScan()
            self?.scheduleNextDailyScan()
        }
        if let dailyTimer { RunLoop.main.add(dailyTimer, forMode: .common) }
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐶"
        statusItem.button?.toolTip = "Cookie SmartTag monitor"
    }

    private func configureWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CookieTag Monitor"
        window.center()
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "🐶  Cookie’s SmartTag2")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .center

        statusLabel = NSTextField(labelWithString: "Preparing Bluetooth scanner…")
        statusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2

        lastSeenLabel = NSTextField(labelWithString: "No successful response yet")
        lastSeenLabel.textColor = .secondaryLabelColor
        lastSeenLabel.alignment = .center

        let schedule = NSTextField(labelWithString: "Automatic check every day at 11:00 AM")
        schedule.textColor = .secondaryLabelColor
        schedule.alignment = .center

        let scanButton = NSButton(title: "Scan Now", target: self, action: #selector(startScan))
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, statusLabel, lastSeenLabel, schedule, scanButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 390)
        ])
        showWindow()
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showWelcomeIfNeeded() {
        guard !defaults.bool(forKey: welcomeShownKey) else { return }
        defaults.set(true, forKey: welcomeShownKey)
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "CookieTag Monitor is running"
            alert.informativeText = "Look for the 🐶 icon near the clock. A 45-second SmartTag2 scan is starting now, and another will run every day at 11:00 AM."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            self?.showWindow()
            self?.refreshMenu()
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .unauthorized:
            setIcon("exclamationmark.triangle.fill")
            notify(title: "Bluetooth permission needed", body: "Allow Bluetooth for CookieTag Monitor in System Settings → Privacy & Security → Bluetooth.")
            refreshMenu(detail: "Bluetooth permission denied")
        case .poweredOff:
            setIcon("exclamationmark.triangle.fill")
            refreshMenu(detail: "Bluetooth is switched off")
        default:
            refreshMenu(detail: "Waiting for Bluetooth…")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isSamsungFindAdvertisement(advertisementData) else { return }
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        if var existing = sightings[id] {
            existing.count += 1
            existing.strongestRSSI = max(existing.strongestRSSI, rssi)
            existing.rssiSamples.append(rssi)
            sightings[id] = existing
        } else {
            sightings[id] = Sighting(count: 1, strongestRSSI: rssi, rssiSamples: [rssi])
        }
        let nearest = sightings.values.min { estimatedDistance(for: $0) < estimatedDistance(for: $1) }
        if let nearest {
            let distance = formatDistance(estimatedDistance(for: nearest))
            statusItem.button?.title = "🐶 \(distance)"
            refreshMenu(detail: "Scanning… nearest tag about \(distance) away")
        }
    }

    private func isSamsungFindAdvertisement(_ data: [String: Any]) -> Bool {
        if let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           serviceData.keys.contains(where: { $0 == samsungFindUUID }) {
            return true
        }
        if let uuids = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           uuids.contains(where: { $0 == samsungFindUUID }) {
            return true
        }
        return false
    }

    @objc private func startScan() {
        guard central?.state == .poweredOn, !isScanning else { return }
        isScanning = true
        sightings.removeAll()
        setIcon("dot.radiowaves.left.and.right")
        refreshMenu(detail: "Scanning for Cookie’s SmartTag2…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanDuration, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    private func finishScan() {
        central.stopScan()
        isScanning = false

        let credible = sightings.values.filter { $0.count >= 2 }
        if credible.isEmpty {
            setIcon("exclamationmark.triangle.fill")
            refreshMenu(detail: "No SmartTag2 response found")
            notify(
                title: "Check Cookie’s SmartTag2",
                body: "No Samsung tracker signal was detected during today’s 45-second check. Check the CR2032 battery and keep Cookie near the Mac for another scan."
            )
            return
        }

        let now = Date()
        defaults.set(now, forKey: lastSeenKey)
        setIcon("checkmark.circle.fill")
        let strongest = credible.map(\.strongestRSSI).max() ?? -127
        let nearest = credible.min { estimatedDistance(for: $0) < estimatedDistance(for: $1) }!
        let distance = formatDistance(estimatedDistance(for: nearest))
        statusItem.button?.title = "🐶 \(distance)"
        refreshMenu(detail: "Healthy — nearest tag about \(distance) away (\(strongest) dBm)")
        if credible.count > 1 {
            notify(
                title: "CookieTag check passed with a caveat",
                body: "More than one Samsung tracker was nearby, so the Mac cannot prove which one was Cookie’s."
            )
        }
    }

    private func setIcon(_ symbol: String) {
        statusItem.button?.title = symbol == "exclamationmark.triangle.fill" ? "🐶⚠️" : "🐶"
    }

    private func estimatedDistance(for sighting: Sighting) -> Double {
        let sorted = sighting.rssiSamples.sorted()
        let median = Double(sorted[sorted.count / 2])
        // SmartTag2 does not publish a calibrated ranging value to macOS.
        // -59 dBm at 1 m and a 2.2 indoor path-loss exponent provide a useful
        // proximity estimate, not a precise measurement.
        return pow(10.0, (-59.0 - median) / 22.0)
    }

    private func formatDistance(_ meters: Double) -> String {
        let bounded = min(max(meters, 0.1), 50)
        if bounded < 1 {
            return "\(Int((bounded * 100).rounded())) cm"
        }
        return String(format: "%.1f m", bounded)
    }

    private func refreshMenu(detail: String? = nil) {
        let summary = detail ?? currentSummary()
        statusLabel?.stringValue = summary
        if let lastSeen = defaults.object(forKey: lastSeenKey) as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastSeenLabel?.stringValue = "Last response: \(formatter.string(from: lastSeen))"
        }

        let menu = NSMenu()
        let state = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let schedule = NSMenuItem(title: "Daily check: 11:00 AM", action: nil, keyEquivalent: "")
        schedule.isEnabled = false
        menu.addItem(schedule)

        if let lastSeen = defaults.object(forKey: lastSeenKey) as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let item = NSMenuItem(title: "Last response: \(formatter.string(from: lastSeen))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open CookieTag Monitor", action: #selector(showWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let scan = NSMenuItem(title: isScanning ? "Scanning…" : "Scan now", action: #selector(startScan), keyEquivalent: "r")
        scan.target = self
        scan.isEnabled = !isScanning && central?.state == .poweredOn
        menu.addItem(scan)

        let info = NSMenuItem(title: "How identification works…", action: #selector(showExplanation), keyEquivalent: "")
        info.target = self
        menu.addItem(info)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit CookieTag Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func currentSummary() -> String {
        if isScanning { return "Scanning for Cookie’s SmartTag2…" }
        guard let lastSeen = defaults.object(forKey: lastSeenKey) as? Date else { return "No successful check yet" }
        return Calendar.current.isDateInToday(lastSeen) ? "Cookie’s tag responded today" : "A daily response is overdue"
    }

    @objc private func showExplanation() {
        let alert = NSAlert()
        alert.messageText = "What this monitor can verify"
        alert.informativeText = "SmartTag2 broadcasts Samsung Find Network BLE packets, but rotates its private identity. macOS can confirm that a nearby SmartTag2 is transmitting; it cannot permanently identify Cookie’s particular tag. Distance is estimated from signal strength and can vary with walls, Cookie’s body, and tag orientation. For a dependable check, keep other Samsung tags away during the scan."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private struct Sighting {
    var count: Int
    var strongestRSSI: Int
    var rssiSamples: [Int]
}

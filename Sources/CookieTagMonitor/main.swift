import AppKit
import CoreBluetooth
import Security
import ServiceManagement
import UserNotifications

private let samsungFindUUID = CBUUID(string: "FD5A")
private let scanDuration: TimeInterval = 45
private let scheduledHour = 11

final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var batteryLabel: NSTextField!
    private var lastSeenLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var scanButton: NSButton!
    private var calibrateButton: NSButton!
    private var smartThingsButton: NSButton!
    private var central: CBCentralManager!
    private var scanTimer: Timer?
    private var dailyTimer: Timer?
    private var sightings: [UUID: Sighting] = [:]
    private var totalBLEDevicesSeen: Set<UUID> = []
    private var isScanning = false

    private let defaults = UserDefaults.standard
    private let lastSeenKey = "lastSuccessfulScan"
    private let welcomeShownKey = "welcomeShown"
    private let historyKey = "checkHistory"
    private let referenceRSSIKey = "distanceReferenceRSSI"
    private let smartThingsDeviceIDKey = "smartThingsCookieTag2DeviceID"

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
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

        batteryLabel = NSTextField(labelWithString: "Battery: waiting for a reading")
        batteryLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        batteryLabel.alignment = .center

        lastSeenLabel = NSTextField(labelWithString: "No successful response yet")
        lastSeenLabel.textColor = .secondaryLabelColor
        lastSeenLabel.alignment = .center

        let schedule = NSTextField(labelWithString: "Automatic check every day at 11:00 AM")
        schedule.textColor = .secondaryLabelColor
        schedule.alignment = .center

        statsLabel = NSTextField(labelWithString: "No check history yet")
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .center
        statsLabel.maximumNumberOfLines = 3

        scanButton = NSButton(title: "Scan Now", target: self, action: #selector(startScan))
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"

        calibrateButton = NSButton(title: "Calibrate at 90 cm", target: self, action: #selector(calibrateDistance))
        calibrateButton.bezelStyle = .rounded

        smartThingsButton = NSButton(title: "Connect SmartThings", target: self, action: #selector(connectSmartThings))
        smartThingsButton.bezelStyle = .rounded
        if loadTokenFromKeychain() != nil { smartThingsButton.title = "Refresh SmartThings" }

        let buttons = NSStackView(views: [scanButton, calibrateButton, smartThingsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, statusLabel, batteryLabel, lastSeenLabel, statsLabel, schedule, buttons])
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
            scanButton?.isEnabled = true
            notify(title: "Bluetooth permission needed", body: "Allow Bluetooth for CookieTag Monitor in System Settings → Privacy & Security → Bluetooth.")
            refreshMenu(detail: "Bluetooth permission denied")
        case .poweredOff:
            setIcon("exclamationmark.triangle.fill")
            scanButton?.isEnabled = true
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
        totalBLEDevicesSeen.insert(peripheral.identifier)
        guard isSamsungFindAdvertisement(advertisementData) else { return }
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        if var existing = sightings[id] {
            existing.count += 1
            existing.strongestRSSI = max(existing.strongestRSSI, rssi)
            existing.rssiSamples.append(rssi)
            if let battery = batteryLevel(from: advertisementData) { existing.batteryLevels.append(battery) }
            sightings[id] = existing
        } else {
            let battery = batteryLevel(from: advertisementData).map { [$0] } ?? []
            sightings[id] = Sighting(count: 1, strongestRSSI: rssi, rssiSamples: [rssi], batteryLevels: battery)
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
        if let uuids = data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID],
           uuids.contains(where: { $0 == samsungFindUUID }) {
            return true
        }
        if let uuids = data[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID],
           uuids.contains(where: { $0 == samsungFindUUID }) {
            return true
        }
        if let name = data[CBAdvertisementDataLocalNameKey] as? String {
            let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if normalized == "smarttag" || normalized == "smarttag2" || normalized == "galaxysmarttag" { return true }
        }
        return false
    }

    private func batteryLevel(from advertisement: [String: Any]) -> Int? {
        guard let serviceData = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let payload = serviceData.first(where: { $0.key == samsungFindUUID })?.value,
              payload.count >= 13 else { return nil }
        // Samsung Offline Finding payload byte 12 uses bits 6–7 for its
        // four-level battery state: very low, low, medium, or full.
        return Int((payload[12] >> 6) & 0x03)
    }

    @objc private func startScan() {
        guard let central else {
            refreshMenu(detail: "Bluetooth scanner is still starting—try again in a moment")
            return
        }
        guard !isScanning else {
            refreshMenu(detail: "A 45-second scan is already running…")
            return
        }
        guard central.state == .poweredOn else {
            let message: String
            switch central.state {
            case .unauthorized:
                message = "Bluetooth permission denied—enable it in System Settings"
            case .poweredOff:
                message = "Bluetooth is switched off"
            case .unsupported:
                message = "Bluetooth Low Energy is not supported on this Mac"
            default:
                message = "Bluetooth is not ready—try again in a moment"
            }
            refreshMenu(detail: message)
            return
        }
        isScanning = true
        scanButton?.title = "Scanning…"
        scanButton?.isEnabled = false
        sightings.removeAll()
        totalBLEDevicesSeen.removeAll()
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
        scanButton?.title = "Scan Again"
        scanButton?.isEnabled = true

        let credible = sightings.values.filter { $0.count >= 2 }
        if credible.isEmpty {
            saveRecord(CheckRecord(date: Date(), detected: false, batteryRaw: nil, medianRSSI: nil))
            setIcon("exclamationmark.triangle.fill")
            refreshMenu(detail: "No SmartTag2 found (\(totalBLEDevicesSeen.count) other BLE devices seen)")
            playWarningSound()
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
        let battery = nearest.batteryLevels.sorted().dropFirst(nearest.batteryLevels.count / 2).first
        let medianRSSI = nearest.rssiSamples.sorted()[nearest.rssiSamples.count / 2]
        saveRecord(CheckRecord(date: now, detected: true, batteryRaw: battery, medianRSSI: medianRSSI))
        updateBatteryDisplay(battery)
        statusItem.button?.title = "🐶 \(distance)"
        refreshMenu(detail: "Healthy — nearest tag about \(distance) away (\(strongest) dBm)")
        if credible.count > 1 {
            notify(
                title: "CookieTag check passed with a caveat",
                body: "More than one Samsung tracker was nearby, so the Mac cannot prove which one was Cookie’s."
            )
        }
        if let battery, battery <= 2 {
            playWarningSound()
            notify(
                title: battery <= 1 ? "CookieTag2 battery is low" : "CookieTag2 battery may be below 50%",
                body: "Replace the CR2032 proactively. Samsung reports only coarse battery states, and a tag can fail while SmartThings still says sufficient."
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
        // Use the saved reference strength at 1 m with a 2.2 indoor path-loss
        // exponent. -80 dBm is a closer default for this tag/Mac combination.
        let reference = defaults.object(forKey: referenceRSSIKey) as? Double ?? -80.0
        return pow(10.0, (reference - median) / 22.0)
    }

    private func formatDistance(_ meters: Double) -> String {
        let bounded = min(max(meters, 0.1), 50)
        if bounded < 1 {
            return "\(Int((bounded * 100).rounded())) cm"
        }
        return String(format: "%.1f m", bounded)
    }

    @objc private func calibrateDistance() {
        guard let latest = loadHistory().last(where: { $0.detected && $0.medianRSSI != nil }),
              let rssi = latest.medianRSSI else {
            refreshMenu(detail: "Run a successful scan before calibrating")
            return
        }
        let knownDistance = 0.9
        let referenceAtOneMeter = Double(rssi) + 22.0 * log10(knownDistance)
        defaults.set(referenceAtOneMeter, forKey: referenceRSSIKey)
        refreshMenu(detail: "Distance calibrated with Cookie at 90 cm")

        let alert = NSAlert()
        alert.messageText = "Distance calibrated"
        alert.informativeText = "The latest signal reading is now treated as 90 cm. Run another scan to see the corrected estimate. Recalibrate whenever the collar or laptop position changes substantially."
        alert.addButton(withTitle: "Scan Again")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { startScan() }
    }

    @objc private func connectSmartThings() {
        if let savedToken = loadTokenFromKeychain() {
            testSmartThings(token: savedToken)
            return
        }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "Paste the 24-hour SmartThings token"
        let alert = NSAlert()
        alert.messageText = "Connect SmartThings"
        alert.informativeText = "The token is stored in your Mac’s Keychain and sent only to api.smartthings.com."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            refreshMenu(detail: "No SmartThings token entered")
            return
        }
        saveTokenToKeychain(token)
        testSmartThings(token: token)
    }

    private func saveTokenToKeychain(_ token: String) {
        let service = "local.cookie.tagmonitor.smartthings"
        let account = "SmartThingsPAT"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.cookie.tagmonitor.smartthings",
            kSecAttrAccount as String: "SmartThingsPAT",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.cookie.tagmonitor.smartthings",
            kSecAttrAccount as String: "SmartThingsPAT"
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func testSmartThings(token: String) {
        smartThingsButton.isEnabled = false
        smartThingsButton.title = "Checking…"
        refreshMenu(detail: "Checking SmartThings for CookieTag…")
        var request = URLRequest(url: URL(string: "https://api.smartthings.com/v1/devices?includeStatus=true&includeHealth=true")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.smartThingsButton.isEnabled = true
                self.smartThingsButton.title = self.loadTokenFromKeychain() == nil ? "Connect SmartThings" : "Refresh SmartThings"
                guard let http = response as? HTTPURLResponse, let data else {
                    self.showSmartThingsResult("Connection failed: \(error?.localizedDescription ?? "no response")")
                    return
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 401 {
                        self.deleteTokenFromKeychain()
                        self.smartThingsButton.title = "Connect SmartThings"
                    }
                    self.showSmartThingsResult(http.statusCode == 401 ? "Token rejected or expired and was removed from Keychain. Generate a new token with Devices read permission, then click Connect SmartThings again." : "SmartThings returned HTTP \(http.statusCode).")
                    return
                }
                self.inspectSmartThingsDevices(data, token: token)
            }
        }.resume()
    }

    private func inspectSmartThingsDevices(_ data: Data, token: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            showSmartThingsResult("SmartThings responded, but the device list format was unexpected.")
            return
        }
        let candidates = items.filter { device in
            let names = [device["label"] as? String, device["name"] as? String].compactMap { $0 }
            return names.contains { $0.compare("CookieTag2", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        guard !candidates.isEmpty else {
            showSmartThingsResult("Connected successfully and found \(items.count) devices, but no device named exactly CookieTag2 was exposed through the public device list. The old CookieTag record was intentionally ignored.")
            return
        }
        if let deviceID = candidates.first?["deviceId"] as? String {
            defaults.set(deviceID, forKey: smartThingsDeviceIDKey)
        }
        guard let device = candidates.first,
              let id = device["deviceId"] as? String else {
            showSmartThingsResult("CookieTag2 was listed, but Samsung returned no device ID.")
            return
        }
        fetchSmartThingsDetails(device: device, deviceID: id, token: token)
    }

    private func fetchSmartThingsDetails(device: [String: Any], deviceID: String, token: String) {
        let urls = [
            URL(string: "https://api.smartthings.com/v1/devices/\(deviceID)/status")!,
            URL(string: "https://api.smartthings.com/v1/devices/\(deviceID)/health")!
        ]
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [[String: Any]] = []
        for url in urls {
            group.enter()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                lock.lock(); results.append(json); lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let name = (device["label"] as? String) ?? (device["name"] as? String) ?? "CookieTag2"
            let model = (device["deviceModel"] as? String) ?? (device["deviceTypeName"] as? String) ?? "not exposed"
            let manufacturer = (device["manufacturerName"] as? String) ?? "not exposed"
            let combined = results.map(String.init(describing:)).joined(separator: " ")
            let battery = self.extractBattery(from: combined) ?? "not exposed"
            let health = combined.localizedCaseInsensitiveContains("ONLINE") ? "Online" : (combined.localizedCaseInsensitiveContains("OFFLINE") ? "Offline" : "not exposed")
            self.showSmartThingsResult("\(name)\nStable ID: \(deviceID)\nModel: \(model)\nManufacturer: \(manufacturer)\nCloud health: \(health)\nBattery: \(battery)\n\nAvailable API data: device identity/label, model metadata, capability status, health and timestamps. Location and precise battery percentage are not exposed unless Samsung includes those capabilities for this tag.")
        }
    }

    private func extractBattery(from text: String) -> String? {
        let pattern = #"(?i)battery[^0-9A-Za-z]{0,30}(FULL|MEDIUM|LOW|VERY_LOW|[0-9]{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func showSmartThingsResult(_ message: String) {
        refreshMenu(detail: "SmartThings check complete")
        let alert = NSAlert()
        alert.messageText = "SmartThings API result"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func batteryName(_ raw: Int) -> String {
        switch raw {
        case 0: return "Very low"
        case 1: return "Low"
        case 2: return "Medium"
        case 3: return "Full"
        default: return "Unknown"
        }
    }

    private func updateBatteryDisplay(_ raw: Int?) {
        guard let raw else {
            batteryLabel?.stringValue = "Battery: not included in this signal"
            batteryLabel?.textColor = .secondaryLabelColor
            return
        }
        batteryLabel?.stringValue = "Battery: \(batteryName(raw))"
        batteryLabel?.textColor = raw <= 1 ? .systemRed : (raw == 2 ? .systemOrange : .systemGreen)
    }

    private func playWarningSound() {
        for delay in [0.0, 0.65, 1.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let sound = NSSound(named: NSSound.Name("Basso")) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func loadHistory() -> [CheckRecord] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([CheckRecord].self, from: data)) ?? []
    }

    private func saveRecord(_ record: CheckRecord) {
        var history = loadHistory()
        history.append(record)
        history = Array(history.suffix(90))
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: historyKey) }
    }

    private func refreshStats() {
        let recent = Array(loadHistory().suffix(7))
        guard !recent.isEmpty else {
            statsLabel?.stringValue = "No check history yet"
            return
        }
        let detected = recent.filter(\.detected)
        let levels = detected.compactMap(\.batteryRaw)
        let batteryTrend: String
        if let first = levels.first, let last = levels.last, last < first {
            batteryTrend = "Battery trend: falling"
        } else if let last = levels.last {
            batteryTrend = "Battery trend: stable at \(batteryName(last).lowercased())"
        } else {
            batteryTrend = "Battery trend: awaiting readings"
        }
        statsLabel?.stringValue = "Last \(recent.count) checks: \(detected.count) detected\n\(batteryTrend)"
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
        refreshStats()

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
    var batteryLevels: [Int]
}

private struct CheckRecord: Codable {
    let date: Date
    let detected: Bool
    let batteryRaw: Int?
    let medianRSSI: Int?
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()

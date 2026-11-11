import AppKit
import ServiceManagement
import SwiftUI

struct RGB: Equatable, Codable {
    var r: Double, g: Double, b: Double   // 0…1

    static let white = RGB(r: 1, g: 1, b: 1)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    /// Colour temperature → RGB (Tanner Helland's approximation). 6600 K ≈ pure white.
    init(kelvin: Double) {
        let t = kelvin / 100
        func clamp(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        self.init(r: clamp(red), g: clamp(green), b: clamp(blue))
    }

    /// Bytes for the strip. With `powerSaving` (SyncLight's default "USB Power Optimization")
    /// R+G+B is kept ≤ 255 so the strip draws roughly a third of its full-white current.
    func deviceBytes(powerSaving: Bool) -> (UInt8, UInt8, UInt8) {
        var v = [r, g, b].map { $0 * 255 }
        let sum = v.reduce(0, +)
        if powerSaving && sum > 255 { v = v.map { $0 * 255 / sum } }
        return (UInt8(v[0].rounded(.down)), UInt8(v[1].rounded(.down)), UInt8(v[2].rounded(.down)))
    }
}

@MainActor
final class LightController: ObservableObject {
    static let shared = LightController()

    enum Mode: String { case white, color }

    @Published var isOn: Bool { didSet { persist(); scheduleApply() } }
    @Published var mode: Mode { didSet { persist(); scheduleApply() } }
    @Published var kelvin: Double { didSet { persist(); if mode == .white { scheduleApply() } } }
    @Published var customColor: RGB { didSet { persist(); if mode == .color { scheduleApply() } } }
    @Published var brightness: Double { didSet { persist(); scheduleApply() } }
    @Published var offWhenDisplaySleeps: Bool { didSet { persist(); } }
    @Published var fullPower: Bool { didSet { persist(); scheduleApply() } }
    @Published var launchAtLogin: Bool { didSet { updateLoginItem() } }

    @Published private(set) var status: HIDStrip.State = .disconnected
    @Published private(set) var info: DeviceInfo?

    var currentColor: RGB { mode == .white ? RGB(kelvin: kelvin) : customColor }

    private let strip = HIDStrip()
    private let defaults = UserDefaults.standard
    private var applyTask: Task<Void, Never>?
    private var displayAsleep = false

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["isOn": true, "mode": "white", "kelvin": 6600.0, "brightness": 255.0,
                              "offWhenDisplaySleeps": false, "fullPower": false])
        fullPower = d.bool(forKey: "fullPower")
        isOn = d.bool(forKey: "isOn")
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .white
        kelvin = d.double(forKey: "kelvin")
        brightness = d.double(forKey: "brightness")
        offWhenDisplaySleeps = d.bool(forKey: "offWhenDisplaySleeps")
        customColor = (d.data(forKey: "customColor")).flatMap { try? JSONDecoder().decode(RGB.self, from: $0) }
            ?? RGB(r: 1, g: 0.5, b: 0)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        strip.onStateChange = { [weak self] in self?.status = $0 }
        strip.onInfo = { [weak self] in self?.info = $0 }
        strip.onConnected = { [weak self] in self?.handshake() }
        strip.start()
        observeSystem()

        // First launch: register as a login item so the strip is restored after every reboot.
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            defaults.set(true, forKey: "didSetUpLoginItem")
            launchAtLogin = true
        }
    }

    // MARK: - Actions

    func selectWhite(kelvin: Double? = nil) {
        if let kelvin { self.kelvin = kelvin }
        mode = .white
        if !isOn { isOn = true }
    }

    func selectColor(_ rgb: RGB) {
        customColor = rgb
        mode = .color
        if !isOn { isOn = true }
    }

    func reapply() { scheduleApply(after: .zero) }

    // MARK: - Device

    private func handshake() {
        Task {
            strip.send(.readInfo)
            try? await Task.sleep(for: .milliseconds(150))
            strip.send(.openURL, [0])
            try? await Task.sleep(for: .milliseconds(150))
            await apply()
        }
    }

    private func scheduleApply(after delay: Duration = .milliseconds(40)) {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    private func apply() async {
        guard status == .connected else { return }
        guard isOn, !displayAsleep else {
            strip.send(.turnOff)
            return
        }
        let (r, g, b) = currentColor.deviceBytes(powerSaving: !fullPower)
        let lamps = UInt8(clamping: info?.lamps ?? 0)
        strip.send(.brightness, [UInt8(brightness.rounded())])
        try? await Task.sleep(for: .milliseconds(60))
        if lamps > 0 && lamps < 254 {
            strip.send(.setSection, [1, r, g, b, lamps, lamps + 1, 0, 0, 0, 254])
        } else {
            strip.send(.setSection, [1, r, g, b, 254])
        }
    }

    // MARK: - System events

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply(after: .seconds(2)) }
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.offWhenDisplaySleeps else { return }
                self.displayAsleep = true
                self.scheduleApply(after: .zero)
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displayAsleep = false
                self.scheduleApply(after: .milliseconds(500))
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(isOn, forKey: "isOn")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(kelvin, forKey: "kelvin")
        defaults.set(brightness, forKey: "brightness")
        defaults.set(offWhenDisplaySleeps, forKey: "offWhenDisplaySleeps")
        defaults.set(fullPower, forKey: "fullPower")
        defaults.set(try? JSONEncoder().encode(customColor), forKey: "customColor")
    }

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled { try service.register() }
            if !launchAtLogin, service.status == .enabled { try service.unregister() }
        } catch {
            NSLog("Backlight: login item update failed: \(error)")
        }
    }
}

import Foundation
import IOKit.hid

/// Low-level access to the ROBOBLOQ USB LED strip (VID 0x1A86, PID 0xFE07).
///
/// Protocol (reverse-engineered from SyncLight 2.20.1): 64-byte HID output reports
///   "RB" | total length | sequence | command | payload… | checksum (sum of all previous bytes mod 256)
struct DeviceInfo: Equatable {
    var id: String
    var displayInches: Int
    var lamps: Int
    var firmware: String
}

@MainActor
final class HIDStrip {
    enum State: Equatable { case disconnected, busy, connected }

    enum Command: UInt8 {
        case readInfo = 0x82
        case setSection = 0x86   // groups of [startLED, r, g, b, endLED]
        case brightness = 0x87   // [5…255]
        case openURL = 0x93      // [0] disables the "type a URL on plug-in" keyboard feature
        case turnOff = 0x97
    }

    static let vendorID = 6790
    static let productID = 65031

    var onStateChange: ((State) -> Void)?
    var onConnected: (() -> Void)?
    var onInfo: ((DeviceInfo) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var busyDevice: IOHIDDevice?
    private var retryTimer: Timer?
    private var sequence: UInt8 = 1
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,   // vendor interface; the strip also exposes a keyboard
        ] as CFDictionary)
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HIDStrip>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HIDStrip>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(dev) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Connection

    private func attach(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // Usually kIOReturnExclusiveAccess: SyncLight has seized the device.
            busyDevice = dev
            state = .busy
            scheduleRetry()
            return
        }
        busyDevice = nil
        retryTimer?.invalidate()
        retryTimer = nil
        device = dev

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64, { ctx, _, _, _, _, report, length in
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            let me = Unmanaged<HIDStrip>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(report: bytes) }
        }, ctx)

        state = .connected
        onConnected?()
    }

    private func detach(_ dev: IOHIDDevice) {
        if dev == device {
            device = nil
            state = .disconnected
        }
        if dev == busyDevice {
            busyDevice = nil
            retryTimer?.invalidate()
            retryTimer = nil
            state = .disconnected
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let dev = self.busyDevice else { return }
                self.attach(dev)
            }
        }
    }

    // MARK: - I/O

    @discardableResult
    func send(_ command: Command, _ payload: [UInt8] = []) -> Bool {
        guard let device else { return false }
        sequence = sequence >= 254 ? 1 : sequence + 1
        var packet: [UInt8] = [0x52, 0x42, UInt8(6 + payload.count), sequence, command.rawValue] + payload
        packet.append(UInt8(packet.reduce(0) { $0 + Int($1) } & 0xFF))
        packet += [UInt8](repeating: 0, count: max(0, 64 - packet.count))
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count) == kIOReturnSuccess
    }

    private func handle(report r: [UInt8]) {
        guard r.count > 23, r[0] == 0x52, r[1] == 0x42, r[4] == Command.readInfo.rawValue else { return }
        let info = DeviceInfo(
            id: r[5...7].map { String(format: "%02x", $0) }.joined(),
            displayInches: Int(r[8]),
            lamps: Int(r[11]),
            firmware: "\(r[21]).\(r[22]).\(r[23])"
        )
        onInfo?(info)
    }
}

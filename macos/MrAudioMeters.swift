import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import IOKit
import IOKit.hid
import Foundation

// MARK: - CoreAudio Input Device Discovery & Hardware Gain
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    let inputChannels: Int
}

final class CoreAudioHelper {
    static func listInputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for devId in ids {
            let channels = inputChannelCount(for: devId)
            guard channels > 0 else { continue }
            let name = stringProperty(kAudioDevicePropertyDeviceNameCFString, deviceId: devId) ?? "Audio Input"
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceId: devId) ?? "\(devId)"
            let sr = sampleRate(for: devId)
            result.append(AudioInputDevice(id: devId, uid: uid, name: name, sampleRate: sr, inputChannels: channels))
        }
        return result
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devId)
        return devId
    }

    static func findRodeNT1DeviceID() -> AudioDeviceID? {
        let list = listInputDevices()
        return list.first(where: { $0.name.localizedCaseInsensitiveContains("NT1") })?.id
            ?? list.first(where: { $0.name.localizedCaseInsensitiveContains("RØDE") || $0.name.localizedCaseInsensitiveContains("RODE") })?.id
    }

    static func getInputGainDb(deviceId: AudioDeviceID) -> Double? {
        for elem: UInt32 in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeDecibels,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: elem
            )
            if AudioObjectHasProperty(deviceId, &addr) {
                var db: Float32 = 0
                var sz = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &sz, &db) == noErr {
                    return Double(db)
                }
            }
        }
        return nil
    }

    static func getInputGainRange(deviceId: AudioDeviceID) -> (Double, Double) {
        for elem: UInt32 in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: elem
            )
            if AudioObjectHasProperty(deviceId, &addr) {
                var rng = AudioValueRange()
                var sz = UInt32(MemoryLayout<AudioValueRange>.size)
                if AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &sz, &rng) == noErr {
                    return (rng.mMinimum, rng.mMaximum)
                }
            }
        }
        return (0.0, 60.0)
    }

    @discardableResult
    static func setInputGainDb(deviceId: AudioDeviceID, db: Double) -> Bool {
        let (minDb, maxDb) = getInputGainRange(deviceId: deviceId)
        var clamped = Float32(max(minDb, min(maxDb, db)))
        for elem: UInt32 in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeDecibels,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: elem
            )
            if AudioObjectHasProperty(deviceId, &addr) {
                var settable: DarwinBoolean = false
                AudioObjectIsPropertySettable(deviceId, &addr, &settable)
                if settable.boolValue {
                    let sz = UInt32(MemoryLayout<Float32>.size)
                    if AudioObjectSetPropertyData(deviceId, &addr, 0, nil, sz, &clamped) == noErr {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func inputChannelCount(for devId: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devId, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(devId, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceId: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, &cfStr) == noErr,
              let val = cfStr?.takeRetainedValue() else { return nil }
        return val as String
    }

    private static func sampleRate(for devId: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sr: Double = 48000.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(devId, &addr, 0, nil, &size, &sr)
        return sr
    }
}

// MARK: - RØDE NT1 5th Gen Hardware DSP State & Native USB HID + CoreAudio Controller
struct RodeDSPSettings: Codable, Equatable {
    var inputGainDb: Double = 42.0       // 0...60 dB (CoreAudio HAL)
    var hpfMode: Int = 1                 // 0 = Off, 1 = 75 Hz, 2 = 150 Hz
    var gateEnabled: Bool = true
    var gateThresholdDb: Double = -38.0  // -75...-15 dB
    var gateAttackMs: Double = 25.0      // 5...100 ms
    var gateHoldMs: Double = 50.0        // 10...300 ms
    var gateReleaseMs: Double = 200.0    // 50...500 ms
    var gateHysteresisDb: Double = -9.0  // -24...0 dB
    var compEnabled: Bool = true
    var compThresholdDb: Double = -24.0  // -50...-5 dB
    var compRatio: Double = 2.0          // 1.5...4.5
    var compAttackMs: Double = 0.8       // 0.1...10.0 ms
    var compReleaseMs: Double = 25.0     // 5.0...200.0 ms
    var compGainDb: Double = 2.0         // 0.0...9.0 dB
    var exciterEnabled: Bool = true
    var exciterMixPct: Double = 58.0     // 0...100 %
    var exciterTuneHz: Double = 3500.0   // 600...5000 Hz
    var exciterHarmonics: Int = 31       // 0...100
    var bigBottomEnabled: Bool = true
    var bigBottomDrivePct: Double = 50.0 // 0...100 %
    var bigBottomTuneHz: Double = 90.0   // 60...300 Hz

    var hpfLabel: String {
        switch hpfMode {
        case 1: return "75 Hz"
        case 2: return "150 Hz"
        default: return "OFF"
        }
    }
}

final class RodeNT1HardwareBridge {
    static let vendorID: Int = 0x19F7
    static let productID: Int = 0x0054 // RØDE NT1 5th Gen

    // Smooth 17-knot DSP fixed-point Q1.31 response curves matching the onboard APHEX DSP engine
    private static let knotPositions: [Double] = [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255]
    private static let compGainKnots: [Double]   = [0.0, 0.040745, 0.076846, 0.115246, 0.156936, 0.2006, 0.249038, 0.298383, 0.351103, 0.405098, 0.461898, 0.523498, 0.593098, 0.666498, 0.742178, 0.829168, 0.913168]
    private static let compThreshKnots: [Double] = [0.0, 0.007202, 0.015533, 0.025574, 0.037689, 0.052277, 0.069885, 0.091217, 0.117249, 0.149261, 0.189178, 0.239777, 0.305359, 0.393219, 0.516632, 0.70343, 0.999908]
    private static let compAtkKnots: [Double]    = [0.105049, 0.039488, 0.026786, 0.016562, 0.010241, 0.006332, 0.003916, 0.00242, 0.001497, 0.000925, 0.00059, 0.000352, 0.000218, 0.000135, 0.0001, 0.000066, 0.000034]
    private static let compRelKnots: [Double]    = [0.000916, 0.000662, 0.00049, 0.000363, 0.000269, 0.000199, 0.000148, 0.00011, 0.000082, 0.000061, 0.000046, 0.000034, 0.000026, 0.00002, 0.000015, 0.000012, 0.000009]
    private static let aeTune1Knots: [Double]    = [0.085938, 0.09933, 0.114763, 0.132004, 0.160022, 0.198815, 0.223869, 0.24111, 0.279855, 0.323382, 0.381417, 0.434806, 0.48222, 0.533482, 0.587054, 0.658944, 0.65625]
    private static let aeTune2Knots: [Double]    = [0.28125, 0.28125, 0.28125, 0.28125, 0.289871, 0.307112, 0.3125, 0.3125, 0.329241, 0.351283, 0.391462, 0.449892, 0.531789, 0.623884, 0.722098, 0.862608, 1.0]
    private static let aeMixKnots: [Double]      = [0.0, 0.011076, 0.02316, 0.036145, 0.050174, 0.065432, 0.082154, 0.10065, 0.121344, 0.144827, 0.171973, 0.204136, 0.243604, 0.294699, 0.367273, 0.493861, 1.0]

    private let ioQueue = DispatchQueue(label: "es.mrmo.rode.nt1.hid", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inBuf = [UInt8](repeating: 0, count: 64)

    private final class ReplyState {
        var expectedReportID: UInt8 = 0
        var expectedCmd: UInt8 = 0
        var reply: [UInt8]? = nil
    }
    private let replyState = ReplyState()

    private static let hidCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let ctx = context, length >= 3 else { return }
        let st = Unmanaged<ReplyState>.fromOpaque(ctx).takeUnretainedValue()
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        if bytes[0] == st.expectedReportID && bytes[1] == st.expectedCmd {
            st.reply = bytes
        }
    }

    private func ensureConnectedOnQueue() -> Bool {
        if device != nil { return true }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let hid = devs.first else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        self.manager = mgr
        self.device = hid
        IOHIDDeviceRegisterInputReportCallback(
            hid, &inBuf, inBuf.count, Self.hidCallback,
            Unmanaged.passUnretained(replyState).toOpaque()
        )
        return true
    }

    private func disconnectOnQueue() {
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
    }

    private func xferOnQueue(outID: UInt8, inID: UInt8, payload: [UInt8]) -> [UInt8]? {
        guard ensureConnectedOnQueue(), let hid = device, let rl = CFRunLoopGetCurrent() else { return nil }
        IOHIDDeviceScheduleWithRunLoop(hid, rl, CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(hid, rl, CFRunLoopMode.defaultMode.rawValue) }

        replyState.expectedReportID = inID
        replyState.expectedCmd = payload[0]
        replyState.reply = nil

        var full = [outID] + payload
        let res = IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, CFIndex(outID), &full, full.count)
        if res != kIOReturnSuccess {
            disconnectOnQueue()
            return nil
        }

        let deadline = Date().addingTimeInterval(0.35)
        while replyState.reply == nil && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.004, true)
        }
        return replyState.reply
    }

    private func getGranular(_ type: UInt8, _ param: UInt8) -> [UInt8]? {
        var req = [UInt8](repeating: 0, count: 28)
        req[0] = type; req[1] = 0x03; req[2] = param
        guard let r = xferOnQueue(outID: 4, inID: 3, payload: req), r.count >= 4, r[2] == 0x41 else { return nil }
        return Array(r.dropFirst(3))
    }

    @discardableResult
    private func setGranular(_ type: UInt8, _ param: UInt8, data: [UInt8]) -> Bool {
        var req = [UInt8](repeating: 0, count: 28)
        req[0] = type; req[1] = 0x02; req[2] = param
        for i in 0..<min(data.count, 25) { req[3 + i] = data[i] }
        guard let r = xferOnQueue(outID: 4, inID: 3, payload: req), r.count >= 3 else { return false }
        return r[2] == 0x41
    }

    private func readI32(_ b: [UInt8], _ off: Int) -> Int32 {
        guard b.count >= off + 4 else { return 0 }
        let u = UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        return Int32(bitPattern: u)
    }

    private func writeI32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
    }

    private func clampQ31(_ v: Double) -> Int32 {
        let scaled = v * Double(1 << 31)
        if scaled >= Double(Int32.max) { return Int32.max }
        if scaled <= Double(Int32.min) { return Int32.min }
        return Int32(scaled)
    }

    private func interpCurve(_ idx: Double, knots: [Double], logInterp: Bool = false) -> Int32 {
        let x = max(0.0, min(255.0, idx))
        for j in 0..<(Self.knotPositions.count - 1) {
            let x0 = Self.knotPositions[j], x1 = Self.knotPositions[j + 1]
            if x >= x0 && x <= x1 {
                let u = (x - x0) / max(1e-6, x1 - x0)
                let v0 = knots[j], v1 = knots[j + 1]
                let val = (logInterp && v0 > 0 && v1 > 0) ? (v0 * pow(v1 / v0, u)) : (v0 + (v1 - v0) * u)
                return clampQ31(val)
            }
        }
        return clampQ31(knots.last ?? 0)
    }

    private func invertCurve(_ raw: Int32, knots: [Double], descending: Bool = false) -> Double {
        let target = Double(raw) / Double(1 << 31)
        for j in 0..<(Self.knotPositions.count - 1) {
            let v0 = knots[j], v1 = knots[j + 1]
            let inRange = descending ? (target <= v0 && target >= v1) : (target >= v0 && target <= v1)
            if inRange {
                let denom = v1 - v0
                let u = abs(denom) > 1e-9 ? (target - v0) / denom : 0.0
                return Self.knotPositions[j] + max(0, min(1, u)) * (Self.knotPositions[j + 1] - Self.knotPositions[j])
            }
        }
        let firstDist = abs(target - knots[0])
        let lastDist = abs(target - (knots.last ?? 0))
        return firstDist < lastDist ? 0.0 : 255.0
    }

    private func encodeGateAttackMs(_ ms: Double) -> Int32 {
        let clampedMs = max(2.0, min(200.0, ms))
        let theta = 5000.0 / (clampedMs * 48000.0)
        let c = cos(theta)
        let v = (c - 1.0) + sqrt(max(0.0, c * c - 4.0 * c + 3.0))
        return clampQ31(v)
    }

    private func decodeGateAttackMs(_ raw: Int32) -> Double {
        let v = max(0.000105, min(0.616, Double(raw) / Double(1 << 31)))
        let u = v + 1.0
        let cosVal = max(-1.0, min(1.0, (3.0 - u * u) / (4.0 - 2.0 * u)))
        let theta = max(1e-6, acos(cosVal))
        return max(2.0, min(200.0, 5000.0 / (48000.0 * theta)))
    }

    // MARK: - Public Async Hardware API
    func readHardwareSettings(completion: @escaping (Bool, RodeDSPSettings?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.ensureConnectedOnQueue() else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }

            var st = RodeDSPSettings()
            if let devId = CoreAudioHelper.findRodeNT1DeviceID(),
               let gain = CoreAudioHelper.getInputGainDb(deviceId: devId) {
                st.inputGainDb = (gain * 2.0).rounded() / 2.0
            }

            // 1. HPF (Report ID 8 -> 7, param 0x01)
            var hpfReq = [UInt8](repeating: 0, count: 27)
            hpfReq[0] = 0x01; hpfReq[1] = 0x01
            if let r = self.xferOnQueue(outID: 8, inID: 7, payload: hpfReq), r.count >= 4, r[2] == 0x41 {
                st.hpfMode = min(2, Int(r[3]))
            } else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }

            // 2. Compressor (type 0)
            if let en = self.getGranular(0, 0) { st.compEnabled = en[0] != 0 }
            if let th = self.getGranular(0, 1) {
                let idx = self.invertCurve(self.readI32(th, 0), knots: Self.compThreshKnots)
                st.compThresholdDb = ((1.0 - idx / 255.0) * 60.0 - 60.0).rounded()
            }
            if let sh = self.getGranular(0, 2) {
                st.compRatio = ((1.5 + (Double(sh[0]) / 255.0) * 3.0) * 10.0).rounded() / 10.0
            }
            if let ak = self.getGranular(0, 3) {
                let idx = self.invertCurve(self.readI32(ak, 0), knots: Self.compAtkKnots, descending: true)
                let norm = idx / 255.0
                st.compAttackMs = (0.1 * pow(100.0, norm) * 10.0).rounded() / 10.0
            }
            if let rl = self.getGranular(0, 4) {
                let idx = self.invertCurve(self.readI32(rl, 0), knots: Self.compRelKnots, descending: true)
                let norm = idx / 255.0
                st.compReleaseMs = (5.0 * pow(40.0, norm)).rounded()
            }
            if let gn = self.getGranular(0, 5) {
                let idx = self.invertCurve(self.readI32(gn, 0), knots: Self.compGainKnots)
                st.compGainDb = ((idx / 255.0) * 9.0 * 2.0).rounded() / 2.0
            }

            // 3. Noise Gate (type 1)
            if let en = self.getGranular(1, 0) { st.gateEnabled = en[0] != 0 }
            if let th = self.getGranular(1, 1) {
                let lin = Double(self.readI32(th, 0)) / Double(1 << 31)
                st.gateThresholdDb = lin > 1e-6 ? max(-85.0, min(0.0, (20.0 * log10(lin)).rounded())) : -80.0
            }
            if let ak = self.getGranular(1, 2) {
                st.gateAttackMs = self.decodeGateAttackMs(self.readI32(ak, 0)).rounded()
            }
            if let hd = self.getGranular(1, 3) {
                let frac = max(1e-7, Double(self.readI32(hd, 0)) / Double(1 << 31))
                st.gateHoldMs = max(10.0, min(500.0, (1.0 / (frac * 48.0)).rounded()))
            }
            if let rl = self.getGranular(1, 4) {
                let frac = max(1e-7, Double(self.readI32(rl, 0)) / Double(1 << 31))
                st.gateReleaseMs = max(20.0, min(1000.0, (1.0 / (frac * 48.0)).rounded()))
            }
            if let hy = self.getGranular(1, 5) {
                let lin = Double(self.readI32(hy, 0)) / Double(1 << 31)
                st.gateHysteresisDb = lin > 1e-6 ? max(-24.0, min(0.0, (20.0 * log10(lin)).rounded())) : -12.0
            }

            // 4. Aural Exciter (type 2)
            if let en = self.getGranular(2, 0) { st.exciterEnabled = en[0] != 0 }
            if let mx = self.getGranular(2, 1), mx.count >= 5 {
                st.exciterMixPct = (Double(mx[4]) / 255.0 * 100.0).rounded()
            }
            if let tn = self.getGranular(2, 2), tn.count >= 9 {
                st.exciterTuneHz = (600.0 + Double(tn[8]) / 255.0 * 4400.0).rounded()
            }
            if let hm = self.getGranular(2, 3) {
                st.exciterHarmonics = Int(hm[0])
            }

            // 5. Big Bottom (type 3)
            if let en = self.getGranular(3, 0) { st.bigBottomEnabled = en[0] != 0 }
            if let dr = self.getGranular(3, 1), dr.count >= 5 {
                st.bigBottomDrivePct = (Double(dr[4]) / 255.0 * 100.0).rounded()
            }
            if let tn = self.getGranular(3, 2) {
                st.bigBottomTuneHz = (60.0 + Double(tn[0]) / 255.0 * 240.0).rounded()
            }

            DispatchQueue.main.async { completion(true, st) }
        }
    }

    func applyHardwareSettings(_ s: RodeDSPSettings, previous: RodeDSPSettings?, completion: @escaping (Bool) -> Void) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            var allOk = true

            // 0. CoreAudio HAL Input Gain
            if previous == nil || abs((previous?.inputGainDb ?? -999) - s.inputGainDb) > 0.2 {
                if let devId = CoreAudioHelper.findRodeNT1DeviceID() {
                    _ = CoreAudioHelper.setInputGainDb(deviceId: devId, db: s.inputGainDb)
                }
            }

            guard self.ensureConnectedOnQueue() else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // 1. HPF
            if previous == nil || previous?.hpfMode != s.hpfMode {
                var req = [UInt8](repeating: 0, count: 27)
                req[0] = 0x01; req[1] = 0x00; req[2] = UInt8(max(0, min(2, s.hpfMode)))
                if let r = self.xferOnQueue(outID: 8, inID: 7, payload: req), r.count >= 3 {
                    allOk = allOk && (r[2] == 0x41)
                } else {
                    allOk = false
                }
            }

            // 2. Noise Gate (type 1)
            if previous == nil || previous?.gateEnabled != s.gateEnabled {
                allOk = self.setGranular(1, 0, data: [s.gateEnabled ? 1 : 0]) && allOk
            }
            if previous == nil || abs((previous?.gateThresholdDb ?? -999) - s.gateThresholdDb) > 0.25 {
                let lin = pow(10.0, max(-90.0, min(0.0, s.gateThresholdDb)) / 20.0)
                allOk = self.setGranular(1, 1, data: self.writeI32(self.clampQ31(lin))) && allOk
            }
            if previous == nil || abs((previous?.gateAttackMs ?? -999) - s.gateAttackMs) > 0.5 {
                allOk = self.setGranular(1, 2, data: self.writeI32(self.encodeGateAttackMs(s.gateAttackMs))) && allOk
            }
            if previous == nil || abs((previous?.gateHoldMs ?? -999) - s.gateHoldMs) > 1.0 {
                let v = 1.0 / (max(10.0, min(500.0, s.gateHoldMs)) * 48.0)
                allOk = self.setGranular(1, 3, data: self.writeI32(self.clampQ31(v))) && allOk
            }
            if previous == nil || abs((previous?.gateReleaseMs ?? -999) - s.gateReleaseMs) > 1.0 {
                let v = 1.0 / (max(20.0, min(1000.0, s.gateReleaseMs)) * 48.0)
                allOk = self.setGranular(1, 4, data: self.writeI32(self.clampQ31(v))) && allOk
            }
            if previous == nil || abs((previous?.gateHysteresisDb ?? -999) - s.gateHysteresisDb) > 0.25 {
                let lin = pow(10.0, max(-24.0, min(0.0, s.gateHysteresisDb)) / 20.0)
                allOk = self.setGranular(1, 5, data: self.writeI32(self.clampQ31(lin))) && allOk
            }

            // 3. Compressor (type 0)
            if previous == nil || previous?.compEnabled != s.compEnabled {
                allOk = self.setGranular(0, 0, data: [s.compEnabled ? 1 : 0]) && allOk
            }
            if previous == nil || abs((previous?.compThresholdDb ?? -999) - s.compThresholdDb) > 0.25 {
                let clamped = max(-60.0, min(0.0, s.compThresholdDb))
                let idx = (1.0 - (clamped + 60.0) / 60.0) * 255.0
                allOk = self.setGranular(0, 1, data: self.writeI32(self.interpCurve(idx, knots: Self.compThreshKnots))) && allOk
            }
            if previous == nil || abs((previous?.compRatio ?? -999) - s.compRatio) > 0.04 {
                let raw = UInt8(max(0, min(255, Int(round((max(1.5, min(4.5, s.compRatio)) - 1.5) / 3.0 * 255.0)))))
                allOk = self.setGranular(0, 2, data: [raw]) && allOk
            }
            if previous == nil || abs((previous?.compAttackMs ?? -999) - s.compAttackMs) > 0.05 {
                let norm = max(0.0, min(1.0, log10(max(0.1, min(10.0, s.compAttackMs)) / 0.1) / log10(100.0)))
                allOk = self.setGranular(0, 3, data: self.writeI32(self.interpCurve(norm * 255.0, knots: Self.compAtkKnots, logInterp: true))) && allOk
            }
            if previous == nil || abs((previous?.compReleaseMs ?? -999) - s.compReleaseMs) > 0.5 {
                let norm = max(0.0, min(1.0, log10(max(5.0, min(200.0, s.compReleaseMs)) / 5.0) / log10(40.0)))
                allOk = self.setGranular(0, 4, data: self.writeI32(self.interpCurve(norm * 255.0, knots: Self.compRelKnots, logInterp: true))) && allOk
            }
            if previous == nil || abs((previous?.compGainDb ?? -999) - s.compGainDb) > 0.1 {
                let idx = max(0.0, min(9.0, s.compGainDb)) / 9.0 * 255.0
                allOk = self.setGranular(0, 5, data: self.writeI32(self.interpCurve(idx, knots: Self.compGainKnots))) && allOk
            }

            // 4. Aural Exciter (type 2)
            if previous == nil || previous?.exciterEnabled != s.exciterEnabled {
                allOk = self.setGranular(2, 0, data: [s.exciterEnabled ? 1 : 0]) && allOk
            }
            if previous == nil || abs((previous?.exciterMixPct ?? -999) - s.exciterMixPct) > 0.5 {
                let idx = max(0.0, min(100.0, s.exciterMixPct)) / 100.0 * 255.0
                let rawByte = UInt8(max(0, min(255, Int(round(idx)))))
                var payload = self.writeI32(self.interpCurve(idx, knots: Self.aeMixKnots))
                payload.append(rawByte)
                allOk = self.setGranular(2, 1, data: payload) && allOk
            }
            if previous == nil || abs((previous?.exciterTuneHz ?? -999) - s.exciterTuneHz) > 15.0 {
                let idx = (max(600.0, min(5000.0, s.exciterTuneHz)) - 600.0) / 4400.0 * 255.0
                let rawByte = UInt8(max(0, min(255, Int(round(idx)))))
                var payload = self.writeI32(self.interpCurve(idx, knots: Self.aeTune1Knots))
                payload.append(contentsOf: self.writeI32(self.interpCurve(idx, knots: Self.aeTune2Knots)))
                payload.append(rawByte)
                allOk = self.setGranular(2, 2, data: payload) && allOk
            }

            // 5. Big Bottom (type 3)
            if previous == nil || previous?.bigBottomEnabled != s.bigBottomEnabled {
                allOk = self.setGranular(3, 0, data: [s.bigBottomEnabled ? 1 : 0]) && allOk
            }
            if previous == nil || abs((previous?.bigBottomDrivePct ?? -999) - s.bigBottomDrivePct) > 0.5 {
                let idx = max(0.0, min(100.0, s.bigBottomDrivePct)) / 100.0 * 255.0
                let rawByte = UInt8(max(0, min(255, Int(round(idx)))))
                var payload = self.writeI32(self.interpCurve(idx, knots: Self.aeMixKnots))
                payload.append(rawByte)
                allOk = self.setGranular(3, 1, data: payload) && allOk
            }
            if previous == nil || abs((previous?.bigBottomTuneHz ?? -999) - s.bigBottomTuneHz) > 1.0 {
                let idx = (max(60.0, min(300.0, s.bigBottomTuneHz)) - 60.0) / 240.0 * 255.0
                let rawByte = UInt8(max(0, min(255, Int(round(idx)))))
                allOk = self.setGranular(3, 2, data: [rawByte]) && allOk
            }

            DispatchQueue.main.async { completion(allOk) }
        }
    }
}

// MARK: - Room Acoustic Profiles & Built-In Presets (Construction, Studio, Echo, Office)
struct RoomAudioProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String
    var isBuiltIn: Bool
    var subtitle: String
    var loudnessTarget: String
    var measuredFloorDb: Double?
    var dsp: RodeDSPSettings

    static let builtInProfiles: [RoomAudioProfile] = [
        RoomAudioProfile(
            id: "builtin_construction",
            name: "Стройка за окном",
            icon: "hammer.fill",
            isBuiltIn: true,
            subtitle: "HPF 150Hz • Жёсткий гейт -33 dB • Без суб-баса",
            loudnessTarget: LoudnessTarget.podcast.rawValue,
            measuredFloorDb: -39.0,
            dsp: RodeDSPSettings(
                inputGainDb: 39.0, hpfMode: 2,
                gateEnabled: true, gateThresholdDb: -33.0, gateAttackMs: 15.0, gateHoldMs: 45.0, gateReleaseMs: 150.0, gateHysteresisDb: -7.0,
                compEnabled: true, compThresholdDb: -23.0, compRatio: 2.4, compAttackMs: 0.7, compReleaseMs: 22.0, compGainDb: 2.0,
                exciterEnabled: true, exciterMixPct: 55.0, exciterTuneHz: 3500.0, exciterHarmonics: 31,
                bigBottomEnabled: false, bigBottomDrivePct: 20.0, bigBottomTuneHz: 100.0
            )
        ),
        RoomAudioProfile(
            id: "builtin_studio",
            name: "Тихая студия",
            icon: "sparkles",
            isBuiltIn: true,
            subtitle: "HPF 75Hz • Мягкий гейт -45 dB • Тёплый бархат",
            loudnessTarget: LoudnessTarget.podcast.rawValue,
            measuredFloorDb: -54.0,
            dsp: RodeDSPSettings(
                inputGainDb: 43.0, hpfMode: 1,
                gateEnabled: true, gateThresholdDb: -45.0, gateAttackMs: 25.0, gateHoldMs: 70.0, gateReleaseMs: 240.0, gateHysteresisDb: -9.0,
                compEnabled: true, compThresholdDb: -25.0, compRatio: 2.0, compAttackMs: 0.8, compReleaseMs: 25.0, compGainDb: 2.0,
                exciterEnabled: true, exciterMixPct: 60.0, exciterTuneHz: 3500.0, exciterHarmonics: 31,
                bigBottomEnabled: true, bigBottomDrivePct: 55.0, bigBottomTuneHz: 88.0
            )
        ),
        RoomAudioProfile(
            id: "builtin_echo",
            name: "Комната с эхом",
            icon: "house.fill",
            isBuiltIn: true,
            subtitle: "HPF 150Hz • Быстрый релиз • Лёгкий компрессор",
            loudnessTarget: LoudnessTarget.calls.rawValue,
            measuredFloorDb: -44.0,
            dsp: RodeDSPSettings(
                inputGainDb: 40.0, hpfMode: 2,
                gateEnabled: true, gateThresholdDb: -36.0, gateAttackMs: 20.0, gateHoldMs: 40.0, gateReleaseMs: 135.0, gateHysteresisDb: -8.0,
                compEnabled: true, compThresholdDb: -20.0, compRatio: 1.8, compAttackMs: 1.0, compReleaseMs: 30.0, compGainDb: 1.5,
                exciterEnabled: true, exciterMixPct: 45.0, exciterTuneHz: 3700.0, exciterHarmonics: 31,
                bigBottomEnabled: true, bigBottomDrivePct: 28.0, bigBottomTuneHz: 95.0
            )
        ),
        RoomAudioProfile(
            id: "builtin_office",
            name: "Офис / Шум",
            icon: "wind",
            isBuiltIn: true,
            subtitle: "HPF 150Hz • Гейт -37 dB • Режет кондиционер",
            loudnessTarget: LoudnessTarget.calls.rawValue,
            measuredFloorDb: -43.0,
            dsp: RodeDSPSettings(
                inputGainDb: 41.0, hpfMode: 2,
                gateEnabled: true, gateThresholdDb: -37.0, gateAttackMs: 20.0, gateHoldMs: 55.0, gateReleaseMs: 180.0, gateHysteresisDb: -9.0,
                compEnabled: true, compThresholdDb: -23.0, compRatio: 2.2, compAttackMs: 0.8, compReleaseMs: 24.0, compGainDb: 2.0,
                exciterEnabled: true, exciterMixPct: 55.0, exciterTuneHz: 3400.0, exciterHarmonics: 31,
                bigBottomEnabled: true, bigBottomDrivePct: 32.0, bigBottomTuneHz: 95.0
            )
        )
    ]
}

// MARK: - Mic / Vocal Character Presets for RØDE NT1 5th Gen (Composes with Room Presets!)
struct MicVoicePreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String
    var isBuiltIn: Bool
    var subtitle: String
    var compEnabled: Bool
    var compThresholdDb: Double
    var compRatio: Double
    var compAttackMs: Double
    var compReleaseMs: Double
    var compGainDb: Double
    var bigBottomEnabled: Bool
    var bigBottomDrivePct: Double
    var bigBottomTuneHz: Double
    var exciterEnabled: Bool
    var exciterMixPct: Double
    var exciterTuneHz: Double
    // Optional full snapshot for custom user mic presets
    var fullDspOverride: RodeDSPSettings? = nil

    static let builtInPresets: [MicVoicePreset] = [
        MicVoicePreset(
            id: "mic_radio",
            name: "Радио / Диктор",
            icon: "radio.fill",
            isBuiltIn: true,
            subtitle: "Плотный бархат • Comp 2.8:1 (+3.5 dB) • Big Bottom 72% • Exciter 65%",
            compEnabled: true, compThresholdDb: -26.0, compRatio: 2.8, compAttackMs: 0.6, compReleaseMs: 20.0, compGainDb: 3.5,
            bigBottomEnabled: true, bigBottomDrivePct: 72.0, bigBottomTuneHz: 85.0,
            exciterEnabled: true, exciterMixPct: 65.0, exciterTuneHz: 3500.0
        ),
        MicVoicePreset(
            id: "mic_podcast",
            name: "Подкаст",
            icon: "mic.fill",
            isBuiltIn: true,
            subtitle: "Сбалансированный студийный • Comp 2.1:1 (+2.0 dB) • Big Bottom 52% • Exciter 58%",
            compEnabled: true, compThresholdDb: -24.0, compRatio: 2.1, compAttackMs: 0.8, compReleaseMs: 25.0, compGainDb: 2.0,
            bigBottomEnabled: true, bigBottomDrivePct: 52.0, bigBottomTuneHz: 90.0,
            exciterEnabled: true, exciterMixPct: 58.0, exciterTuneHz: 3500.0
        ),
        MicVoicePreset(
            id: "mic_calls",
            name: "Созвоны / Meet",
            icon: "video.fill",
            isBuiltIn: true,
            subtitle: "Чёткая разборчивость речи • Comp 2.3:1 • Сдержанный бас 25% • Exciter 62%",
            compEnabled: true, compThresholdDb: -22.0, compRatio: 2.3, compAttackMs: 0.7, compReleaseMs: 22.0, compGainDb: 2.0,
            bigBottomEnabled: true, bigBottomDrivePct: 25.0, bigBottomTuneHz: 105.0,
            exciterEnabled: true, exciterMixPct: 62.0, exciterTuneHz: 3100.0
        ),
        MicVoicePreset(
            id: "mic_bright",
            name: "Яркий голос",
            icon: "sun.max.fill",
            isBuiltIn: true,
            subtitle: "Воздух и чёткость дикции • Comp 2.2:1 (+2.5 dB) • Exciter 78% @ 4.0 kHz",
            compEnabled: true, compThresholdDb: -23.0, compRatio: 2.2, compAttackMs: 0.7, compReleaseMs: 24.0, compGainDb: 2.5,
            bigBottomEnabled: true, bigBottomDrivePct: 35.0, bigBottomTuneHz: 95.0,
            exciterEnabled: true, exciterMixPct: 78.0, exciterTuneHz: 4000.0
        ),
        MicVoicePreset(
            id: "mic_asmr",
            name: "Мягкий / ASMR",
            icon: "ear.fill",
            isBuiltIn: true,
            subtitle: "Интимная подача и шёпот • Мягкий Comp 1.7:1 (+3.0 dB) • Exciter 70% @ 4.2 kHz",
            compEnabled: true, compThresholdDb: -28.0, compRatio: 1.7, compAttackMs: 1.5, compReleaseMs: 40.0, compGainDb: 3.0,
            bigBottomEnabled: true, bigBottomDrivePct: 45.0, bigBottomTuneHz: 80.0,
            exciterEnabled: true, exciterMixPct: 70.0, exciterTuneHz: 4200.0
        ),
        MicVoicePreset(
            id: "mic_raw",
            name: "Чистый / Raw",
            icon: "waveform",
            isBuiltIn: true,
            subtitle: "Без окраса APHEX (Comp / Big Bottom / Exciter OFF) — для вокала и DAW",
            compEnabled: false, compThresholdDb: -24.0, compRatio: 2.0, compAttackMs: 0.8, compReleaseMs: 25.0, compGainDb: 0.0,
            bigBottomEnabled: false, bigBottomDrivePct: 0.0, bigBottomTuneHz: 90.0,
            exciterEnabled: false, exciterMixPct: 0.0, exciterTuneHz: 3500.0
        )
    ]
}

// MARK: - ITU-R BS.1770-4 K-Weighting Biquads (@ 48 kHz)
struct BiquadFilter {
    var b0: Float; var b1: Float; var b2: Float
    var a1: Float; var a2: Float
    var z1: Float = 0; var z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func kWeightShelf48k() -> BiquadFilter {
        BiquadFilter(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                     a1: -1.69065929318241, a2: 0.73248077421585)
    }
    static func kWeightHighPass48k() -> BiquadFilter {
        BiquadFilter(b0: 1.0, b1: -2.0, b2: 1.0,
                     a1: -1.99004745483398, a2: 0.99007225036621)
    }
}

// MARK: - Iconic Competitor Visual Themes
enum MeterTheme: String, CaseIterable {
    case miniCyber   = "MiniMeters"
    case fabProQ     = "FabFilter"
    case magmaHeat   = "Magma"
    case prismCool   = "TDR Prism"

    var primary: Color {
        switch self {
        case .miniCyber: return Color(red: 0.35, green: 0.88, blue: 1.00)
        case .fabProQ:   return Color(red: 1.00, green: 0.72, blue: 0.14)
        case .magmaHeat: return Color(red: 1.00, green: 0.36, blue: 0.45)
        case .prismCool: return Color(red: 0.34, green: 0.94, blue: 0.68)
        }
    }

    var secondary: Color {
        switch self {
        case .miniCyber: return Color(red: 0.68, green: 0.42, blue: 1.00)
        case .fabProQ:   return Color(red: 1.00, green: 0.35, blue: 0.10)
        case .magmaHeat: return Color(red: 1.00, green: 0.85, blue: 0.25)
        case .prismCool: return Color(red: 0.22, green: 0.68, blue: 1.00)
        }
    }

    var bgDark: Color {
        switch self {
        case .miniCyber: return Color(red: 0.045, green: 0.050, blue: 0.068)
        case .fabProQ:   return Color(red: 0.060, green: 0.055, blue: 0.050)
        case .magmaHeat: return Color(red: 0.052, green: 0.036, blue: 0.058)
        case .prismCool: return Color(red: 0.040, green: 0.058, blue: 0.064)
        }
    }

    func heatColor(_ v: Float) -> Color {
        let t = Double(max(0, min(1, v)))
        switch self {
        case .miniCyber:
            if t < 0.22 { return Color(red: 0.04, green: 0.06, blue: 0.16 + t * 2.1) }
            if t < 0.55 { let u = (t - 0.22) / 0.33; return Color(red: 0.16 * u, green: 0.24 + u * 0.62, blue: 0.65 + u * 0.35) }
            let u = (t - 0.55) / 0.45
            return Color(red: 0.16 + u * 0.84, green: 0.86 + u * 0.14, blue: 1.0)
        case .fabProQ:
            if t < 0.30 { return Color(red: 0.12 + t * 1.4, green: 0.07 + t * 0.5, blue: 0.04) }
            if t < 0.70 { let u = (t - 0.30) / 0.40; return Color(red: 0.54 + u * 0.46, green: 0.22 + u * 0.52, blue: 0.05 + u * 0.08) }
            let u = (t - 0.70) / 0.30
            return Color(red: 1.0, green: 0.74 + u * 0.26, blue: 0.13 + u * 0.75)
        case .magmaHeat:
            if t < 0.25 { let u = t / 0.25; return Color(red: 0.08 + u * 0.35, green: 0.03 + u * 0.05, blue: 0.18 + u * 0.38) }
            if t < 0.65 { let u = (t - 0.25) / 0.40; return Color(red: 0.43 + u * 0.57, green: 0.08 + u * 0.28, blue: 0.56 - u * 0.34) }
            let u = (t - 0.65) / 0.35
            return Color(red: 1.0, green: 0.36 + u * 0.62, blue: 0.22 + u * 0.55)
        case .prismCool:
            if t < 0.30 { return Color(red: 0.03, green: 0.10 + t * 1.2, blue: 0.16 + t * 1.4) }
            if t < 0.70 { let u = (t - 0.30) / 0.40; return Color(red: 0.05 + u * 0.28, green: 0.46 + u * 0.48, blue: 0.58 + u * 0.22) }
            let u = (t - 0.70) / 0.30
            return Color(red: 0.33 + u * 0.65, green: 0.94 + u * 0.06, blue: 0.80 + u * 0.20)
        }
    }
}

// MARK: - Youlean-Style Loudness Target Presets
enum LoudnessTarget: String, CaseIterable {
    case youtube   = "YouTube (-14)"
    case podcast   = "Podcast (-16)"
    case calls     = "Meet/Zoom (-18)"
    case broadcast = "EBU R128 (-23)"

    var lufs: Float {
        switch self {
        case .youtube:   return -14.0
        case .podcast:   return -16.0
        case .calls:     return -18.0
        case .broadcast: return -23.0
        }
    }
    var shortLabel: String {
        switch self {
        case .youtube:   return "YT -14"
        case .podcast:   return "POD -16"
        case .calls:     return "CALL -18"
        case .broadcast: return "EBU -23"
        }
    }
}

enum MeterLayoutMode: String, CaseIterable {
    case bar  = "Bar"
    case quad = "Quad"
}

struct ColoredWaveSlice {
    var amplitude: Float
    var lowWeight: Float
    var midWeight: Float
    var highWeight: Float

    var color: Color {
        let total = max(0.001, lowWeight + midWeight + highWeight)
        let l = pow(Double(lowWeight / total), 0.75)
        let m = pow(Double(midWeight / total), 0.75)
        let h = pow(Double(highWeight / total), 0.75)
        let norm = max(0.001, l + m + h)
        let ln = l / norm; let mn = m / norm; let hn = h / norm
        let r = min(1.0, ln * 1.00 + mn * 0.08 + hn * 0.85)
        let g = min(1.0, ln * 0.28 + mn * 0.92 + hn * 0.42)
        let b = min(1.0, ln * 0.22 + mn * 1.00 + hn * 1.00)
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Persistent App Config
struct AudioMetersConfig: Codable {
    var selectedDeviceUID: String?
    var theme: String
    var layoutMode: String
    var loudnessTarget: String
    var spectrumTilt: Double
    var alwaysOnTop: Bool
    var showWaveform: Bool
    var showOscilloscope: Bool
    var showSpectrum: Bool
    var showSpectrogram: Bool
    var showLoudness: Bool
    var showStereo: Bool
    var showTargetCurve: Bool
    var showVocalZones: Bool
    var showRodeDrawer: Bool
    var autoAdaptiveGuard: Bool
    var activeProfileId: String?
    var customProfiles: [RoomAudioProfile]
    var activeMicPresetId: String?
    var customMicPresets: [MicVoicePreset]?
    var windowOpacity: Double
    var lang: String
    var windowX: Double?
    var windowY: Double?
    var windowW: Double?
    var windowH: Double?
}

// MARK: - Acoustic Scan & Calibration Report
struct AcousticScanReport {
    let modeTitle: String
    let environmentLabel: String
    let diagnosisDetail: String
    let noiseFloorDb: Double
    let peakImpulseDb: Double
    let rumbleDb: Double
    let speechLufs: Double?
    let peakSpeechDb: Double?
    let suggestedDsp: RodeDSPSettings
    let appliedToHardware: Bool
}

// MARK: - Titled Floating Studio Panel (Standard macOS Titlebar + Optional Full-Screen Overlay)
final class FloatingMetersPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Flagship Audio Analyzer + Noise-Adaptive Room Engine + Live RØDE NT1 Bridge
final class AudioAnalyzerEngine: ObservableObject {
    // Device & Runtime
    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String = ""
    @Published var activeDeviceName: String = "RØDE NT1 5th Gen"
    @Published var activeSampleRate: Double = 48000
    @Published var activeChannels: Int = 1
    @Published var isRunning: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var toastMessage: String = ""

    // Visual & Layout Controls
    @Published var theme: MeterTheme = .miniCyber
    @Published var layoutMode: MeterLayoutMode = .quad
    @Published var loudnessTarget: LoudnessTarget = .podcast
    @Published var spectrumTilt: Double = 4.5
    @Published var alwaysOnTop: Bool = false
    @Published var isFrozen: Bool = false
    @Published var showWaveform: Bool = true
    @Published var showOscilloscope: Bool = false
    @Published var showSpectrum: Bool = true
    @Published var showSpectrogram: Bool = true
    @Published var showLoudness: Bool = true
    @Published var showStereo: Bool = false
    @Published var showTargetCurve: Bool = true
    @Published var showVocalZones: Bool = true
    @Published var showRodeDrawer: Bool = true
    @Published var windowOpacity: Double = 1.0
    @Published var lang: String = {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.lowercased().hasPrefix("ru") ? "ru" : "en"
    }()

    // Live RØDE NT1 5th Gen Hardware State
    @Published var rodeConnected: Bool = false
    @Published var rodeSyncing: Bool = false
    @Published var rodeDsp: RodeDSPSettings = RodeDSPSettings()
    @Published var previousRodeDsp: RodeDSPSettings? = nil

    // Multi-Room Profiles & Adaptive Noise Guard
    @Published var customProfiles: [RoomAudioProfile] = []
    @Published var activeProfileId: String = ""
    @Published var autoAdaptiveGuard: Bool = false
    @Published var liveNoiseStatus: String = "Тихо"
    @Published var liveRumbleDb: Float = -68.0
    @Published var showSaveRoomPopover: Bool = false
    @Published var newRoomName: String = ""

    // Mic / Vocal Character Presets (RØDE APHEX Voice Presets)
    @Published var customMicPresets: [MicVoicePreset] = []
    @Published var activeMicPresetId: String = ""
    @Published var showSaveMicPresetPopover: Bool = false
    @Published var newMicPresetName: String = ""

    var allProfiles: [RoomAudioProfile] { RoomAudioProfile.builtInProfiles + customProfiles }
    var allMicPresets: [MicVoicePreset] { MicVoicePreset.builtInPresets + customMicPresets }

    // Real-Time Meter Buffers (60 Hz)
    static let spectrumBins = 64
    static let waveSlicesCount = 150
    static let oscPointsCount = 140
    static let spectrogramCols = 76
    static let spectrogramRows = 32
    static let lufsHistoryCount = 96
    static let stereoPointsCount = 90

    @Published var spectrumCurve: [Float] = Array(repeating: 0, count: spectrumBins)
    @Published var spectrumPeaks: [Float] = Array(repeating: 0, count: spectrumBins)
    @Published var frozenSpectrum: [Float] = Array(repeating: 0, count: spectrumBins)
    @Published var coloredWave: [ColoredWaveSlice] = Array(repeating: ColoredWaveSlice(amplitude: 0, lowWeight: 0.3, midWeight: 0.5, highWeight: 0.2), count: waveSlicesCount)
    @Published var oscilloscope: [Float] = Array(repeating: 0, count: oscPointsCount)
    @Published var spectrogram: [[Float]] = Array(repeating: Array(repeating: 0, count: spectrogramRows), count: spectrogramCols)
    @Published var lufsHistory: [Float] = Array(repeating: -60.0, count: lufsHistoryCount)
    @Published var stereoXY: [(Float, Float)] = Array(repeating: (0, 0), count: stereoPointsCount)
    @Published var stereoCorrelation: Float = 1.0

    // Numeric Studio Readouts
    @Published var peakDb: Float = -60.0
    @Published var peakHoldDb: Float = -60.0
    @Published var rmsDb: Float = -60.0
    @Published var momentaryLufs: Float = -60.0
    @Published var shortTermLufs: Float = -60.0
    @Published var integratedLufs: Float = -60.0
    @Published var dynamicsPlrDb: Float = 0.0
    @Published var noiseFloorDb: Float = -60.0
    @Published var dominantFreqHz: Double = 0
    @Published var dominantNote: String = "—"
    @Published var isClipping: Bool = false

    // Acoustic Scan / Calibration State
    @Published var isScanning: Bool = false
    @Published var scanMode: String = "" // "noise5s" or "full10s"
    @Published var scanCountdown: Int = 0
    @Published var scanPhase: String = "" // "quiet" or "speak"
    @Published var scanReport: AcousticScanReport? = nil
    @Published var showScanPopover: Bool = false

    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onOpacityChanged: ((Double) -> Void)?
    var onLayoutChanged: ((MeterLayoutMode, Bool) -> Void)?
    var savedWindowFrame: NSRect? = nil

    // Hardware Bridge & Debounce
    private let rodeBridge = RodeNT1HardwareBridge()
    private var lastWrittenRodeDsp: RodeDSPSettings? = nil
    private var rodeWriteWorkItem: DispatchWorkItem?

    // Audio Engine & DSP Internals
    private var audioEngine: AVAudioEngine?
    private let fftSize = 2048
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var ringL: [Float] = []
    private var ringR: [Float] = []
    private var ringWriteIdx: Int = 0
    private var ringLock = os_unfair_lock()

    // 10s Rolling WAV Clip Buffer
    private let clipBufferCapacity = 48000 * 10
    private var clipRing: [Float] = []
    private var clipWriteIdx: Int = 0
    private var clipFilled: Int = 0

    private var displayTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var lufsHistoryTick: Int = 0

    // Loudness K-Weighting
    private var kwShelf = BiquadFilter.kWeightShelf48k()
    private var kwHP = BiquadFilter.kWeightHighPass48k()
    private var momentaryRing: [Float] = Array(repeating: 1e-10, count: 24)
    private var momentaryIdx: Int = 0
    private var shortTermRing: [Float] = Array(repeating: 1e-10, count: 180)
    private var shortTermIdx: Int = 0
    private var integratedEnergySum: Double = 0
    private var integratedBlockCount: Int = 0
    private var peakHoldTimer: Int = 0
    private var clipHoldTimer: Int = 0
    private var noiseFloorEstimate: Float = -54.0
    private var rumbleEstimate: Float = -68.0

    // Live Adaptive Noise Guard tracking
    private var guardQuietSamples: [Float] = []
    private var guardRumbleSamples: [Float] = []
    private var guardTick: Int = 0
    private var lastAutoGuardApplyTime: Date = .distantPast

    // Scanner Accumulators
    private var scanTimer: Timer?
    private var scanStep: Int = 0
    private var scanQuietRms: [Float] = []
    private var scanQuietPeaks: [Float] = []
    private var scanQuietRumble: [Float] = []
    private var scanQuietMid: [Float] = []
    private var scanQuietHigh: [Float] = []
    private var scanSpeechLufs: [Float] = []
    private var scanSpeechPeakMax: Float = -60.0
    private var scanMud: [Float] = []
    private var scanPres: [Float] = []
    private var scanSib: [Float] = []

    // Log Frequency Tables
    private var specBinRanges: [(Int, Int)] = []
    private var specBandCenterHz: [Float] = []
    private var waterfallBinRanges: [(Int, Int)] = []

    static let vocalTargetCurve: [Float] = {
        var pts = [Float](repeating: 0, count: spectrumBins)
        for i in 0..<spectrumBins {
            let x = Float(i) / Float(spectrumBins - 1)
            let hpfRoll  = 1.0 / (1.0 + exp(-(x - 0.14) * 18.0))
            let body     = 0.62 * exp(-pow((x - 0.27) / 0.16, 2))
            let midFill  = 0.44 * exp(-pow((x - 0.48) / 0.22, 2))
            let presence = 0.56 * exp(-pow((x - 0.72) / 0.16, 2))
            let airRoll  = 1.0 - 0.45 / (1.0 + exp(-(x - 0.88) * 14.0))
            pts[i] = min(0.85, max(0.08, (0.20 + body + midFill + presence) * hpfRoll * airRoll))
        }
        return pts
    }()

    private let cfgKey = "mraudiometers_pro_config_v3"
    func tr(_ ru: String, _ en: String) -> String { lang == "ru" ? ru : en }

    init() {
        ringL = Array(repeating: 0, count: fftSize * 2)
        ringR = Array(repeating: 0, count: fftSize * 2)
        clipRing = Array(repeating: 0, count: clipBufferCapacity)
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))

        loadConfig()
        refreshDevices()
        rebuildBinTables(sampleRate: activeSampleRate)

        let isShot = CommandLine.arguments.contains("--screenshot") || CommandLine.arguments.contains("--screenshot-quad")
        if !isShot {
            requestMicAndStart()
            syncFromRodeHardware(silent: true)
        } else {
            layoutMode = CommandLine.arguments.contains("--screenshot") ? .bar : .quad
            showRodeDrawer = !CommandLine.arguments.contains("--screenshot")
            populateDemoVisualization()
        }
    }

    deinit {
        stopEngine()
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Persistence
    func loadConfig() {
        guard let raw = UserDefaults.standard.data(forKey: cfgKey),
              let c = try? JSONDecoder().decode(AudioMetersConfig.self, from: raw) else { return }
        if let uid = c.selectedDeviceUID { selectedDeviceUID = uid }
        if let t = MeterTheme(rawValue: c.theme) { theme = t }
        if let lm = MeterLayoutMode(rawValue: c.layoutMode) { layoutMode = lm }
        if let lt = LoudnessTarget(rawValue: c.loudnessTarget) { loudnessTarget = lt }
        spectrumTilt = c.spectrumTilt
        alwaysOnTop = c.alwaysOnTop
        showWaveform = c.showWaveform
        showOscilloscope = c.showOscilloscope
        showSpectrum = c.showSpectrum
        showSpectrogram = c.showSpectrogram
        showLoudness = c.showLoudness
        showStereo = c.showStereo
        showTargetCurve = c.showTargetCurve
        showVocalZones = c.showVocalZones
        showRodeDrawer = c.showRodeDrawer
        autoAdaptiveGuard = c.autoAdaptiveGuard
        activeProfileId = c.activeProfileId ?? ""
        customProfiles = c.customProfiles
        activeMicPresetId = c.activeMicPresetId ?? ""
        customMicPresets = c.customMicPresets ?? []
        windowOpacity = max(0.65, min(1.0, c.windowOpacity))
        lang = c.lang
        if let x = c.windowX, let y = c.windowY, let w = c.windowW, let h = c.windowH {
            savedWindowFrame = NSRect(x: x, y: y, width: w, height: h)
        }
    }

    func scheduleSaveConfig() {
        guard !CommandLine.arguments.contains("--screenshot") && !CommandLine.arguments.contains("--screenshot-quad") else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveConfigNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func saveConfigNow() {
        guard !CommandLine.arguments.contains("--screenshot") && !CommandLine.arguments.contains("--screenshot-quad") else { return }
        let c = AudioMetersConfig(
            selectedDeviceUID: selectedDeviceUID,
            theme: theme.rawValue,
            layoutMode: layoutMode.rawValue,
            loudnessTarget: loudnessTarget.rawValue,
            spectrumTilt: spectrumTilt,
            alwaysOnTop: alwaysOnTop,
            showWaveform: showWaveform,
            showOscilloscope: showOscilloscope,
            showSpectrum: showSpectrum,
            showSpectrogram: showSpectrogram,
            showLoudness: showLoudness,
            showStereo: showStereo,
            showTargetCurve: showTargetCurve,
            showVocalZones: showVocalZones,
            showRodeDrawer: showRodeDrawer,
            autoAdaptiveGuard: autoAdaptiveGuard,
            activeProfileId: activeProfileId,
            customProfiles: customProfiles,
            activeMicPresetId: activeMicPresetId,
            customMicPresets: customMicPresets,
            windowOpacity: windowOpacity,
            lang: lang,
            windowX: savedWindowFrame.map { Double($0.origin.x) },
            windowY: savedWindowFrame.map { Double($0.origin.y) },
            windowW: savedWindowFrame.map { Double($0.size.width) },
            windowH: savedWindowFrame.map { Double($0.size.height) }
        )
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: cfgKey)
        }
    }

    // MARK: - RØDE NT1 5th Gen Hardware Sync & Live Control
    func syncFromRodeHardware(silent: Bool = false) {
        rodeSyncing = true
        rodeBridge.readHardwareSettings { [weak self] ok, settings in
            guard let self = self else { return }
            self.rodeSyncing = false
            self.rodeConnected = ok
            if ok, let st = settings {
                self.rodeDsp = st
                self.lastWrittenRodeDsp = st
                if !silent {
                    self.showToast(self.tr("✓ Считано с RØDE NT1 (Gain \(Int(st.inputGainDb))dB, HPF \(st.hpfLabel), Gate \(Int(st.gateThresholdDb))dB)", "✓ Synced from RØDE NT1"))
                }
            } else if !silent {
                self.showToast(self.tr("RØDE NT1 5th Gen не найден по USB", "RØDE NT1 5th Gen USB not found"))
            }
        }
    }

    func updateRodeParam(_ mutate: (inout RodeDSPSettings) -> Void) {
        if previousRodeDsp == nil { previousRodeDsp = rodeDsp }
        mutate(&rodeDsp)
        activeProfileId = ""
        activeMicPresetId = ""
        scheduleRodeHardwareWrite(immediate: false)
    }

    func applyRodeSettingsNow(_ target: RodeDSPSettings, label: String? = nil) {
        previousRodeDsp = rodeDsp
        rodeDsp = target
        rodeWriteWorkItem?.cancel()
        rodeSyncing = true
        let prev = lastWrittenRodeDsp
        rodeBridge.applyHardwareSettings(target, previous: prev) { [weak self] ok in
            guard let self = self else { return }
            self.rodeSyncing = false
            self.rodeConnected = ok
            if ok {
                self.lastWrittenRodeDsp = target
                if let lbl = label {
                    self.showToast("✓ RØDE NT1: \(lbl)")
                }
            } else {
                self.showToast(self.tr("⚠ Ошибка записи в RØDE NT1", "⚠ Failed writing to RØDE NT1"))
            }
        }
    }

    func undoLastRodeChange() {
        guard let prev = previousRodeDsp else { return }
        let restore = prev
        previousRodeDsp = nil
        applyRodeSettingsNow(restore, label: tr("Откат настроек", "Restored previous DSP"))
    }

    private func scheduleRodeHardwareWrite(immediate: Bool) {
        rodeWriteWorkItem?.cancel()
        let snap = rodeDsp
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let prev = self.lastWrittenRodeDsp
            self.rodeBridge.applyHardwareSettings(snap, previous: prev) { [weak self] ok in
                guard let self = self else { return }
                self.rodeConnected = ok
                if ok { self.lastWrittenRodeDsp = snap }
            }
        }
        rodeWriteWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0.01 : 0.14), execute: work)
    }

    // MARK: - Room Profiles
    func applyRoomProfile(_ profile: RoomAudioProfile) {
        activeProfileId = profile.id
        if let lt = LoudnessTarget(rawValue: profile.loudnessTarget) {
            loudnessTarget = lt
        }
        applyRodeSettingsNow(profile.dsp, label: profile.name)
        scheduleSaveConfig()
    }

    func saveCurrentAsCustomRoom(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = RoomAudioProfile(
            id: "room_\(UUID().uuidString.prefix(8))",
            name: trimmed,
            icon: "door.left.hand.open",
            isBuiltIn: false,
            subtitle: "HPF \(rodeDsp.hpfLabel) • Gate \(Int(rodeDsp.gateThresholdDb))dB • Gain \(Int(rodeDsp.inputGainDb))dB",
            loudnessTarget: loudnessTarget.rawValue,
            measuredFloorDb: Double(noiseFloorDb.rounded()),
            dsp: rodeDsp
        )
        customProfiles.append(profile)
        activeProfileId = profile.id
        newRoomName = ""
        showSaveRoomPopover = false
        scheduleSaveConfig()
        showToast(tr("💾 Комната «\(trimmed)» сохранена", "💾 Room '\(trimmed)' saved"))
    }

    func deleteCustomRoom(_ id: String) {
        customProfiles.removeAll { $0.id == id }
        if activeProfileId == id { activeProfileId = "" }
        scheduleSaveConfig()
    }

    // MARK: - Mic / Vocal Character Presets (Preserves Active Room HPF & Noise Gate!)
    func applyMicVoicePreset(_ preset: MicVoicePreset) {
        activeMicPresetId = preset.id
        var next = rodeDsp
        if let full = preset.fullDspOverride {
            // Custom user mic preset restores its saved full DSP snapshot
            next = full
            applyRodeSettingsNow(next, label: tr("Мик: \(preset.name)", "Mic: \(preset.name)"))
        } else {
            // Built-in voice presets layer cleanly over your Room's HPF & Noise Gate!
            next.compEnabled = preset.compEnabled
            next.compThresholdDb = preset.compThresholdDb
            next.compRatio = preset.compRatio
            next.compAttackMs = preset.compAttackMs
            next.compReleaseMs = preset.compReleaseMs
            next.compGainDb = preset.compGainDb
            next.exciterEnabled = preset.exciterEnabled
            next.exciterMixPct = preset.exciterMixPct
            next.exciterTuneHz = preset.exciterTuneHz

            let inConstruction = (activeProfileId == "builtin_construction")
            if inConstruction && preset.bigBottomEnabled {
                // Keep construction rumble protection intact while still giving warmth
                next.bigBottomEnabled = true
                next.bigBottomDrivePct = min(28.0, preset.bigBottomDrivePct)
                next.bigBottomTuneHz = max(95.0, preset.bigBottomTuneHz)
                applyRodeSettingsNow(next, label: tr("Голос: \(preset.name) (HPF/Gate стройки сохранены)", "Voice: \(preset.name) (room guard kept)"))
            } else {
                next.bigBottomEnabled = preset.bigBottomEnabled
                next.bigBottomDrivePct = preset.bigBottomDrivePct
                next.bigBottomTuneHz = preset.bigBottomTuneHz
                applyRodeSettingsNow(next, label: tr("Голос: \(preset.name)", "Voice: \(preset.name)"))
            }
        }
        scheduleSaveConfig()
    }

    func saveCurrentAsCustomMicPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = MicVoicePreset(
            id: "mic_custom_\(UUID().uuidString.prefix(8))",
            name: trimmed,
            icon: "dial.high.fill",
            isBuiltIn: false,
            subtitle: "Gain \(Int(rodeDsp.inputGainDb))dB • HPF \(rodeDsp.hpfLabel) • Comp \(String(format: "%.1f", rodeDsp.compRatio)):1 • BB \(Int(rodeDsp.bigBottomDrivePct))% • AE \(Int(rodeDsp.exciterMixPct))%",
            compEnabled: rodeDsp.compEnabled,
            compThresholdDb: rodeDsp.compThresholdDb,
            compRatio: rodeDsp.compRatio,
            compAttackMs: rodeDsp.compAttackMs,
            compReleaseMs: rodeDsp.compReleaseMs,
            compGainDb: rodeDsp.compGainDb,
            bigBottomEnabled: rodeDsp.bigBottomEnabled,
            bigBottomDrivePct: rodeDsp.bigBottomDrivePct,
            bigBottomTuneHz: rodeDsp.bigBottomTuneHz,
            exciterEnabled: rodeDsp.exciterEnabled,
            exciterMixPct: rodeDsp.exciterMixPct,
            exciterTuneHz: rodeDsp.exciterTuneHz,
            fullDspOverride: rodeDsp
        )
        customMicPresets.append(preset)
        activeMicPresetId = preset.id
        newMicPresetName = ""
        showSaveMicPresetPopover = false
        scheduleSaveConfig()
        showToast(tr("💾 Пресет мик. «\(trimmed)» сохранён", "💾 Mic preset '\(trimmed)' saved"))
    }

    func deleteCustomMicPreset(_ id: String) {
        customMicPresets.removeAll { $0.id == id }
        if activeMicPresetId == id { activeMicPresetId = "" }
        scheduleSaveConfig()
    }

    // MARK: - General Actions
    func refreshDevices() {
        let list = CoreAudioHelper.listInputDevices()
        devices = list
        if selectedDeviceUID.isEmpty || !list.contains(where: { $0.uid == selectedDeviceUID }) {
            if let rode = list.first(where: { $0.name.localizedCaseInsensitiveContains("RØDE") || $0.name.localizedCaseInsensitiveContains("RODE") }) {
                selectedDeviceUID = rode.uid
            } else {
                let defId = CoreAudioHelper.defaultInputDeviceID()
                if let def = list.first(where: { $0.id == defId }) ?? list.first {
                    selectedDeviceUID = def.uid
                }
            }
        }
        if let dev = list.first(where: { $0.uid == selectedDeviceUID }) {
            activeDeviceName = dev.name
            activeSampleRate = dev.sampleRate
            activeChannels = dev.inputChannels
        }
    }

    func selectDevice(uid: String) {
        selectedDeviceUID = uid
        if let dev = devices.first(where: { $0.uid == uid }) {
            activeDeviceName = dev.name
            activeSampleRate = dev.sampleRate
            activeChannels = dev.inputChannels
        }
        resetLoudnessStats()
        scheduleSaveConfig()
        restartEngine()
    }

    func setLayoutMode(_ mode: MeterLayoutMode) {
        layoutMode = mode
        onLayoutChanged?(mode, showRodeDrawer)
        scheduleSaveConfig()
    }

    func toggleRodeDrawer() {
        showRodeDrawer.toggle()
        onLayoutChanged?(layoutMode, showRodeDrawer)
        scheduleSaveConfig()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTop = enabled
        onAlwaysOnTopChanged?(enabled)
        scheduleSaveConfig()
    }

    func setOpacity(_ val: Double) {
        windowOpacity = val
        onOpacityChanged?(val)
        scheduleSaveConfig()
    }

    func toggleFreeze() {
        isFrozen.toggle()
        if isFrozen { frozenSpectrum = spectrumCurve }
    }

    func resetLoudnessStats() {
        integratedEnergySum = 0
        integratedBlockCount = 0
        integratedLufs = -60.0
        peakHoldDb = -60.0
        isClipping = false
        lufsHistory = Array(repeating: -60.0, count: Self.lufsHistoryCount)
        spectrumPeaks = Array(repeating: 0, count: Self.spectrumBins)
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            if self?.toastMessage == msg { self?.toastMessage = "" }
        }
    }

    func saveLast10SecondsClip() {
        os_unfair_lock_lock(&ringLock)
        let count = min(clipFilled, clipBufferCapacity)
        guard count > 4000 else {
            os_unfair_lock_unlock(&ringLock)
            showToast(tr("Буфер пока пуст", "Audio buffer empty"))
            return
        }
        var pcm = [Float](repeating: 0, count: count)
        var idx = clipWriteIdx - count
        if idx < 0 { idx += clipBufferCapacity }
        for i in 0..<count { pcm[i] = clipRing[(idx + i) % clipBufferCapacity] }
        os_unfair_lock_unlock(&ringLock)

        let dir = "\(NSHomeDirectory())/Desktop/PixelProCam/Captures"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let outUrl = URL(fileURLWithPath: "\(dir)/AudioCheck_\(df.string(from: Date())).wav")

        if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: activeSampleRate, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) {
            buf.frameLength = AVAudioFrameCount(count)
            if let ch = buf.floatChannelData?[0] {
                pcm.withUnsafeBufferPointer { src in ch.update(from: src.baseAddress!, count: count) }
            }
            if let file = try? AVAudioFile(forWriting: outUrl, settings: format.settings) {
                try? file.write(from: buf)
                showToast(tr("💾 Сохранено 10с → Captures", "💾 Saved 10s WAV → Captures"))
                NSWorkspace.shared.activateFileViewerSelecting([outUrl])
                return
            }
        }
        showToast(tr("Ошибка сохранения WAV", "WAV save failed"))
    }

    // MARK: - CoreAudio / AVAudioEngine Capture
    func requestMicAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionDenied = false
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionDenied = !granted
                    if granted { self?.startEngine() }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func restartEngine() { stopEngine(); startEngine() }

    func stopEngine() {
        displayTimer?.invalidate(); displayTimer = nil
        if let eng = audioEngine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        audioEngine = nil
        isRunning = false
    }

    func startEngine() {
        stopEngine()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let targetDev = devices.first(where: { $0.uid == selectedDeviceUID }),
           let au = inputNode.audioUnit {
            var devId = targetDev.id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devId, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let fmt = inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 && fmt.channelCount > 0 else { return }
        activeSampleRate = fmt.sampleRate
        activeChannels = Int(fmt.channelCount)
        rebuildBinTables(sampleRate: fmt.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self = self, let chData = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let chCount = Int(buffer.format.channelCount)
            guard n > 0 else { return }

            os_unfair_lock_lock(&self.ringLock)
            let rLen = self.ringL.count
            let c0 = chData[0]
            let c1 = chCount >= 2 ? chData[1] : chData[0]
            for i in 0..<n {
                let l = c0[i]; let r = c1[i]
                let mono = 0.5 * (l + r)
                self.ringL[self.ringWriteIdx] = l
                self.ringR[self.ringWriteIdx] = r
                self.ringWriteIdx = (self.ringWriteIdx + 1) % rLen
                self.clipRing[self.clipWriteIdx] = mono
                self.clipWriteIdx = (self.clipWriteIdx + 1) % self.clipBufferCapacity
            }
            self.clipFilled = min(self.clipBufferCapacity, self.clipFilled + n)
            os_unfair_lock_unlock(&self.ringLock)
        }

        do {
            try engine.start()
            audioEngine = engine
            isRunning = true
            startDisplayLoop()
        } catch {
            isRunning = false
        }
    }

    private func rebuildBinTables(sampleRate: Double) {
        let nyquist = sampleRate / 2.0
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2 - 1

        func buildLogBands(count: Int, minHz: Double, maxHz: Double) -> ([(Int, Int)], [Float]) {
            var ranges: [(Int, Int)] = []
            var centers: [Float] = []
            for i in 0..<count {
                let f0 = minHz * pow(maxHz / minHz, Double(i) / Double(count))
                let f1 = minHz * pow(maxHz / minHz, Double(i + 1) / Double(count))
                let b0 = max(1, min(maxBin, Int(floor(f0 / binHz))))
                let b1 = max(b0, min(maxBin, Int(ceil(f1 / binHz))))
                ranges.append((b0, b1))
                centers.append(Float(sqrt(f0 * f1)))
            }
            return (ranges, centers)
        }
        let (rSpec, cSpec) = buildLogBands(count: Self.spectrumBins, minHz: 25.0, maxHz: min(20000.0, nyquist))
        specBinRanges = rSpec
        specBandCenterHz = cSpec
        let (rWf, _) = buildLogBands(count: Self.spectrogramRows, minHz: 45.0, maxHz: min(16000.0, nyquist))
        waterfallBinRanges = rWf
    }

    // MARK: - 60 FPS Hardware vDSP Processing
    private func startDisplayLoop() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.processAudioFrame()
        }
        if let t = displayTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private func freqToNoteName(_ hz: Double) -> String {
        guard hz >= 30.0 && hz <= 18000.0 else { return "—" }
        let midi = Int(round(69.0 + 12.0 * log2(hz / 440.0)))
        let name = Self.noteNames[((midi % 12) + 12) % 12]
        return "\(name)\((midi / 12) - 1)"
    }

    private func processAudioFrame() {
        var samplesL = [Float](repeating: 0, count: fftSize)
        var samplesR = [Float](repeating: 0, count: fftSize)
        os_unfair_lock_lock(&ringLock)
        let rLen = ringL.count
        var startIdx = ringWriteIdx - fftSize
        if startIdx < 0 { startIdx += rLen }
        for i in 0..<fftSize {
            let p = (startIdx + i) % rLen
            samplesL[i] = ringL[p]
            samplesR[i] = ringR[p]
        }
        os_unfair_lock_unlock(&ringLock)

        var mono = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize { mono[i] = 0.5 * (samplesL[i] + samplesR[i]) }

        let recentCount = 800
        let recentOffset = fftSize - recentCount
        var maxAbs: Float = 0; var sumSq: Float = 0; var kwSumSq: Float = 0
        var sumLR: Float = 0; var sumLL: Float = 0; var sumRR: Float = 0

        for i in recentOffset..<fftSize {
            let m = mono[i]; let l = samplesL[i]; let r = samplesR[i]
            let a = max(abs(l), abs(r))
            if a > maxAbs { maxAbs = a }
            sumSq += m * m
            let ks = kwHP.process(kwShelf.process(m))
            kwSumSq += ks * ks
            sumLR += l * r; sumLL += l * l; sumRR += r * r
        }

        let rms = sqrt(sumSq / Float(recentCount))
        let curPeakDb = max(-72.0, 20.0 * log10(max(maxAbs, 1e-6)))
        let curRmsDb  = max(-72.0, 20.0 * log10(max(rms, 1e-6)))
        let corrDenom = sqrt(sumLL * sumRR)
        let curCorr: Float = corrDenom > 1e-9 ? max(-1, min(1, sumLR / corrDenom)) : 1.0

        let frameKwPwr = kwSumSq / Float(recentCount)
        momentaryRing[momentaryIdx] = frameKwPwr; momentaryIdx = (momentaryIdx + 1) % momentaryRing.count
        shortTermRing[shortTermIdx] = frameKwPwr; shortTermIdx = (shortTermIdx + 1) % shortTermRing.count

        let momMean = momentaryRing.reduce(0, +) / Float(momentaryRing.count)
        let stMean  = shortTermRing.reduce(0, +) / Float(shortTermRing.count)
        let momLufs = max(-70.0, -0.691 + 10.0 * log10(max(momMean, 1e-10)))
        let stLufs  = max(-70.0, -0.691 + 10.0 * log10(max(stMean, 1e-10)))

        if momLufs > -45.0 {
            integratedEnergySum += Double(frameKwPwr)
            integratedBlockCount += 1
        }
        let intLufs: Float = integratedBlockCount > 5
            ? max(-70.0, Float(-0.691 + 10.0 * log10(max(integratedEnergySum / Double(integratedBlockCount), 1e-10))))
            : stLufs
        let plr = (stLufs > -50.0) ? max(0, min(30, peakHoldDb - stLufs)) : 0

        if curRmsDb < noiseFloorEstimate {
            noiseFloorEstimate = noiseFloorEstimate * 0.90 + curRmsDb * 0.10
        } else {
            noiseFloorEstimate = noiseFloorEstimate * 0.996 + curRmsDb * 0.004
        }

        if curPeakDb >= peakHoldDb {
            peakHoldDb = curPeakDb; peakHoldTimer = 90
        } else if peakHoldTimer > 0 { peakHoldTimer -= 1 }
        else { peakHoldDb = max(curPeakDb, peakHoldDb - 0.30) }

        if curPeakDb > -0.8 { isClipping = true; clipHoldTimer = 90 }
        else if clipHoldTimer > 0 { clipHoldTimer -= 1 }
        else { isClipping = false }

        // Pitch-Locked Oscilloscope
        var zeroCrossIdx = fftSize - Self.oscPointsCount * 3
        for i in (fftSize - 700)..<(fftSize - Self.oscPointsCount * 2 - 2) {
            if mono[i] <= 0 && mono[i + 1] > 0 { zeroCrossIdx = i; break }
        }
        var newOsc = [Float](repeating: 0, count: Self.oscPointsCount)
        for i in 0..<Self.oscPointsCount { newOsc[i] = mono[min(fftSize - 1, zeroCrossIdx + i * 2)] }

        // Stereo Goniometer XY
        var newXY: [(Float, Float)] = []
        newXY.reserveCapacity(Self.stereoPointsCount)
        let stepXY = recentCount / Self.stereoPointsCount
        for i in 0..<Self.stereoPointsCount {
            let idx = recentOffset + i * stepXY
            let l = samplesL[idx]; let r = samplesR[idx]
            newXY.append(((l - r) * 0.7071, (l + r) * 0.7071))
        }

        // Hardware vDSP FFT
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(mono, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeBytes { rawPtr in
                    let cPtr = rawPtr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfN))
                }
                if let setup = fftSetup {
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
                }
            }
        }

        let normScale = Float(fftSize * fftSize) / 4.0
        let binHz = Float(activeSampleRate) / Float(fftSize)
        let tiltF = Float(spectrumTilt)

        var magDb = [Float](repeating: -85, count: halfN)
        var domBin = 0; var domPwr: Float = 0
        var lowE: Float = 0; var midE: Float = 0; var highE: Float = 0
        var rumbleSum: Float = 0; var rumbleBins: Int = 0

        for i in 1..<halfN {
            let pwr = mags[i] / normScale
            let freq = Float(i) * binHz
            if freq >= 55 && freq <= 6000 && pwr > domPwr { domPwr = pwr; domBin = i }
            if freq >= 20 && freq <= 150 { rumbleSum += pwr; rumbleBins += 1 }
            if freq < 250 { lowE += pwr }
            else if freq < 2400 { midE += pwr }
            else { highE += pwr }

            let amp = sqrt(max(pwr, 1e-12))
            let tilt = tiltF * log2(max(freq / 300.0, 0.08))
            magDb[i] = 20.0 * log10(amp) + tilt
        }

        let curRumbleDb = 10.0 * log10(max(rumbleSum / Float(max(1, rumbleBins)), 1e-12))
        rumbleEstimate = rumbleEstimate * 0.92 + curRumbleDb * 0.08

        let domHz = (curRmsDb > -48 && domBin > 0) ? Double(domBin) * Double(binHz) : 0
        let domNote = domHz > 0 ? freqToNoteName(domHz) : "—"

        // Multi-Band Waveform
        let lowW = sqrt(lowE) * 0.9; let midW = sqrt(midE) * 1.4; let highW = sqrt(highE) * 2.8
        var newWave = coloredWave
        newWave.removeFirst()
        newWave.append(ColoredWaveSlice(amplitude: min(1.0, maxAbs * 1.35), lowWeight: lowW, midWeight: midW, highWeight: highW))

        // 64-Band Spectrum Curve
        var newCurve = spectrumCurve
        var newPeaks = spectrumPeaks
        for b in 0..<Self.spectrumBins {
            let (b0, b1) = specBinRanges[b]
            var pk: Float = -85
            for k in b0...b1 { if magDb[k] > pk { pk = magDb[k] } }
            let norm = max(0, min(1, (pk + 70.0) / 66.0))
            let prev = newCurve[b]
            let sm = norm > prev ? (prev * 0.35 + norm * 0.65) : (prev * 0.82 + norm * 0.18)
            newCurve[b] = sm
            newPeaks[b] = max(sm, newPeaks[b] - 0.005)
        }

        // Mel Spectrogram
        var wfCol = [Float](repeating: 0, count: Self.spectrogramRows)
        for r in 0..<Self.spectrogramRows {
            let (b0, b1) = waterfallBinRanges[r]
            var pk: Float = -85
            for k in b0...b1 { if magDb[k] > pk { pk = magDb[k] } }
            wfCol[r] = max(0, min(1, (pk + 66.0) / 60.0))
        }
        var newSpec = spectrogram
        newSpec.removeFirst()
        newSpec.append(wfCol)

        // LUFS History
        lufsHistoryTick += 1
        var newLufsHist = lufsHistory
        if lufsHistoryTick >= 8 {
            lufsHistoryTick = 0
            newLufsHist.removeFirst()
            newLufsHist.append(stLufs)
        }

        func bandRawDb(_ f0: Float, _ f1: Float) -> Float {
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(halfN - 1, Int(f1 / binHz))
            var s: Float = 0
            for k in i0...i1 { s += mags[k] / normScale }
            return 10.0 * log10(max(s / Float(max(1, i1 - i0 + 1)), 1e-12))
        }

        // Acoustic Scan Sampling
        if isScanning {
            if scanPhase == "quiet" {
                scanQuietRms.append(curRmsDb)
                scanQuietPeaks.append(curPeakDb)
                scanQuietRumble.append(curRumbleDb)
                scanQuietMid.append(bandRawDb(150, 1000))
                scanQuietHigh.append(bandRawDb(1000, 8000))
            } else if scanPhase == "speak" && curRmsDb > -46.0 {
                scanSpeechLufs.append(momLufs)
                if curPeakDb > scanSpeechPeakMax { scanSpeechPeakMax = curPeakDb }
                scanMud.append(bandRawDb(120, 320))
                scanPres.append(bandRawDb(2000, 5000))
                scanSib.append(bandRawDb(5500, 9000))
            }
        }

        // Live Noise Classification Badge + Optional Continuous Auto-Guard
        guardTick += 1
        if curRmsDb < -26.0 && !isScanning {
            guardQuietSamples.append(curRmsDb)
            guardRumbleSamples.append(curRumbleDb)
            if guardQuietSamples.count > 180 { guardQuietSamples.removeFirst() }
            if guardRumbleSamples.count > 180 { guardRumbleSamples.removeFirst() }
        }
        if guardTick >= 60 { // once per second
            guardTick = 0
            if noiseFloorEstimate > -41.0 || rumbleEstimate > -50.0 {
                liveNoiseStatus = tr("⚠ Шум/Стройка", "⚠ High Noise")
            } else if noiseFloorEstimate > -48.0 {
                liveNoiseStatus = tr("Умеренный фон", "Moderate")
            } else {
                liveNoiseStatus = tr("Тихо", "Quiet")
            }

            if autoAdaptiveGuard && rodeConnected && !isScanning && guardQuietSamples.count >= 120 {
                let now = Date()
                if now.timeIntervalSince(lastAutoGuardApplyTime) > 6.0 {
                    let sortedRms = guardQuietSamples.sorted()
                    let p40Floor = Double(sortedRms[Int(Double(sortedRms.count) * 0.40)])
                    let p90Noise = Double(sortedRms[Int(Double(sortedRms.count) * 0.90)])
                    let meanRumble = Double(guardRumbleSamples.reduce(0, +)) / Double(guardRumbleSamples.count)

                    let targetGate = max(-48.0, min(-28.0, (max(p40Floor + 8.0, p90Noise + 3.0)).rounded()))
                    let wantHpf150 = (meanRumble > -52.0 || p40Floor > -43.0)
                    let targetHpf = wantHpf150 ? 2 : 1

                    if abs(targetGate - rodeDsp.gateThresholdDb) >= 3.0 || targetHpf != rodeDsp.hpfMode {
                        lastAutoGuardApplyTime = now
                        var next = rodeDsp
                        next.gateEnabled = true
                        next.gateThresholdDb = targetGate
                        next.hpfMode = targetHpf
                        if wantHpf150 && p40Floor > -41.0 {
                            next.bigBottomEnabled = false
                        }
                        applyRodeSettingsNow(next, label: tr("Авто-адаптация: HPF \(next.hpfLabel), Gate \(Int(targetGate)) dB", "Auto-adapted: HPF \(next.hpfLabel), Gate \(Int(targetGate)) dB"))
                    }
                }
            }
        }

        // Publish to SwiftUI
        peakDb = curPeakDb
        rmsDb = curRmsDb
        momentaryLufs = momLufs
        shortTermLufs = stLufs
        integratedLufs = intLufs
        dynamicsPlrDb = plr
        noiseFloorDb = noiseFloorEstimate
        liveRumbleDb = rumbleEstimate
        dominantFreqHz = domHz
        dominantNote = domNote
        stereoCorrelation = stereoCorrelation * 0.8 + curCorr * 0.2

        if !isFrozen {
            spectrumCurve = newCurve
            spectrumPeaks = newPeaks
            coloredWave = newWave
            oscilloscope = newOsc
            spectrogram = newSpec
            lufsHistory = newLufsHist
            stereoXY = newXY
        }
    }

    // MARK: - Smart Noise Auto-Scanner (5s Pure Room Noise OR 10s Room + Voice)
    func startNoiseAutoScan(fullWithVoice: Bool) {
        if isScanning { cancelScan(); return }
        isScanning = true
        scanMode = fullWithVoice ? "full10s" : "noise5s"
        scanReport = nil
        showScanPopover = false
        scanQuietRms.removeAll(); scanQuietPeaks.removeAll(); scanQuietRumble.removeAll()
        scanQuietMid.removeAll(); scanQuietHigh.removeAll()
        scanSpeechLufs.removeAll(); scanMud.removeAll(); scanPres.removeAll(); scanSib.removeAll()
        scanSpeechPeakMax = -60.0
        scanStep = 0
        scanPhase = "quiet"
        scanCountdown = fullWithVoice ? 4 : 5

        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.scanStep += 1
            if self.scanMode == "noise5s" {
                if self.scanStep < 5 {
                    self.scanPhase = "quiet"; self.scanCountdown = 5 - self.scanStep
                } else {
                    t.invalidate(); self.finishAcousticScan(withVoice: false)
                }
            } else {
                if self.scanStep < 4 {
                    self.scanPhase = "quiet"; self.scanCountdown = 4 - self.scanStep
                } else if self.scanStep < 10 {
                    self.scanPhase = "speak"; self.scanCountdown = 10 - self.scanStep
                } else {
                    t.invalidate(); self.finishAcousticScan(withVoice: true)
                }
            }
        }
    }

    func cancelScan() {
        scanTimer?.invalidate(); scanTimer = nil
        isScanning = false; scanPhase = ""; scanMode = ""
    }

    private func finishAcousticScan(withVoice: Bool) {
        isScanning = false; scanPhase = ""
        func mean(_ a: [Float], _ fb: Double) -> Double { a.isEmpty ? fb : Double(a.reduce(0, +)) / Double(a.count) }
        func pct(_ a: [Float], _ p: Double, _ fb: Double) -> Double {
            guard !a.isEmpty else { return fb }
            let s = a.sorted()
            return Double(s[min(s.count - 1, max(0, Int(Double(s.count) * p)))])
        }

        let floorDb   = pct(scanQuietRms, 0.50, Double(noiseFloorDb))
        let peakImp   = pct(scanQuietPeaks, 0.95, floorDb + 8.0)
        let rumbleDb  = mean(scanQuietRumble, Double(liveRumbleDb))
        let midNoise  = mean(scanQuietMid, -58.0)
        let highNoise = mean(scanQuietHigh, -62.0)
        let impulseJump = peakImp - floorDb

        // Build tailored hardware DSP preset from actual measured acoustics!
        var dsp = rodeDsp
        var envLabel = ""
        var diag = ""

        let isHeavyConstruction = (rumbleDb > -50.0) || (floorDb > -41.0) || (peakImp > -28.0 && impulseJump > 12.0)
        let isModerateNoise     = (floorDb > -48.0) || (midNoise > -52.0) || (highNoise > -56.0)

        if isHeavyConstruction {
            envLabel = tr("🏗 Стройка / Сильный внешний шум", "🏗 Construction / Heavy Rumble")
            diag = tr("Обнаружен низкий гул (\(Int(rumbleDb)) dB) и всплески шума до \(Int(peakImp)) dB. Включён HPF 150 Hz, жёсткий Noise Gate и отключён Big Bottom.",
                      "Detected heavy rumble (\(Int(rumbleDb)) dB) & spikes to \(Int(peakImp)) dB. Enabled 150 Hz HPF, tight gate, disabled Big Bottom.")
            dsp.hpfMode = 2
            dsp.gateEnabled = true
            dsp.gateThresholdDb = max(-42.0, min(-26.0, max(floorDb + 8.0, peakImp + 1.5).rounded()))
            dsp.gateAttackMs = 15.0
            dsp.gateHoldMs = 45.0
            dsp.gateReleaseMs = 150.0
            dsp.gateHysteresisDb = -7.0
            dsp.bigBottomEnabled = false
            dsp.bigBottomDrivePct = 20.0
            dsp.compEnabled = true
            dsp.compThresholdDb = -23.0
            dsp.compRatio = 2.4
            dsp.compGainDb = 2.0
            dsp.exciterEnabled = true
            dsp.exciterMixPct = 55.0
            dsp.exciterTuneHz = 3500.0
            if !withVoice { dsp.inputGainDb = min(dsp.inputGainDb, 40.0) }
        } else if isModerateNoise {
            envLabel = tr("🏢 Помещение с фоном / Эхом", "🏢 Moderate Room / HVAC Noise")
            diag = tr("Фон комнаты \(Int(floorDb)) dB (гул \(Int(rumbleDb)) dB). Выставлен оптимальный HPF и быстрый релиз гейта, чтобы отсечь фон и хвосты эха.",
                      "Room floor \(Int(floorDb)) dB. Applied optimal HPF & fast gate release to keep room noise out.")
            dsp.hpfMode = rumbleDb > -55.0 ? 2 : 1
            dsp.gateEnabled = true
            dsp.gateThresholdDb = max(-45.0, min(-32.0, max(floorDb + 7.5, peakImp + 1.0).rounded()))
            dsp.gateAttackMs = 20.0
            dsp.gateHoldMs = 50.0
            dsp.gateReleaseMs = 165.0
            dsp.gateHysteresisDb = -8.0
            dsp.bigBottomEnabled = true
            dsp.bigBottomDrivePct = 32.0
            dsp.bigBottomTuneHz = 95.0
            dsp.compEnabled = true
            dsp.compThresholdDb = -22.0
            dsp.compRatio = 2.0
            dsp.compGainDb = 1.5
            dsp.exciterEnabled = true
            dsp.exciterMixPct = 52.0
            dsp.exciterTuneHz = 3500.0
            if !withVoice { dsp.inputGainDb = max(39.0, min(42.0, dsp.inputGainDb)) }
        } else {
            envLabel = tr("🎙 Тихая студийная комната", "🎙 Quiet Studio Room")
            diag = tr("Отличная тишина (\(Int(floorDb)) dB)! Выставлен мягкий HPF 75 Hz, бережный гейт и тёплая студийная обработка APHEX.",
                      "Clean quiet room (\(Int(floorDb)) dB)! Set 75 Hz HPF, gentle gate & full warm APHEX studio chain.")
            dsp.hpfMode = 1
            dsp.gateEnabled = true
            dsp.gateThresholdDb = max(-52.0, min(-42.0, (floorDb + 7.0).rounded()))
            dsp.gateAttackMs = 25.0
            dsp.gateHoldMs = 70.0
            dsp.gateReleaseMs = 240.0
            dsp.gateHysteresisDb = -9.0
            dsp.bigBottomEnabled = true
            dsp.bigBottomDrivePct = 55.0
            dsp.bigBottomTuneHz = 88.0
            dsp.compEnabled = true
            dsp.compThresholdDb = -25.0
            dsp.compRatio = 2.0
            dsp.compGainDb = 2.0
            dsp.exciterEnabled = true
            dsp.exciterMixPct = 60.0
            dsp.exciterTuneHz = 3500.0
            if !withVoice { dsp.inputGainDb = max(41.0, min(44.0, dsp.inputGainDb)) }
        }

        // If full voice calibration was run, also dial in exact Input Gain + Exciter/BigBottom to the user's voice!
        var speechLufsOut: Double? = nil
        var speechPeakOut: Double? = nil
        if withVoice && !scanSpeechLufs.isEmpty {
            let avgLufs = mean(scanSpeechLufs, Double(shortTermLufs))
            let pk = Double(scanSpeechPeakMax)
            speechLufsOut = avgLufs
            speechPeakOut = pk
            let target = Double(loudnessTarget.lufs)

            if pk > -2.5 {
                dsp.inputGainDb = max(28.0, (dsp.inputGainDb - 4.0).rounded())
            } else if avgLufs < target - 4.0 {
                dsp.inputGainDb = min(50.0, (dsp.inputGainDb + min(5.0, (target - avgLufs) * 0.6)).rounded())
            } else if avgLufs > target + 3.0 {
                dsp.inputGainDb = max(30.0, (dsp.inputGainDb - min(4.0, (avgLufs - target) * 0.6)).rounded())
            }

            let mudDb = mean(scanMud, -42.0)
            let presDb = mean(scanPres, -46.0)
            let sibDb = mean(scanSib, -54.0)
            if mudDb > presDb + 10.0 && !isHeavyConstruction {
                dsp.bigBottomDrivePct = 25.0
            }
            if sibDb > presDb - 3.5 {
                dsp.exciterMixPct = 30.0
            }
        }

        // Apply straight into RØDE NT1 5th Gen hardware immediately if connected!
        let willApply = rodeConnected
        if willApply {
            activeProfileId = ""
            applyRodeSettingsNow(dsp, label: envLabel)
        }

        scanReport = AcousticScanReport(
            modeTitle: withVoice ? tr("🎯 Полная калибровка (Шум + Голос)", "🎯 Full Room + Voice Scan") : tr("⚡ Авто-подбор по шуму (5 сек)", "⚡ 5s Room Noise Auto-Scan"),
            environmentLabel: envLabel,
            diagnosisDetail: diag,
            noiseFloorDb: floorDb,
            peakImpulseDb: peakImp,
            rumbleDb: rumbleDb,
            speechLufs: speechLufsOut,
            peakSpeechDb: speechPeakOut,
            suggestedDsp: dsp,
            appliedToHardware: willApply
        )
        showScanPopover = true
    }

    // Demo Visualization for --screenshot
    private func populateDemoVisualization() {
        isRunning = true
        rodeConnected = true
        activeDeviceName = "RØDE NT1 5th Gen"
        activeProfileId = "builtin_construction"
        activeMicPresetId = "mic_radio"
        rodeDsp = RoomAudioProfile.builtInProfiles[0].dsp
        liveNoiseStatus = "⚠ Шум/Стройка"
        peakDb = -6.8; peakHoldDb = -5.2; rmsDb = -15.4
        momentaryLufs = -15.6; shortTermLufs = -16.1; integratedLufs = -16.3
        dynamicsPlrDb = 10.9; noiseFloorDb = -39.2; liveRumbleDb = -46.5
        dominantFreqHz = 148; dominantNote = "D3"; stereoCorrelation = 0.96

        for i in 0..<Self.waveSlicesCount {
            let t = Float(i) * 0.13
            let env = min(0.95, max(0.08, 0.25 + 0.62 * abs(sin(t * 0.42)) * (0.6 + 0.4 * cos(t * 1.1))))
            coloredWave[i] = ColoredWaveSlice(
                amplitude: env,
                lowWeight: 0.35 + 0.45 * abs(sin(t * 0.27)),
                midWeight: 0.55 + 0.35 * abs(cos(t * 0.51)),
                highWeight: 0.15 + 0.55 * pow(max(0, sin(t * 0.83)), 3)
            )
        }
        for i in 0..<Self.oscPointsCount {
            let p = Float(i) / Float(Self.oscPointsCount) * 4.0 * .pi
            oscilloscope[i] = sin(p) * 0.55 + sin(p * 2.0 + 0.6) * 0.28 + sin(p * 3.0) * 0.14
        }
        for b in 0..<Self.spectrumBins {
            let v = min(0.92, max(0.06, Self.vocalTargetCurve[b] * (0.88 + 0.20 * sin(Float(b) * 0.55))))
            spectrumCurve[b] = v; spectrumPeaks[b] = min(0.96, v + 0.08)
        }
        for c in 0..<Self.spectrogramCols {
            let mod = 0.42 + 0.58 * abs(sin(Float(c) * 0.15))
            for r in 0..<Self.spectrogramRows {
                let y = Float(r) / Float(Self.spectrogramRows)
                let f1 = exp(-pow((y - 0.24) / 0.15, 2)) * 0.92 * mod
                let f2 = exp(-pow((y - 0.56) / 0.16, 2)) * 0.72 * mod
                let f3 = exp(-pow((y - 0.80) / 0.10, 2)) * 0.38 * mod
                spectrogram[c][r] = min(1.0, max(0.02, f1 + f2 + f3))
            }
        }
        for i in 0..<Self.lufsHistoryCount {
            let t = Float(i) * 0.16
            lufsHistory[i] = -16.5 + sin(t) * 3.2 + cos(t * 2.3) * 1.4
        }
        for i in 0..<Self.stereoPointsCount {
            let a = Float(i) * 0.25
            stereoXY[i] = (sin(a * 1.7) * 0.22, cos(a) * 0.72)
        }
    }
}

// MARK: - Standard Titled macOS Studio UI (Meters + Room Presets + Live RØDE NT1 DSP Drawer)
struct AudioMetersView: View {
    @ObservedObject var eng: AudioAnalyzerEngine

    var body: some View {
        VStack(spacing: 0) {
            // ROW 1: Main Studio Controls Toolbar (Clean, No Frameless Overlap!)
            HStack(spacing: 8) {
                if let logoPath = Bundle.main.path(forResource: "mo_audio_logo", ofType: "png") ?? Bundle.main.path(forResource: "mo_logo", ofType: "png"),
                   let nsImg = NSImage(contentsOfFile: logoPath) {
                    Image(nsImage: nsImg)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }

                // Input Device Picker
                Menu {
                    ForEach(eng.devices) { dev in
                        Button((dev.uid == eng.selectedDeviceUID ? "✅ " : "") + "\(dev.name) • \(Int(dev.sampleRate/1000))kHz") {
                            eng.selectDevice(uid: dev.uid)
                        }
                    }
                    Divider()
                    Button(eng.tr("🔄 Обновить входы", "🔄 Refresh Inputs")) {
                        eng.refreshDevices(); eng.restartEngine()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(eng.isRunning ? Color.green : Color.red).frame(width: 6.5, height: 6.5)
                        Text(eng.activeDeviceName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text("\(Int(eng.activeSampleRate/1000))k").font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderedButton).controlSize(.small).frame(maxWidth: 200)

                // Layout Toggle: BAR vs QUAD
                HStack(spacing: 2) {
                    layoutPill("BAR",  active: eng.layoutMode == .bar)  { eng.setLayoutMode(.bar) }
                    layoutPill("QUAD", active: eng.layoutMode == .quad) { eng.setLayoutMode(.quad) }
                }

                // Fast 5s Room Noise Auto-Scan -> Direct Apply to RØDE NT1!
                Button(action: { eng.startNoiseAutoScan(fullWithVoice: false) }) {
                    HStack(spacing: 4) {
                        Image(systemName: eng.isScanning && eng.scanMode == "noise5s" ? "waveform.circle.fill" : "bolt.fill")
                        if eng.isScanning && eng.scanMode == "noise5s" {
                            Text(eng.tr("Молчите \(eng.scanCountdown)с...", "Silence \(eng.scanCountdown)s..."))
                        } else {
                            Text(eng.tr("Авто-шум 5с", "Auto-Noise 5s"))
                        }
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 9).padding(.vertical, 4.5)
                    .background(eng.isScanning && eng.scanMode == "noise5s" ? Color.orange : Color.orange.opacity(0.22))
                    .foregroundColor(eng.isScanning && eng.scanMode == "noise5s" ? .white : .orange)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Замерит шум комнаты/стройки за 5 сек и сразу настроит RØDE NT1", "Measure 5s room/construction noise and auto-configure RØDE NT1"))

                // Full 10s Room + Voice Calibrator
                Button(action: { eng.startNoiseAutoScan(fullWithVoice: true) }) {
                    HStack(spacing: 4) {
                        Image(systemName: eng.isScanning && eng.scanMode == "full10s" ? "waveform.circle.fill" : "target")
                        if eng.isScanning && eng.scanMode == "full10s" {
                            Text(eng.scanPhase == "quiet"
                                 ? eng.tr("Тишина \(eng.scanCountdown)с", "Quiet \(eng.scanCountdown)s")
                                 : eng.tr("Говорите \(eng.scanCountdown)с", "Speak \(eng.scanCountdown)s"))
                        } else {
                            Text(eng.tr("Голос+Шум 10с", "Voice+Room 10s"))
                        }
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4.5)
                    .background(eng.isScanning && eng.scanMode == "full10s" ? (eng.scanPhase == "quiet" ? Color.orange : Color.red) : eng.theme.primary.opacity(0.18))
                    .foregroundColor(eng.isScanning && eng.scanMode == "full10s" ? .white : eng.theme.primary)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $eng.showScanPopover, arrowEdge: .bottom) {
                    scanResultPopoverView
                }

                // 10s WAV Capture + Freeze
                Button(action: { eng.saveLast10SecondsClip() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform.badge.plus")
                        Text("10s WAV")
                    }
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.08)).foregroundColor(.primary.opacity(0.9)).cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button(action: { eng.toggleFreeze() }) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 6.5).padding(.vertical, 4.5)
                        .background(eng.isFrozen ? Color.cyan : Color.white.opacity(0.08))
                        .foregroundColor(eng.isFrozen ? .black : .secondary).cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Заморозить спектр", "Freeze spectrum"))

                Spacer()

                if !eng.toastMessage.isEmpty {
                    Text(eng.toastMessage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .lineLimit(1)
                }

                // RØDE Hardware DSP Drawer Toggle
                Button(action: { eng.toggleRodeDrawer() }) {
                    HStack(spacing: 4.5) {
                        Circle().fill(eng.rodeConnected ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Image(systemName: "dial.medium.fill")
                        Text("RØDE DSP")
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 8.5).padding(.vertical, 4.5)
                    .background(eng.showRodeDrawer ? Color.green.opacity(0.24) : Color.white.opacity(0.08))
                    .foregroundColor(eng.showRodeDrawer ? .green : .primary.opacity(0.85))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Показать/скрыть прямое управление RØDE NT1 5th Gen по USB", "Toggle direct RØDE NT1 5th Gen hardware DSP controls"))

                // Settings Menu
                Menu {
                    Section(eng.tr("Цель громкости (Youlean)", "Loudness Target")) {
                        ForEach(LoudnessTarget.allCases, id: \.self) { lt in
                            Button((eng.loudnessTarget == lt ? "✅ " : "") + lt.rawValue) {
                                eng.loudnessTarget = lt; eng.scheduleSaveConfig()
                            }
                        }
                    }
                    Section(eng.tr("Наклон спектра", "Spectrum Tilt")) {
                        Button((eng.spectrumTilt == 0.0 ? "✅ " : "") + "0 dB/oct (Flat)")          { eng.spectrumTilt = 0.0; eng.scheduleSaveConfig() }
                        Button((eng.spectrumTilt == 3.0 ? "✅ " : "") + "+3.0 dB/oct (TDR Prism)")  { eng.spectrumTilt = 3.0; eng.scheduleSaveConfig() }
                        Button((eng.spectrumTilt == 4.5 ? "✅ " : "") + "+4.5 dB/oct (FabFilter)")  { eng.spectrumTilt = 4.5; eng.scheduleSaveConfig() }
                    }
                    Section(eng.tr("Оверлеи спектра", "Spectrum Overlays")) {
                        Button((eng.showTargetCurve ? "✅ " : "") + eng.tr("Эталонная кривая голоса", "Vocal Target Curve")) {
                            eng.showTargetCurve.toggle(); eng.scheduleSaveConfig()
                        }
                        Button((eng.showVocalZones ? "✅ " : "") + eng.tr("Зоны частот (HPF / Гул / С-Ш)", "Vocal Freq Zones")) {
                            eng.showVocalZones.toggle(); eng.scheduleSaveConfig()
                        }
                    }
                    Section(eng.tr("Цветовая тема", "Color Theme")) {
                        ForEach(MeterTheme.allCases, id: \.self) { t in
                            Button((eng.theme == t ? "✅ " : "") + t.rawValue) {
                                eng.theme = t; eng.scheduleSaveConfig()
                            }
                        }
                    }
                    if eng.layoutMode == .bar {
                        Section(eng.tr("Модули в режиме BAR", "Bar Modules")) {
                            Button((eng.showWaveform ? "✅ " : "") + "Multi-Band Waveform")  { eng.showWaveform.toggle(); eng.scheduleSaveConfig() }
                            Button((eng.showOscilloscope ? "✅ " : "") + "Oscilloscope")     { eng.showOscilloscope.toggle(); eng.scheduleSaveConfig() }
                            Button((eng.showSpectrum ? "✅ " : "") + "FabFilter Spectrum")   { eng.showSpectrum.toggle(); eng.scheduleSaveConfig() }
                            Button((eng.showSpectrogram ? "✅ " : "") + "Mel Spectrogram")   { eng.showSpectrogram.toggle(); eng.scheduleSaveConfig() }
                            Button((eng.showStereo ? "✅ " : "") + "Stereometer")            { eng.showStereo.toggle(); eng.scheduleSaveConfig() }
                            Button((eng.showLoudness ? "✅ " : "") + "Youlean Loudness")     { eng.showLoudness.toggle(); eng.scheduleSaveConfig() }
                        }
                    }
                    Divider()
                    Button(eng.tr("🎚 Открыть RØDE Central", "🎚 Open RØDE Central")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RODE Central.app"))
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundColor(eng.theme.primary)
                }
                .menuStyle(.borderedButton).controlSize(.small).frame(width: 32)

                // Always on Top Toggle (works over Full-Screen too!)
                Button(action: { eng.setAlwaysOnTop(!eng.alwaysOnTop) }) {
                    Image(systemName: eng.alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 6.5).padding(.vertical, 4.5)
                        .background(eng.alwaysOnTop ? Color.indigo : Color.white.opacity(0.08))
                        .foregroundColor(.white).cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Поверх всех окон (включая Full-Screen)", "Pin always on top (Full-Screen overlay)"))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.black.opacity(0.36))

            hairlineH

            // ROW 2: Multi-Room Profiles & Live Noise-Adaptive Preset Strip!
            HStack(spacing: 6) {
                // Live Room Noise Sensor Badge
                HStack(spacing: 5) {
                    Circle()
                        .fill(eng.noiseFloorDb > -41 ? Color.red : (eng.noiseFloorDb > -48 ? Color.orange : Color.green))
                        .frame(width: 6.5, height: 6.5)
                    Text(String(format: "%@ %.0fdB", eng.liveNoiseStatus, eng.noiseFloorDb))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(eng.noiseFloorDb > -41 ? .orange : .secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3.5)
                .background(Color.white.opacity(0.05)).cornerRadius(5)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(eng.allProfiles) { prof in
                            let isActive = eng.activeProfileId == prof.id
                            HStack(spacing: 3) {
                                Button(action: { eng.applyRoomProfile(prof) }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: prof.icon).font(.system(size: 9.5))
                                        Text(prof.name).font(.system(size: 10, weight: isActive ? .bold : .semibold))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(isActive ? eng.theme.primary.opacity(0.26) : Color.white.opacity(0.06))
                                    .foregroundColor(isActive ? eng.theme.primary : .primary.opacity(0.85))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isActive ? eng.theme.primary.opacity(0.75) : Color.clear, lineWidth: 1))
                                    .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                                .help(prof.subtitle)

                                if !prof.isBuiltIn {
                                    Button(action: { eng.deleteCustomRoom(prof.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .help(eng.tr("Удалить комнату", "Delete room"))
                                }
                            }
                        }

                        // + Save Current Room Profile
                        Button(action: { eng.showSaveRoomPopover.toggle() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                Text(eng.tr("Комната", "Room"))
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(.secondary)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $eng.showSaveRoomPopover, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(eng.tr("Сохранить текущую комнату", "Save Current Room Profile"))
                                    .font(.system(size: 12, weight: .bold))
                                Text(eng.tr("Сохранит Gain, HPF, Gate, Compressor и APHEX для быстрого переключения.", "Saves Gain, HPF, Gate, Compressor & APHEX for 1-click recall."))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                TextField(eng.tr("Напр.: Кабинет (стройка), Спальня...", "e.g. Office, Bedroom..."), text: $eng.newRoomName)
                                    .textFieldStyle(.roundedBorder).frame(width: 230)
                                HStack {
                                    Spacer()
                                    Button(eng.tr("Отмена", "Cancel")) { eng.showSaveRoomPopover = false }.controlSize(.small)
                                    Button(eng.tr("Сохранить", "Save")) { eng.saveCurrentAsCustomRoom(name: eng.newRoomName) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                        .disabled(eng.newRoomName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            .padding(12)
                        }
                    }
                }

                // Undo Last Hardware Change
                if eng.previousRodeDsp != nil {
                    Button(action: { eng.undoLastRodeChange() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.08)).foregroundColor(.orange).cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help(eng.tr("Вернуть предыдущие настройки RØDE NT1", "Undo last RØDE NT1 DSP change"))
                }

                // Live Auto-Adaptive Noise Guard Toggle
                Button(action: { eng.autoAdaptiveGuard.toggle(); eng.scheduleSaveConfig() }) {
                    HStack(spacing: 3.5) {
                        Image(systemName: eng.autoAdaptiveGuard ? "shield.lefthalf.filled.badge.checkmark" : "shield")
                        Text(eng.tr("Авто-гейт", "Auto-Gate"))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(eng.autoAdaptiveGuard ? Color.purple.opacity(0.32) : Color.white.opacity(0.06))
                    .foregroundColor(eng.autoAdaptiveGuard ? Color(red: 0.82, green: 0.65, blue: 1.0) : .secondary)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(eng.autoAdaptiveGuard ? Color.purple.opacity(0.7) : Color.clear, lineWidth: 1))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(eng.tr("В паузах автоматически подстраивает RØDE Noise Gate и HPF 150Hz, если за окном началась или стихла стройка", "Automatically adapts RØDE Gate & HPF 150Hz during silence if outdoor construction starts or stops"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5.5)
            .background(Color.black.opacity(0.24))

            hairlineH

            if eng.permissionDenied {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill").foregroundColor(.orange)
                    Text(eng.tr("Дайте доступ к Микрофону: Системные настройки → Конфиденциальность → Микрофон", "Grant Microphone access in System Settings → Privacy & Security → Microphone"))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.orange)
                    Spacer()
                    Button(eng.tr("Настройки", "Settings")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button(eng.tr("Повторить", "Retry")) { eng.requestMicAndStart() }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.14))
            }

            // METERS WORKSPACE (MiniMeters + FabFilter Pro-Q + TDR Prism + Youlean)
            Group {
                if eng.layoutMode == .bar {
                    HStack(spacing: 0) {
                        if eng.showWaveform {
                            meterCell("WAVEFORM", badge: "MULTI-BAND") { MultiBandWaveformCanvas(slices: eng.coloredWave) }
                                .frame(minWidth: 160)
                            hairlineV
                        }
                        if eng.showOscilloscope {
                            meterCell("OSCILLOSCOPE", badge: eng.dominantNote) { OscilloscopeCanvas(samples: eng.oscilloscope, theme: eng.theme) }
                                .frame(minWidth: 120, maxWidth: 170)
                            hairlineV
                        }
                        if eng.showSpectrum {
                            meterCell("SPECTRUM", badge: eng.dominantFreqHz > 0 ? String(format: "%.0fHz %@", eng.dominantFreqHz, eng.dominantNote) : "+\(String(format: "%.1f", eng.spectrumTilt))dB/o") {
                                FabFilterSpectrumCanvas(curve: eng.spectrumCurve, peaks: eng.spectrumPeaks, frozen: eng.isFrozen ? eng.frozenSpectrum : nil, theme: eng.theme, showTargetCurve: eng.showTargetCurve, showVocalZones: eng.showVocalZones)
                            }
                            .frame(minWidth: 260)
                            hairlineV
                        }
                        if eng.showSpectrogram {
                            meterCell("SPECTROGRAM", badge: "MEL") { SpectrogramCanvas(grid: eng.spectrogram, theme: eng.theme) }
                                .frame(minWidth: 150)
                            hairlineV
                        }
                        if eng.showStereo {
                            meterCell("STEREOMETER", badge: String(format: "Φ %+.2f", eng.stereoCorrelation)) { StereometerCanvas(points: eng.stereoXY, correlation: eng.stereoCorrelation, theme: eng.theme) }
                                .frame(width: 118)
                            hairlineV
                        }
                        if eng.showLoudness {
                            YouleanLoudnessCell(eng: eng).frame(width: 245)
                        }
                    }
                    .frame(minHeight: 115)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            meterCell("FABFILTER / TDR SPECTRUM (25Hz–20kHz)", badge: eng.dominantFreqHz > 0 ? String(format: "Peak: %.0f Hz (%@) • +%.1f dB/oct", eng.dominantFreqHz, eng.dominantNote, eng.spectrumTilt) : "+\(String(format: "%.1f", eng.spectrumTilt)) dB/oct") {
                                FabFilterSpectrumCanvas(curve: eng.spectrumCurve, peaks: eng.spectrumPeaks, frozen: eng.isFrozen ? eng.frozenSpectrum : nil, theme: eng.theme, showTargetCurve: eng.showTargetCurve, showVocalZones: eng.showVocalZones)
                            }
                            hairlineV
                            YouleanLoudnessCell(eng: eng).frame(width: 295)
                        }
                        .frame(minHeight: 155)
                        hairlineH
                        HStack(spacing: 0) {
                            meterCell("MULTI-BAND WAVEFORM (BASS•MID•AIR)", badge: String(format: "RMS %.1f dB", eng.rmsDb)) {
                                MultiBandWaveformCanvas(slices: eng.coloredWave)
                            }
                            hairlineV
                            meterCell("MEL SPECTROGRAM", badge: eng.theme.rawValue.uppercased()) {
                                SpectrogramCanvas(grid: eng.spectrogram, theme: eng.theme)
                            }
                            hairlineV
                            meterCell("OSCILLOSCOPE", badge: eng.dominantNote) {
                                OscilloscopeCanvas(samples: eng.oscilloscope, theme: eng.theme)
                            }
                            .frame(width: 165)
                            hairlineV
                            meterCell("STEREOMETER", badge: String(format: "Φ %+.2f", eng.stereoCorrelation)) {
                                StereometerCanvas(points: eng.stereoXY, correlation: eng.stereoCorrelation, theme: eng.theme)
                            }
                            .frame(width: 140)
                        }
                        .frame(minHeight: 130)
                    }
                }
            }

            // LIVE RØDE NT1 5TH GEN DIRECT USB HARDWARE DSP PANEL
            if eng.showRodeDrawer {
                hairlineH
                RodeDSPDrawerView(eng: eng)
            }
        }
        .background(eng.theme.bgDark)
        .preferredColorScheme(.dark)
    }

    private var hairlineV: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.6) }
    private var hairlineH: some View { Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.6) }

    private func layoutPill(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05))
                .foregroundColor(active ? .white : .secondary)
                .cornerRadius(4.5)
        }.buttonStyle(.plain)
    }

    private func meterCell<Content: View>(_ title: String, badge: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(title).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(badge).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(eng.theme.primary.opacity(0.85))
            }
            .padding(.horizontal, 7).padding(.top, 4)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var scanResultPopoverView: some View {
        if let r = eng.scanReport {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.modeTitle).font(.system(size: 13, weight: .heavy, design: .rounded))
                        Text(r.environmentLabel).font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
                    }
                    Spacer()
                    if r.appliedToHardware {
                        Text(eng.tr("✓ В RØDE NT1", "✓ Applied"))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.green.opacity(0.22)).foregroundColor(.green).cornerRadius(5)
                    }
                }
                Text(r.diagnosisDetail).font(.system(size: 10.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 8) {
                    calBox(eng.tr("Фон", "Floor"), String(format: "%.0f dB", r.noiseFloorDb), ok: r.noiseFloorDb < -46)
                    calBox(eng.tr("Пик шума", "Spike"), String(format: "%.0f dB", r.peakImpulseDb), ok: r.peakImpulseDb < -35)
                    calBox(eng.tr("Гул <150Hz", "Rumble"), String(format: "%.0f dB", r.rumbleDb), ok: r.rumbleDb < -52)
                    if let lufs = r.speechLufs {
                        calBox("LUFS", String(format: "%.1f", lufs), ok: abs(lufs - Double(eng.loudnessTarget.lufs)) <= 4.0)
                    }
                }
                Divider()
                calRow("Input Gain:", "\(Int(r.suggestedDsp.inputGainDb)) dB")
                calRow("High-Pass:", r.suggestedDsp.hpfLabel)
                calRow("Noise Gate:", "ON • Threshold \(Int(r.suggestedDsp.gateThresholdDb)) dB • Rel \(Int(r.suggestedDsp.gateReleaseMs)) ms")
                calRow("Compressor:", "ON • \(Int(r.suggestedDsp.compThresholdDb)) dB • \(String(format: "%.1f", r.suggestedDsp.compRatio)):1 • +\(String(format: "%.1f", r.suggestedDsp.compGainDb)) dB")
                calRow("Big Bottom:", r.suggestedDsp.bigBottomEnabled ? "ON (\(Int(r.suggestedDsp.bigBottomDrivePct))%)" : "OFF (\(eng.tr("чтобы не усиливать гул", "avoid low rumble")))")
                calRow("Aural Exciter:", r.suggestedDsp.exciterEnabled ? "ON (\(Int(r.suggestedDsp.exciterMixPct))%, \(Int(r.suggestedDsp.exciterTuneHz)) Hz)" : "OFF")
                Divider()
                HStack {
                    Button(eng.tr("+ Сохранить комнату", "+ Save Room")) {
                        eng.showScanPopover = false
                        eng.showSaveRoomPopover = true
                    }.buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    if !r.appliedToHardware {
                        Button(eng.tr("Применить в RØDE NT1", "Apply to RØDE NT1")) {
                            eng.applyRodeSettingsNow(r.suggestedDsp, label: r.environmentLabel)
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    } else if eng.previousRodeDsp != nil {
                        Button(eng.tr("↩ Откатить", "↩ Undo")) {
                            eng.undoLastRodeChange()
                            eng.showScanPopover = false
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .padding(14).frame(width: 440)
        } else {
            Text(eng.tr("Нажмите «Авто-шум 5с» для замера", "Click Auto-Noise 5s to scan")).padding(12)
        }
    }

    private func calBox(_ k: String, _ v: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 8.5)).foregroundColor(.secondary)
            Text(v).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(ok ? .green : .orange)
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.05)).cornerRadius(5)
    }

    private func calRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).font(.system(size: 10.5, weight: .bold)).foregroundColor(eng.theme.primary).frame(width: 96, alignment: .leading)
            Text(v).font(.system(size: 10.5)).foregroundColor(.primary)
            Spacer()
        }
    }
}

// MARK: - Live RØDE NT1 5th Gen Hardware DSP Control Drawer (Direct USB HID + CoreAudio HAL!)
struct RodeDSPDrawerView: View {
    @ObservedObject var eng: AudioAnalyzerEngine

    var body: some View {
        VStack(spacing: 6) {
            // Drawer Header
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(eng.rodeConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(eng.rodeConnected
                         ? eng.tr("RØDE NT1 5th Gen • Прямая связь USB HID + APHEX DSP", "RØDE NT1 5th Gen • Direct USB HID + APHEX DSP")
                         : eng.tr("RØDE NT1 5th Gen не подключён (проверьте USB)", "RØDE NT1 5th Gen not connected"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(eng.rodeConnected ? .primary : .orange)
                }
                Spacer()
                Button(action: { eng.syncFromRodeHardware(silent: false) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text(eng.tr("Считать с мик.", "Read Mic"))
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.mini)

                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RODE Central.app")) }) {
                    Text("RØDE Central ↗").font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
            .padding(.horizontal, 10).padding(.top, 7)

            // Mic / Vocal Tone Presets Strip (Layers over Room Noise Presets!)
            HStack(spacing: 6) {
                Text(eng.tr("МИК ПРЕСЕТЫ:", "MIC PRESETS:"))
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(eng.allMicPresets) { preset in
                            let isActive = eng.activeMicPresetId == preset.id
                            HStack(spacing: 3) {
                                Button(action: { eng.applyMicVoicePreset(preset) }) {
                                    HStack(spacing: 3.5) {
                                        Image(systemName: preset.icon).font(.system(size: 9))
                                        Text(preset.name).font(.system(size: 9.5, weight: isActive ? .bold : .semibold))
                                    }
                                    .padding(.horizontal, 7.5).padding(.vertical, 3)
                                    .background(isActive ? eng.theme.secondary.opacity(0.32) : Color.white.opacity(0.055))
                                    .foregroundColor(isActive ? Color(red: 0.86, green: 0.72, blue: 1.0) : .primary.opacity(0.85))
                                    .overlay(RoundedRectangle(cornerRadius: 4.5).stroke(isActive ? eng.theme.secondary.opacity(0.85) : Color.clear, lineWidth: 1))
                                    .cornerRadius(4.5)
                                }
                                .buttonStyle(.plain)
                                .help(preset.subtitle)

                                if !preset.isBuiltIn {
                                    Button(action: { eng.deleteCustomMicPreset(preset.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .help(eng.tr("Удалить пресет", "Delete preset"))
                                }
                            }
                        }

                        // + Save Custom Mic DSP Preset
                        Button(action: { eng.showSaveMicPresetPopover.toggle() }) {
                            HStack(spacing: 2.5) {
                                Image(systemName: "plus")
                                Text(eng.tr("Пресет", "Preset"))
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(.secondary)
                            .cornerRadius(4.5)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $eng.showSaveMicPresetPopover, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(eng.tr("Сохранить пресет микрофона", "Save RØDE Mic Preset"))
                                    .font(.system(size: 12, weight: .bold))
                                Text(eng.tr("Сохранит текущие настройки Gain, HPF, Gate, Compressor, Big Bottom и Exciter.", "Saves all current RØDE NT1 hardware DSP settings."))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                TextField(eng.tr("Напр.: Мой дикторский, Стрим, Вокал...", "e.g. Broadcast, Stream, Vocal..."), text: $eng.newMicPresetName)
                                    .textFieldStyle(.roundedBorder).frame(width: 235)
                                HStack {
                                    Spacer()
                                    Button(eng.tr("Отмена", "Cancel")) { eng.showSaveMicPresetPopover = false }.controlSize(.small)
                                    Button(eng.tr("Сохранить", "Save")) { eng.saveCurrentAsCustomMicPreset(name: eng.newMicPresetName) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                        .disabled(eng.newMicPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            .padding(12)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            // 5 Hardware DSP Channel Cards Side-by-Side
            HStack(spacing: 7) {
                // 1. Preamp Gain + HPF
                dspCard(title: "PREAMP & HPF", enabled: .constant(true), showToggle: false) {
                    dspSlider(
                        label: "Gain",
                        valStr: String(format: "%.0f dB", eng.rodeDsp.inputGainDb),
                        value: Binding(get: { eng.rodeDsp.inputGainDb }, set: { v in eng.updateRodeParam { $0.inputGainDb = v.rounded() } }),
                        range: 0...60
                    )
                    HStack(spacing: 3) {
                        Text("HPF").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        Spacer()
                        ForEach([(0, "OFF"), (1, "75Hz"), (2, "150Hz")], id: \.0) { (mode, lbl) in
                            Button(lbl) { eng.updateRodeParam { $0.hpfMode = mode } }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(eng.rodeDsp.hpfMode == mode ? eng.theme.primary.opacity(0.28) : Color.white.opacity(0.06))
                                .foregroundColor(eng.rodeDsp.hpfMode == mode ? eng.theme.primary : .secondary)
                                .cornerRadius(4)
                                .buttonStyle(.plain)
                        }
                    }
                }

                // 2. Noise Gate
                dspCard(title: "NOISE GATE", enabled: Binding(get: { eng.rodeDsp.gateEnabled }, set: { v in eng.updateRodeParam { $0.gateEnabled = v } })) {
                    dspSlider(
                        label: "Thresh",
                        valStr: String(format: "%.0f dB", eng.rodeDsp.gateThresholdDb),
                        value: Binding(get: { eng.rodeDsp.gateThresholdDb }, set: { v in eng.updateRodeParam { $0.gateThresholdDb = v.rounded() } }),
                        range: -70...(-15)
                    )
                    dspSlider(
                        label: "Release",
                        valStr: String(format: "%.0f ms", eng.rodeDsp.gateReleaseMs),
                        value: Binding(get: { eng.rodeDsp.gateReleaseMs }, set: { v in eng.updateRodeParam { $0.gateReleaseMs = (v / 10).rounded() * 10 } }),
                        range: 50...450
                    )
                }

                // 3. Compressor
                dspCard(title: "COMPRESSOR", enabled: Binding(get: { eng.rodeDsp.compEnabled }, set: { v in eng.updateRodeParam { $0.compEnabled = v } })) {
                    dspSlider(
                        label: "Thresh",
                        valStr: String(format: "%.0f dB", eng.rodeDsp.compThresholdDb),
                        value: Binding(get: { eng.rodeDsp.compThresholdDb }, set: { v in eng.updateRodeParam { $0.compThresholdDb = v.rounded() } }),
                        range: -50...(-5)
                    )
                    VStack(spacing: 1.5) {
                        HStack(spacing: 3) {
                            Text("Ratio").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(String(format: "%.1f:1", eng.rodeDsp.compRatio)).font(.system(size: 9, weight: .bold, design: .monospaced))
                            Spacer()
                            Button("−") { eng.updateRodeParam { $0.compGainDb = max(0, (($0.compGainDb - 0.5) * 2).rounded() / 2) } }
                                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(Color.white.opacity(0.08)).cornerRadius(3)
                            Text(String(format: "+%.1f", eng.rodeDsp.compGainDb)).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(eng.theme.primary)
                            Button("+") { eng.updateRodeParam { $0.compGainDb = min(9, (($0.compGainDb + 0.5) * 2).rounded() / 2) } }
                                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(Color.white.opacity(0.08)).cornerRadius(3)
                        }
                        Slider(value: Binding(get: { eng.rodeDsp.compRatio }, set: { v in eng.updateRodeParam { $0.compRatio = (v * 10).rounded() / 10 } }), in: 1.5...4.5).controlSize(.mini)
                    }
                }

                // 4. APHEX Big Bottom
                dspCard(title: "BIG BOTTOM", enabled: Binding(get: { eng.rodeDsp.bigBottomEnabled }, set: { v in eng.updateRodeParam { $0.bigBottomEnabled = v } })) {
                    dspSlider(
                        label: "Drive",
                        valStr: String(format: "%.0f%%", eng.rodeDsp.bigBottomDrivePct),
                        value: Binding(get: { eng.rodeDsp.bigBottomDrivePct }, set: { v in eng.updateRodeParam { $0.bigBottomDrivePct = v.rounded() } }),
                        range: 0...100
                    )
                    dspSlider(
                        label: "Tune",
                        valStr: String(format: "%.0f Hz", eng.rodeDsp.bigBottomTuneHz),
                        value: Binding(get: { eng.rodeDsp.bigBottomTuneHz }, set: { v in eng.updateRodeParam { $0.bigBottomTuneHz = v.rounded() } }),
                        range: 60...240
                    )
                }

                // 5. APHEX Aural Exciter
                dspCard(title: "AURAL EXCITER", enabled: Binding(get: { eng.rodeDsp.exciterEnabled }, set: { v in eng.updateRodeParam { $0.exciterEnabled = v } })) {
                    dspSlider(
                        label: "Mix",
                        valStr: String(format: "%.0f%%", eng.rodeDsp.exciterMixPct),
                        value: Binding(get: { eng.rodeDsp.exciterMixPct }, set: { v in eng.updateRodeParam { $0.exciterMixPct = v.rounded() } }),
                        range: 0...100
                    )
                    dspSlider(
                        label: "Tune",
                        valStr: String(format: "%.1f kHz", eng.rodeDsp.exciterTuneHz / 1000.0),
                        value: Binding(get: { eng.rodeDsp.exciterTuneHz }, set: { v in eng.updateRodeParam { $0.exciterTuneHz = (v / 100).rounded() * 100 } }),
                        range: 600...5000
                    )
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 9)
        }
        .background(Color.black.opacity(0.32))
    }

    private func dspCard<Content: View>(title: String, enabled: Binding<Bool>, showToggle: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(enabled.wrappedValue ? eng.theme.primary : .secondary)
                Spacer()
                if showToggle {
                    Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            content()
                .opacity(enabled.wrappedValue ? 1.0 : 0.42)
                .disabled(!enabled.wrappedValue)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.045))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        .cornerRadius(7)
    }

    private func dspSlider(label: String, valStr: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 1.5) {
            HStack {
                Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(valStr).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.primary)
            }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
}

// MARK: - 1. Multi-Band Waveform Canvas
struct MultiBandWaveformCanvas: View {
    let slices: [ColoredWaveSlice]
    var body: some View {
        Canvas { ctx, size in
            let w = size.width; let h = size.height; let midY = h * 0.54
            for frac in [0.24, 0.54, 0.84] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h * frac)); p.addLine(to: CGPoint(x: w, y: h * frac))
                ctx.stroke(p, with: .color(Color.white.opacity(frac == 0.54 ? 0.12 : 0.04)), lineWidth: 0.6)
            }
            let count = slices.count; guard count > 0 else { return }
            let dx = w / CGFloat(count); let barW = max(1.0, dx * 0.86)
            for i in 0..<count {
                let s = slices[i]
                let amp = max(1.0, CGFloat(s.amplitude) * (h * 0.42))
                let rect = CGRect(x: CGFloat(i) * dx, y: midY - amp, width: barW, height: amp * 2.0)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.7), with: .color(s.color.opacity(0.92)))
            }
        }
    }
}

// MARK: - 2. Pitch-Locked Oscilloscope Canvas
struct OscilloscopeCanvas: View {
    let samples: [Float]; let theme: MeterTheme
    var body: some View {
        Canvas { ctx, size in
            let w = size.width; let h = size.height; let midY = h * 0.54
            var cLine = Path()
            cLine.move(to: CGPoint(x: 0, y: midY)); cLine.addLine(to: CGPoint(x: w, y: midY))
            ctx.stroke(cLine, with: .color(Color.white.opacity(0.08)), lineWidth: 0.6)
            guard samples.count > 1 else { return }
            let dx = w / CGFloat(samples.count - 1)
            var path = Path()
            for i in 0..<samples.count {
                let y = midY - CGFloat(max(-1, min(1, samples[i] * 1.45))) * (h * 0.40)
                if i == 0 { path.move(to: CGPoint(x: 0, y: y)) }
                else { path.addLine(to: CGPoint(x: CGFloat(i) * dx, y: y)) }
            }
            ctx.stroke(path, with: .color(theme.primary.opacity(0.32)), lineWidth: 4.0)
            ctx.stroke(path, with: .color(theme.primary), lineWidth: 1.5)
        }
    }
}

// MARK: - 3. FabFilter Pro-Q 4 + TDR Prism Spectrum Curve Canvas
struct FabFilterSpectrumCanvas: View {
    let curve: [Float]; let peaks: [Float]; let frozen: [Float]?
    let theme: MeterTheme; let showTargetCurve: Bool; let showVocalZones: Bool

    private func buildSmoothPath(values: [Float], w: CGFloat, h: CGFloat, topPad: CGFloat) -> Path {
        var path = Path(); let n = values.count; guard n > 1 else { return path }
        let usableH = h - topPad; let dx = w / CGFloat(n - 1)
        var pts: [CGPoint] = []; pts.reserveCapacity(n)
        for i in 0..<n { pts.append(CGPoint(x: CGFloat(i) * dx, y: topPad + usableH * (1.0 - CGFloat(values[i])))) }
        path.move(to: pts[0])
        for i in 1..<n {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) * 0.5, y: (pts[i - 1].y + pts[i].y) * 0.5)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[n - 1])
        return path
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width; let h = size.height - 13; let topPad: CGFloat = 15
            if showVocalZones {
                let zones: [(CGFloat, CGFloat, Color)] = [
                    (0.00, 0.25, Color.red.opacity(0.06)),    // HPF 25-150Hz
                    (0.25, 0.40, Color.orange.opacity(0.055)),// Mud 150-350Hz
                    (0.65, 0.79, Color.green.opacity(0.06)),  // Presence 2-5kHz
                    (0.81, 0.90, Color.yellow.opacity(0.055)) // Sibilance 5.5-9kHz
                ]
                for (x0, x1, col) in zones {
                    ctx.fill(Path(CGRect(x: w * x0, y: topPad, width: w * (x1 - x0), height: h - topPad)), with: .color(col))
                }
            }
            for frac in [0.25, 0.5, 0.75] {
                var g = Path(); let y = topPad + (h - topPad) * frac
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(g, with: .color(Color.white.opacity(0.055)), lineWidth: 0.6)
            }
            let ticks: [(String, CGFloat)] = [("50", 0.10), ("150", 0.27), ("500", 0.45), ("1k", 0.55), ("3k", 0.71), ("8k", 0.86), ("16k", 0.96)]
            for (lbl, pos) in ticks {
                var vLine = Path()
                vLine.move(to: CGPoint(x: w * pos, y: topPad)); vLine.addLine(to: CGPoint(x: w * pos, y: h))
                ctx.stroke(vLine, with: .color(Color.white.opacity(0.045)), lineWidth: 0.6)
                ctx.draw(Text(lbl).font(.system(size: 7.5, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.40)), at: CGPoint(x: w * pos, y: h + 6.5))
            }
            if showTargetCurve {
                let tp = buildSmoothPath(values: AudioAnalyzerEngine.vocalTargetCurve, w: w, h: h, topPad: topPad)
                ctx.stroke(tp, with: .color(Color.yellow.opacity(0.30)), style: StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
            }
            ctx.stroke(buildSmoothPath(values: peaks, w: w, h: h, topPad: topPad), with: .color(theme.secondary.opacity(0.45)), lineWidth: 1.0)
            let mainStroke = buildSmoothPath(values: frozen ?? curve, w: w, h: h, topPad: topPad)
            var fillPath = mainStroke
            fillPath.addLine(to: CGPoint(x: w, y: h)); fillPath.addLine(to: CGPoint(x: 0, y: h)); fillPath.closeSubpath()
            ctx.fill(fillPath, with: .linearGradient(Gradient(colors: [theme.primary.opacity(0.42), theme.secondary.opacity(0.14), theme.primary.opacity(0.01)]), startPoint: CGPoint(x: 0, y: topPad), endPoint: CGPoint(x: 0, y: h)))
            ctx.stroke(mainStroke, with: .color(frozen != nil ? .cyan : theme.primary), lineWidth: 1.7)
        }
    }
}

// MARK: - 4. Mel Spectrogram Waterfall Canvas
struct SpectrogramCanvas: View {
    let grid: [[Float]]; let theme: MeterTheme
    var body: some View {
        Canvas { ctx, size in
            let cols = grid.count; guard cols > 0 else { return }
            let rows = grid[0].count; let cw = size.width / CGFloat(cols); let rh = size.height / CGFloat(rows)
            for c in 0..<cols {
                let colData = grid[c]; let x = CGFloat(c) * cw
                for r in 0..<rows {
                    let v = colData[r]; if v < 0.04 { continue }
                    ctx.fill(Path(CGRect(x: x, y: size.height - CGFloat(r + 1) * rh, width: cw + 0.6, height: rh + 0.6)), with: .color(theme.heatColor(v)))
                }
            }
        }
    }
}

// MARK: - 5. Stereometer Canvas
struct StereometerCanvas: View {
    let points: [(Float, Float)]; let correlation: Float; let theme: MeterTheme
    var body: some View {
        Canvas { ctx, size in
            let w = size.width; let h = size.height - 14
            let cx = w * 0.5; let cy = h * 0.54; let rad = min(w, h) * 0.40
            for angle in [0.0, .pi / 4.0, .pi / 2.0, 3.0 * .pi / 4.0] {
                var p = Path(); let dx = CGFloat(cos(angle)) * rad; let dy = CGFloat(sin(angle)) * rad
                p.move(to: CGPoint(x: cx - dx, y: cy - dy)); p.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
                ctx.stroke(p, with: .color(Color.white.opacity(0.07)), lineWidth: 0.6)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)), with: .color(Color.white.opacity(0.08)), lineWidth: 0.7)
            if points.count > 1 {
                var trace = Path()
                for i in 0..<points.count {
                    let px = cx + CGFloat(max(-1, min(1, points[i].0 * 1.6))) * rad
                    let py = cy - CGFloat(max(-1, min(1, points[i].1 * 1.6))) * rad
                    if i == 0 { trace.move(to: CGPoint(x: px, y: py)) } else { trace.addLine(to: CGPoint(x: px, y: py)) }
                }
                ctx.stroke(trace, with: .color(theme.primary.opacity(0.82)), lineWidth: 1.3)
            }
            let barY = size.height - 9
            ctx.fill(Path(roundedRect: CGRect(x: 8, y: barY, width: w - 16, height: 4), cornerRadius: 2), with: .color(Color.white.opacity(0.08)))
            let markerX = 8 + (w - 16) * CGFloat((correlation + 1.0) * 0.5)
            ctx.fill(Path(roundedRect: CGRect(x: min(w * 0.5, markerX), y: barY, width: abs(markerX - w * 0.5), height: 4), cornerRadius: 2), with: .color((correlation >= 0 ? Color.green : Color.red).opacity(0.85)))
            ctx.fill(Path(CGRect(x: markerX - 1, y: barY - 1, width: 2, height: 6)), with: .color(.white))
        }
    }
}

// MARK: - 6. Youlean Loudness Panel
struct YouleanLoudnessCell: View {
    @ObservedObject var eng: AudioAnalyzerEngine
    private func normLufs(_ v: Float) -> CGFloat { CGFloat(max(0, min(1, (v + 48.0) / 48.0))) }
    private func normDb(_ v: Float) -> CGFloat   { CGFloat(max(0, min(1, (v + 60.0) / 60.0))) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(eng.loudnessTarget.shortLabel).font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundColor(eng.theme.primary)
                    Spacer()
                    Button(action: { eng.resetLoudnessStats() }) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 8.5, weight: .bold)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                youleanRow("INT",   String(format: "%.1f", eng.integratedLufs), color: abs(eng.integratedLufs - eng.loudnessTarget.lufs) <= 3.0 ? .green : eng.theme.primary)
                youleanRow("SHORT", String(format: "%.1f", eng.shortTermLufs), color: .primary.opacity(0.9))
                youleanRow("PEAK",  String(format: "%.1f", eng.peakHoldDb), color: eng.isClipping ? .red : .yellow)
                youleanRow("PLR",   String(format: "%.1f", eng.dynamicsPlrDb), color: (eng.dynamicsPlrDb >= 7.0 && eng.dynamicsPlrDb <= 16.0) ? .green : .orange)
                youleanRow("FLOOR", String(format: "%.0f", eng.noiseFloorDb), color: eng.noiseFloorDb > -42 ? .orange : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: 98)

            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 0.6)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let w = size.width; let h = size.height; let target = eng.loudnessTarget.lufs
                    let targetY = h * (1.0 - normLufs(target))
                    let bandTop = h * (1.0 - normLufs(target + 2.5))
                    let bandBot = h * (1.0 - normLufs(target - 2.5))
                    ctx.fill(Path(CGRect(x: 0, y: bandTop, width: w, height: max(2, bandBot - bandTop))), with: .color(Color.green.opacity(0.10)))
                    var tLine = Path(); tLine.move(to: CGPoint(x: 0, y: targetY)); tLine.addLine(to: CGPoint(x: w, y: targetY))
                    ctx.stroke(tLine, with: .color(Color.green.opacity(0.55)), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))

                    let hist = eng.lufsHistory; let n = hist.count; guard n > 1 else { return }
                    let dx = w / CGFloat(n - 1)
                    for i in 0..<n {
                        let v = hist[i]; if v <= -47.5 { continue }
                        let x = CGFloat(i) * dx; let y = h * (1.0 - normLufs(v))
                        let col: Color = v > target + 2.5 ? .red : (v >= target - 3.0 ? .green : eng.theme.primary)
                        ctx.fill(Path(CGRect(x: x, y: y, width: max(1.0, dx), height: h - y)), with: .color(col.opacity(0.32)))
                        ctx.fill(Path(CGRect(x: x, y: y, width: max(1.0, dx), height: 1.6)), with: .color(col))
                    }
                }
                Text("LUFS HISTORY").font(.system(size: 7.5, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.42)).padding(.leading, 6).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GeometryReader { geo in
                let h = geo.size.height - 10
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .bottom, endPoint: .top))
                        .frame(height: max(2, h * normDb(eng.peakDb)))
                    Rectangle().fill(eng.isClipping ? Color.red : Color.white).frame(height: 1.8).offset(y: -(h * normDb(eng.peakHoldDb) - 1))
                }
                .padding(.vertical, 5)
            }
            .frame(width: 11).padding(.trailing, 6)
        }
    }

    private func youleanRow(_ k: String, _ v: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(k).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(.secondary)
            Spacer()
            Text(v).font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundColor(color)
        }
    }
}

// MARK: - AppDelegate (Standard Titled macOS Window + Full-Screen Overlay + Menu Bar)
final class MetersAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: FloatingMetersPanel!
    var statusItem: NSStatusItem!
    let eng = AudioAnalyzerEngine()

    private func idealSize(for mode: MeterLayoutMode, drawer: Bool) -> NSSize {
        let baseH: CGFloat = mode == .quad ? 400 : 215
        let extra: CGFloat = drawer ? 178 : 0
        let w: CGFloat = mode == .quad ? 995 : 1080
        return NSSize(width: w, height: baseH + extra)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let isShotBar  = CommandLine.arguments.contains("--screenshot")
        let isShotQuad = CommandLine.arguments.contains("--screenshot-quad")

        let defaultFrame: NSRect
        if isShotBar {
            defaultFrame = NSRect(x: 100, y: 100, width: 1080, height: 225)
        } else if isShotQuad {
            defaultFrame = NSRect(x: 100, y: 100, width: 995, height: 585)
        } else if let saved = eng.savedWindowFrame,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            defaultFrame = saved
        } else if let scr = NSScreen.main?.visibleFrame {
            let sz = idealSize(for: eng.layoutMode, drawer: eng.showRodeDrawer)
            let w = min(sz.width, scr.width - 40)
            let h = min(sz.height, scr.height - 60)
            defaultFrame = NSRect(x: scr.midX - w / 2, y: scr.midY - h / 2, width: w, height: h)
        } else {
            defaultFrame = NSRect(x: 120, y: 120, width: 980, height: 550)
        }

        // STANDARD NATIVE MACOS WINDOW (NOT Frameless — real dark titlebar, easy drag & resize!)
        window = FloatingMetersPanel(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Mr. Audio Meters — RØDE NT1 5th Gen Studio"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 195)
        window.maxSize = NSSize(width: 2400, height: 1100)
        window.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.050, blue: 0.068, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.worksWhenModal = true
        window.alphaValue = CGFloat(eng.windowOpacity)
        window.contentView = NSHostingView(rootView: AudioMetersView(eng: eng))

        eng.onAlwaysOnTopChanged = { [weak self] enabled in self?.applyAlwaysOnTop(enabled) }
        eng.onOpacityChanged = { [weak self] val in self?.window?.alphaValue = CGFloat(val) }
        eng.onLayoutChanged = { [weak self] mode, drawer in self?.animateResize(mode: mode, drawer: drawer) }
        applyAlwaysOnTop(eng.alwaysOnTop)

        if isShotBar || isShotQuad {
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let win = self?.window, let content = win.contentView else { NSApp.terminate(nil); return }
                let targetView = content.superview ?? content
                targetView.layoutSubtreeIfNeeded()
                if let rep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) {
                    targetView.cacheDisplay(in: targetView.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let fname = isShotQuad ? "audio_meters_quad.png" : "audio_meters_bar.png"
                        let out = "\(NSHomeDirectory())/Desktop/PixelProCam/assets/screenshots/\(fname)"
                        try? png.write(to: URL(fileURLWithPath: out))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupMenuBar()
    }

    func animateResize(mode: MeterLayoutMode, drawer: Bool) {
        guard let win = window, let scr = NSScreen.main?.visibleFrame else { return }
        let cur = win.frame
        let target = idealSize(for: mode, drawer: drawer)
        let newW = min(target.width, scr.width - 32)
        let newH = min(target.height, scr.height - 40)
        let newX = max(scr.minX + 10, min(scr.maxX - newW - 10, cur.midX - newW / 2))
        let newY = max(scr.minY + 10, min(scr.maxY - newH - 10, cur.maxY - newH))
        win.setFrame(NSRect(x: newX, y: newY, width: newW, height: newH), display: true, animate: true)
    }

    func applyAlwaysOnTop(_ enabled: Bool) {
        guard let panel = window else { return }
        if enabled {
            panel.styleMask.insert(.nonactivatingPanel)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
        } else {
            panel.styleMask.remove(.nonactivatingPanel)
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.collectionBehavior = [.fullScreenAuxiliary]
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "waveform.path.ecg.rectangle", accessibilityDescription: "Mr. Audio Meters")
            btn.imagePosition = .imageLeading
            btn.title = " Meters"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let showItem = NSMenuItem(title: eng.tr("Открыть Mr. Audio Meters", "Show Mr. Audio Meters"), action: #selector(showWin), keyEquivalent: "")
        showItem.target = self; menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())
        let scanItem = NSMenuItem(title: eng.tr("⚡ Авто-подбор по шуму (5 сек)", "⚡ 5s Room Noise Auto-Scan"), action: #selector(runNoiseScan), keyEquivalent: "")
        scanItem.target = self; menu.addItem(scanItem)

        for p in eng.allProfiles {
            let item = NSMenuItem(title: (eng.activeProfileId == p.id ? "✓ " : "   ") + p.name, action: #selector(pickProfile(_:)), keyEquivalent: "")
            item.representedObject = p.id
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let micHdr = NSMenuItem(title: eng.tr("🎙 Пресеты микрофона (RØDE)", "🎙 Mic Voice Presets (RØDE)"), action: nil, keyEquivalent: "")
        micHdr.isEnabled = false
        menu.addItem(micHdr)
        for mp in eng.allMicPresets {
            let item = NSMenuItem(title: (eng.activeMicPresetId == mp.id ? "✓ " : "   ") + mp.name, action: #selector(pickMicPreset(_:)), keyEquivalent: "")
            item.representedObject = mp.id
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let pinItem = NSMenuItem(title: eng.tr("📌 Поверх всех окон (Full-Screen)", "📌 Always on Top"), action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self; pinItem.state = eng.alwaysOnTop ? .on : .off; menu.addItem(pinItem)

        let clipItem = NSMenuItem(title: eng.tr("💾 Сохранить последние 10с WAV", "💾 Save Last 10s WAV"), action: #selector(saveClip), keyEquivalent: "")
        clipItem.target = self; menu.addItem(clipItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: eng.tr("🚪 Выйти", "🚪 Quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
    }

    func windowDidMove(_ notification: Notification)   { eng.savedWindowFrame = window.frame; eng.scheduleSaveConfig() }
    func windowDidResize(_ notification: Notification) { eng.savedWindowFrame = window.frame; eng.scheduleSaveConfig() }
    func applicationWillTerminate(_ notification: Notification) { eng.saveConfigNow(); eng.stopEngine() }

    @objc func showWin() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func runNoiseScan() { showWin(); eng.startNoiseAutoScan(fullWithVoice: false) }
    @objc func pickProfile(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let p = eng.allProfiles.first(where: { $0.id == id }) {
            eng.applyRoomProfile(p)
        }
    }
    @objc func pickMicPreset(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let mp = eng.allMicPresets.first(where: { $0.id == id }) {
            eng.applyMicVoicePreset(mp)
        }
    }
    @objc func togglePin() { eng.setAlwaysOnTop(!eng.alwaysOnTop) }
    @objc func saveClip()  { eng.saveLast10SecondsClip() }
    @objc func quitApp()   { eng.saveConfigNow(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MetersAppDelegate()
app.delegate = delegate
app.run()

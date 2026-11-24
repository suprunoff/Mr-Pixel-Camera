import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import Foundation

// MARK: - CoreAudio Input Device Discovery
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

    private static func inputChannelCount(for devId: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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
    case fabGold     = "FabFilter"
    case magma       = "Magma"
    case tdrEmerald  = "TDR Prism"

    var primary: Color {
        switch self {
        case .miniCyber:  return Color(red: 0.20, green: 0.86, blue: 1.00)
        case .fabGold:    return Color(red: 0.99, green: 0.78, blue: 0.22)
        case .magma:      return Color(red: 1.00, green: 0.42, blue: 0.24)
        case .tdrEmerald: return Color(red: 0.20, green: 0.94, blue: 0.62)
        }
    }

    var secondary: Color {
        switch self {
        case .miniCyber:  return Color(red: 0.56, green: 0.38, blue: 1.00)
        case .fabGold:    return Color(red: 0.95, green: 0.45, blue: 0.16)
        case .magma:      return Color(red: 0.98, green: 0.84, blue: 0.26)
        case .tdrEmerald: return Color(red: 0.16, green: 0.68, blue: 0.95)
        }
    }

    var bgDark: Color {
        switch self {
        case .miniCyber:  return Color(red: 0.040, green: 0.044, blue: 0.062)
        case .fabGold:    return Color(red: 0.052, green: 0.050, blue: 0.058)
        case .magma:      return Color(red: 0.048, green: 0.036, blue: 0.052)
        case .tdrEmerald: return Color(red: 0.038, green: 0.052, blue: 0.055)
        }
    }

    func heatColor(_ norm: Float) -> Color {
        let v = max(0, min(1, Double(norm)))
        switch self {
        case .miniCyber:
            if v < 0.35 { let t = v / 0.35; return Color(red: 0.04 + t * 0.10, green: 0.06 + t * 0.24, blue: 0.16 + t * 0.48) }
            if v < 0.72 { let t = (v - 0.35) / 0.37; return Color(red: 0.14 + t * 0.12, green: 0.30 + t * 0.60, blue: 0.64 + t * 0.35) }
            let t = (v - 0.72) / 0.28
            return Color(red: 0.26 + t * 0.74, green: 0.90 + t * 0.10, blue: 0.99)
        case .fabGold:
            if v < 0.38 { let t = v / 0.38; return Color(red: 0.12 + t * 0.42, green: 0.06 + t * 0.16, blue: 0.04 + t * 0.05) }
            if v < 0.75 { let t = (v - 0.38) / 0.37; return Color(red: 0.54 + t * 0.44, green: 0.22 + t * 0.50, blue: 0.09 + t * 0.10) }
            let t = (v - 0.75) / 0.25
            return Color(red: 0.98 + t * 0.02, green: 0.72 + t * 0.26, blue: 0.19 + t * 0.65)
        case .magma:
            if v < 0.35 { let t = v / 0.35; return Color(red: t * 0.46, green: t * 0.06, blue: t * 0.52 + 0.05) }
            if v < 0.72 { let t = (v - 0.35) / 0.37; return Color(red: 0.46 + t * 0.53, green: 0.06 + t * 0.45, blue: 0.57 - t * 0.40) }
            let t = (v - 0.72) / 0.28
            return Color(red: 1.0, green: 0.51 + t * 0.47, blue: 0.17 + t * 0.73)
        case .tdrEmerald:
            if v < 0.4 { let t = v / 0.4; return Color(red: 0.02, green: t * 0.36 + 0.05, blue: t * 0.28 + 0.07) }
            if v < 0.78 { let t = (v - 0.4) / 0.38; return Color(red: t * 0.22, green: 0.41 + t * 0.52, blue: 0.35 + t * 0.25) }
            let t = (v - 0.78) / 0.22
            return Color(red: 0.22 + t * 0.76, green: 0.93 + t * 0.07, blue: 0.60 + t * 0.36)
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

// MARK: - Layout Modes (MiniMeters Horizontal Bar vs Quad Studio Grid)
enum MeterLayoutMode: String, CaseIterable {
    case bar  = "Bar"
    case quad = "Quad"
}

// MARK: - Multi-Band Colored Waveform Slice (MiniMeters Iconic Signature!)
struct ColoredWaveSlice {
    var amplitude: Float  // 0...1 peak envelope
    var lowWeight: Float  // 0...1 bass proportion (red/amber)
    var midWeight: Float  // 0...1 vocal mids proportion (cyan/emerald)
    var highWeight: Float // 0...1 air/sibilance proportion (violet/white)

    var color: Color {
        let total = max(0.001, lowWeight + midWeight + highWeight)
        let l = pow(Double(lowWeight / total), 0.75)
        let m = pow(Double(midWeight / total), 0.75)
        let h = pow(Double(highWeight / total), 0.75)
        let norm = max(0.001, l + m + h)
        let ln = l / norm; let mn = m / norm; let hn = h / norm
        // MiniMeters vibrant Multi-Band palette: Bass = Coral-Red, Mids = Electric Cyan, Highs = Neon Violet
        let r = min(1.0, ln * 1.00 + mn * 0.08 + hn * 0.85)
        let g = min(1.0, ln * 0.28 + mn * 0.92 + hn * 0.42)
        let b = min(1.0, ln * 0.22 + mn * 1.00 + hn * 1.00)
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Persistent Settings
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
    var windowOpacity: Double
    var lang: String
    var windowX: Double?
    var windowY: Double?
    var windowW: Double?
    var windowH: Double?
}

// MARK: - RØDE Central Tailored Calibration Report
struct RodeCalibrationReport {
    let noiseFloorDb: Double
    let speechLufs: Double
    let peakDb: Double
    let dynamicsDb: Double
    let subBassEnergyDb: Double
    let mudEnergyDb: Double
    let presenceEnergyDb: Double
    let sibilanceEnergyDb: Double
    let recommendedHpf: String
    let recommendedGateDb: Int
    let recommendedGainAdvice: String
    let recommendedCompressor: String
    let recommendedBigBottom: String
    let recommendedExciter: String
}

// MARK: - Full-Screen Overlay Floating NSPanel
final class FloatingMetersPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Flagship Real-Time DSP Audio Engine (vDSP + K-Weighted LUFS + Multi-Band + 10s Ring Recorder)
final class AudioAnalyzerEngine: ObservableObject {
    // Device & Runtime Status
    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String = ""
    @Published var activeDeviceName: String = "RØDE NT1 5th Gen"
    @Published var activeSampleRate: Double = 48000
    @Published var activeChannels: Int = 1
    @Published var isRunning: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var toastMessage: String = ""

    // Visual & Competitor Controls
    @Published var theme: MeterTheme = .miniCyber
    @Published var layoutMode: MeterLayoutMode = .bar
    @Published var loudnessTarget: LoudnessTarget = .podcast
    @Published var spectrumTilt: Double = 4.5 // 0.0 Flat, 3.0 Pink (TDR), 4.5 Vocal (FabFilter Pro-Q)
    @Published var alwaysOnTop: Bool = true
    @Published var isFrozen: Bool = false // TDR Prism / FabFilter Freeze!
    @Published var showWaveform: Bool = true
    @Published var showOscilloscope: Bool = false
    @Published var showSpectrum: Bool = true
    @Published var showSpectrogram: Bool = true
    @Published var showLoudness: Bool = true
    @Published var showStereo: Bool = false
    @Published var showTargetCurve: Bool = true
    @Published var showVocalZones: Bool = true
    @Published var windowOpacity: Double = 0.96
    @Published var lang: String = {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.lowercased().hasPrefix("ru") ? "ru" : "en"
    }()

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

    // Numeric Studio Readouts (Youlean + FabFilter)
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

    // 10s RØDE Calibrator
    @Published var isCalibrating: Bool = false
    @Published var calibrationCountdown: Int = 0
    @Published var calibrationPhase: String = ""
    @Published var calibrationReport: RodeCalibrationReport? = nil
    @Published var showCalibrationPopover: Bool = false

    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onOpacityChanged: ((Double) -> Void)?
    var onLayoutModeChanged: ((MeterLayoutMode) -> Void)?
    var savedWindowFrame: NSRect? = nil

    // Audio Engine & DSP Internals
    private var audioEngine: AVAudioEngine?
    private let fftSize = 2048
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var ringL: [Float] = []
    private var ringR: [Float] = []
    private var ringWriteIdx: Int = 0
    private var ringLock = os_unfair_lock()

    // 10-Second Rolling Clip Buffer (MiniMeters Killer Feature: Instant 10s WAV Capture!)
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
    private var momentaryRing: [Float] = Array(repeating: 1e-10, count: 24)  // 400ms @ 60Hz
    private var momentaryIdx: Int = 0
    private var shortTermRing: [Float] = Array(repeating: 1e-10, count: 180) // 3s @ 60Hz
    private var shortTermIdx: Int = 0
    private var integratedEnergySum: Double = 0
    private var integratedBlockCount: Int = 0
    private var peakHoldTimer: Int = 0
    private var clipHoldTimer: Int = 0
    private var noiseFloorEstimate: Float = -55.0

    // Calibrator
    private var calTimer: Timer?
    private var calStep: Int = 0
    private var calQuietRms: [Float] = []
    private var calSpeechLufs: [Float] = []
    private var calSpeechPeakMax: Float = -60.0
    private var calSub: [Float] = []
    private var calMud: [Float] = []
    private var calPres: [Float] = []
    private var calSib: [Float] = []

    // Log Frequency Tables
    private var specBinRanges: [(Int, Int)] = []
    private var specBandCenterHz: [Float] = []
    private var waterfallBinRanges: [(Int, Int)] = []

    // Ideal Broadcast Vocal Target Curve (Normalized 0...1 across 64 log bands, @ +4.5 dB/oct tilt)
    static let vocalTargetCurve: [Float] = {
        var pts = [Float](repeating: 0, count: spectrumBins)
        for i in 0..<spectrumBins {
            let x = Float(i) / Float(spectrumBins - 1) // 0=25Hz .. 1=20kHz
            // Smooth HPF roll-off below 80Hz, warm body 120-260Hz, slight dip 450Hz, rich presence 2-5kHz, gentle air roll-off >12kHz
            let hpfRoll  = 1.0 / (1.0 + exp(-(x - 0.14) * 18.0))
            let body     = 0.62 * exp(-pow((x - 0.27) / 0.16, 2))
            let midFill  = 0.44 * exp(-pow((x - 0.48) / 0.22, 2))
            let presence = 0.56 * exp(-pow((x - 0.72) / 0.16, 2))
            let airRoll  = 1.0 - 0.45 / (1.0 + exp(-(x - 0.88) * 14.0))
            pts[i] = min(0.85, max(0.08, (0.20 + body + midFill + presence) * hpfRoll * airRoll))
        }
        return pts
    }()

    private let cfgKey = "mraudiometers_pro_config_v2"
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

        if !CommandLine.arguments.contains("--screenshot") && !CommandLine.arguments.contains("--screenshot-quad") {
            requestMicAndStart()
        } else {
            if CommandLine.arguments.contains("--screenshot-quad") {
                layoutMode = .quad
            }
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
        windowOpacity = max(0.55, min(1.0, c.windowOpacity))
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

    // MARK: - Actions
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
        onLayoutModeChanged?(mode)
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
        if isFrozen {
            frozenSpectrum = spectrumCurve
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            if self?.toastMessage == msg { self?.toastMessage = "" }
        }
    }

    // MiniMeters Killer Feature: Instantly save the last 10 seconds of audio as a 48kHz WAV!
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
        for i in 0..<count {
            pcm[i] = clipRing[(idx + i) % clipBufferCapacity]
        }
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
                pcm.withUnsafeBufferPointer { src in
                    ch.update(from: src.baseAddress!, count: count)
                }
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

    func restartEngine() {
        stopEngine()
        startEngine()
    }

    func stopEngine() {
        displayTimer?.invalidate()
        displayTimer = nil
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
                let l = c0[i]
                let r = c1[i]
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

        // Mel-like perceptual scale for Spectrogram (MiniMeters signature!)
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
        let oct = (midi / 12) - 1
        return "\(name)\(oct)"
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

        // 1. Peak, RMS, Stereo Correlation, and K-Weighted LUFS on latest ~16.6ms (800 samples)
        let recentCount = 800
        let recentOffset = fftSize - recentCount
        var maxAbs: Float = 0
        var sumSq: Float = 0
        var kwSumSq: Float = 0
        var sumLR: Float = 0; var sumLL: Float = 0; var sumRR: Float = 0

        for i in recentOffset..<fftSize {
            let m = mono[i]
            let l = samplesL[i]; let r = samplesR[i]
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
        momentaryRing[momentaryIdx] = frameKwPwr
        momentaryIdx = (momentaryIdx + 1) % momentaryRing.count
        shortTermRing[shortTermIdx] = frameKwPwr
        shortTermIdx = (shortTermIdx + 1) % shortTermRing.count

        let momMean = momentaryRing.reduce(0, +) / Float(momentaryRing.count)
        let stMean  = shortTermRing.reduce(0, +) / Float(shortTermRing.count)
        let momLufs = max(-70.0, -0.691 + 10.0 * log10(max(momMean, 1e-10)))
        let stLufs  = max(-70.0, -0.691 + 10.0 * log10(max(stMean, 1e-10)))

        // Gated Integrated LUFS (ITU-R BS.1770 absolute gate -70 LUFS, voice gate -45 LUFS)
        if momLufs > -45.0 {
            integratedEnergySum += Double(frameKwPwr)
            integratedBlockCount += 1
        }
        let intLufs: Float = integratedBlockCount > 5
            ? max(-70.0, Float(-0.691 + 10.0 * log10(max(integratedEnergySum / Double(integratedBlockCount), 1e-10))))
            : stLufs

        // Dynamics / PLR (Peak-to-Loudness Ratio — Youlean signature metric!)
        let plr = (stLufs > -50.0) ? max(0, min(30, peakHoldDb - stLufs)) : 0

        if curRmsDb < noiseFloorEstimate {
            noiseFloorEstimate = noiseFloorEstimate * 0.92 + curRmsDb * 0.08
        } else {
            noiseFloorEstimate = noiseFloorEstimate * 0.997 + curRmsDb * 0.003
        }

        if curPeakDb >= peakHoldDb {
            peakHoldDb = curPeakDb
            peakHoldTimer = 90
        } else if peakHoldTimer > 0 {
            peakHoldTimer -= 1
        } else {
            peakHoldDb = max(curPeakDb, peakHoldDb - 0.30)
        }
        if curPeakDb > -0.8 {
            isClipping = true
            clipHoldTimer = 90
        } else if clipHoldTimer > 0 {
            clipHoldTimer -= 1
        } else {
            isClipping = false
        }

        // 2. Pitch-Locked Zero-Crossing Oscilloscope (MiniMeters style!)
        var zeroCrossIdx = fftSize - Self.oscPointsCount * 3
        for i in (fftSize - 700)..<(fftSize - Self.oscPointsCount * 2 - 2) {
            if mono[i] <= 0 && mono[i + 1] > 0 {
                zeroCrossIdx = i
                break
            }
        }
        var newOsc = [Float](repeating: 0, count: Self.oscPointsCount)
        for i in 0..<Self.oscPointsCount {
            let idx = min(fftSize - 1, zeroCrossIdx + i * 2)
            newOsc[i] = mono[idx]
        }

        // 3. Stereo Goniometer XY points (Lissajous rotated 45 deg: M = (L+R)*0.707, S = (L-R)*0.707)
        var newXY: [(Float, Float)] = []
        newXY.reserveCapacity(Self.stereoPointsCount)
        let stepXY = recentCount / Self.stereoPointsCount
        for i in 0..<Self.stereoPointsCount {
            let idx = recentOffset + i * stepXY
            let l = samplesL[idx]; let r = samplesR[idx]
            let x = (l - r) * 0.7071 // Side (width)
            let y = (l + r) * 0.7071 // Mid (center)
            newXY.append((x, y))
        }

        // 4. Hardware Accelerate vDSP FFT (2048 pts, Hann)
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
        var domBin = 0
        var domPwr: Float = 0
        var lowE: Float = 0; var midE: Float = 0; var highE: Float = 0

        for i in 1..<halfN {
            let pwr = mags[i] / normScale
            let freq = Float(i) * binHz
            if freq >= 55 && freq <= 6000 && pwr > domPwr {
                domPwr = pwr
                domBin = i
            }
            // 3-band spectral energy for MiniMeters Frequency-Colored Waveform!
            if freq < 250 { lowE += pwr }
            else if freq < 2400 { midE += pwr }
            else { highE += pwr }

            let amp = sqrt(max(pwr, 1e-12))
            let tilt = tiltF * log2(max(freq / 300.0, 0.08))
            magDb[i] = 20.0 * log10(amp) + tilt
        }

        // Dominant frequency & note (FabFilter Pro-Q style!)
        let domHz = (curRmsDb > -48 && domBin > 0) ? Double(domBin) * Double(binHz) : 0
        let domNote = domHz > 0 ? freqToNoteName(domHz) : "—"

        // 5. Push Frequency-Colored Waveform slice (MiniMeters signature!)
        let lowW  = sqrt(lowE) * 0.9
        let midW  = sqrt(midE) * 1.4
        let highW = sqrt(highE) * 2.8
        let waveAmp = min(1.0, maxAbs * 1.35)
        var newWave = coloredWave
        newWave.removeFirst()
        newWave.append(ColoredWaveSlice(amplitude: waveAmp, lowWeight: lowW, midWeight: midW, highWeight: highW))

        // 6. 64-Band Continuous Smooth Spectrum Curve (FabFilter / TDR Prism style)
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

        // 7. Rolling Spectrogram Column
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

        // 8. Youlean Scrolling LUFS History (every 8 frames ≈ 7.5 Hz -> ~13s history window)
        lufsHistoryTick += 1
        var newLufsHist = lufsHistory
        if lufsHistoryTick >= 8 {
            lufsHistoryTick = 0
            newLufsHist.removeFirst()
            newLufsHist.append(stLufs)
        }

        // 9. Calibration sampling
        if isCalibrating {
            if calibrationPhase == "quiet" {
                calQuietRms.append(curRmsDb)
            } else if calibrationPhase == "speak" && curRmsDb > -48.0 {
                calSpeechLufs.append(momLufs)
                if curPeakDb > calSpeechPeakMax { calSpeechPeakMax = curPeakDb }
                func bandRawDb(_ f0: Float, _ f1: Float) -> Float {
                    let i0 = max(1, Int(f0 / binHz))
                    let i1 = min(halfN - 1, Int(f1 / binHz))
                    var s: Float = 0
                    for k in i0...i1 { s += mags[k] / normScale }
                    return 10.0 * log10(max(s / Float(max(1, i1 - i0 + 1)), 1e-12))
                }
                calSub.append(bandRawDb(20, 80))
                calMud.append(bandRawDb(120, 320))
                calPres.append(bandRawDb(2000, 5000))
                calSib.append(bandRawDb(5500, 9000))
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

    // MARK: - 10-Second Interactive RØDE Calibrator
    func startCalibration() {
        guard !isCalibrating else { cancelCalibration(); return }
        isCalibrating = true
        calibrationReport = nil
        showCalibrationPopover = false
        calQuietRms.removeAll(); calSpeechLufs.removeAll()
        calSub.removeAll(); calMud.removeAll(); calPres.removeAll(); calSib.removeAll()
        calSpeechPeakMax = -60.0
        calStep = 0; calibrationPhase = "quiet"; calibrationCountdown = 3

        calTimer?.invalidate()
        calTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.calStep += 1
            if self.calStep < 3 {
                self.calibrationPhase = "quiet"; self.calibrationCountdown = 3 - self.calStep
            } else if self.calStep < 10 {
                self.calibrationPhase = "speak"; self.calibrationCountdown = 10 - self.calStep
            } else {
                t.invalidate(); self.finishCalibration()
            }
        }
    }

    func cancelCalibration() {
        calTimer?.invalidate(); calTimer = nil
        isCalibrating = false; calibrationPhase = ""
    }

    private func finishCalibration() {
        isCalibrating = false; calibrationPhase = ""
        func mean(_ a: [Float], _ fb: Double) -> Double { a.isEmpty ? fb : Double(a.reduce(0, +)) / Double(a.count) }
        let avgNoise = mean(calQuietRms, Double(noiseFloorDb))
        let avgLufs  = mean(calSpeechLufs, Double(shortTermLufs))
        let pk       = Double(calSpeechPeakMax)
        let dyn      = max(0, pk - avgLufs)
        let subDb    = mean(calSub, -65); let mudDb = mean(calMud, -42)
        let presDb   = mean(calPres, -46); let sibDb = mean(calSib, -54)

        let gateDb = Int(max(-55, min(-34, (avgNoise + 6.0).rounded())))
        let hpf = (subDb > mudDb - 10.0) ? "150 Hz (\(tr("сильный гул <80Hz", "strong <80Hz rumble")))" : "75 Hz (\(tr("оптимально", "optimal")))"
        let target = Double(loudnessTarget.lufs)
        let gainAdvice: String
        if pk > -2.5 {
            gainAdvice = tr("Снизить Gain на 4–6 dB (риск клиппинга)", "Lower Gain by 4–6 dB (near clip)")
        } else if avgLufs < target - 5.0 {
            gainAdvice = tr("Поднять Gain на +4…+6 dB", "Raise Gain by +4…+6 dB")
        } else if avgLufs > target + 3.0 {
            gainAdvice = tr("Слегка убавить Gain (-2…-3 dB)", "Lower Gain slightly (-2…-3 dB)")
        } else {
            gainAdvice = tr("Идеально под цель \(loudnessTarget.shortLabel) ✅", "Spot-on for \(loudnessTarget.shortLabel) ✅")
        }

        let compRec = avgNoise > -44.0
            ? "Ratio 2:1, Threshold -18 dB (\(tr("мягко, чтобы не тянуть комнату", "gentle for room noise")))"
            : "Ratio 2.5:1 – 3:1, Threshold \(Int(max(-24, min(-14, avgLufs - 2.0)))) dB"
        let bigBottom = mudDb > presDb + 10.0
            ? tr("OFF (баса достаточно от близости)", "OFF (plenty of natural low-end)")
            : tr("ON, 10–15% (80 Hz)", "ON, subtle 10–15% (80 Hz)")
        let exciter = sibDb > presDb - 4.0
            ? tr("OFF или 10% (выражены шипящие С/Ш)", "OFF or 10% (bright sibilance)")
            : tr("ON, 20–25% (воздух и ясность)", "ON, 20–25% (adds crisp vocal air)")

        calibrationReport = RodeCalibrationReport(
            noiseFloorDb: avgNoise, speechLufs: avgLufs, peakDb: pk, dynamicsDb: dyn,
            subBassEnergyDb: subDb, mudEnergyDb: mudDb, presenceEnergyDb: presDb, sibilanceEnergyDb: sibDb,
            recommendedHpf: hpf, recommendedGateDb: gateDb, recommendedGainAdvice: gainAdvice,
            recommendedCompressor: compRec, recommendedBigBottom: bigBottom, recommendedExciter: exciter
        )
        showCalibrationPopover = true
    }

    // Rich Studio Demo Signal for --screenshot verification
    private func populateDemoVisualization() {
        isRunning = true
        activeDeviceName = "RØDE NT1 5th Gen"
        peakDb = -6.8; peakHoldDb = -5.2; rmsDb = -15.4
        momentaryLufs = -15.6; shortTermLufs = -16.1; integratedLufs = -16.3
        dynamicsPlrDb = 10.9; noiseFloorDb = -53.4
        dominantFreqHz = 148; dominantNote = "D3"; stereoCorrelation = 0.96

        for i in 0..<Self.waveSlicesCount {
            let t = Float(i) * 0.13
            let env = min(0.95, max(0.08, 0.25 + 0.62 * abs(sin(t * 0.42)) * (0.6 + 0.4 * cos(t * 1.1))))
            let low  = 0.35 + 0.45 * abs(sin(t * 0.27))
            let mid  = 0.55 + 0.35 * abs(cos(t * 0.51))
            let high = 0.15 + 0.55 * pow(max(0, sin(t * 0.83)), 3)
            coloredWave[i] = ColoredWaveSlice(amplitude: env, lowWeight: low, midWeight: mid, highWeight: high)
        }
        for i in 0..<Self.oscPointsCount {
            let p = Float(i) / Float(Self.oscPointsCount) * 4.0 * .pi
            oscilloscope[i] = (sin(p) * 0.55 + sin(p * 2.0 + 0.6) * 0.28 + sin(p * 3.0) * 0.14)
        }
        for b in 0..<Self.spectrumBins {
            let v = min(0.92, max(0.06, Self.vocalTargetCurve[b] * (0.88 + 0.20 * sin(Float(b) * 0.55))))
            spectrumCurve[b] = v
            spectrumPeaks[b] = min(0.96, v + 0.08)
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

// MARK: - Flagship Frameless MiniMeters + FabFilter + Youlean UI
struct AudioMetersView: View {
    @ObservedObject var eng: AudioAnalyzerEngine

    var body: some View {
        VStack(spacing: 0) {
            // ULTRA-SLIM FRAMELESS PRO HEADER STRIP (MiniMeters Style)
            HStack(spacing: 6) {
                // Brand Mark (padded cleanly past macOS traffic lights)
                Spacer().frame(width: 62)

                Group {
                    if let logoPath = Bundle.main.path(forResource: "mo_logo", ofType: "png"),
                       let nsImg = NSImage(contentsOfFile: logoPath) {
                        Image(nsImage: nsImg)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 17, height: 17)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                // CoreAudio Device Selector Pill
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
                    HStack(spacing: 4) {
                        Circle().fill(eng.isRunning ? Color.green : Color.red).frame(width: 5.5, height: 5.5)
                        Text(eng.activeDeviceName).font(.system(size: 10, weight: .bold)).lineLimit(1)
                        Text("\(Int(eng.activeSampleRate/1000))k").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderedButton).controlSize(.mini).frame(maxWidth: 185)

                // Layout Switcher: Bar vs Quad (MiniMeters Signature!)
                HStack(spacing: 2) {
                    layoutPill("BAR",  active: eng.layoutMode == .bar)  { eng.setLayoutMode(.bar) }
                    layoutPill("QUAD", active: eng.layoutMode == .quad) { eng.setLayoutMode(.quad) }
                }

                // 10s RØDE Voice & Room Calibrator
                Button(action: { eng.startCalibration() }) {
                    HStack(spacing: 3) {
                        Image(systemName: eng.isCalibrating ? "waveform.circle.fill" : "target")
                        if eng.isCalibrating {
                            Text(eng.calibrationPhase == "quiet"
                                 ? eng.tr("Тишина \(eng.calibrationCountdown)с", "Quiet \(eng.calibrationCountdown)s")
                                 : eng.tr("Говорите \(eng.calibrationCountdown)с", "Speak \(eng.calibrationCountdown)s"))
                        } else {
                            Text(eng.tr("Калибр. RØDE", "RØDE Cal"))
                        }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(eng.isCalibrating ? (eng.calibrationPhase == "quiet" ? Color.orange : Color.red) : eng.theme.primary.opacity(0.18))
                    .foregroundColor(eng.isCalibrating ? .white : eng.theme.primary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $eng.showCalibrationPopover, arrowEdge: .bottom) {
                    calibrationPopoverView
                }

                // Instant 10s Audio Clip Saver (MiniMeters Feature!)
                Button(action: { eng.saveLast10SecondsClip() }) {
                    HStack(spacing: 2.5) {
                        Image(systemName: "waveform.badge.plus")
                        Text("10s WAV")
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.white.opacity(0.07)).foregroundColor(.primary.opacity(0.85)).cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Сохранить последние 10 сек звука в WAV для прослушивания", "Save last 10 seconds of audio as 48kHz WAV"))

                // Freeze Spectrum (FabFilter / TDR Prism Feature!)
                Button(action: { eng.toggleFreeze() }) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5.5).padding(.vertical, 3)
                        .background(eng.isFrozen ? Color.cyan : Color.white.opacity(0.07))
                        .foregroundColor(eng.isFrozen ? .black : .secondary).cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Заморозить спектр (как в TDR Prism / FabFilter)", "Freeze spectrum & meters"))

                if !eng.toastMessage.isEmpty {
                    Text(eng.toastMessage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                        .lineLimit(1)
                }

                Spacer()

                // Compact Module Pills (in Bar mode)
                if eng.layoutMode == .bar {
                    modPill("WAVE", eng.showWaveform)     { eng.showWaveform.toggle(); eng.scheduleSaveConfig() }
                    modPill("OSC",  eng.showOscilloscope) { eng.showOscilloscope.toggle(); eng.scheduleSaveConfig() }
                    modPill("FFT",  eng.showSpectrum)     { eng.showSpectrum.toggle(); eng.scheduleSaveConfig() }
                    modPill("SPEC", eng.showSpectrogram)  { eng.showSpectrogram.toggle(); eng.scheduleSaveConfig() }
                    modPill("STER", eng.showStereo)       { eng.showStereo.toggle(); eng.scheduleSaveConfig() }
                    modPill("LUFS", eng.showLoudness)     { eng.showLoudness.toggle(); eng.scheduleSaveConfig() }
                }

                // Target Preset + Tilt + Theme Pro Menu
                Menu {
                    Section(eng.tr("Цель громкости (Youlean)", "Loudness Target (Youlean)")) {
                        ForEach(LoudnessTarget.allCases, id: \.self) { lt in
                            Button((eng.loudnessTarget == lt ? "✅ " : "") + lt.rawValue) {
                                eng.loudnessTarget = lt; eng.scheduleSaveConfig()
                            }
                        }
                    }
                    Section(eng.tr("Наклон спектра (TDR Prism / FabFilter)", "Spectrum Tilt (TDR / FabFilter)")) {
                        Button((eng.spectrumTilt == 0.0 ? "✅ " : "") + "0 dB/oct (Flat)")           { eng.spectrumTilt = 0.0; eng.scheduleSaveConfig() }
                        Button((eng.spectrumTilt == 3.0 ? "✅ " : "") + "+3.0 dB/oct (Pink / TDR)")  { eng.spectrumTilt = 3.0; eng.scheduleSaveConfig() }
                        Button((eng.spectrumTilt == 4.5 ? "✅ " : "") + "+4.5 dB/oct (FabFilter)")   { eng.spectrumTilt = 4.5; eng.scheduleSaveConfig() }
                    }
                    Section(eng.tr("Оверлеи спектра", "Spectrum Overlays")) {
                        Button((eng.showTargetCurve ? "✅ " : "") + eng.tr("Эталонная кривая голоса", "Broadcast Vocal Target Curve")) {
                            eng.showTargetCurve.toggle(); eng.scheduleSaveConfig()
                        }
                        Button((eng.showVocalZones ? "✅ " : "") + eng.tr("Зоны частот (HPF / Бубнёж / С-Ш)", "Vocal Freq Zones")) {
                            eng.showVocalZones.toggle(); eng.scheduleSaveConfig()
                        }
                    }
                    Section(eng.tr("Тема (Color Map)", "Theme (Color Map)")) {
                        ForEach(MeterTheme.allCases, id: \.self) { t in
                            Button((eng.theme == t ? "✅ " : "") + t.rawValue) {
                                eng.theme = t; eng.scheduleSaveConfig()
                            }
                        }
                    }
                    Section(eng.tr("Прозрачность окна", "Window Opacity")) {
                        Button("100%") { eng.setOpacity(1.0) }
                        Button("90%")  { eng.setOpacity(0.90) }
                        Button("78%")  { eng.setOpacity(0.78) }
                    }
                    Divider()
                    Button(eng.tr("🎚 Открыть RØDE Central", "🎚 Open RØDE Central")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RODE Central.app"))
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundColor(eng.theme.primary)
                }
                .menuStyle(.borderedButton).controlSize(.mini).frame(width: 28)

                // Always on Top (Even Over Full-Screen Apps!)
                Button(action: { eng.setAlwaysOnTop(!eng.alwaysOnTop) }) {
                    Image(systemName: eng.alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 5.5).padding(.vertical, 3.5)
                        .background(eng.alwaysOnTop ? Color.indigo : Color.white.opacity(0.07))
                        .foregroundColor(.white).cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(eng.tr("Поверх всех окон (включая Full-Screen)", "Pin always on top (Full-Screen overlay)"))
            }
            .frame(height: 27)
            .padding(.trailing, 7)
            .background(Color.black.opacity(0.45))

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            if eng.permissionDenied {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill").foregroundColor(.orange)
                    Text(eng.tr("Дайте доступ к Микрофону: Системные настройки → Конфиденциальность → Микрофон", "Grant Microphone access in System Settings → Privacy & Security → Microphone"))
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
                    Spacer()
                    Button(eng.tr("Настройки", "Settings")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    }.buttonStyle(.borderedProminent).controlSize(.mini)
                    Button(eng.tr("Повторить", "Retry")) { eng.requestMicAndStart() }.buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.orange.opacity(0.14))
            }

            // FRAMELESS MODULES WORKSPACE (MiniMeters Hairline Dividers!)
            if eng.layoutMode == .bar {
                HStack(spacing: 0) {
                    if eng.showWaveform {
                        meterCell("WAVEFORM", badge: "MULTI-BAND") {
                            MultiBandWaveformCanvas(slices: eng.coloredWave)
                        }
                        .frame(minWidth: 165)
                        hairlineV
                    }
                    if eng.showOscilloscope {
                        meterCell("OSCILLOSCOPE", badge: eng.dominantNote) {
                            OscilloscopeCanvas(samples: eng.oscilloscope, theme: eng.theme)
                        }
                        .frame(minWidth: 120, maxWidth: 170)
                        hairlineV
                    }
                    if eng.showSpectrum {
                        meterCell("SPECTRUM", badge: eng.dominantFreqHz > 0 ? String(format: "%.0fHz %@", eng.dominantFreqHz, eng.dominantNote) : "+\(String(format: "%.1f", eng.spectrumTilt))dB/o") {
                            FabFilterSpectrumCanvas(
                                curve: eng.spectrumCurve,
                                peaks: eng.spectrumPeaks,
                                frozen: eng.isFrozen ? eng.frozenSpectrum : nil,
                                theme: eng.theme,
                                showTargetCurve: eng.showTargetCurve,
                                showVocalZones: eng.showVocalZones
                            )
                        }
                        .frame(minWidth: 270)
                        hairlineV
                    }
                    if eng.showSpectrogram {
                        meterCell("SPECTROGRAM", badge: "MEL") {
                            SpectrogramCanvas(grid: eng.spectrogram, theme: eng.theme)
                        }
                        .frame(minWidth: 155)
                        hairlineV
                    }
                    if eng.showStereo {
                        meterCell("STEREOMETER", badge: String(format: "Φ %+.2f", eng.stereoCorrelation)) {
                            StereometerCanvas(points: eng.stereoXY, correlation: eng.stereoCorrelation, theme: eng.theme)
                        }
                        .frame(width: 118)
                        hairlineV
                    }
                    if eng.showLoudness {
                        YouleanLoudnessCell(eng: eng)
                            .frame(width: 245)
                    }
                }
            } else {
                // QUAD 2x2 STUDIO MONITOR LAYOUT (MiniMeters Quad + Youlean History + FabFilter Big FFT!)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        meterCell("FABFILTER / TDR SPECTRUM (25Hz–20kHz)", badge: eng.dominantFreqHz > 0 ? String(format: "Peak: %.0f Hz (%@) • +%.1f dB/oct", eng.dominantFreqHz, eng.dominantNote, eng.spectrumTilt) : "+\(String(format: "%.1f", eng.spectrumTilt)) dB/oct") {
                            FabFilterSpectrumCanvas(
                                curve: eng.spectrumCurve,
                                peaks: eng.spectrumPeaks,
                                frozen: eng.isFrozen ? eng.frozenSpectrum : nil,
                                theme: eng.theme,
                                showTargetCurve: eng.showTargetCurve,
                                showVocalZones: eng.showVocalZones
                            )
                        }
                        hairlineV
                        YouleanLoudnessCell(eng: eng)
                            .frame(width: 295)
                    }
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
                }
            }
        }
        .background(eng.theme.bgDark)
        .ignoresSafeArea(.all, edges: .top)
        .preferredColorScheme(.dark)
    }

    private var hairlineV: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5) }
    private var hairlineH: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }

    private func layoutPill(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(active ? Color.white.opacity(0.18) : Color.white.opacity(0.04))
                .foregroundColor(active ? .white : .secondary)
                .cornerRadius(4)
        }.buttonStyle(.plain)
    }

    private func modPill(_ label: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4.5).padding(.vertical, 2.5)
                .background(active ? eng.theme.primary.opacity(0.20) : Color.white.opacity(0.04))
                .foregroundColor(active ? eng.theme.primary : .secondary)
                .cornerRadius(3.5)
        }.buttonStyle(.plain)
    }

    private func meterCell<Content: View>(_ title: String, badge: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(title)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(badge)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(eng.theme.primary.opacity(0.85))
            }
            .padding(.horizontal, 6).padding(.top, 3)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var calibrationPopoverView: some View {
        if let r = eng.calibrationReport {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(eng.tr("🎯 Рецепт настройки RØDE Central", "🎯 Tailored RØDE Central Recipe"))
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    Spacer()
                    Button("RØDE Central ↗") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RODE Central.app"))
                    }.buttonStyle(.borderedProminent).controlSize(.mini)
                }
                Divider()
                HStack(spacing: 8) {
                    calBox(eng.tr("Шум", "Floor"), String(format: "%.0f dB", r.noiseFloorDb), ok: r.noiseFloorDb < -44)
                    calBox("LUFS", String(format: "%.1f", r.speechLufs), ok: abs(r.speechLufs - Double(eng.loudnessTarget.lufs)) <= 4.0)
                    calBox("Peak", String(format: "%.1f dB", r.peakDb), ok: r.peakDb < -1.5)
                    calBox("PLR", String(format: "%.1f dB", r.dynamicsDb), ok: r.dynamicsDb >= 7.0)
                }
                Divider()
                calRow("Input Gain:", r.recommendedGainAdvice)
                calRow("High-Pass:", r.recommendedHpf)
                calRow("Noise Gate:", "ON • Threshold \(r.recommendedGateDb) dB")
                calRow("Compressor:", r.recommendedCompressor)
                calRow("Big Bottom™:", r.recommendedBigBottom)
                calRow("Aural Exciter™:", r.recommendedExciter)
            }
            .padding(12).frame(width: 410)
        } else {
            Text(eng.tr("Нажмите «Калибр. RØDE» для замера", "Click RØDE Cal to measure")).padding(12)
        }
    }

    private func calBox(_ k: String, _ v: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 8.5)).foregroundColor(.secondary)
            Text(v).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(ok ? .green : .orange)
        }.padding(5).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.05)).cornerRadius(5)
    }

    private func calRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).font(.system(size: 10, weight: .bold)).foregroundColor(eng.theme.primary).frame(width: 100, alignment: .leading)
            Text(v).font(.system(size: 10)).foregroundColor(.primary)
            Spacer()
        }
    }
}

// MARK: - 1. MiniMeters Iconic Frequency-Colored Waveform
struct MultiBandWaveformCanvas: View {
    let slices: [ColoredWaveSlice]

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let midY = h * 0.54

            for frac in [0.24, 0.54, 0.84] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h * frac))
                p.addLine(to: CGPoint(x: w, y: h * frac))
                ctx.stroke(p, with: .color(Color.white.opacity(frac == 0.54 ? 0.12 : 0.04)), lineWidth: 0.6)
            }

            let count = slices.count
            guard count > 0 else { return }
            let dx = w / CGFloat(count)
            let barW = max(1.0, dx * 0.86)

            for i in 0..<count {
                let s = slices[i]
                let amp = max(1.0, CGFloat(s.amplitude) * (h * 0.42))
                let x = CGFloat(i) * dx
                let rect = CGRect(x: x, y: midY - amp, width: barW, height: amp * 2.0)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.7), with: .color(s.color.opacity(0.92)))
            }
        }
    }
}

// MARK: - 2. MiniMeters Pitch-Locked Oscilloscope
struct OscilloscopeCanvas: View {
    let samples: [Float]
    let theme: MeterTheme

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

// MARK: - 3. FabFilter Pro-Q 4 + TDR Prism Smooth Filled Vector Spectrum Curve
struct FabFilterSpectrumCanvas: View {
    let curve: [Float]
    let peaks: [Float]
    let frozen: [Float]?
    let theme: MeterTheme
    let showTargetCurve: Bool
    let showVocalZones: Bool

    private func buildSmoothPath(values: [Float], w: CGFloat, h: CGFloat, topPad: CGFloat) -> Path {
        var path = Path()
        let n = values.count
        guard n > 1 else { return path }
        let usableH = h - topPad
        let dx = w / CGFloat(n - 1)
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            pts.append(CGPoint(x: CGFloat(i) * dx, y: topPad + usableH * (1.0 - CGFloat(values[i]))))
        }
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
            let w = size.width
            let h = size.height - 12
            let topPad: CGFloat = 14

            // Subtle studio vocal frequency zones
            if showVocalZones {
                let zones: [(CGFloat, CGFloat, Color)] = [
                    (0.00, 0.17, Color.red.opacity(0.06)),    // HPF < 80Hz
                    (0.24, 0.39, Color.orange.opacity(0.06)), // Mud 120–320Hz
                    (0.65, 0.79, Color.green.opacity(0.06)),  // Presence 2–5kHz
                    (0.81, 0.90, Color.yellow.opacity(0.06))  // Sibilance 5.5–9kHz
                ]
                for (x0, x1, col) in zones {
                    ctx.fill(Path(CGRect(x: w * x0, y: topPad, width: w * (x1 - x0), height: h - topPad)), with: .color(col))
                }
            }

            // Crisp vector dB & Octave grid (FabFilter Pro-Q style!)
            for frac in [0.25, 0.5, 0.75] {
                var g = Path()
                let y = topPad + (h - topPad) * frac
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(g, with: .color(Color.white.opacity(0.055)), lineWidth: 0.6)
            }
            let ticks: [(String, CGFloat)] = [("50", 0.10), ("150", 0.27), ("500", 0.45), ("1k", 0.55), ("3k", 0.71), ("8k", 0.86), ("16k", 0.96)]
            for (lbl, pos) in ticks {
                var vLine = Path()
                vLine.move(to: CGPoint(x: w * pos, y: topPad)); vLine.addLine(to: CGPoint(x: w * pos, y: h))
                ctx.stroke(vLine, with: .color(Color.white.opacity(0.045)), lineWidth: 0.6)
                let txt = Text(lbl).font(.system(size: 7.5, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.38))
                ctx.draw(txt, at: CGPoint(x: w * pos, y: h + 6))
            }

            // Ideal Broadcast Vocal Target Curve Overlay (dashed warm gold!)
            if showTargetCurve {
                let targetPath = buildSmoothPath(values: AudioAnalyzerEngine.vocalTargetCurve, w: w, h: h, topPad: topPad)
                ctx.stroke(targetPath, with: .color(Color.yellow.opacity(0.30)), style: StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
            }

            // Peak Hold Curve (thin bright ghost trace)
            let peakPath = buildSmoothPath(values: peaks, w: w, h: h, topPad: topPad)
            ctx.stroke(peakPath, with: .color(theme.secondary.opacity(0.45)), lineWidth: 1.0)

            // Main Live Filled Spectrum Curve (FabFilter Pro-Q 4 glow!)
            let liveVals = frozen ?? curve
            let mainStroke = buildSmoothPath(values: liveVals, w: w, h: h, topPad: topPad)
            var fillPath = mainStroke
            fillPath.addLine(to: CGPoint(x: w, y: h))
            fillPath.addLine(to: CGPoint(x: 0, y: h))
            fillPath.closeSubpath()

            ctx.fill(fillPath, with: .linearGradient(
                Gradient(colors: [theme.primary.opacity(0.42), theme.secondary.opacity(0.14), theme.primary.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: topPad),
                endPoint: CGPoint(x: 0, y: h)
            ))
            ctx.stroke(mainStroke, with: .color(frozen != nil ? .cyan : theme.primary), lineWidth: 1.7)
        }
    }
}

// MARK: - 4. Rolling Mel-Scale Spectrogram Waterfall
struct SpectrogramCanvas: View {
    let grid: [[Float]]
    let theme: MeterTheme

    var body: some View {
        Canvas { ctx, size in
            let cols = grid.count
            guard cols > 0 else { return }
            let rows = grid[0].count
            let cw = size.width / CGFloat(cols)
            let rh = size.height / CGFloat(rows)
            for c in 0..<cols {
                let colData = grid[c]
                let x = CGFloat(c) * cw
                for r in 0..<rows {
                    let v = colData[r]
                    if v < 0.04 { continue }
                    let y = size.height - CGFloat(r + 1) * rh
                    ctx.fill(Path(CGRect(x: x, y: y, width: cw + 0.6, height: rh + 0.6)), with: .color(theme.heatColor(v)))
                }
            }
        }
    }
}

// MARK: - 5. MiniMeters Stereometer (Lissajous Goniometer + Correlation Bar)
struct StereometerCanvas: View {
    let points: [(Float, Float)]
    let correlation: Float
    let theme: MeterTheme

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height - 14
            let cx = w * 0.5
            let cy = h * 0.54
            let rad = min(w, h) * 0.40

            // Subtle vector goniometer crosshair (L/R 45 deg axes)
            for angle in [0.0, .pi / 4.0, .pi / 2.0, 3.0 * .pi / 4.0] {
                var p = Path()
                let dx = CGFloat(cos(angle)) * rad
                let dy = CGFloat(sin(angle)) * rad
                p.move(to: CGPoint(x: cx - dx, y: cy - dy))
                p.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
                ctx.stroke(p, with: .color(Color.white.opacity(0.07)), lineWidth: 0.6)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)),
                       with: .color(Color.white.opacity(0.08)), lineWidth: 0.7)

            // Lissajous vector trace
            if points.count > 1 {
                var trace = Path()
                for i in 0..<points.count {
                    let px = cx + CGFloat(max(-1, min(1, points[i].0 * 1.6))) * rad
                    let py = cy - CGFloat(max(-1, min(1, points[i].1 * 1.6))) * rad
                    if i == 0 { trace.move(to: CGPoint(x: px, y: py)) }
                    else { trace.addLine(to: CGPoint(x: px, y: py)) }
                }
                ctx.stroke(trace, with: .color(theme.primary.opacity(0.82)), lineWidth: 1.3)
            }

            // Bottom Phase Correlation Bar (-1 ... 0 ... +1)
            let barY = size.height - 9
            let barRect = CGRect(x: 8, y: barY, width: w - 16, height: 4)
            ctx.fill(Path(roundedRect: barRect, cornerRadius: 2), with: .color(Color.white.opacity(0.08)))
            let normC = CGFloat((correlation + 1.0) * 0.5)
            let markerX = 8 + (w - 16) * normC
            let col: Color = correlation >= 0 ? .green : .red
            ctx.fill(Path(roundedRect: CGRect(x: min(w * 0.5, markerX), y: barY, width: abs(markerX - w * 0.5), height: 4), cornerRadius: 2), with: .color(col.opacity(0.85)))
            ctx.fill(Path(CGRect(x: markerX - 1, y: barY - 1, width: 2, height: 6)), with: .color(.white))
        }
    }
}

// MARK: - 6. Youlean Loudness Meter 2 Style Panel (Scrolling LUFS Graph + Target Line + Numeric Block)
struct YouleanLoudnessCell: View {
    @ObservedObject var eng: AudioAnalyzerEngine

    private func normLufs(_ v: Float) -> CGFloat {
        // Map -48 LUFS (bottom) -> 0 LUFS (top)
        CGFloat(max(0, min(1, (v + 48.0) / 48.0)))
    }
    private func normDb(_ v: Float) -> CGFloat {
        CGFloat(max(0, min(1, (v + 60.0) / 60.0)))
    }

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: Youlean Numeric Readout Column
            VStack(alignment: .leading, spacing: 2.5) {
                HStack {
                    Text(eng.loudnessTarget.shortLabel)
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(eng.theme.primary)
                    Spacer()
                    Button(action: { eng.resetLoudnessStats() }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(eng.tr("Сбросить Integrated LUFS и пики", "Reset Integrated LUFS & Peak Hold"))
                }

                youleanRow("INT",   String(format: "%.1f", eng.integratedLufs),
                           color: abs(eng.integratedLufs - eng.loudnessTarget.lufs) <= 3.0 ? .green : eng.theme.primary)
                youleanRow("SHORT", String(format: "%.1f", eng.shortTermLufs), color: .primary.opacity(0.9))
                youleanRow("PEAK",  String(format: "%.1f", eng.peakHoldDb), color: eng.isClipping ? .red : .yellow)
                youleanRow("PLR",   String(format: "%.1f", eng.dynamicsPlrDb), color: (eng.dynamicsPlrDb >= 7.0 && eng.dynamicsPlrDb <= 16.0) ? .green : .orange)
                youleanRow("FLOOR", String(format: "%.0f", eng.noiseFloorDb), color: .secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(width: 96)

            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 0.5)

            // MIDDLE: Youlean Scrolling Color-Coded LUFS History Graph!
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let w = size.width; let h = size.height
                    let target = eng.loudnessTarget.lufs
                    let targetY = h * (1.0 - normLufs(target))

                    // Broadcast Green Target Band (±2.5 LUFS around target)
                    let bandTop = h * (1.0 - normLufs(target + 2.5))
                    let bandBot = h * (1.0 - normLufs(target - 2.5))
                    ctx.fill(Path(CGRect(x: 0, y: bandTop, width: w, height: max(2, bandBot - bandTop))), with: .color(Color.green.opacity(0.10)))

                    // Dashed Target Line
                    var tLine = Path()
                    tLine.move(to: CGPoint(x: 0, y: targetY)); tLine.addLine(to: CGPoint(x: w, y: targetY))
                    ctx.stroke(tLine, with: .color(Color.green.opacity(0.55)), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))

                    let hist = eng.lufsHistory
                    let n = hist.count
                    guard n > 1 else { return }
                    let dx = w / CGFloat(n - 1)

                    // Color-coded bars / filled history (Youlean signature!)
                    for i in 0..<n {
                        let v = hist[i]
                        if v <= -47.5 { continue }
                        let x = CGFloat(i) * dx
                        let y = h * (1.0 - normLufs(v))
                        let col: Color
                        if v > target + 2.5 { col = .red }
                        else if v >= target - 3.0 { col = .green }
                        else { col = eng.theme.primary }
                        ctx.fill(Path(CGRect(x: x, y: y, width: max(1.0, dx), height: h - y)), with: .color(col.opacity(0.32)))
                        ctx.fill(Path(CGRect(x: x, y: y, width: max(1.0, dx), height: 1.6)), with: .color(col))
                    }
                }
                Text("LUFS HISTORY")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.40))
                    .padding(.leading, 5).padding(.top, 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // RIGHT: Ultra-Crisp True Peak Vertical Meter Bar
            GeometryReader { geo in
                let h = geo.size.height - 8
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .bottom, endPoint: .top))
                        .frame(height: max(2, h * normDb(eng.peakDb)))
                    Rectangle()
                        .fill(eng.isClipping ? Color.red : Color.white)
                        .frame(height: 1.8)
                        .offset(y: -(h * normDb(eng.peakHoldDb) - 1))
                }
                .padding(.vertical, 4)
            }
            .frame(width: 11)
            .padding(.trailing, 5)
        }
    }

    private func youleanRow(_ k: String, _ v: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(k).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.secondary)
            Spacer()
            Text(v).font(.system(size: 9.5, weight: .heavy, design: .monospaced)).foregroundColor(color)
        }
    }
}

// MARK: - AppDelegate (Floating MiniMeters Bar + Quad + Full-Screen Overlay + Menu Bar)
final class MetersAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: FloatingMetersPanel!
    var statusItem: NSStatusItem!
    let eng = AudioAnalyzerEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let defaultFrame: NSRect
        if CommandLine.arguments.contains("--screenshot") {
            defaultFrame = NSRect(x: 100, y: 100, width: 1040, height: 146)
        } else if CommandLine.arguments.contains("--screenshot-quad") {
            defaultFrame = NSRect(x: 100, y: 100, width: 900, height: 420)
        } else if let saved = eng.savedWindowFrame,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            defaultFrame = saved
        } else if let scr = NSScreen.main?.visibleFrame {
            let w: CGFloat = min(1040, scr.width - 36)
            let h: CGFloat = eng.layoutMode == .quad ? 420 : 146
            defaultFrame = NSRect(x: scr.midX - w / 2, y: scr.minY + 20, width: w, height: h)
        } else {
            defaultFrame = NSRect(x: 100, y: 80, width: 1040, height: 146)
        }

        window = FloatingMetersPanel(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Mr. Audio Meters — mrmo.es"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 620, height: 122)
        window.maxSize = NSSize(width: 2400, height: 960)
        window.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.044, blue: 0.062, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.worksWhenModal = true
        window.alphaValue = CGFloat(eng.windowOpacity)
        window.contentView = NSHostingView(rootView: AudioMetersView(eng: eng))

        eng.onAlwaysOnTopChanged = { [weak self] enabled in self?.applyAlwaysOnTop(enabled) }
        eng.onOpacityChanged = { [weak self] val in self?.window?.alphaValue = CGFloat(val) }
        eng.onLayoutModeChanged = { [weak self] mode in self?.animateLayoutResize(mode) }
        applyAlwaysOnTop(eng.alwaysOnTop)

        if CommandLine.arguments.contains("--screenshot") || CommandLine.arguments.contains("--screenshot-quad") {
            let isQuad = CommandLine.arguments.contains("--screenshot-quad")
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let view = self?.window.contentView else { NSApp.terminate(nil); return }
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let fname = isQuad ? "audio_meters_quad.png" : "audio_meters_bar.png"
                        let out = "\(NSHomeDirectory())/Desktop/PixelProCam/assets/screenshots/\(fname)"
                        try? png.write(to: URL(fileURLWithPath: out))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }

        window.orderFrontRegardless()
        setupMenuBar()
    }

    func animateLayoutResize(_ mode: MeterLayoutMode) {
        guard let win = window, let scr = NSScreen.main?.visibleFrame else { return }
        let cur = win.frame
        let newW: CGFloat = mode == .quad ? min(920, scr.width - 60) : min(1060, scr.width - 36)
        let newH: CGFloat = mode == .quad ? 420 : 146
        let newX = max(scr.minX + 12, min(scr.maxX - newW - 12, cur.midX - newW / 2))
        let newY = max(scr.minY + 12, min(scr.maxY - newH - 12, cur.minY))
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

        let barItem = NSMenuItem(title: eng.tr("▬ Режим полоски (Bar)", "▬ Horizontal Bar Mode"), action: #selector(modeBar), keyEquivalent: "")
        barItem.target = self; barItem.state = eng.layoutMode == .bar ? .on : .off; menu.addItem(barItem)

        let quadItem = NSMenuItem(title: eng.tr("⊞ Студийная сетка (Quad 2×2)", "⊞ Studio Quad Grid (2×2)"), action: #selector(modeQuad), keyEquivalent: "")
        quadItem.target = self; quadItem.state = eng.layoutMode == .quad ? .on : .off; menu.addItem(quadItem)

        menu.addItem(NSMenuItem.separator())
        let snapBot = NSMenuItem(title: eng.tr("⬇ Прикрепить снизу экрана", "⬇ Snap Bottom Bar"), action: #selector(snapToBottom), keyEquivalent: "")
        snapBot.target = self; menu.addItem(snapBot)

        let snapTop = NSMenuItem(title: eng.tr("⬆ Прикрепить сверху экрана", "⬆ Snap Top Bar"), action: #selector(snapToTop), keyEquivalent: "")
        snapTop.target = self; menu.addItem(snapTop)

        let pinItem = NSMenuItem(title: eng.tr("📌 Поверх всех окон (Full-Screen)", "📌 Always on Top (Full-Screen)"), action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self; pinItem.state = eng.alwaysOnTop ? .on : .off; menu.addItem(pinItem)

        menu.addItem(NSMenuItem.separator())
        let calItem = NSMenuItem(title: eng.tr("🎯 Калибровка RØDE (10 сек)", "🎯 Calibrate RØDE (10s)"), action: #selector(startCal), keyEquivalent: "")
        calItem.target = self; menu.addItem(calItem)

        let clipItem = NSMenuItem(title: eng.tr("💾 Сохранить последние 10с WAV", "💾 Save Last 10s WAV Clip"), action: #selector(saveClip), keyEquivalent: "")
        clipItem.target = self; menu.addItem(clipItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: eng.tr("🚪 Выйти из Mr. Audio Meters", "🚪 Quit Mr. Audio Meters"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
    }

    @objc func showWin() {
        if eng.alwaysOnTop { applyAlwaysOnTop(true) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func modeBar()  { eng.setLayoutMode(.bar); showWin() }
    @objc func modeQuad() { eng.setLayoutMode(.quad); showWin() }
    @objc func snapToBottom() {
        guard let scr = NSScreen.main?.visibleFrame else { return }
        eng.layoutMode = .bar
        let w = min(1080, scr.width - 28)
        window.setFrame(NSRect(x: scr.midX - w / 2, y: scr.minY + 10, width: w, height: 142), display: true, animate: true)
    }
    @objc func snapToTop() {
        guard let scr = NSScreen.main?.visibleFrame else { return }
        eng.layoutMode = .bar
        let w = min(1080, scr.width - 28)
        window.setFrame(NSRect(x: scr.midX - w / 2, y: scr.maxY - 150, width: w, height: 142), display: true, animate: true)
    }
    @objc func togglePin() { eng.setAlwaysOnTop(!eng.alwaysOnTop) }
    @objc func startCal()  { showWin(); eng.startCalibration() }
    @objc func saveClip()  { eng.saveLast10SecondsClip() }
    @objc func quitApp()   { NSApp.terminate(nil) }

    func windowDidMove(_ notification: Notification)   { eng.savedWindowFrame = window.frame; eng.scheduleSaveConfig() }
    func windowDidResize(_ notification: Notification) { eng.savedWindowFrame = window.frame; eng.scheduleSaveConfig() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWin(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        eng.savedWindowFrame = window.frame
        eng.saveConfigNow()
        eng.stopEngine()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return false }
}

let app = NSApplication.shared
let delegate = MetersAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

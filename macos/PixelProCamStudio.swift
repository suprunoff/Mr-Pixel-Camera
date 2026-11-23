import Cocoa
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Vision

// MARK: - Diagnostic File & UI Logger
final class FileLogger {
    static let shared = FileLogger()
    let logFilePath: String = {
        let base = "\(NSHomeDirectory())/Desktop/PixelProCam"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return "\(base)/pixelprocam_debug.log"
    }()
    private let queue = DispatchQueue(label: "com.pixelprocam.logger", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    var onNewLogLine: ((String) -> Void)?

    private init() {
        let header = "=== PixelProCam Studio v2.1 Diagnostic Log Started at \(Date()) ===\n"
        try? header.write(toFile: logFilePath, atomically: true, encoding: .utf8)
    }

    func log(_ category: String, _ message: String, uiVisible: Bool = true) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(category)] \(message)"
        queue.async {
            if let handle = FileHandle(forWritingAtPath: self.logFilePath) {
                handle.seekToEndOfFile()
                if let data = (line + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        }
        if uiVisible {
            DispatchQueue.main.async {
                self.onNewLogLine?(line)
            }
        }
    }
}

// MARK: - Isolated Sub-States (Prevents Main Window Redraw Storms)
final class VuMeterState: ObservableObject {
    @Published var level: Double = 0.0
}

final class LivePreviewState: ObservableObject {
    @Published var image: NSImage? = nil
}

// MARK: - Custom User Memory Slot Model (M1 / M2 / M3)
struct StudioMemorySlot: Codable {
    var selectedLUT: String
    var lutIntensity: Double
    var vignetteEnabled: Bool
    var letterboxEnabled: Bool
    var zoomLevel: Double
    var panX: Double
    var panY: Double
    var isMirrored: Bool
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var vargamma: Double
    var hueShift: Double
    var sharpness: Double
}

// MARK: - Studio Controller v2.1
final class StudioController: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    // Localization (EN / RU) & UI Modes
    @Published var lang: String = {
        if let saved = UserDefaults.standard.string(forKey: "pixelprocam_lang") {
            return saved
        }
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.lowercased().hasPrefix("ru") ? "ru" : "en"
    }()
    @Published var miniMode: Bool = false
    @Published var showPreview: Bool = false
    @Published var showGridOverlay: Bool = true
    @Published var activeMemorySlot: Int = 0 // 0 = none, 1..3 = M1..M3
    @Published var savedSlotsMask: Set<Int> = []

    func tr(_ ru: String, _ en: String) -> String {
        return lang == "ru" ? ru : en
    }

    func toggleLanguage() {
        lang = (lang == "ru") ? "en" : "ru"
        UserDefaults.standard.set(lang, forKey: "pixelprocam_lang")
        FileLogger.shared.log("UI", "Switched language to \(lang.uppercased())")
        onStatusChangeForMenuBar?()
    }

    // Connection & Hardware status
    @Published var obsConnected: Bool = false
    @Published var pixelConnected: Bool = false
    @Published var pixelScreenUnlocked: Bool = true
    @Published var currentCameraFacing: String = "1x 24mm f/1.68"
    @Published var isHQMode: Bool = true
    @Published var is60FpsMode: Bool = true

    // Physical Lens & Prime Focal Length Selection
    @Published var selectedPhysicalLens: String = "1x"
    @Published var selectedPrimeFocal: String = "24mm"

    // Live OBS Telemetry & USB Cable Diagnostics
    @Published var obsFps: Double = 60.0
    @Published var obsRenderTimeMs: Double = 0.8
    @Published var obsCpuUsage: Double = 3.0
    @Published var obsSkippedFrames: Int = 0
    @Published var obsTotalFrames: Int = 0
    @Published var usbCableSpeed: String = "2.0 (480M)"
    @Published var usbIsSuperSpeed: Bool = false
    @Published var pixelBatteryLevel: Int = 100
    @Published var pixelTempC: Double = 36.0
    @Published var logEntries: [String] = []
    @Published var showLogs: Bool = false
    private var lastSkippedFrames: Int = 0

    // Framing / PTZ / Smooth Dolly Zoom / Mirror / Pin / Apple Vision AI Auto-Frame
    @Published var zoomLevel: Double = 1.0
    @Published var panX: Double = 0.0
    @Published var panY: Double = 0.0
    @Published var isMirrored: Bool = false
    @Published var alwaysOnTop: Bool = false
    @Published var aiAutoFrameEnabled: Bool = false
    @Published var aiFaceStatus: String = "OFF"
    private var dollyTimer: Timer?
    private var aiFrameTimer: Timer?
    private var previewTimer: Timer?
    private var previewInFlight: Bool = false
    private var forceImmediateAiFrame: Bool = false
    private var lastDetectedFaceX: Double = 0.5
    private var lastDetectedFaceY: Double = 0.45
    private var lastDetectedFaceH: Double = 0.27

    // Capture (Photo & Video Recording)
    @Published var isRecording: Bool = false
    @Published var recordSeconds: Int = 0
    @Published var lastCaptureMessage: String = ""
    private var recordTimer: Timer?
    let capturesDir = "\(NSHomeDirectory())/Desktop/PixelProCam/Captures"

    // Color, 3D LUTs & Cinema 2.35:1 Scope
    @Published var selectedLUT: String = "sony"
    @Published var lutIntensity: Double = 0.75
    @Published var vignetteEnabled: Bool = true
    @Published var letterboxEnabled: Bool = false

    // Manual Picture Adjustments
    @Published var brightness: Double = 0.015
    @Published var contrast: Double = 0.08
    @Published var saturation: Double = 0.06
    @Published var vargamma: Double = -0.02
    @Published var hueShift: Double = 0.0
    @Published var sharpness: Double = 0.06

    // Studio Features & RØDE NT1 5th Gen (Pure DSP + Lip-Sync)
    @Published var activeLightingPreset: String = "day"
    @Published var activeAudioPreset: String = "pure"
    @Published var rodeLipSyncMs: Double = 35.0
    @Published var rodeSafetyLimiter: Bool = true
    @Published var isRodeMuted: Bool = false
    @Published var liveVuEnabled: Bool = false
    @Published var isPrivacyStandby: Bool = false
    @Published var isBlackoutEnabled: Bool = false

    let vuState = VuMeterState()
    let previewState = LivePreviewState()
    var onStatusChangeForMenuBar: (() -> Void)?
    var onWindowSizeChangeRequested: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var pixelSceneItemId: Int = 2
    private var vignetteSceneItemId: Int = 3
    private var standbySceneItemId: Int = 4
    private var letterboxSceneItemId: Int = 5
    private var reconnectTimer: Timer?
    private var statsTimer: Timer?
    private var colorUpdateWorkItem: DispatchWorkItem?
    private var lutUpdateWorkItem: DispatchWorkItem?
    private var syncUpdateWorkItem: DispatchWorkItem?

    let adbPath: String = {
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/adb"
        let mrPixelApp = "\(NSHomeDirectory())/Desktop/PixelProCam/Mr. Pixel Camera.app/Contents/MacOS/adb"
        let desktopApp = "\(NSHomeDirectory())/Desktop/PixelProCam/PixelProCam Studio.app/Contents/MacOS/adb"
        let localBin = "\(NSHomeDirectory())/Desktop/PixelProCam/bin/adb"
        for p in [bundled, mrPixelApp, desktopApp, localBin, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return mrPixelApp
    }()

    @Published var pixelSerial: String = "55141FDCH000EC"
    let singleLutFilterName = "Sony S-Cinetone (3D LUT)"

    var lutPaths: [String: String] {
        let obsLutDir = "\(NSHomeDirectory())/Library/Application Support/obs-studio/LUTs"
        let davinciKodak = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Film Looks/Rec709 Kodak 2383 D60.cube"
        let fallbackKodak = "\(obsLutDir)/Pixel10Pro_Cinema_ProMist_Warm.cube"
        return [
            "sony": "\(obsLutDir)/Pixel10Pro_SonyAlpha_SCinetone.cube",
            "promist": "\(obsLutDir)/Pixel10Pro_Cinema_ProMist_Warm.cube",
            "teal": "\(obsLutDir)/Pixel10Pro_TealOrange_Blockbuster.cube",
            "leica": "\(obsLutDir)/Pixel10Pro_Leica_Monochrome_BW.cube",
            "kodak": FileManager.default.fileExists(atPath: davinciKodak) ? davinciKodak : fallbackKodak
        ]
    }

    override init() {
        super.init()
        try? FileManager.default.createDirectory(atPath: capturesDir, withIntermediateDirectories: true)
        refreshSavedMemorySlots()

        FileLogger.shared.onNewLogLine = { [weak self] line in
            guard let self = self else { return }
            self.logEntries.append(line)
            if self.logEntries.count > 60 {
                self.logEntries.removeFirst(self.logEntries.count - 60)
            }
        }
        FileLogger.shared.log("INIT", "Starting PixelProCam Studio v2.1 (EN/RU + Live Preview + 2D Pad + M1-M3 + Mini Mode)")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        discoverAdbDeviceSerial()
        connectOBS()
        configurePhoneStayAwake()
        checkPixelStatusLight()

        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollObsStats()
        }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.obsConnected {
                self.connectOBS()
            }
            self.checkPixelStatusLight()
        }
    }

    // MARK: - Live Preview Monitor Control
    func togglePreviewMonitor(_ enabled: Bool) {
        showPreview = enabled
        previewTimer?.invalidate()
        previewTimer = nil
        previewInFlight = false
        if enabled {
            requestPreviewFrame()
            // 6 FPS lightweight preview (zero GPU stall, only runs while preview is visible)
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
                self?.requestPreviewFrame()
            }
        } else {
            previewState.image = nil
        }
        onWindowSizeChangeRequested?()
    }

    func toggleMiniMode(_ enabled: Bool) {
        miniMode = enabled
        if enabled && showPreview {
            togglePreviewMonitor(false)
        }
        onWindowSizeChangeRequested?()
    }

    private func requestPreviewFrame() {
        guard obsConnected, showPreview, !previewInFlight else { return }
        previewInFlight = true
        sendOBSRequest(type: "GetSourceScreenshot", data: [
            "sourceName": "Сцена",
            "imageFormat": "jpg",
            "imageWidth": 512,
            "imageHeight": 288,
            "imageCompressionQuality": 68
        ], id: "live_preview_frame")
    }

    // MARK: - User Memory Slots (M1 / M2 / M3)
    private func refreshSavedMemorySlots() {
        var mask: Set<Int> = []
        for idx in 1...3 {
            if UserDefaults.standard.data(forKey: "pixelprocam_mem_\(idx)") != nil {
                mask.insert(idx)
            }
        }
        savedSlotsMask = mask
    }

    func saveMemorySlot(_ slot: Int) {
        let data = StudioMemorySlot(
            selectedLUT: selectedLUT,
            lutIntensity: lutIntensity,
            vignetteEnabled: vignetteEnabled,
            letterboxEnabled: letterboxEnabled,
            zoomLevel: zoomLevel,
            panX: panX,
            panY: panY,
            isMirrored: isMirrored,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            vargamma: vargamma,
            hueShift: hueShift,
            sharpness: sharpness
        )
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "pixelprocam_mem_\(slot)")
            savedSlotsMask.insert(slot)
            activeMemorySlot = slot
            lastCaptureMessage = tr("💾 Сохранено в слот M\(slot)", "💾 Saved look to slot M\(slot)")
            FileLogger.shared.log("MEMORY", "Saved custom studio look into slot M\(slot)")
        }
    }

    func loadMemorySlot(_ slot: Int) {
        guard let raw = UserDefaults.standard.data(forKey: "pixelprocam_mem_\(slot)"),
              let mem = try? JSONDecoder().decode(StudioMemorySlot.self, from: raw) else {
            // If slot is empty, save current settings into it!
            saveMemorySlot(slot)
            return
        }
        activeMemorySlot = slot
        selectedLUT = mem.selectedLUT
        lutIntensity = mem.lutIntensity
        isMirrored = mem.isMirrored
        brightness = mem.brightness
        contrast = mem.contrast
        saturation = mem.saturation
        vargamma = mem.vargamma
        hueShift = mem.hueShift
        sharpness = mem.sharpness

        applyLUTDebounced()
        setVignette(mem.vignetteEnabled)
        setCinemaLetterbox(mem.letterboxEnabled)
        applyColorCorrection()
        smoothFrameTo(zoom: mem.zoomLevel, panX: mem.panX, panY: mem.panY)
        lastCaptureMessage = tr("✨ Загружен слот M\(slot)", "✨ Loaded custom slot M\(slot)")
        FileLogger.shared.log("MEMORY", "Loaded custom studio look from slot M\(slot)")
    }

    private func discoverAdbDeviceSerial() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.adbPath)
            task.arguments = ["devices"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                for line in out.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "\t")
                    if parts.count == 2 && parts[1] == "device" {
                        let serial = String(parts[0])
                        DispatchQueue.main.async {
                            self.pixelSerial = serial
                        }
                        break
                    }
                }
            }
        }
    }

    // MARK: - OBS WebSocket v5 Connection
    func connectOBS() {
        webSocketTask?.cancel()
        guard let url = URL(string: "ws://127.0.0.1:4455") else { return }
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    func setLiveVuMeter(enabled: Bool) {
        liveVuEnabled = enabled
        FileLogger.shared.log("AUDIO", "Live 60Hz VU-Meter toggled: \(enabled)")
        if !enabled {
            vuState.level = 0.0
        }
        connectOBS()
    }

    private func sendIdentify() {
        let subs = liveVuEnabled ? 65536 : 0
        let identify: [String: Any] = [
            "op": 1,
            "d": [
                "rpcVersion": 1,
                "eventSubscriptions": subs
            ]
        ]
        sendJSON(identify)
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let op = json["op"] as? Int {
                    if op == 0 {
                        self.sendIdentify()
                    } else if op == 2 {
                        self.obsConnected = true
                        FileLogger.shared.log("WS", "Connected & Identified with OBS WebSocket (port 4455)")
                        self.fetchSceneItemIds()
                        self.configureInitialObsStudioSettings()
                        self.pollObsStats()
                        self.onStatusChangeForMenuBar?()
                    } else if op == 5 {
                        if self.liveVuEnabled,
                           let d = json["d"] as? [String: Any],
                           let eventType = d["eventType"] as? String,
                           eventType == "InputVolumeMeters",
                           let eventData = d["eventData"] as? [String: Any],
                           let inputs = eventData["inputs"] as? [[String: Any]] {
                            for input in inputs {
                                if let name = input["inputName"] as? String, name.contains("RØDE"),
                                   let levels = input["inputLevelsMul"] as? [[Double]],
                                   let firstChannel = levels.first, firstChannel.count >= 2 {
                                    let peak = firstChannel[1]
                                    let normalized = min(1.0, max(0.0, pow(peak, 0.35)))
                                    DispatchQueue.main.async {
                                        if abs(self.vuState.level - normalized) > 0.025 {
                                            self.vuState.level = normalized
                                        }
                                    }
                                }
                            }
                        }
                    } else if op == 7 {
                        if let d = json["d"] as? [String: Any],
                           let reqId = d["requestId"] as? String {
                            let respData = d["responseData"] as? [String: Any] ?? [:]
                            self.handleObsResponse(reqId: reqId, data: respData)
                        }
                    }
                }
                self.receiveMessage()
            case .failure(let err):
                if self.obsConnected {
                    FileLogger.shared.log("WS-ERR", "OBS WebSocket disconnected: \(err.localizedDescription)")
                }
                self.obsConnected = false
                self.previewInFlight = false
                self.onStatusChangeForMenuBar?()
            }
        }
    }

    private func configureInitialObsStudioSettings() {
        sendOBSRequest(type: "SetRecordDirectory", data: ["recordDirectory": capturesDir], id: "init_rec_dir")
        applyRodeLipSyncImmediate()
    }

    private func handleObsResponse(reqId: String, data: [String: Any]) {
        if reqId == "live_preview_frame" {
            self.previewInFlight = false
            if let imgStr = data["imageData"] as? String,
               let commaIdx = imgStr.firstIndex(of: ",") {
                let b64 = String(imgStr[imgStr.index(after: commaIdx)...])
                DispatchQueue.global(qos: .userInteractive).async {
                    if let imgData = Data(base64Encoded: b64), let nsImg = NSImage(data: imgData) {
                        DispatchQueue.main.async {
                            self.previewState.image = nsImg
                        }
                    }
                }
            }
        } else if reqId == "get_items", let items = data["sceneItems"] as? [[String: Any]] {
            var foundLetterbox = false
            for item in items {
                let name = item["sourceName"] as? String ?? ""
                let id = item["sceneItemId"] as? Int ?? 1
                let enabled = item["sceneItemEnabled"] as? Bool ?? false
                if name == "Pixel 10 Pro" {
                    self.pixelSceneItemId = id
                } else if name.contains("Виньетка") {
                    self.vignetteSceneItemId = id
                    self.vignetteEnabled = enabled
                } else if name.contains("Заставка") {
                    self.standbySceneItemId = id
                    self.isPrivacyStandby = enabled
                } else if name.contains("Кино-каше") {
                    self.letterboxSceneItemId = id
                    self.letterboxEnabled = enabled
                    foundLetterbox = true
                }
            }
            if !foundLetterbox {
                sendOBSRequest(type: "CreateInput", data: [
                    "sceneName": "Сцена",
                    "inputName": "Кино-каше 2.35:1",
                    "inputKind": "image_source",
                    "inputSettings": [
                        "file": "\(NSHomeDirectory())/Library/Application Support/obs-studio/LUTs/Cinema_Letterbox_235_1.png"
                    ],
                    "sceneItemEnabled": false
                ], id: "create_letterbox")
            }
        } else if reqId == "create_letterbox" {
            if let id = data["sceneItemId"] as? Int {
                self.letterboxSceneItemId = id
            }
        } else if reqId == "get_stats" {
            let fps = data["activeFps"] as? Double ?? 0.0
            let renderTime = data["averageFrameRenderTime"] as? Double ?? 0.0
            let cpu = data["cpuUsage"] as? Double ?? 0.0
            let skipped = data["renderSkippedFrames"] as? Int ?? 0
            let total = data["renderTotalFrames"] as? Int ?? 0

            self.obsFps = fps
            self.obsRenderTimeMs = renderTime
            self.obsCpuUsage = cpu
            let newSkips = max(0, skipped - self.lastSkippedFrames)
            self.lastSkippedFrames = skipped
            self.obsSkippedFrames = skipped
            self.obsTotalFrames = total

            let minTargetFps = is60FpsMode ? 55.0 : 28.0
            if newSkips > 0 || (fps < minTargetFps && total > 150) {
                FileLogger.shared.log("WARN-LAG", String(format: "Frame drop! FPS=%.1f Render=%.2fms CPU=%.1f%% NewDrops=+%d (Total=%d/%d)", fps, renderTime, cpu, newSkips, skipped, total), uiVisible: true)
            } else {
                FileLogger.shared.log("STATS", String(format: "FPS=%.1f | Render=%.2fms | OBS-CPU=%.1f%% | Drops=%d (%d/%d)", fps, renderTime, cpu, newSkips, skipped, total), uiVisible: false)
            }
        } else if reqId == "vision_frame_shot" {
            if let imgStr = data["imageData"] as? String {
                self.processVisionFaceDetection(base64DataUri: imgStr)
            }
        }
    }

    func pollObsStats() {
        guard obsConnected else { return }
        sendOBSRequest(type: "GetStats", data: [:], id: "get_stats")
    }

    private func fetchSceneItemIds() {
        sendOBSRequest(type: "GetSceneItemList", data: ["sceneName": "Сцена"], id: "get_items")
    }

    func sendOBSRequest(type: String, data: [String: Any], id: String = UUID().uuidString) {
        let payload: [String: Any] = [
            "op": 6,
            "d": [
                "requestType": type,
                "requestId": id,
                "requestData": data
            ]
        ]
        sendJSON(payload)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    // MARK: - Studio Photo Snapshot & Video Recording
    func takeStudioPhoto() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "MrPixelCamera_Photo_\(df.string(from: Date())).png"
        let fullPath = "\(capturesDir)/\(filename)"

        sendOBSRequest(type: "SaveSourceScreenshot", data: [
            "sourceName": "Сцена",
            "imageFormat": "png",
            "imageFilePath": fullPath,
            "imageWidth": 1920,
            "imageHeight": 1080
        ], id: "save_photo")

        NSSound(named: NSSound.Name("Tink"))?.play()
        lastCaptureMessage = tr("📸 Сохранено: \(filename)", "📸 Saved: \(filename)")
        FileLogger.shared.log("PHOTO", "Saved 1920x1080 studio snapshot to \(fullPath)")
    }

    func toggleStudioRecording() {
        if !isRecording {
            isRecording = true
            recordSeconds = 0
            sendOBSRequest(type: "SetRecordDirectory", data: ["recordDirectory": capturesDir])
            sendOBSRequest(type: "StartRecord", data: [:], id: "start_rec")
            lastCaptureMessage = tr("🔴 Запись в /Captures...", "🔴 Recording to /Captures...")
            FileLogger.shared.log("RECORD", "Started studio video recording to \(capturesDir)")
            recordTimer?.invalidate()
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.recordSeconds += 1
                self?.onStatusChangeForMenuBar?()
            }
        } else {
            isRecording = false
            recordTimer?.invalidate()
            recordTimer = nil
            sendOBSRequest(type: "StopRecord", data: [:], id: "stop_rec")
            lastCaptureMessage = tr("🎬 Видео сохранено в Captures", "🎬 Video saved to Captures")
            FileLogger.shared.log("RECORD", "Stopped studio video recording (duration: \(recordSeconds)s)")
        }
        onStatusChangeForMenuBar?()
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: capturesDir))
    }

    func openAuthorWebsite() {
        if let url = URL(string: "https://mrmo.es") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Apple Vision Neural Engine AI Auto-Framing
    func toggleAiAutoFraming(_ enabled: Bool) {
        aiAutoFrameEnabled = enabled
        aiFrameTimer?.invalidate()
        aiFrameTimer = nil
        if enabled {
            aiFaceStatus = "Vision AI"
            FileLogger.shared.log("VISION-AI", "Enabled Apple Vision Neural Engine Auto-Framing")
            requestVisionFrameOnce(immediate: true)
            aiFrameTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.requestVisionFrameOnce(immediate: false)
            }
        } else {
            aiFaceStatus = "OFF"
            FileLogger.shared.log("VISION-AI", "Disabled Apple Vision Auto-Framing")
        }
        onStatusChangeForMenuBar?()
    }

    func triggerSingleAiFaceFrame() {
        aiFaceStatus = "..."
        requestVisionFrameOnce(immediate: true)
    }

    private func requestVisionFrameOnce(immediate: Bool) {
        guard obsConnected else { return }
        forceImmediateAiFrame = immediate
        sendOBSRequest(type: "GetSourceScreenshot", data: [
            "sourceName": "Pixel 10 Pro",
            "imageFormat": "jpg",
            "imageWidth": 256,
            "imageHeight": 144,
            "imageCompressionQuality": 60
        ], id: "vision_frame_shot")
    }

    private func processVisionFaceDetection(base64DataUri: String) {
        guard let commaIdx = base64DataUri.firstIndex(of: ",") else { return }
        let b64 = String(base64DataUri[base64DataUri.index(after: commaIdx)...])
        guard let imgData = Data(base64Encoded: b64) else { return }

        let forceNow = self.forceImmediateAiFrame
        self.forceImmediateAiFrame = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let handler = VNImageRequestHandler(data: imgData, options: [:])
            let request = VNDetectFaceRectanglesRequest { [weak self] req, _ in
                guard let self = self else { return }
                guard let results = req.results as? [VNFaceObservation],
                      let mainFace = results.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }) else {
                    DispatchQueue.main.async {
                        self.aiFaceStatus = self.tr("Нет лица", "No face")
                    }
                    return
                }

                let box = mainFace.boundingBox
                let faceCenterX = Double(box.midX)
                let faceCenterY = 1.0 - Double(box.midY)
                let faceH = Double(box.height)

                DispatchQueue.main.async {
                    let movedX = abs(faceCenterX - self.lastDetectedFaceX)
                    let movedY = abs(faceCenterY - self.lastDetectedFaceY)
                    let movedH = abs(faceH - self.lastDetectedFaceH)

                    guard forceNow || movedX > 0.048 || movedY > 0.048 || movedH > 0.045 else {
                        return
                    }
                    self.lastDetectedFaceX = faceCenterX
                    self.lastDetectedFaceY = faceCenterY
                    self.lastDetectedFaceH = faceH

                    let desiredZoom = min(1.75, max(1.22, 0.27 / max(0.10, faceH)))
                    let denom = max(0.12, desiredZoom - 1.0)

                    let rawPanX: Double
                    if self.isMirrored {
                        rawPanX = (faceCenterX - 0.50) * (1.5 * desiredZoom) / denom
                    } else {
                        rawPanX = (0.50 - faceCenterX) * (1.5 * desiredZoom) / denom
                    }
                    let rawPanY = (0.46 - faceCenterY) * (1.5 * desiredZoom) / denom

                    let targetPanX = min(0.85, max(-0.85, rawPanX))
                    let targetPanY = min(0.85, max(-0.85, rawPanY))

                    self.aiFaceStatus = String(format: "%.2fx", desiredZoom)
                    FileLogger.shared.log("VISION-AI", String(format: "Auto-Framing face (x=%.2f, y=%.2f) -> Zoom=%.2fx Pan=(%.2f, %.2f)", faceCenterX, faceCenterY, desiredZoom, targetPanX, targetPanY))
                    self.smoothFrameTo(zoom: desiredZoom, panX: targetPanX, panY: targetPanY)
                }
            }
            try? handler.perform([request])
        }
    }

    // MARK: - Switch UVC Capture & OBS Canvas FPS Mode
    func setCameraFpsMode(use60Fps: Bool) {
        is60FpsMode = use60Fps
        let num = use60Fps ? 60000240 : 30000030
        let targetCanvasFps = use60Fps ? 60 : 30
        rodeLipSyncMs = use60Fps ? 35.0 : 65.0

        FileLogger.shared.log("LATENCY", "Switching pipeline to \(use60Fps ? "60 FPS Ultra-Low-Latency (~35ms)" : "30 FPS Studio (~65ms)")")

        sendOBSRequest(type: "SetInputSettings", data: [
            "inputName": "Pixel 10 Pro",
            "inputSettings": [
                "buffering": false,
                "frame_rate": [
                    "denominator": 1000000,
                    "numerator": num
                ]
            ],
            "overlay": true
        ])

        sendOBSRequest(type: "StopVirtualCam", data: [:], id: "vc_stop_fps")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            self.sendOBSRequest(type: "SetVideoSettings", data: [
                "fpsNumerator": targetCanvasFps,
                "fpsDenominator": 1,
                "baseWidth": 1920,
                "baseHeight": 1080,
                "outputWidth": 1920,
                "outputHeight": 1080
            ], id: "set_canvas_fps")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.sendOBSRequest(type: "StartVirtualCam", data: [:], id: "vc_start_fps")
                self?.applyRodeLipSyncImmediate()
            }
        }
        onStatusChangeForMenuBar?()
    }

    // MARK: - 1. Physical Lens & Prime Focal Length Selection
    func selectPhysicalLens(_ lens: String) {
        if !pixelScreenUnlocked {
            FileLogger.shared.log("LENS-WARN", tr("Экран Pixel заблокирован! Разблокируйте отпечатком 1 раз.", "Pixel screen locked! Unlock once with fingerprint."))
        }

        switch lens {
        case "0.5x":
            selectedPhysicalLens = "0.5x"
            selectedPrimeFocal = "12mm"
            currentCameraFacing = "0.5x 12mm f/2.2"
            FileLogger.shared.log("LENS", "Switched Pixel physical lens to 0.5x Ultra-Wide")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 414 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "1x":
            selectedPhysicalLens = "1x"
            selectedPrimeFocal = "24mm"
            currentCameraFacing = "1x 24mm f/1.68"
            FileLogger.shared.log("LENS", "Switched Pixel physical lens to 1x Main Wide")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 540 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "2x":
            selectedPhysicalLens = "2x"
            selectedPrimeFocal = "50mm"
            currentCameraFacing = "2x 50mm Optical"
            FileLogger.shared.log("LENS", "Switched Pixel physical lens to 2x Optical")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 666 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "5x":
            selectedPhysicalLens = "5x"
            selectedPrimeFocal = "113mm"
            currentCameraFacing = "5x 113mm Tele"
            FileLogger.shared.log("LENS", "Switched to 5x Telephoto mode (113mm)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 666 2149")
            smoothFrameTo(zoom: 2.25, panX: 0.0, panY: 0.0)

        case "front":
            selectedPhysicalLens = (selectedPhysicalLens == "front") ? "1x" : "front"
            currentCameraFacing = (selectedPhysicalLens == "front") ? "Front 42MP 17mm" : "1x 24mm f/1.68"
            FileLogger.shared.log("LENS", "Toggled Front / Rear camera module")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 126 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "picker":
            FileLogger.shared.log("LENS", "Opened native CameraPickerDialog on Pixel screen")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input swipe 126 2149 126 2149 700")

        default:
            break
        }
        onStatusChangeForMenuBar?()
    }

    func selectPrimeFocalLength(_ focal: String) {
        selectedPrimeFocal = focal
        switch focal {
        case "24mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 24mm (1.00x)")
            smoothFrameTo(zoom: 1.00, panX: 0.0, panY: 0.0)
        case "35mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 35mm (1.35x)")
            smoothFrameTo(zoom: 1.35, panX: 0.0, panY: 0.0)
        case "50mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 50mm (1.75x)")
            smoothFrameTo(zoom: 1.75, panX: 0.0, panY: 0.0)
        case "85mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 85mm (2.35x)")
            smoothFrameTo(zoom: 2.35, panX: 0.0, panY: -0.05)
        default:
            break
        }
        onStatusChangeForMenuBar?()
    }

    // MARK: - 2. Framing / Smooth Interpolated Dolly Zoom & Mirroring
    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTop = enabled
        FileLogger.shared.log("WINDOW", "Always on Top = \(enabled)")
        DispatchQueue.main.async {
            for win in NSApp.windows where win.title.contains("Mr. Pixel") || win.title.contains("PixelProCam") {
                win.level = enabled ? .floating : .normal
            }
        }
        onStatusChangeForMenuBar?()
    }

    func toggleMirror(_ enabled: Bool) {
        isMirrored = enabled
        FileLogger.shared.log("MIRROR", "Horizontal Mirror = \(enabled)")
        applyFramingImmediate()
        onStatusChangeForMenuBar?()
    }

    func applyFramingImmediate() {
        let baseW = 1920.0
        let baseH = 1080.0
        let scaledW = baseW * zoomLevel
        let scaledH = baseH * zoomLevel
        let maxOffsetX = (scaledW - baseW) / 2.0
        let maxOffsetY = (scaledH - baseH) / 2.0

        let finalScaleX = isMirrored ? -zoomLevel : zoomLevel
        let posX: Double
        if isMirrored {
            posX = baseW + maxOffsetX + (panX * maxOffsetX)
        } else {
            posX = -(maxOffsetX) + (panX * maxOffsetX)
        }
        let posY = -(maxOffsetY) + (panY * maxOffsetY)

        let transform: [String: Any] = [
            "scaleX": finalScaleX,
            "scaleY": zoomLevel,
            "positionX": posX,
            "positionY": posY,
            "boundsType": "OBS_BOUNDS_NONE"
        ]
        sendOBSRequest(type: "SetSceneItemTransform", data: [
            "sceneName": "Сцена",
            "sceneItemId": pixelSceneItemId,
            "sceneItemTransform": transform
        ])
    }

    func smoothFrameTo(zoom targetZoom: Double, panX targetX: Double, panY targetY: Double) {
        dollyTimer?.invalidate()
        let startZoom = self.zoomLevel
        let startX = self.panX
        let startY = self.panY
        if abs(targetZoom - startZoom) > 0.01 {
            FileLogger.shared.log("DOLLY", String(format: "Smooth Dolly %.2fx -> %.2fx", startZoom, targetZoom))
        }

        let steps = 18
        var currentStep = 0
        dollyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            currentStep += 1
            let t = Double(currentStep) / Double(steps)
            let ease = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            self.zoomLevel = startZoom + (targetZoom - startZoom) * ease
            self.panX = startX + (targetX - startX) * ease
            self.panY = startY + (targetY - startY) * ease
            self.applyFramingImmediate()
            if currentStep >= steps {
                timer.invalidate()
            }
        }
    }

    // MARK: - 3. Color, Single-Filter 3D LUT Switcher & 2.35:1 Cinema Letterbox
    func selectLUT(_ lutKey: String) {
        selectedLUT = lutKey
        applyLUTDebounced()
        onStatusChangeForMenuBar?()
    }

    func applyLUTDebounced() {
        lutUpdateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.selectedLUT == "none" {
                self.sendOBSRequest(type: "SetSourceFilterEnabled", data: [
                    "sourceName": "Pixel 10 Pro",
                    "filterName": self.singleLutFilterName,
                    "filterEnabled": false
                ])
                FileLogger.shared.log("LUT", "Disabled 3D LUT (Pure Rec.709)")
            } else if let path = self.lutPaths[self.selectedLUT] {
                self.sendOBSRequest(type: "SetSourceFilterSettings", data: [
                    "sourceName": "Pixel 10 Pro",
                    "filterName": self.singleLutFilterName,
                    "filterSettings": [
                        "image_path": path,
                        "clut_amount": self.lutIntensity
                    ],
                    "overlay": true
                ])
                self.sendOBSRequest(type: "SetSourceFilterEnabled", data: [
                    "sourceName": "Pixel 10 Pro",
                    "filterName": self.singleLutFilterName,
                    "filterEnabled": true
                ])
                FileLogger.shared.log("LUT", "Switched 3D LUT to '\(self.selectedLUT)' (\(Int(self.lutIntensity * 100))%)")
            }
        }
        lutUpdateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    func setVignette(_ enabled: Bool) {
        vignetteEnabled = enabled
        FileLogger.shared.log("OPTICS", "Optical Vignette 35mm f/1.4 = \(enabled)")
        sendOBSRequest(type: "SetSceneItemEnabled", data: [
            "sceneName": "Сцена",
            "sceneItemId": vignetteSceneItemId,
            "sceneItemEnabled": enabled
        ])
        onStatusChangeForMenuBar?()
    }

    func setCinemaLetterbox(_ enabled: Bool) {
        letterboxEnabled = enabled
        FileLogger.shared.log("CINEMA", "Anamorphic 2.35:1 Cinema Letterbox = \(enabled)")
        sendOBSRequest(type: "SetSceneItemEnabled", data: [
            "sceneName": "Сцена",
            "sceneItemId": letterboxSceneItemId,
            "sceneItemEnabled": enabled
        ])
        onStatusChangeForMenuBar?()
    }

    func applyColorCorrection() {
        colorUpdateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendOBSRequest(type: "SetSourceFilterSettings", data: [
                "sourceName": "Pixel 10 Pro",
                "filterName": "Коррекция цвета",
                "filterSettings": [
                    "brightness": self.brightness,
                    "contrast": self.contrast,
                    "saturation": self.saturation,
                    "gamma": self.vargamma,
                    "hue_shift": self.hueShift
                ],
                "overlay": true
            ])
            self.sendOBSRequest(type: "SetSourceFilterSettings", data: [
                "sourceName": "Pixel 10 Pro",
                "filterName": "Резкость (Детализация)",
                "filterSettings": [
                    "sharpness": self.sharpness
                ],
                "overlay": true
            ])
        }
        colorUpdateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
    }

    func resetExposureAuto() {
        brightness = 0.015; contrast = 0.08; vargamma = -0.02
        applyColorCorrection()
    }

    func resetWhiteBalanceAuto() {
        hueShift = 0.0; saturation = 0.06
        applyColorCorrection()
    }

    func resetAllImageAuto() {
        brightness = 0.015; contrast = 0.08; saturation = 0.06; vargamma = -0.02; hueShift = 0.0; sharpness = 0.06
        activeLightingPreset = "day"
        applyColorCorrection()
        triggerFaceAutofocus()
    }

    // MARK: - 4. Studio Lighting Scenarios
    func applyLightingPreset(_ preset: String) {
        activeLightingPreset = preset
        FileLogger.shared.log("PRESET", "Applied lighting preset: \(preset)")
        switch preset {
        case "day":
            brightness = 0.015; contrast = 0.08; saturation = 0.06; vargamma = -0.02; hueShift = 0.0; sharpness = 0.06
            selectLUT("sony"); lutIntensity = 0.75; applyLUTDebounced()
        case "evening":
            brightness = 0.028; contrast = 0.11; saturation = 0.04; vargamma = 0.03; hueShift = -2.5; sharpness = 0.05
            selectLUT("promist"); lutIntensity = 0.72; applyLUTDebounced()
        case "monitor":
            brightness = 0.010; contrast = 0.10; saturation = 0.08; vargamma = -0.03; hueShift = -4.5; sharpness = 0.06
            selectLUT("sony"); lutIntensity = 0.80; applyLUTDebounced()
        case "podcast":
            brightness = 0.005; contrast = 0.16; saturation = 0.05; vargamma = -0.06; hueShift = 0.0; sharpness = 0.07
            selectLUT("kodak"); lutIntensity = 0.68; applyLUTDebounced()
        default:
            break
        }
        applyColorCorrection()
        onStatusChangeForMenuBar?()
    }

    // MARK: - 5. RØDE NT1 5th Gen Audio Control
    func applyRodeLipSyncDebounced() {
        syncUpdateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyRodeLipSyncImmediate()
        }
        syncUpdateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func applyRodeLipSyncImmediate() {
        let ms = Int(rodeLipSyncMs.rounded())
        sendOBSRequest(type: "SetInputAudioSyncOffset", data: [
            "inputName": "RØDE NT1 5th Gen",
            "inputAudioSyncOffset": ms
        ])
        FileLogger.shared.log("LIPSYNC", "RØDE NT1 5th Gen Hardware Audio Sync Offset = +\(ms) ms")
    }

    func toggleRodeMute() {
        isRodeMuted.toggle()
        FileLogger.shared.log("AUDIO", "RØDE NT1 Mute = \(isRodeMuted)")
        sendOBSRequest(type: "SetInputMute", data: [
            "inputName": "RØDE NT1 5th Gen",
            "inputMuted": isRodeMuted
        ])
        onStatusChangeForMenuBar?()
    }

    func openRodeCentralApp() {
        FileLogger.shared.log("AUDIO", "Opening RØDE Central.app")
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RODE Central.app"))
    }

    func setRodeAudioMode(_ mode: String) {
        activeAudioPreset = mode
        if mode == "pure" {
            for fname in ["ИИ-Шумоподавление (RNNoise)", "Шумовой гейт (Паузы)", "Эквалайзер RØDE NT1", "Студийный компрессор"] {
                sendOBSRequest(type: "SetSourceFilterEnabled", data: [
                    "sourceName": "RØDE NT1 5th Gen",
                    "filterName": fname,
                    "filterEnabled": false
                ])
            }
            sendOBSRequest(type: "SetSourceFilterEnabled", data: [
                "sourceName": "RØDE NT1 5th Gen",
                "filterName": "Лимитер (-1.5 dB)",
                "filterEnabled": rodeSafetyLimiter
            ])
            FileLogger.shared.log("AUDIO", "Switched to Pure RØDE Central Hardware APHEX DSP")
        } else {
            var eqSettings: [String: Any] = [:]
            var compSettings: [String: Any] = [:]
            if mode == "radio" {
                eqSettings = ["low": 3.0, "mid": -1.5, "high": 2.2]
                compSettings = ["ratio": 4.0, "threshold": -21.0, "attack_time": 6, "release_time": 60, "output_gain": 3.0]
            } else {
                eqSettings = ["low": 1.2, "mid": -0.8, "high": 1.8]
                compSettings = ["ratio": 3.0, "threshold": -20.0, "attack_time": 8, "release_time": 65, "output_gain": 2.0]
            }
            sendOBSRequest(type: "SetSourceFilterSettings", data: [
                "sourceName": "RØDE NT1 5th Gen",
                "filterName": "Эквалайзер RØDE NT1",
                "filterSettings": eqSettings,
                "overlay": true
            ])
            sendOBSRequest(type: "SetSourceFilterSettings", data: [
                "sourceName": "RØDE NT1 5th Gen",
                "filterName": "Студийный компрессор",
                "filterSettings": compSettings,
                "overlay": true
            ])
            for fname in ["Эквалайзер RØDE NT1", "Студийный компрессор", "Лимитер (-1.5 dB)"] {
                sendOBSRequest(type: "SetSourceFilterEnabled", data: [
                    "sourceName": "RØDE NT1 5th Gen",
                    "filterName": fname,
                    "filterEnabled": true
                ])
            }
            FileLogger.shared.log("AUDIO", "Enabled optional OBS voice profile: \(mode)")
        }
        onStatusChangeForMenuBar?()
    }

    // MARK: - 6. Privacy Standby & OLED Blackout
    func togglePrivacyStandby() {
        isPrivacyStandby.toggle()
        sendOBSRequest(type: "SetSceneItemEnabled", data: [
            "sceneName": "Сцена",
            "sceneItemId": standbySceneItemId,
            "sceneItemEnabled": isPrivacyStandby
        ])
        if isPrivacyStandby && !isRodeMuted {
            toggleRodeMute()
        } else if !isPrivacyStandby && isRodeMuted {
            toggleRodeMute()
        }
        FileLogger.shared.log("STANDBY", "Privacy Standby = \(isPrivacyStandby)")
        onStatusChangeForMenuBar?()
    }

    func togglePixelBlackout(_ enabled: Bool) {
        isBlackoutEnabled = enabled
        FileLogger.shared.log("BLACKOUT", "OLED Blackout = \(enabled)")
        if enabled {
            runADBCommand("svc power stayon usb && settings put system screen_brightness_mode 0 && settings put system screen_brightness 1")
        } else {
            runADBCommand("settings put system screen_brightness 130")
        }
    }

    // MARK: - 7. Pixel 10 Pro Hardware ADB Commands
    func configurePhoneStayAwake() {
        runADBCommand("svc power stayon usb && settings put system screen_off_timeout 1800000")
    }

    func checkPixelStatusLight() {
        DispatchQueue.global(qos: .utility).async {
            let ioTask = Process()
            ioTask.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            ioTask.arguments = ["-p", "IOUSB", "-l", "-w", "0"]
            let ioPipe = Pipe()
            ioTask.standardOutput = ioPipe
            ioTask.standardError = Pipe()
            if (try? ioTask.run()) != nil {
                let ioData = ioPipe.fileHandleForReading.readDataToEndOfFile()
                let ioOut = String(data: ioData, encoding: .utf8) ?? ""
                if let range = ioOut.range(of: "Pixel") {
                    let sub = String(ioOut[range.lowerBound...].prefix(1800))
                    var speedText = "2.0 (480M)"
                    var superSpeed = false
                    if sub.contains("\"UsbLinkSpeed\" = 10000000000") {
                        speedText = "3.2 (10G)"
                        superSpeed = true
                    } else if sub.contains("\"UsbLinkSpeed\" = 5000000000") {
                        speedText = "3.1 (5G)"
                        superSpeed = true
                    }
                    DispatchQueue.main.async {
                        self.usbCableSpeed = speedText
                        self.usbIsSuperSpeed = superSpeed
                    }
                }
            }
        }

        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.adbPath)
            task.arguments = ["-s", self.pixelSerial, "shell", "dumpsys window | grep mCurrentFocus ; dumpsys battery | grep -E 'level:|temperature:'"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                let deadline = Date().addingTimeInterval(1.5)
                while task.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if task.isRunning {
                    task.terminate()
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                let connected = !out.isEmpty
                let unlocked = !out.contains("NotificationShade") && !out.contains("Keyguard")

                var batt = self.pixelBatteryLevel
                var temp = self.pixelTempC
                for line in out.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("level:"), let val = Int(trimmed.replacingOccurrences(of: "level:", with: "").trimmingCharacters(in: .whitespaces)) {
                        batt = val
                    } else if trimmed.hasPrefix("temperature:"), let val = Double(trimmed.replacingOccurrences(of: "temperature:", with: "").trimmingCharacters(in: .whitespaces)) {
                        temp = val / 10.0
                    }
                }

                DispatchQueue.main.async {
                    if self.pixelConnected != connected {
                        self.pixelConnected = connected
                    }
                    if connected && self.pixelScreenUnlocked != unlocked {
                        self.pixelScreenUnlocked = unlocked
                    }
                    self.pixelBatteryLevel = batt
                    self.pixelTempC = temp
                }
            } catch {}
        }
    }

    func triggerFaceAutofocus() {
        FileLogger.shared.log("ADB", "Triggering Face/Eye Center Lock AF (540, 1100)")
        runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 540 1100")
    }

    func triggerContinuousAutofocus() {
        FileLogger.shared.log("ADB", "Resetting to Continuous Video AF (CAF)")
        runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 540 320")
    }

    func toggleHQMode() {
        FileLogger.shared.log("ADB", "Toggling Pixel HQ Mode (954, 2149)")
        runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 954 2149")
        isHQMode.toggle()
    }

    private func runADBCommand(_ shellCmd: String) {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.adbPath)
            task.arguments = ["-s", self.pixelSerial, "shell", shellCmd]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            let deadline = Date().addingTimeInterval(2.5)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning {
                task.terminate()
            }
        }
    }
}

// MARK: - Isolated Subviews (VU Meter, Live Preview Monitor, 2D Framing Trackpad)
struct IsolatedVuMeterBar: View {
    @ObservedObject var vuState: VuMeterState
    let isMuted: Bool
    let isEnabled: Bool
    let placeholderText: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.45))
                if isEnabled {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [.green, .green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(4, geo.size.width * (isMuted ? 0.0 : vuState.level)))
                } else {
                    Text(placeholderText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
        .frame(height: 16)
    }
}

struct LiveCinemaPreviewView: View {
    @ObservedObject var previewState: LivePreviewState
    @ObservedObject var ctrl: StudioController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)

            if let img = previewState.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .cornerRadius(8)
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(ctrl.tr("Подключение видеопотока OBS...", "Connecting OBS live feed..."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Optional Rule-of-Thirds 3x3 Cinema Grid
            if ctrl.showGridOverlay {
                GeometryReader { geo in
                    Path { p in
                        let w = geo.size.width
                        let h = geo.size.height
                        p.move(to: CGPoint(x: w / 3, y: 0)); p.addLine(to: CGPoint(x: w / 3, y: h))
                        p.move(to: CGPoint(x: 2 * w / 3, y: 0)); p.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                        p.move(to: CGPoint(x: 0, y: h / 3)); p.addLine(to: CGPoint(x: w, y: h / 3))
                        p.move(to: CGPoint(x: 0, y: 2 * h / 3)); p.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                    }
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.7)
                }
                .allowsHitTesting(false)
            }

            // Top-left live HUD overlay badges
            VStack {
                HStack {
                    if ctrl.isRecording {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Text("REC").font(.system(size: 9, weight: .black, design: .monospaced))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65)).foregroundColor(.white).cornerRadius(4)
                    }
                    Text("\(ctrl.selectedLUT.uppercased()) • \(Int(ctrl.obsFps)) FPS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6)).foregroundColor(.cyan).cornerRadius(4)

                    Spacer()

                    Button(action: { ctrl.showGridOverlay.toggle() }) {
                        Text(ctrl.showGridOverlay ? "# 3×3: ON" : "# 3×3: OFF")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(ctrl.showGridOverlay ? .yellow : .secondary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                Spacer()
            }
        }
        .frame(width: 320, height: 180)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct InteractiveFramingPad: View {
    @ObservedObject var ctrl: StudioController

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let z = max(1.0, ctrl.zoomLevel)
            let boxW = w / z
            let boxH = h / z
            let maxMoveX = (w - boxW) / 2.0
            let maxMoveY = (h - boxH) / 2.0
            let offsetX = -ctrl.panX * maxMoveX
            let offsetY = -ctrl.panY * maxMoveY

            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.16), lineWidth: 1))

                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 4)); p.addLine(to: CGPoint(x: w / 2, y: h - 4))
                    p.move(to: CGPoint(x: 4, y: h / 2)); p.addLine(to: CGPoint(x: w - 4, y: h / 2))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.6)

                // Active Crop Viewport Rectangle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.purple.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.purple, lineWidth: 1.3))
                    .frame(width: max(12, boxW), height: max(8, boxH))
                    .offset(x: offsetX, y: offsetY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if ctrl.zoomLevel < 1.10 {
                            ctrl.zoomLevel = 1.22
                        }
                        let normX = (val.location.x / w - 0.5) * -2.0
                        let normY = (val.location.y / h - 0.5) * -2.0
                        ctrl.panX = min(1.0, max(-1.0, normX))
                        ctrl.panY = min(1.0, max(-1.0, normY))
                        ctrl.applyFramingImmediate()
                    }
            )
            .onTapGesture(count: 2) {
                ctrl.smoothFrameTo(zoom: ctrl.zoomLevel, panX: 0.0, panY: 0.0)
            }
        }
        .frame(width: 96, height: 54)
        .help(ctrl.tr("Тяните рамку для сдвига кадра • Двойной клик — центр", "Drag crop box to pan • Double-click to center"))
    }
}

// MARK: - Pro Cinema Card Container
struct StudioCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    let trailingText: String?
    let content: Content

    init(title: String, icon: String, accent: Color, trailingText: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.trailingText = trailingText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(accent)
                    .frame(width: 18, height: 18)
                    .background(accent.opacity(0.16))
                    .cornerRadius(4)

                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundColor(.primary.opacity(0.92))

                Spacer()

                if let trailing = trailingText {
                    Text(trailing)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - SwiftUI Pro Cinema Dark Deck v2.1
struct StudioPanelView: View {
    @ObservedObject var ctrl: StudioController

    private func formatRecordTime(_ secs: Int) -> String {
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    var computedHeight: CGFloat {
        if ctrl.miniMode { return 118 }
        var h: CGFloat = 685
        if ctrl.showPreview { h += 192 }
        if ctrl.showLogs { h += 104 }
        return h
    }

    var body: some View {
        VStack(spacing: 7) {
            // TOP TRANSPORT, LANGUAGE & MODE HEADER BAR
            HStack(spacing: 5) {
                HStack(spacing: 7) {
                    Group {
                        if let logoPath = Bundle.main.path(forResource: "mo_logo", ofType: "png") ?? (FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Desktop/PixelProCam/assets/icons/mo_logo.png") ? "\(NSHomeDirectory())/Desktop/PixelProCam/assets/icons/mo_logo.png" : nil),
                           let nsLogo = NSImage(contentsOfFile: logoPath) {
                            Image(nsImage: nsLogo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.black)
                                    .frame(width: 30, height: 30)
                                Text("Mo.")
                                    .font(.system(size: 11, weight: .black, design: .serif))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .onTapGesture { ctrl.openAuthorWebsite() }
                    .help("mrmo.es")

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("Mr. Pixel Camera")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text("v2.1")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.22)).foregroundColor(.orange).cornerRadius(4)
                        }
                        Text(ctrl.lastCaptureMessage.isEmpty ? "Pixel 10 Pro • RØDE NT1 • Vision AI" : ctrl.lastCaptureMessage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(ctrl.lastCaptureMessage.isEmpty ? .secondary : .green)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Preview Toggle
                if !ctrl.miniMode {
                    Button(action: { ctrl.togglePreviewMonitor(!ctrl.showPreview) }) {
                        HStack(spacing: 3) {
                            Image(systemName: ctrl.showPreview ? "eye.fill" : "eye")
                            Text(ctrl.tr("Превью", "Preview"))
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(ctrl.showPreview ? Color.purple : Color.white.opacity(0.08))
                        .foregroundColor(.white).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Mini Mode Toggle
                Button(action: { ctrl.toggleMiniMode(!ctrl.miniMode) }) {
                    HStack(spacing: 3) {
                        Image(systemName: ctrl.miniMode ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        Text(ctrl.miniMode ? ctrl.tr("Полный", "Full") : ctrl.tr("Мини", "Mini"))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(ctrl.miniMode ? Color.teal : Color.white.opacity(0.08))
                    .foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Pin Always on Top
                Button(action: { ctrl.setAlwaysOnTop(!ctrl.alwaysOnTop) }) {
                    Image(systemName: ctrl.alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(ctrl.alwaysOnTop ? Color.indigo : Color.white.opacity(0.08))
                        .foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(ctrl.tr("Закрепить поверх всех окон", "Pin window always on top"))

                // Studio Photo
                Button(action: { ctrl.takeStudioPhoto() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "camera.fill")
                        Text(ctrl.tr("ФОТО", "PHOTO"))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.22)).foregroundColor(.cyan).cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Video Record
                Button(action: { ctrl.toggleStudioRecording() }) {
                    HStack(spacing: 3) {
                        Image(systemName: ctrl.isRecording ? "stop.circle.fill" : "record.circle")
                        Text(ctrl.isRecording ? formatRecordTime(ctrl.recordSeconds) : ctrl.tr("ЗАПИСЬ", "REC"))
                    }
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(ctrl.isRecording ? Color.red : Color.red.opacity(0.22))
                    .foregroundColor(ctrl.isRecording ? .white : .red).cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { ctrl.openCapturesFolder() }) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(Color.white.opacity(0.08)).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(ctrl.tr("Открыть папку Captures", "Open Captures folder"))

                // Privacy Standby
                Button(action: { ctrl.togglePrivacyStandby() }) {
                    HStack(spacing: 3) {
                        Image(systemName: ctrl.isPrivacyStandby ? "play.fill" : "pause.fill")
                        Text(ctrl.isPrivacyStandby ? ctrl.tr("ЭФИР", "LIVE") : ctrl.tr("ПАУЗА", "PAUSE"))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(ctrl.isPrivacyStandby ? Color.red : Color.orange.opacity(0.22))
                    .foregroundColor(ctrl.isPrivacyStandby ? .white : .orange).cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Language Switcher EN / RU
                Button(action: { ctrl.toggleLanguage() }) {
                    Text(ctrl.lang == "ru" ? "RU" : "EN")
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.yellow)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(ctrl.tr("Switch interface to English", "Переключить интерфейс на Русский"))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.38)))

            // MINI DECK MODE STRIP
            if ctrl.miniMode {
                HStack(spacing: 6) {
                    lensMiniBtn("0.5x", id: "0.5x")
                    lensMiniBtn("1x", id: "1x")
                    lensMiniBtn("2x", id: "2x")
                    lensMiniBtn("5x", id: "5x")
                    lensMiniBtn("🤳", id: "front")

                    Divider().frame(height: 18)

                    lutMiniBtn("S-Cine", id: "sony", color: .blue)
                    lutMiniBtn("ProMist", id: "promist", color: .orange)
                    lutMiniBtn("Kodak", id: "kodak", color: .yellow)
                    lutMiniBtn("Teal", id: "teal", color: .teal)
                    lutMiniBtn("B&W", id: "leica", color: .gray)

                    Divider().frame(height: 18)

                    Button(action: { ctrl.triggerSingleAiFaceFrame() }) {
                        Text("🎯 AI").font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(Color.purple.opacity(0.35)).cornerRadius(5)
                    }.buttonStyle(.plain)

                    Button(action: { ctrl.toggleRodeMute() }) {
                        Text(ctrl.isRodeMuted ? "🔇" : "🎙")
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(ctrl.isRodeMuted ? Color.red : Color.green.opacity(0.25)).cornerRadius(5)
                    }.buttonStyle(.plain)

                    Spacer()

                    Button(action: { ctrl.openAuthorWebsite() }) {
                        Text("mrmo.es ↗")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.85))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            } else {
                // COLLAPSIBLE LIVE PREVIEW MONITOR
                if ctrl.showPreview {
                    HStack(spacing: 12) {
                        LiveCinemaPreviewView(previewState: ctrl.previewState, ctrl: ctrl)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(ctrl.tr("📺 Живой Монитор Студии", "📺 Live Studio Monitor"))
                                .font(.system(size: 11.5, weight: .bold))
                            Text(ctrl.tr("Показывает финальный кадр с 3D LUT, виньеткой и 2.35:1.\nОкно OBS можно полностью скрыть (⌘H).", "Shows final graded output with 3D LUT, vignette & 2.35:1.\nYou can safely hide OBS (⌘H)."))
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)

                            HStack(spacing: 6) {
                                Button(action: { ctrl.triggerFaceAutofocus() }) {
                                    Label(ctrl.tr("Фокус на лицо", "Face AF"), systemImage: "face.smiling")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Color.blue).foregroundColor(.white).cornerRadius(6)
                                }.buttonStyle(.plain)

                                Button(action: { ctrl.triggerSingleAiFaceFrame() }) {
                                    Label(ctrl.tr("ИИ-Кадр", "AI Frame"), systemImage: "scope")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Color.purple.opacity(0.45)).foregroundColor(.white).cornerRadius(6)
                                }.buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.32)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.35), lineWidth: 1))
                }

                // QUICK LIGHTING SCENARIOS + CUSTOM MEMORY SLOTS (M1 / M2 / M3)
                HStack(spacing: 5) {
                    presetBtn(title: ctrl.tr("☀️ Офис", "☀️ Daylight"), id: "day")
                    presetBtn(title: ctrl.tr("🌆 Вечер", "🌆 Warm"), id: "evening")
                    presetBtn(title: ctrl.tr("🖥 Монитор", "🖥 Monitor"), id: "monitor")
                    presetBtn(title: ctrl.tr("🎙 Подкаст", "🎙 Podcast"), id: "podcast")

                    Divider().frame(height: 18)

                    Text(ctrl.tr("Слоты:", "Looks:"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.secondary)

                    ForEach(1...3, id: \.self) { slot in
                        HStack(spacing: 2) {
                            Button(action: { ctrl.loadMemorySlot(slot) }) {
                                Text("M\(slot)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                                    .background(ctrl.activeMemorySlot == slot ? Color.indigo : (ctrl.savedSlotsMask.contains(slot) ? Color.white.opacity(0.14) : Color.white.opacity(0.05)))
                                    .foregroundColor(ctrl.savedSlotsMask.contains(slot) ? .white : .secondary)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .help(ctrl.tr("Загрузить слот M\(slot)", "Load memory slot M\(slot)"))

                            Button(action: { ctrl.saveMemorySlot(slot) }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 8.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(ctrl.tr("Сохранить текущие настройки в M\(slot)", "Save current look to M\(slot)"))
                        }
                    }
                }

                // CARD 1: OPTICS, PHYSICAL LENSES & AUTOFOCUS
                StudioCard(title: ctrl.tr("1. Оптика Pixel 10 Pro, Кино-фиксы и Автофокус", "1. Pixel 10 Pro Optics, Cinema Primes & Autofocus"), icon: "camera.filters", accent: .blue, trailingText: ctrl.currentCameraFacing) {
                    VStack(spacing: 6) {
                        if !ctrl.pixelScreenUnlocked {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.iphone").foregroundColor(.orange)
                                Text(ctrl.tr("Разблокируйте Pixel отпечатком 1 раз для переключения физических объективов (Stay-On USB активен).", "Unlock Pixel once with fingerprint to switch hardware lenses (Stay-On USB enabled)."))
                                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(.orange)
                                Spacer()
                            }
                            .padding(5).background(Color.orange.opacity(0.14)).cornerRadius(6)
                        }

                        HStack(spacing: 5) {
                            Text(ctrl.tr("Сенсор:", "Sensor:"))
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)

                            lensBtn(title: ctrl.tr("0.5x Ширик", "0.5x Ultra"), subtitle: "12mm f/2.2", id: "0.5x")
                            lensBtn(title: ctrl.tr("1x Основной", "1x Main"), subtitle: "24mm 50MP", id: "1x")
                            lensBtn(title: ctrl.tr("2x Портрет", "2x Optical"), subtitle: "50mm Crop", id: "2x")
                            lensBtn(title: ctrl.tr("5x Телевик", "5x Tele"), subtitle: "113mm", id: "5x")
                            lensBtn(title: ctrl.tr("🤳 Селфи", "🤳 Front"), subtitle: "42MP 17mm", id: "front")

                            Button(action: { ctrl.selectPhysicalLens("picker") }) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 11)).padding(6)
                                    .background(Color.white.opacity(0.08)).cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help(ctrl.tr("Меню всех камер на экране Pixel", "Open native Camera Picker on Pixel"))
                        }

                        HStack(spacing: 5) {
                            Text(ctrl.tr("Фиксы:", "Primes:"))
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)

                            primeBtn(title: "24mm", id: "24mm")
                            primeBtn(title: "35mm", id: "35mm")
                            primeBtn(title: "50mm", id: "50mm")
                            primeBtn(title: "85mm", id: "85mm")

                            Divider().frame(height: 16)

                            Button(action: { ctrl.triggerFaceAutofocus() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "face.smiling")
                                    Text(ctrl.tr("AF Лицо", "Face AF"))
                                }
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue).foregroundColor(.white).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Button(action: { ctrl.triggerContinuousAutofocus() }) {
                                Text(ctrl.tr("Следящий AF", "Continuous AF"))
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08)).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Button(action: { ctrl.toggleHQMode() }) {
                                Text(ctrl.isHQMode ? "HQ: ON" : "HQ: OFF")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(ctrl.isHQMode ? Color.green.opacity(0.25) : Color.white.opacity(0.08))
                                    .foregroundColor(ctrl.isHQMode ? .green : .secondary).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Toggle("OLED Blackout", isOn: Binding(
                                get: { ctrl.isBlackoutEnabled },
                                set: { ctrl.togglePixelBlackout($0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                        }
                    }
                }

                // CARD 2: FRAMING, INTERACTIVE 2D PAD & APPLE VISION AI
                StudioCard(title: ctrl.tr("2. Кадрирование, 2D-Трекпад & ИИ-Трекинг (Apple Vision)", "2. Framing, 2D Trackpad & AI Face Tracking (Apple Vision)"), icon: "viewfinder.circle.fill", accent: .purple, trailingText: String(format: "%.2fx • AI: %@", ctrl.zoomLevel, ctrl.aiFaceStatus)) {
                    HStack(spacing: 10) {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Toggle(isOn: Binding(
                                    get: { ctrl.aiAutoFrameEnabled },
                                    set: { ctrl.toggleAiAutoFraming($0) }
                                )) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "brain.head.profile")
                                            .foregroundColor(ctrl.aiAutoFrameEnabled ? .green : .purple)
                                        Text(ctrl.tr("ИИ-Слежение (Center Stage)", "AI Center Stage Tracking"))
                                            .font(.system(size: 10.5, weight: .bold))
                                    }
                                }
                                .toggleStyle(.checkbox)

                                Button(action: { ctrl.triggerSingleAiFaceFrame() }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "scope")
                                        Text(ctrl.tr("Навести по лицу", "Frame Face"))
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(Color.purple.opacity(0.35)).foregroundColor(.white).cornerRadius(5)
                                }.buttonStyle(.plain)

                                Spacer()

                                Button(action: { ctrl.toggleMirror(!ctrl.isMirrored) }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                                        Text(ctrl.isMirrored ? ctrl.tr("Зеркало: ВКЛ", "Mirror: ON") : ctrl.tr("Зеркалить", "Mirror"))
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                                    .background(ctrl.isMirrored ? Color.blue : Color.white.opacity(0.08))
                                    .foregroundColor(.white).cornerRadius(5)
                                }.buttonStyle(.plain)
                            }

                            HStack(spacing: 6) {
                                dollyBtn(ctrl.tr("1.0x Общий", "1.0x Wide"), zoom: 1.0, py: 0.0)
                                dollyBtn(ctrl.tr("1.22x Студия", "1.22x Chest"), zoom: 1.22, py: -0.04)
                                dollyBtn(ctrl.tr("1.5x Портрет", "1.5x Portrait"), zoom: 1.5, py: -0.06)
                                dollyBtn(ctrl.tr("2.0x Макро", "2.0x Close"), zoom: 2.0, py: 0.0)

                                Slider(value: Binding(
                                    get: { ctrl.zoomLevel },
                                    set: { ctrl.zoomLevel = $0; ctrl.applyFramingImmediate() }
                                ), in: 1.0...2.5)
                                .controlSize(.small)
                            }
                        }

                        // Interactive 2D Pan/Tilt Framing Trackpad
                        InteractiveFramingPad(ctrl: ctrl)
                    }
                }

                // CARD 3: 3D CINEMA LUT CARDS WITH COLOR SWATCHES & 2.35:1 SCOPE
                StudioCard(title: ctrl.tr("3. Кинематографические 3D LUT и Анаморфотное Каше 2.35:1", "3. 3D Cinema LUTs & 2.35:1 Anamorphic Scope"), icon: "film.stack", accent: .orange, trailingText: "\(Int(ctrl.lutIntensity * 100))%") {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            lutCard(title: "S-Cinetone", sub: "Sony Alpha", id: "sony",
                                    swatch: [Color(red: 0.15, green: 0.28, blue: 0.45), Color(red: 0.85, green: 0.65, blue: 0.52)], accent: .blue)
                            lutCard(title: "Pro-Mist", sub: ctrl.tr("Тёплый/Мягкий", "Warm/Soft"), id: "promist",
                                    swatch: [Color(red: 0.42, green: 0.25, blue: 0.18), Color(red: 0.98, green: 0.78, blue: 0.50)], accent: .orange)
                            lutCard(title: "Kodak 2383", sub: ctrl.tr("Киноплёнка", "Film Print"), id: "kodak",
                                    swatch: [Color(red: 0.12, green: 0.25, blue: 0.28), Color(red: 0.92, green: 0.74, blue: 0.42)], accent: .yellow)
                            lutCard(title: "Teal & Orange", sub: ctrl.tr("Голливуд", "Blockbuster"), id: "teal",
                                    swatch: [Color(red: 0.02, green: 0.55, blue: 0.62), Color(red: 0.98, green: 0.52, blue: 0.18)], accent: .teal)
                            lutCard(title: "Leica B&W", sub: ctrl.tr("Монохром", "Monochrome"), id: "leica",
                                    swatch: [Color.black, Color.gray, Color.white], accent: .gray)
                            lutCard(title: "Rec.709", sub: ctrl.tr("Чистый", "Neutral"), id: "none",
                                    swatch: [Color.white.opacity(0.25), Color.white.opacity(0.45)], accent: .secondary)
                        }

                        HStack(spacing: 10) {
                            Text(ctrl.tr("Сила LUT: \(Int(ctrl.lutIntensity * 100))%", "LUT Strength: \(Int(ctrl.lutIntensity * 100))%"))
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 96, alignment: .leading)

                            Slider(value: Binding(
                                get: { ctrl.lutIntensity },
                                set: { ctrl.lutIntensity = $0; ctrl.applyLUTDebounced() }
                            ), in: 0.0...1.0)
                            .controlSize(.small)

                            Toggle(ctrl.tr("Виньетка 35mm", "35mm Vignette"), isOn: Binding(
                                get: { ctrl.vignetteEnabled },
                                set: { ctrl.setVignette($0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10.5))

                            Toggle(ctrl.tr("🎬 Рамка 2.35:1", "🎬 2.35:1 Scope"), isOn: Binding(
                                get: { ctrl.letterboxEnabled },
                                set: { ctrl.setCinemaLetterbox($0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10.5, weight: .bold))
                        }
                    }
                }

                // CARD 4: 2-COLUMN EXPOSURE, WHITE BALANCE & DETAIL MATRIX
                StudioCard(title: ctrl.tr("4. Экспозиция, Баланс Белого (ББ) и Детализация", "4. Exposure, White Balance & Sharpening"), icon: "slider.horizontal.3", accent: .cyan) {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Button(action: { ctrl.resetExposureAuto() }) {
                                Label(ctrl.tr("АВТО Экспозиция", "AUTO Exposure"), systemImage: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(Color.indigo.opacity(0.35)).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Button(action: { ctrl.resetWhiteBalanceAuto() }) {
                                Label(ctrl.tr("АВТО Баланс Белого", "AUTO White Balance"), systemImage: "thermometer.medium")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(Color.teal.opacity(0.35)).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Spacer()

                            Button(action: { ctrl.resetAllImageAuto() }) {
                                Label(ctrl.tr("Сброс в АВТО", "Reset All Auto"), systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(Color.white.opacity(0.08)).cornerRadius(5)
                            }.buttonStyle(.plain)
                        }

                        HStack(spacing: 14) {
                            VStack(spacing: 3.5) {
                                compactSlider(label: ctrl.tr("Экспозиция", "Exposure"), value: $ctrl.brightness, range: -0.25...0.25, fmt: "%+.0f%%", mult: 100)
                                compactSlider(label: ctrl.tr("Контраст", "Contrast"), value: $ctrl.contrast, range: -0.30...0.45, fmt: "%+.0f%%", mult: 100)
                                compactSlider(label: ctrl.tr("Гамма (Тени)", "Gamma"), value: $ctrl.vargamma, range: -0.30...0.30, fmt: "%+.0f%%", mult: 100)
                            }
                            VStack(spacing: 3.5) {
                                compactSlider(label: ctrl.tr("ББ (Тёпл/Хол)", "White Balance"), value: $ctrl.hueShift, range: -25.0...25.0, fmt: "%+.1f°", mult: 1)
                                compactSlider(label: ctrl.tr("Насыщенность", "Saturation"), value: $ctrl.saturation, range: -0.40...0.50, fmt: "%+.0f%%", mult: 100)
                                compactSlider(label: ctrl.tr("Резкость", "Sharpness"), value: $ctrl.sharpness, range: 0.0...0.25, fmt: "%.0f%%", mult: 400)
                            }
                        }
                    }
                }

                // CARD 5: RØDE NT1 5th Gen STUDIO AUDIO & HARDWARE LIP-SYNC
                StudioCard(title: ctrl.tr("5. Аудио RØDE NT1 5th Gen (Родной APHEX DSP + Аппаратный Lip-Sync)", "5. RØDE NT1 5th Gen Audio (Native APHEX DSP + Hardware Lip-Sync)"), icon: "mic.fill", accent: .green, trailingText: "Lip-Sync: +\(Int(ctrl.rodeLipSyncMs)) ms") {
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            IsolatedVuMeterBar(
                                vuState: ctrl.vuState,
                                isMuted: ctrl.isRodeMuted,
                                isEnabled: ctrl.liveVuEnabled,
                                placeholderText: ctrl.tr("VU-метр выкл (0% CPU) • Включите справа для теста уровня", "VU Meter OFF (0% CPU) • Toggle right to monitor levels")
                            )

                            Toggle("VU", isOn: Binding(
                                get: { ctrl.liveVuEnabled },
                                set: { ctrl.setLiveVuMeter(enabled: $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))

                            Button(action: { ctrl.openRodeCentralApp() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "slider.vertical.3")
                                    Text("RØDE Central")
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3.5)
                                .background(Color.white.opacity(0.09)).cornerRadius(5)
                            }.buttonStyle(.plain)

                            Button(action: { ctrl.toggleRodeMute() }) {
                                Text(ctrl.isRodeMuted ? ctrl.tr("🔇 ВЫКЛ", "🔇 MUTED") : ctrl.tr("🎙 В ЭФИРЕ", "🎙 LIVE"))
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(ctrl.isRodeMuted ? Color.red : Color.green.opacity(0.25))
                                    .foregroundColor(ctrl.isRodeMuted ? .white : .green).cornerRadius(5)
                            }.buttonStyle(.plain)
                        }

                        HStack(spacing: 5) {
                            audioPresetBtn(title: ctrl.tr("🎯 Родной RØDE Central (Pure)", "🎯 Native RØDE Central (Pure)"), id: "pure")
                            audioPresetBtn(title: ctrl.tr("📻 +OBS Радио", "📻 +OBS Broadcast"), id: "radio")
                            audioPresetBtn(title: ctrl.tr("🎙 +OBS Речь", "🎙 +OBS Voice"), id: "voice")

                            Divider().frame(height: 16)

                            Text("⏱ +\(Int(ctrl.rodeLipSyncMs))ms")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 56, alignment: .leading)

                            Slider(value: Binding(
                                get: { ctrl.rodeLipSyncMs },
                                set: { ctrl.rodeLipSyncMs = $0; ctrl.applyRodeLipSyncDebounced() }
                            ), in: 0.0...140.0)
                            .frame(width: 90)
                            .controlSize(.small)

                            Button(ctrl.is60FpsMode ? "35ms" : "65ms") {
                                ctrl.rodeLipSyncMs = ctrl.is60FpsMode ? 35.0 : 65.0
                                ctrl.applyRodeLipSyncImmediate()
                            }
                            .font(.system(size: 9.5, weight: .bold))
                            .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }

                // FOOTER TELEMETRY, CABLE & MRMO.ES CREDIT STRIP
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        statBadge(label: "FPS", value: String(format: "%.0f", ctrl.obsFps),
                                  ok: ctrl.obsFps >= (ctrl.is60FpsMode ? 55.0 : 28.5))
                        statBadge(label: "GPU", value: String(format: "%.1fms", ctrl.obsRenderTimeMs),
                                  ok: ctrl.obsRenderTimeMs < 13.5)
                        statBadge(label: "CPU", value: String(format: "%.1f%%", ctrl.obsCpuUsage),
                                  ok: ctrl.obsCpuUsage < 25.0)
                        statBadge(label: "USB", value: ctrl.usbCableSpeed, ok: true)
                        statBadge(label: "Pixel", value: String(format: "%d%% %.0f°C", ctrl.pixelBatteryLevel, ctrl.pixelTempC),
                                  ok: ctrl.pixelTempC < 41.0)

                        Spacer()

                        Button(ctrl.is60FpsMode ? "30 FPS" : "✅ 30") {
                            ctrl.setCameraFpsMode(use60Fps: false)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)

                        Button(ctrl.is60FpsMode ? "⚡ 60 FPS" : "60 FPS") {
                            ctrl.setCameraFpsMode(use60Fps: true)
                        }
                        .buttonStyle(.borderedProminent).tint(ctrl.is60FpsMode ? .green : .gray).controlSize(.mini)

                        Button(action: {
                            ctrl.showLogs.toggle()
                            ctrl.onWindowSizeChangeRequested?()
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: ctrl.showLogs ? "chevron.up" : "chevron.down")
                                Text(ctrl.tr("Логи", "Logs"))
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.mini)

                        // Author Website Credit Badge (mrmo.es)
                        Button(action: { ctrl.openAuthorWebsite() }) {
                            Text("mrmo.es ↗")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6).padding(.vertical, 2.5)
                                .background(Color.cyan.opacity(0.14))
                                .foregroundColor(.cyan)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("https://mrmo.es")
                    }

                    if ctrl.showLogs {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(ctrl.logEntries.suffix(8), id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(line.contains("WARN") || line.contains("ERR") ? .orange : .secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(4)
                        }
                        .frame(height: 74)
                        .background(Color.black.opacity(0.35))
                        .cornerRadius(6)

                        HStack {
                            Text(FileLogger.shared.logFilePath)
                                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                            Spacer()
                            Button(ctrl.tr("Очистить", "Clear")) { ctrl.logEntries.removeAll() }
                                .buttonStyle(.bordered).controlSize(.mini)
                            Button(ctrl.tr("Открыть .log", "Open .log")) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: FileLogger.shared.logFilePath))
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
            }
        }
        .padding(10)
        .frame(width: 716, height: computedHeight)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12))
        .preferredColorScheme(.dark)
    }

    // MARK: - Custom Studio UI Components
    private func statBadge(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 5.5, height: 5.5)
            Text("\(label):").font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5).padding(.vertical, 2.5)
        .background(Color.white.opacity(0.06)).cornerRadius(4)
    }

    private func lensBtn(title: String, subtitle: String, id: String) -> some View {
        let active = ctrl.selectedPhysicalLens == id
        return Button(action: { ctrl.selectPhysicalLens(id) }) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 10, weight: active ? .bold : .medium))
                Text(subtitle).font(.system(size: 8)).foregroundColor(active ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
            .background(active ? Color.blue : Color.white.opacity(0.07))
            .foregroundColor(.white).cornerRadius(6)
        }.buttonStyle(.plain)
    }

    private func lensMiniBtn(_ title: String, id: String) -> some View {
        let active = ctrl.selectedPhysicalLens == id
        return Button(action: { ctrl.selectPhysicalLens(id) }) {
            Text(title).font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(active ? Color.blue : Color.white.opacity(0.08))
                .foregroundColor(.white).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func lutMiniBtn(_ title: String, id: String, color: Color) -> some View {
        let active = ctrl.selectedLUT == id
        return Button(action: { ctrl.selectLUT(id) }) {
            Text(title).font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(active ? color.opacity(0.55) : Color.white.opacity(0.08))
                .foregroundColor(.white).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func primeBtn(title: String, id: String) -> some View {
        let active = ctrl.selectedPrimeFocal == id
        return Button(action: { ctrl.selectPrimeFocalLength(id) }) {
            Text(title).font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(active ? Color.indigo : Color.white.opacity(0.07))
                .foregroundColor(.white).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func dollyBtn(_ title: String, zoom: Double, py: Double) -> some View {
        let active = abs(ctrl.zoomLevel - zoom) < 0.04
        return Button(action: { ctrl.smoothFrameTo(zoom: zoom, panX: 0, panY: py) }) {
            Text(title).font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 6.5).padding(.vertical, 3.5)
                .background(active ? Color.purple.opacity(0.45) : Color.white.opacity(0.07))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func lutCard(title: String, sub: String, id: String, swatch: [Color], accent: Color) -> some View {
        let active = ctrl.selectedLUT == id
        return Button(action: { ctrl.selectLUT(id) }) {
            VStack(spacing: 0) {
                // Cinema Color Swatch Gradient Strip
                LinearGradient(colors: swatch, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4)

                VStack(spacing: 1) {
                    Text(title).font(.system(size: 9.5, weight: active ? .bold : .semibold)).lineLimit(1)
                    Text(sub).font(.system(size: 8)).foregroundColor(active ? .white.opacity(0.85) : .secondary).lineLimit(1)
                }
                .padding(.vertical, 4.5)
                .padding(.horizontal, 3)
            }
            .frame(maxWidth: .infinity)
            .background(active ? accent.opacity(0.32) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? accent : Color.white.opacity(0.06), lineWidth: active ? 1.4 : 0.7))
        }.buttonStyle(.plain)
    }

    private func presetBtn(title: String, id: String) -> some View {
        let active = ctrl.activeLightingPreset == id
        return Button(action: { ctrl.applyLightingPreset(id) }) {
            Text(title).font(.system(size: 10, weight: active ? .bold : .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(active ? Color.blue.opacity(0.35) : Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.cyan.opacity(0.7) : Color.clear, lineWidth: 1))
                .cornerRadius(6)
        }.buttonStyle(.plain)
    }

    private func audioPresetBtn(title: String, id: String) -> some View {
        let active = ctrl.activeAudioPreset == id
        return Button(action: { ctrl.setRodeAudioMode(id) }) {
            Text(title).font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(active ? Color.green.opacity(0.32) : Color.white.opacity(0.07))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func compactSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String, mult: Double) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 84, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; ctrl.applyColorCorrection() }
            ), in: range)
            .controlSize(.small)
            Text(String(format: fmt, value.wrappedValue * mult))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - AppDelegate with Persistent Top macOS Menu Bar (Bilingual EN/RU)
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let ctrl = StudioController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let contentView = StudioPanelView(ctrl: ctrl)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 716, height: 685),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mr. Pixel Camera v2.1 — mrmo.es"
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--screenshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let view = self.window.contentView else { NSApp.terminate(nil); return }
                self.ctrl.lang = "en"
                self.ctrl.obsConnected = true
                self.ctrl.pixelConnected = true
                self.ctrl.pixelScreenUnlocked = true
                self.ctrl.obsFps = 60.0
                self.ctrl.obsRenderTimeMs = 7.4
                self.ctrl.obsCpuUsage = 6.2
                self.ctrl.usbCableSpeed = "2.0 (480M)"
                self.ctrl.pixelBatteryLevel = 100
                self.ctrl.pixelTempC = 36.2
                self.ctrl.zoomLevel = 1.22
                self.ctrl.aiFaceStatus = "1.22x"
                self.ctrl.savedSlotsMask = [1, 2]
                self.ctrl.activeMemorySlot = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    view.layoutSubtreeIfNeeded()
                    let bounds = view.bounds
                    if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                        view.cacheDisplay(in: bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            let out = "\(NSHomeDirectory())/Desktop/PixelProCam/assets/screenshots/studio_ui_v2.1.png"
                            try? png.write(to: URL(fileURLWithPath: out))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }

        setupMenuBarExtra()
        ctrl.onStatusChangeForMenuBar = { [weak self] in
            self?.updateStatusButtonTitle()
        }
        ctrl.onWindowSizeChangeRequested = { [weak self] in
            self?.resizeWindowSmoothly()
        }
    }

    func resizeWindowSmoothly() {
        guard let win = window else { return }
        var targetH: CGFloat = ctrl.miniMode ? 118 : 685
        if !ctrl.miniMode {
            if ctrl.showPreview { targetH += 192 }
            if ctrl.showLogs { targetH += 104 }
        }
        let currentFrame = win.frame
        let newContentRect = NSRect(x: 0, y: 0, width: 716, height: targetH)
        let newFrameSize = win.frameRect(forContentRect: newContentRect).size
        let deltaY = newFrameSize.height - currentFrame.size.height
        let newFrame = NSRect(x: currentFrame.origin.x, y: currentFrame.origin.y - deltaY, width: newFrameSize.width, height: newFrameSize.height)
        win.setFrame(newFrame, display: true, animate: true)
    }

    func setupMenuBarExtra() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusButtonTitle()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func updateStatusButtonTitle() {
        guard let btn = statusItem?.button else { return }
        if ctrl.isRecording {
            btn.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            btn.title = String(format: " %02d:%02d", ctrl.recordSeconds / 60, ctrl.recordSeconds % 60)
        } else if ctrl.isPrivacyStandby {
            btn.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Paused")
            btn.title = ctrl.tr(" ПАУЗА", " PAUSED")
        } else {
            btn.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Mr. Pixel Camera")
            btn.title = " Mr. Pixel"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let showTitle = ctrl.tr("🎛 Показать окно Mr. Pixel Camera", "🎛 Show Mr. Pixel Camera Window")
        let showItem = NSMenuItem(title: showTitle, action: #selector(toggleMainWindow), keyEquivalent: "p")
        showItem.target = self
        menu.addItem(showItem)

        let pinItem = NSMenuItem(title: ctrl.tr("📌 Закрепить поверх всех окон", "📌 Pin Always on Top"), action: #selector(menuTogglePin), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = ctrl.alwaysOnTop ? .on : .off
        menu.addItem(pinItem)

        let langItem = NSMenuItem(title: ctrl.tr("🌐 Language: Русский (Switch to English)", "🌐 Language: English (Переключить на Русский)"), action: #selector(menuToggleLang), keyEquivalent: "")
        langItem.target = self
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())

        let photoItem = NSMenuItem(title: ctrl.tr("📸 Сделать студийное ФОТО (1920×1080 PNG)", "📸 Take Studio PHOTO (1920×1080 PNG)"), action: #selector(menuTakePhoto), keyEquivalent: "s")
        photoItem.target = self
        menu.addItem(photoItem)

        let recTitle = ctrl.isRecording ? ctrl.tr("⏹ Остановить ЗАПИСЬ видео", "⏹ Stop Video Recording") : ctrl.tr("🔴 Начать ЗАПИСЬ студийного видео", "🔴 Start Studio Video Recording")
        let recItem = NSMenuItem(title: recTitle, action: #selector(menuToggleRec), keyEquivalent: "r")
        recItem.target = self
        menu.addItem(recItem)

        let folderItem = NSMenuItem(title: ctrl.tr("📂 Открыть папку Captures", "📂 Open Captures Folder"), action: #selector(menuOpenCaptures), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

        let standbyTitle = ctrl.isPrivacyStandby ? ctrl.tr("▶️ ВЕРНУТЬСЯ В ЭФИР", "▶️ RESUME LIVE FEED") : ctrl.tr("⏸ НА ПАУЗУ (Заставка + Mute)", "⏸ PRIVACY STANDBY (Slate + Mute)")
        let standbyItem = NSMenuItem(title: standbyTitle, action: #selector(menuToggleStandby), keyEquivalent: "")
        standbyItem.target = self
        menu.addItem(standbyItem)

        let muteTitle = ctrl.isRodeMuted ? ctrl.tr("🔇 Микрофон RØDE: ВЫКЛ (Включить)", "🔇 RØDE Mic: MUTED (Unmute)") : ctrl.tr("🎙 Микрофон RØDE: В ЭФИРЕ (Заглушить)", "🎙 RØDE Mic: LIVE (Mute)")
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(menuToggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        let aiItem = NSMenuItem(title: ctrl.tr("🧠 ИИ-Автокадрирование (Apple Vision)", "🧠 AI Face Auto-Framing (Apple Vision)"), action: #selector(menuToggleAi), keyEquivalent: "")
        aiItem.target = self
        aiItem.state = ctrl.aiAutoFrameEnabled ? .on : .off
        menu.addItem(aiItem)

        let aiOnceItem = NSMenuItem(title: ctrl.tr("🎯 Навести по лицу (1 раз)", "🎯 Frame Face Once"), action: #selector(menuAiOnce), keyEquivalent: "")
        aiOnceItem.target = self
        menu.addItem(aiOnceItem)

        let mirrorItem = NSMenuItem(title: ctrl.tr("🪞 Зеркалить картинку", "🪞 Mirror Horizontal"), action: #selector(menuToggleMirror), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = ctrl.isMirrored ? .on : .off
        menu.addItem(mirrorItem)

        let letterboxItem = NSMenuItem(title: ctrl.tr("🎬 Кино-рамка 2.35:1", "🎬 2.35:1 Cinema Scope"), action: #selector(menuToggleLetterbox), keyEquivalent: "")
        letterboxItem.target = self
        letterboxItem.state = ctrl.letterboxEnabled ? .on : .off
        menu.addItem(letterboxItem)

        menu.addItem(NSMenuItem.separator())

        let lensMenu = NSMenu()
        let lenses: [(String, String)] = [
            (ctrl.tr("0.5x Ультраширик (12mm)", "0.5x Ultra-Wide (12mm)"), "0.5x"),
            (ctrl.tr("1x Основной (24mm 50MP)", "1x Main Wide (24mm 50MP)"), "1x"),
            (ctrl.tr("2x Портрет (50mm Оптика)", "2x Optical Portrait (50mm)"), "2x"),
            (ctrl.tr("5x Телевик (113mm)", "5x Telephoto (113mm)"), "5x"),
            (ctrl.tr("🤳 Селфи / Тыл (42MP)", "🤳 Front / Rear (42MP)"), "front")
        ]
        for (title, id) in lenses {
            let item = NSMenuItem(title: title, action: #selector(menuSelectLens(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.selectedPhysicalLens == id) ? .on : .off
            lensMenu.addItem(item)
        }
        let lensParent = NSMenuItem(title: ctrl.tr("📷 Объектив Pixel 10 Pro", "📷 Pixel 10 Pro Lens"), action: nil, keyEquivalent: "")
        lensParent.submenu = lensMenu
        menu.addItem(lensParent)

        let lutMenu = NSMenu()
        let luts: [(String, String)] = [
            ("🎬 Sony Alpha S-Cinetone", "sony"),
            ("✨ Tiffen Black Pro-Mist", "promist"),
            ("🎞 Kodak 2383 Film Print", "kodak"),
            ("🔥 Teal & Orange", "teal"),
            ("⚫️⚪️ Leica Monochrome", "leica"),
            (ctrl.tr("🚫 Без LUT (Rec.709)", "🚫 Pure Rec.709 (Off)"), "none")
        ]
        for (title, id) in luts {
            let item = NSMenuItem(title: title, action: #selector(menuSelectLut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.selectedLUT == id) ? .on : .off
            lutMenu.addItem(item)
        }
        let lutParent = NSMenuItem(title: ctrl.tr("🎨 Кино-стиль (3D LUT)", "🎨 3D Cinema LUT"), action: nil, keyEquivalent: "")
        lutParent.submenu = lutMenu
        menu.addItem(lutParent)

        menu.addItem(NSMenuItem.separator())

        let fps60Item = NSMenuItem(title: ctrl.tr("⚡ 60 FPS Ультранизкая задержка (~35 мс)", "⚡ 60 FPS Ultra-Low-Latency (~35 ms)"), action: #selector(menuSet60Fps), keyEquivalent: "")
        fps60Item.target = self
        fps60Item.state = ctrl.is60FpsMode ? .on : .off
        menu.addItem(fps60Item)

        let fps30Item = NSMenuItem(title: ctrl.tr("🎥 30 FPS Студия (~65 мс)", "🎥 30 FPS Studio (~65 ms)"), action: #selector(menuSet30Fps), keyEquivalent: "")
        fps30Item.target = self
        fps30Item.state = !ctrl.is60FpsMode ? .on : .off
        menu.addItem(fps30Item)

        menu.addItem(NSMenuItem.separator())

        let siteItem = NSMenuItem(title: "🌐 mrmo.es", action: #selector(menuOpenSite), keyEquivalent: "")
        siteItem.target = self
        menu.addItem(siteItem)

        let quitItem = NSMenuItem(title: ctrl.tr("🚪 Выйти из Mr. Pixel Camera", "🚪 Quit Mr. Pixel Camera"), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc func toggleMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func menuTogglePin() { ctrl.setAlwaysOnTop(!ctrl.alwaysOnTop) }
    @objc func menuToggleLang() { ctrl.toggleLanguage() }
    @objc func menuTakePhoto() { ctrl.takeStudioPhoto() }
    @objc func menuToggleRec() { ctrl.toggleStudioRecording() }
    @objc func menuOpenCaptures() { ctrl.openCapturesFolder() }
    @objc func menuToggleStandby() { ctrl.togglePrivacyStandby() }
    @objc func menuToggleMute() { ctrl.toggleRodeMute() }
    @objc func menuToggleAi() { ctrl.toggleAiAutoFraming(!ctrl.aiAutoFrameEnabled) }
    @objc func menuAiOnce() { ctrl.triggerSingleAiFaceFrame() }
    @objc func menuToggleMirror() { ctrl.toggleMirror(!ctrl.isMirrored) }
    @objc func menuToggleLetterbox() { ctrl.setCinemaLetterbox(!ctrl.letterboxEnabled) }
    @objc func menuSet60Fps() { ctrl.setCameraFpsMode(use60Fps: true) }
    @objc func menuSet30Fps() { ctrl.setCameraFpsMode(use60Fps: false) }
    @objc func menuOpenSite() { ctrl.openAuthorWebsite() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    @objc func menuSelectLens(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { ctrl.selectPhysicalLens(id) }
    }
    @objc func menuSelectLut(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { ctrl.selectLUT(id) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

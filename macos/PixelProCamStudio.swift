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
        let header = "=== PixelProCam Studio v2.0 Diagnostic Log Started at \(Date()) ===\n"
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

// MARK: - Isolated VU Meter State
final class VuMeterState: ObservableObject {
    @Published var level: Double = 0.0
}

// MARK: - Studio Controller v2.0
final class StudioController: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    // Connection & Hardware status
    @Published var obsConnected: Bool = false
    @Published var pixelConnected: Bool = false
    @Published var pixelScreenUnlocked: Bool = true
    @Published var currentFocusStatus: String = "Следящий ИИ-AF (CAF)"
    @Published var currentCameraFacing: String = "1x Основной (50MP 24mm f/1.68)"
    @Published var isHQMode: Bool = true
    @Published var is60FpsMode: Bool = true

    // Physical Lens & Prime Focal Length Selection
    @Published var selectedPhysicalLens: String = "1x" // "0.5x", "1x", "2x", "5x", "front"
    @Published var selectedPrimeFocal: String = "24mm" // "24mm", "35mm", "50mm", "85mm"

    // Live OBS Telemetry & USB Cable Diagnostics
    @Published var obsFps: Double = 60.0
    @Published var obsRenderTimeMs: Double = 0.8
    @Published var obsCpuUsage: Double = 3.0
    @Published var obsSkippedFrames: Int = 0
    @Published var obsTotalFrames: Int = 0
    @Published var usbCableSpeed: String = "USB 2.0 (480 Мбит/с)"
    @Published var usbIsSuperSpeed: Bool = false
    @Published var usbPowerProfile: String = "15W PD (5V/3A)"
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
    @Published var aiFaceStatus: String = "Выкл"
    private var dollyTimer: Timer?
    private var aiFrameTimer: Timer?
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
    @Published var activeAudioPreset: String = "pure" // "pure", "radio", "voice"
    @Published var rodeLipSyncMs: Double = 35.0
    @Published var rodeSafetyLimiter: Bool = true
    @Published var isRodeMuted: Bool = false
    @Published var liveVuEnabled: Bool = false
    @Published var isPrivacyStandby: Bool = false
    @Published var isBlackoutEnabled: Bool = false

    let vuState = VuMeterState()
    var onStatusChangeForMenuBar: (() -> Void)?

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
        let desktopApp = "\(NSHomeDirectory())/Desktop/PixelProCam/PixelProCam Studio.app/Contents/MacOS/adb"
        let localBin = "\(NSHomeDirectory())/Desktop/PixelProCam/bin/adb"
        for p in [bundled, desktopApp, localBin, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return desktopApp
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

        FileLogger.shared.onNewLogLine = { [weak self] line in
            guard let self = self else { return }
            self.logEntries.append(line)
            if self.logEntries.count > 60 {
                self.logEntries.removeFirst(self.logEntries.count - 60)
            }
        }
        FileLogger.shared.log("INIT", "Starting PixelProCam Studio v2.0 Pro Cinema Dark Edition")

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
                self.onStatusChangeForMenuBar?()
            }
        }
    }

    private func configureInitialObsStudioSettings() {
        sendOBSRequest(type: "SetRecordDirectory", data: ["recordDirectory": capturesDir], id: "init_rec_dir")
        applyRodeLipSyncImmediate()
    }

    private func handleObsResponse(reqId: String, data: [String: Any]) {
        if reqId == "get_items", let items = data["sceneItems"] as? [[String: Any]] {
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
        let filename = "PixelProCam_Photo_\(df.string(from: Date())).png"
        let fullPath = "\(capturesDir)/\(filename)"

        sendOBSRequest(type: "SaveSourceScreenshot", data: [
            "sourceName": "Сцена",
            "imageFormat": "png",
            "imageFilePath": fullPath,
            "imageWidth": 1920,
            "imageHeight": 1080
        ], id: "save_photo")

        NSSound(named: NSSound.Name("Tink"))?.play()
        lastCaptureMessage = "📸 Сохранено: \(filename)"
        FileLogger.shared.log("PHOTO", "Saved 1920x1080 studio snapshot to \(fullPath)")
    }

    func toggleStudioRecording() {
        if !isRecording {
            isRecording = true
            recordSeconds = 0
            sendOBSRequest(type: "SetRecordDirectory", data: ["recordDirectory": capturesDir])
            sendOBSRequest(type: "StartRecord", data: [:], id: "start_rec")
            lastCaptureMessage = "🔴 Запись видео в /Captures..."
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
            lastCaptureMessage = "🎬 Видео сохранено в Captures"
            FileLogger.shared.log("RECORD", "Stopped studio video recording (duration: \(recordSeconds)s)")
        }
        onStatusChangeForMenuBar?()
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: capturesDir))
    }

    // MARK: - Apple Vision Neural Engine AI Auto-Framing
    func toggleAiAutoFraming(_ enabled: Bool) {
        aiAutoFrameEnabled = enabled
        aiFrameTimer?.invalidate()
        aiFrameTimer = nil
        if enabled {
            aiFaceStatus = "Активен (Vision AI)"
            FileLogger.shared.log("VISION-AI", "Enabled Apple Vision Neural Engine Auto-Framing")
            requestVisionFrameOnce(immediate: true)
            aiFrameTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.requestVisionFrameOnce(immediate: false)
            }
        } else {
            aiFaceStatus = "Выкл"
            FileLogger.shared.log("VISION-AI", "Disabled Apple Vision Auto-Framing")
        }
        onStatusChangeForMenuBar?()
    }

    func triggerSingleAiFaceFrame() {
        aiFaceStatus = "Поиск лица..."
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
                        self.aiFaceStatus = "Лицо не найдено"
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

                    self.aiFaceStatus = String(format: "Захват (%.2fx)", desiredZoom)
                    FileLogger.shared.log("VISION-AI", String(format: "Auto-Framing face (x=%.2f, y=%.2f) -> Zoom=%.2fx Pan=(%.2f, %.2f)", faceCenterX, faceCenterY, desiredZoom, targetPanX, targetPanY))
                    self.smoothFrameTo(zoom: desiredZoom, panX: targetPanX, panY: targetPanY)
                }
            }
            try? handler.perform([request])
        }
    }

    // MARK: - Switch UVC Capture & OBS Canvas FPS Mode (60 FPS ~35ms vs 30 FPS ~65ms)
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
            FileLogger.shared.log("LENS-WARN", "Экран Pixel 10 Pro заблокирован! Разблокируйте телефон отпечатком 1 раз.")
        }

        switch lens {
        case "0.5x":
            selectedPhysicalLens = "0.5x"
            selectedPrimeFocal = "12mm"
            currentCameraFacing = "0.5x Ультраширик (12mm f/2.2)"
            FileLogger.shared.log("LENS", "Switched Pixel 10 Pro physical lens to 0.5x Ultra-Wide (12mm f/2.2)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 414 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "1x":
            selectedPhysicalLens = "1x"
            selectedPrimeFocal = "24mm"
            currentCameraFacing = "1x Основной (50MP 24mm f/1.68)"
            FileLogger.shared.log("LENS", "Switched Pixel 10 Pro physical lens to 1x Main Wide (24mm f/1.68)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 540 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "2x":
            selectedPhysicalLens = "2x"
            selectedPrimeFocal = "50mm"
            currentCameraFacing = "2x Портретный (50mm Оптика)"
            FileLogger.shared.log("LENS", "Switched Pixel 10 Pro physical lens to 2x Optical (50mm)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 666 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "5x":
            selectedPhysicalLens = "5x"
            selectedPrimeFocal = "113mm"
            currentCameraFacing = "5x Телевик (113mm Крупный план)"
            FileLogger.shared.log("LENS", "Switched to 5x Telephoto mode (2x Optical Sensor + 2.25x OBS GPU Scale = 113mm)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 666 2149")
            smoothFrameTo(zoom: 2.25, panX: 0.0, panY: 0.0)

        case "front":
            selectedPhysicalLens = (selectedPhysicalLens == "front") ? "1x" : "front"
            currentCameraFacing = (selectedPhysicalLens == "front") ? "Фронтальная (42MP 17mm f/2.2)" : "1x Основной (50MP 24mm f/1.68)"
            FileLogger.shared.log("LENS", "Toggled Front / Rear camera module (126, 2149)")
            runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 126 2149")
            smoothFrameTo(zoom: 1.0, panX: 0.0, panY: 0.0)

        case "picker":
            FileLogger.shared.log("LENS", "Opened native CameraPickerDialog on Pixel 10 Pro screen")
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
            FileLogger.shared.log("PRIME", "Prime Lens: 24mm f/1.68 (1.00x)")
            smoothFrameTo(zoom: 1.00, panX: 0.0, panY: 0.0)
        case "35mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 35mm f/1.4 Cinema (1.35x)")
            smoothFrameTo(zoom: 1.35, panX: 0.0, panY: 0.0)
        case "50mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 50mm f/1.2 Portrait (1.75x)")
            smoothFrameTo(zoom: 1.75, panX: 0.0, panY: 0.0)
        case "85mm":
            FileLogger.shared.log("PRIME", "Prime Lens: 85mm f/1.4 Close-Up (2.35x)")
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
            for win in NSApp.windows where win.title.contains("PixelProCam") {
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
            FileLogger.shared.log("DOLLY", String(format: "Smooth Dolly Zoom %.2fx -> %.2fx", startZoom, targetZoom))
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
                    var speedText = "USB 2.0 (480 Мбит/с)"
                    var superSpeed = false
                    if sub.contains("\"UsbLinkSpeed\" = 10000000000") {
                        speedText = "USB 3.2 (10 Гбит/с)"
                        superSpeed = true
                    } else if sub.contains("\"UsbLinkSpeed\" = 5000000000") {
                        speedText = "USB 3.1 (5 Гбит/с)"
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
        currentFocusStatus = "Точечный фокус (Лицо)"
    }

    func triggerContinuousAutofocus() {
        FileLogger.shared.log("ADB", "Resetting to Continuous Video AF (CAF)")
        runADBCommand("input keyevent KEYCODE_WAKEUP && am start -n com.android.DeviceAsWebcam/com.android.deviceaswebcam.DeviceAsWebcamPreview >/dev/null 2>&1 && input tap 540 320")
        currentFocusStatus = "Следящий ИИ-AF (CAF)"
    }

    func toggleHQMode() {
        FileLogger.shared.log("ADB", "Toggling Pixel 10 Pro HQ Mode (954, 2149)")
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

// MARK: - Isolated VU Meter Subview
struct IsolatedVuMeterBar: View {
    @ObservedObject var vuState: VuMeterState
    let isMuted: Bool
    let isEnabled: Bool

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
                    Text("VU-метр выкл (0% CPU) • Включите справа для теста уровня")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
        .frame(height: 16)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - SwiftUI Pro Cinema Dark Deck (Zero-Scroll Ergonomic Layout)
struct StudioPanelView: View {
    @ObservedObject var ctrl: StudioController

    private func formatRecordTime(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 8) {
            // TOP TRANSPORT & STATUS HEADER BAR
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text("PixelProCam Studio")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text("v2.0")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.25))
                                .foregroundColor(.cyan)
                                .cornerRadius(4)
                        }
                        Text(ctrl.lastCaptureMessage.isEmpty ? "Google Pixel 10 Pro • RØDE NT1 5th Gen • Apple Vision AI" : ctrl.lastCaptureMessage)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(ctrl.lastCaptureMessage.isEmpty ? .secondary : .green)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Transport Controls
                Button(action: { ctrl.setAlwaysOnTop(!ctrl.alwaysOnTop) }) {
                    HStack(spacing: 3) {
                        Image(systemName: ctrl.alwaysOnTop ? "pin.fill" : "pin")
                        Text(ctrl.alwaysOnTop ? "ЗАКРЕП" : "ПОВЕРХ")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(ctrl.alwaysOnTop ? Color.indigo : Color.white.opacity(0.08))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { ctrl.takeStudioPhoto() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                        Text("ФОТО")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.22))
                    .foregroundColor(.cyan)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { ctrl.toggleStudioRecording() }) {
                    HStack(spacing: 4) {
                        Image(systemName: ctrl.isRecording ? "stop.circle.fill" : "record.circle")
                        Text(ctrl.isRecording ? "СТОП \(formatRecordTime(ctrl.recordSeconds))" : "ЗАПИСЬ")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(ctrl.isRecording ? Color.red : Color.red.opacity(0.22))
                    .foregroundColor(ctrl.isRecording ? .white : .red)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { ctrl.openCapturesFolder() }) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Открыть папку Captures")

                Button(action: { ctrl.togglePrivacyStandby() }) {
                    HStack(spacing: 4) {
                        Image(systemName: ctrl.isPrivacyStandby ? "play.fill" : "pause.fill")
                        Text(ctrl.isPrivacyStandby ? "В ЭФИР" : "ПАУЗА")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(ctrl.isPrivacyStandby ? Color.red : Color.orange.opacity(0.22))
                    .foregroundColor(ctrl.isPrivacyStandby ? .white : .orange)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Connection Pills
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(ctrl.obsConnected ? Color.green : Color.red).frame(width: 6, height: 6)
                        Text("OBS \(Int(ctrl.obsFps))fps").font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    HStack(spacing: 4) {
                        Circle().fill(ctrl.pixelConnected ? (ctrl.pixelScreenUnlocked ? Color.green : Color.orange) : Color.orange).frame(width: 6, height: 6)
                        Text(ctrl.pixelScreenUnlocked ? "Pixel USB" : "Блок экрана")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))

            // QUICK LIGHTING SCENARIOS BAR
            HStack(spacing: 6) {
                Label("Свет:", systemImage: "sparkles")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(.trailing, 2)
                presetBtn(title: "☀️ Дневной офис", id: "day")
                presetBtn(title: "🌆 Вечер / Тёплый", id: "evening")
                presetBtn(title: "🖥 Свет от монитора", id: "monitor")
                presetBtn(title: "🎙 Кино-Подкаст", id: "podcast")
            }

            // CARD 1: OPTICS, PHYSICAL LENSES & AUTOFOCUS
            StudioCard(title: "1. Оптика Pixel 10 Pro, Кино-фиксы и Автофокус", icon: "camera.filters", accent: .blue, trailingText: ctrl.currentCameraFacing) {
                VStack(spacing: 6) {
                    if !ctrl.pixelScreenUnlocked {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.iphone").foregroundColor(.orange)
                            Text("Разблокируйте Pixel 10 Pro отпечатком 1 раз для переключения физических модулей камеры (Stay-On USB активен).")
                                .font(.system(size: 9.5, weight: .medium)).foregroundColor(.orange)
                            Spacer()
                        }
                        .padding(5)
                        .background(Color.orange.opacity(0.14))
                        .cornerRadius(6)
                    }

                    // Physical Camera Modules
                    HStack(spacing: 5) {
                        Text("Сенсор:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .leading)

                        lensBtn(title: "0.5x Ультраширик", subtitle: "12mm f/2.2", id: "0.5x")
                        lensBtn(title: "1x Основной", subtitle: "24mm 50MP", id: "1x")
                        lensBtn(title: "2x Портрет", subtitle: "50mm Оптика", id: "2x")
                        lensBtn(title: "5x Телевик", subtitle: "113mm Крупный", id: "5x")
                        lensBtn(title: "🤳 Селфи/Тыл", subtitle: "42MP 17mm", id: "front")

                        Button(action: { ctrl.selectPhysicalLens("picker") }) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 11))
                                .padding(6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Открыть меню всех камер на экране Pixel 10 Pro")
                    }

                    // Zero-Latency Prime Focal Lengths + Autofocus Controls in one clean split row
                    HStack(spacing: 5) {
                        Text("Фиксы:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .leading)

                        primeBtn(title: "24mm f/1.68", id: "24mm")
                        primeBtn(title: "35mm f/1.4", id: "35mm")
                        primeBtn(title: "50mm f/1.2", id: "50mm")
                        primeBtn(title: "85mm f/1.4", id: "85mm")

                        Divider().frame(height: 18)

                        Button(action: { ctrl.triggerFaceAutofocus() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "face.smiling")
                                Text("AF Лицо")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Button(action: { ctrl.triggerContinuousAutofocus() }) {
                            Text("Следящий AF")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Button(action: { ctrl.toggleHQMode() }) {
                            Text(ctrl.isHQMode ? "HQ: ВКЛ" : "HQ: ВЫКЛ")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(ctrl.isHQMode ? Color.green.opacity(0.25) : Color.white.opacity(0.08))
                                .foregroundColor(ctrl.isHQMode ? .green : .secondary)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Toggle("OLED Blackout", isOn: Binding(
                            get: { ctrl.isBlackoutEnabled },
                            set: { ctrl.togglePixelBlackout($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                    }
                }
            }

            // CARD 2: FRAMING, SMOOTH DOLLY & APPLE VISION AI AUTO-FRAMING
            StudioCard(title: "2. Кадрирование, Smooth Dolly & ИИ-Трекинг (Apple Vision)", icon: "viewfinder.circle.fill", accent: .purple, trailingText: String(format: "Зум %.2fx • ИИ: %@", ctrl.zoomLevel, ctrl.aiFaceStatus)) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { ctrl.aiAutoFrameEnabled },
                            set: { ctrl.toggleAiAutoFraming($0) }
                        )) {
                            HStack(spacing: 4) {
                                Image(systemName: "brain.head.profile")
                                    .foregroundColor(ctrl.aiAutoFrameEnabled ? .green : .purple)
                                Text("ИИ-Слежение за лицом (Center Stage)")
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button(action: { ctrl.triggerSingleAiFaceFrame() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "scope")
                                Text("Навести по лицу")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.3))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        dollyBtn("1.0x Общий", zoom: 1.0, py: 0.0)
                        dollyBtn("1.22x По грудь", zoom: 1.22, py: -0.04)
                        dollyBtn("1.5x Портрет", zoom: 1.5, py: -0.06)
                        dollyBtn("2.0x Макро", zoom: 2.0, py: 0.0)
                    }

                    HStack(spacing: 8) {
                        Text(String(format: "%.2fx", ctrl.zoomLevel))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .frame(width: 40, alignment: .leading)

                        Slider(value: Binding(
                            get: { ctrl.zoomLevel },
                            set: { ctrl.zoomLevel = $0; ctrl.applyFramingImmediate() }
                        ), in: 1.0...2.5)

                        // Compact Pan Joypad
                        HStack(spacing: 3) {
                            panBtn("⬅️") { ctrl.smoothFrameTo(zoom: max(1.15, ctrl.zoomLevel), panX: max(-1.0, ctrl.panX - 0.25), panY: ctrl.panY) }
                            panBtn("⬆️") { ctrl.smoothFrameTo(zoom: max(1.15, ctrl.zoomLevel), panX: ctrl.panX, panY: max(-1.0, ctrl.panY - 0.25)) }
                            panBtn("🎯") { ctrl.smoothFrameTo(zoom: ctrl.zoomLevel, panX: 0.0, panY: 0.0) }
                            panBtn("⬇️") { ctrl.smoothFrameTo(zoom: max(1.15, ctrl.zoomLevel), panX: ctrl.panX, panY: min(1.0, ctrl.panY + 0.25)) }
                            panBtn("➡️") { ctrl.smoothFrameTo(zoom: max(1.15, ctrl.zoomLevel), panX: min(1.0, ctrl.panX + 0.25), panY: ctrl.panY) }
                        }

                        Button(action: { ctrl.toggleMirror(!ctrl.isMirrored) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                                Text(ctrl.isMirrored ? "Зеркало: ВКЛ" : "Зеркалить")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ctrl.isMirrored ? Color.blue : Color.white.opacity(0.08))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // CARD 3: 3D CINEMA LUT CARDS, VIGNETTE & 2.35:1 ANAMORPHIC SCOPE
            StudioCard(title: "3. Кинематографические 3D LUT и Анаморфотное Каше 2.35:1", icon: "film.stack", accent: .orange, trailingText: "Интенсивность: \(Int(ctrl.lutIntensity * 100))%") {
                VStack(spacing: 6) {
                    // 6 Visual 1-Click Cinema Look Cards
                    HStack(spacing: 5) {
                        lutCard(title: "🎬 S-Cinetone", sub: "Sony Alpha", id: "sony", color: .blue)
                        lutCard(title: "✨ Pro-Mist", sub: "Тёплый/Мягкий", id: "promist", color: .orange)
                        lutCard(title: "🎞 Kodak 2383", sub: "Киноплёнка", id: "kodak", color: .yellow)
                        lutCard(title: "🔥 Teal & Orange", sub: "Голливуд", id: "teal", color: .teal)
                        lutCard(title: "⚫️ Leica B&W", sub: "Монохром", id: "leica", color: .gray)
                        lutCard(title: "🚫 Rec.709", sub: "Чистый", id: "none", color: .secondary)
                    }

                    HStack(spacing: 10) {
                        Text("Сила LUT: \(Int(ctrl.lutIntensity * 100))%")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 85, alignment: .leading)

                        Slider(value: Binding(
                            get: { ctrl.lutIntensity },
                            set: { ctrl.lutIntensity = $0; ctrl.applyLUTDebounced() }
                        ), in: 0.0...1.0)

                        Toggle("Виньетка 35mm f/1.4", isOn: Binding(
                            get: { ctrl.vignetteEnabled },
                            set: { ctrl.setVignette($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5))

                        Toggle("🎬 Кино-рамка 2.35:1", isOn: Binding(
                            get: { ctrl.letterboxEnabled },
                            set: { ctrl.setCinemaLetterbox($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5, weight: .bold))
                    }
                }
            }

            // CARD 4: 2-COLUMN EXPOSURE, WHITE BALANCE & DETAIL MATRIX
            StudioCard(title: "4. Экспозиция, Баланс Белого (ББ) и Детализация", icon: "slider.horizontal.3", accent: .cyan) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Button(action: { ctrl.resetExposureAuto() }) {
                            Label("АВТО Экспозиция", systemImage: "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.indigo.opacity(0.35)).cornerRadius(5)
                        }.buttonStyle(.plain)

                        Button(action: { ctrl.resetWhiteBalanceAuto() }) {
                            Label("АВТО Баланс Белого", systemImage: "thermometer.medium")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.teal.opacity(0.35)).cornerRadius(5)
                        }.buttonStyle(.plain)

                        Spacer()

                        Button(action: { ctrl.resetAllImageAuto() }) {
                            Label("Сброс всего в АВТО", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.08)).cornerRadius(5)
                        }.buttonStyle(.plain)
                    }

                    // 2x3 Compact Studio Slider Matrix
                    HStack(spacing: 14) {
                        VStack(spacing: 4) {
                            compactSlider(label: "Экспозиция", value: $ctrl.brightness, range: -0.25...0.25, fmt: "%+.0f%%", mult: 100)
                            compactSlider(label: "Контраст", value: $ctrl.contrast, range: -0.30...0.45, fmt: "%+.0f%%", mult: 100)
                            compactSlider(label: "Гамма (Тени)", value: $ctrl.vargamma, range: -0.30...0.30, fmt: "%+.0f%%", mult: 100)
                        }
                        VStack(spacing: 4) {
                            compactSlider(label: "ББ (Тёпл/Хол)", value: $ctrl.hueShift, range: -25.0...25.0, fmt: "%+.1f°", mult: 1)
                            compactSlider(label: "Насыщенность", value: $ctrl.saturation, range: -0.40...0.50, fmt: "%+.0f%%", mult: 100)
                            compactSlider(label: "Резкость", value: $ctrl.sharpness, range: 0.0...0.25, fmt: "%.0f%%", mult: 400)
                        }
                    }
                }
            }

            // CARD 5: RØDE NT1 5th Gen STUDIO AUDIO & HARDWARE LIP-SYNC
            StudioCard(title: "5. Аудио RØDE NT1 5th Gen (Родной APHEX DSP + Аппаратный Lip-Sync)", icon: "mic.fill", accent: .green, trailingText: "Задержка звука: +\(Int(ctrl.rodeLipSyncMs)) мс") {
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        IsolatedVuMeterBar(vuState: ctrl.vuState, isMuted: ctrl.isRodeMuted, isEnabled: ctrl.liveVuEnabled)

                        Toggle("VU-Метр", isOn: Binding(
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
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.09)).cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Button(action: { ctrl.toggleRodeMute() }) {
                            Text(ctrl.isRodeMuted ? "🔇 МИКРОФОН ВЫКЛ" : "🎙 В ЭФИРЕ")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(ctrl.isRodeMuted ? Color.red : Color.green.opacity(0.25))
                                .foregroundColor(ctrl.isRodeMuted ? .white : .green)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        audioPresetBtn(title: "🎯 Родной DSP RØDE Central (Без дублей)", id: "pure")
                        audioPresetBtn(title: "📻 +OBS Радио-Бас", id: "radio")
                        audioPresetBtn(title: "🎙 +OBS Чёткая речь", id: "voice")

                        Divider().frame(height: 16)

                        Text("⏱ Lip-Sync: +\(Int(ctrl.rodeLipSyncMs))мс")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(width: 105, alignment: .leading)

                        Slider(value: Binding(
                            get: { ctrl.rodeLipSyncMs },
                            set: { ctrl.rodeLipSyncMs = $0; ctrl.applyRodeLipSyncDebounced() }
                        ), in: 0.0...140.0)
                        .frame(width: 90)

                        Button(ctrl.is60FpsMode ? "35мс" : "65мс") {
                            ctrl.rodeLipSyncMs = ctrl.is60FpsMode ? 35.0 : 65.0
                            ctrl.applyRodeLipSyncImmediate()
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            // FOOTER TELEMETRY & CABLE STRIP
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    statBadge(label: "FPS", value: String(format: "%.1f", ctrl.obsFps),
                              ok: ctrl.obsFps >= (ctrl.is60FpsMode ? 55.0 : 28.5))
                    statBadge(label: "Render", value: String(format: "%.1fms", ctrl.obsRenderTimeMs),
                              ok: ctrl.obsRenderTimeMs < 13.5)
                    statBadge(label: "CPU", value: String(format: "%.1f%%", ctrl.obsCpuUsage),
                              ok: ctrl.obsCpuUsage < 25.0)
                    statBadge(label: "Кабель", value: ctrl.usbCableSpeed, ok: true)
                    statBadge(label: "PD", value: "15W", ok: true)
                    statBadge(label: "Pixel", value: String(format: "%d%% • %.1f°C", ctrl.pixelBatteryLevel, ctrl.pixelTempC),
                              ok: ctrl.pixelTempC < 41.0)

                    Spacer()

                    Button(ctrl.is60FpsMode ? "30 FPS" : "✅ 30 FPS") {
                        ctrl.setCameraFpsMode(use60Fps: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(ctrl.is60FpsMode ? "⚡ 60 FPS (~35мс)" : "60 FPS") {
                        ctrl.setCameraFpsMode(use60Fps: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ctrl.is60FpsMode ? .green : .gray)
                    .controlSize(.mini)

                    Button(action: { ctrl.showLogs.toggle() }) {
                        HStack(spacing: 2) {
                            Image(systemName: ctrl.showLogs ? "chevron.up" : "chevron.down")
                            Text("Логи")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
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
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Очистить") { ctrl.logEntries.removeAll() }
                            .buttonStyle(.bordered).controlSize(.mini)
                        Button("Открыть .log") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: FileLogger.shared.logFilePath))
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
        }
        .padding(10)
        .frame(width: 660, height: ctrl.showLogs ? 775 : 675)
    }

    // MARK: - Custom Studio UI Components
    private func statBadge(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 5.5, height: 5.5)
            Text("\(label):").font(.system(size: 9.5)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9.5, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(Color.white.opacity(0.06))
        .cornerRadius(4)
    }

    private func lensBtn(title: String, subtitle: String, id: String) -> some View {
        let active = ctrl.selectedPhysicalLens == id
        return Button(action: { ctrl.selectPhysicalLens(id) }) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: active ? .bold : .medium))
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundColor(active ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(active ? Color.blue : Color.white.opacity(0.07))
            .foregroundColor(.white)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func primeBtn(title: String, id: String) -> some View {
        let active = ctrl.selectedPrimeFocal == id
        return Button(action: { ctrl.selectPrimeFocalLength(id) }) {
            Text(title)
                .font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? Color.indigo : Color.white.opacity(0.07))
                .foregroundColor(.white)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func dollyBtn(_ title: String, zoom: Double, py: Double) -> some View {
        let active = abs(ctrl.zoomLevel - zoom) < 0.04
        return Button(action: { ctrl.smoothFrameTo(zoom: zoom, panX: 0, panY: py) }) {
            Text(title)
                .font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(active ? Color.purple.opacity(0.45) : Color.white.opacity(0.07))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func panBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .frame(width: 23, height: 21)
                .background(Color.white.opacity(0.08))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func lutCard(title: String, sub: String, id: String, color: Color) -> some View {
        let active = ctrl.selectedLUT == id
        return Button(action: { ctrl.selectLUT(id) }) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: active ? .bold : .semibold))
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 8))
                    .foregroundColor(active ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(active ? color.opacity(0.45) : Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? color : Color.clear, lineWidth: 1.2)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func presetBtn(title: String, id: String) -> some View {
        let active = ctrl.activeLightingPreset == id
        return Button(action: { ctrl.applyLightingPreset(id) }) {
            Text(title)
                .font(.system(size: 10, weight: active ? .bold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4.5)
                .background(active ? Color.blue.opacity(0.35) : Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(active ? Color.cyan.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func audioPresetBtn(title: String, id: String) -> some View {
        let active = ctrl.activeAudioPreset == id
        return Button(action: { ctrl.setRodeAudioMode(id) }) {
            Text(title)
                .font(.system(size: 9.5, weight: active ? .bold : .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? Color.green.opacity(0.32) : Color.white.opacity(0.07))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func compactSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String, mult: Double) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; ctrl.applyColorCorrection() }
            ), in: range)
            .controlSize(.small)
            Text(String(format: fmt, value.wrappedValue * mult))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.8))
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - AppDelegate with Persistent Top macOS Menu Bar (NSStatusItem)
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let ctrl = StudioController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let contentView = StudioPanelView(ctrl: ctrl)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 675),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "PixelProCam Studio v2.0 — Google Pixel 10 Pro & RØDE NT1"
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBarExtra()
        ctrl.onStatusChangeForMenuBar = { [weak self] in
            self?.updateStatusButtonTitle()
        }
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
            let m = ctrl.recordSeconds / 60
            let s = ctrl.recordSeconds % 60
            btn.title = String(format: " %02d:%02d", m, s)
        } else if ctrl.isPrivacyStandby {
            btn.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Paused")
            btn.title = " ПАУЗА"
        } else {
            btn.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "PixelProCam Studio")
            btn.title = " PixelProCam"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let showTitle = window.isVisible ? "🎛 Показать / На передний план пульт" : "🎛 Открыть окно пульта PixelProCam"
        let showItem = NSMenuItem(title: showTitle, action: #selector(toggleMainWindow), keyEquivalent: "p")
        showItem.target = self
        menu.addItem(showItem)

        let pinItem = NSMenuItem(title: "📌 Закрепить пульт поверх всех окон", action: #selector(menuTogglePin), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = ctrl.alwaysOnTop ? .on : .off
        menu.addItem(pinItem)

        menu.addItem(NSMenuItem.separator())

        let photoItem = NSMenuItem(title: "📸 Сделать студийное ФОТО (1920×1080 PNG)", action: #selector(menuTakePhoto), keyEquivalent: "s")
        photoItem.target = self
        menu.addItem(photoItem)

        let recTitle = ctrl.isRecording ? "⏹ Остановить ЗАПИСЬ видео" : "🔴 Начать ЗАПИСЬ студийного видео"
        let recItem = NSMenuItem(title: recTitle, action: #selector(menuToggleRec), keyEquivalent: "r")
        recItem.target = self
        menu.addItem(recItem)

        let folderItem = NSMenuItem(title: "📂 Открыть папку Captures (Фото и Видео)", action: #selector(menuOpenCaptures), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

        let standbyTitle = ctrl.isPrivacyStandby ? "▶️ ВЕРНУТЬСЯ В ЭФИР (Снять паузу)" : "⏸ НА ПАУЗУ (Заставка + Mute RØDE)"
        let standbyItem = NSMenuItem(title: standbyTitle, action: #selector(menuToggleStandby), keyEquivalent: "")
        standbyItem.target = self
        menu.addItem(standbyItem)

        let muteTitle = ctrl.isRodeMuted ? "🔇 Микрофон RØDE NT1: ВЫКЛ (Включить)" : "🎙 Микрофон RØDE NT1: В ЭФИРЕ (Заглушить)"
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(menuToggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        let aiItem = NSMenuItem(title: "🧠 ИИ-Автокадрирование по лицу (Apple Vision)", action: #selector(menuToggleAi), keyEquivalent: "")
        aiItem.target = self
        aiItem.state = ctrl.aiAutoFrameEnabled ? .on : .off
        menu.addItem(aiItem)

        let aiOnceItem = NSMenuItem(title: "🎯 Центрировать кадр по лицу (1 раз)", action: #selector(menuAiOnce), keyEquivalent: "")
        aiOnceItem.target = self
        menu.addItem(aiOnceItem)

        let mirrorItem = NSMenuItem(title: "🪞 Зеркалить картинку", action: #selector(menuToggleMirror), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = ctrl.isMirrored ? .on : .off
        menu.addItem(mirrorItem)

        let letterboxItem = NSMenuItem(title: "🎬 Кино-рамка 2.35:1 Cinema Scope", action: #selector(menuToggleLetterbox), keyEquivalent: "")
        letterboxItem.target = self
        letterboxItem.state = ctrl.letterboxEnabled ? .on : .off
        menu.addItem(letterboxItem)

        menu.addItem(NSMenuItem.separator())

        let lensMenu = NSMenu()
        let lenses: [(String, String)] = [
            ("0.5x Ультраширик (12mm f/2.2)", "0.5x"),
            ("1x Основной (24mm 50MP)", "1x"),
            ("2x Портрет (50mm Оптика)", "2x"),
            ("5x Телевик (113mm Крупный)", "5x"),
            ("🤳 Селфи / Тыл (42MP 17mm)", "front")
        ]
        for (title, id) in lenses {
            let item = NSMenuItem(title: title, action: #selector(menuSelectLens(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.selectedPhysicalLens == id) ? .on : .off
            lensMenu.addItem(item)
        }
        lensMenu.addItem(NSMenuItem.separator())
        let primes: [(String, String)] = [
            ("Кино-фикс 24mm f/1.68 (1.0x)", "24mm"),
            ("Кино-фикс 35mm f/1.4 (1.35x)", "35mm"),
            ("Кино-фикс 50mm f/1.2 (1.75x)", "50mm"),
            ("Кино-фикс 85mm f/1.4 (2.35x)", "85mm")
        ]
        for (title, id) in primes {
            let item = NSMenuItem(title: title, action: #selector(menuSelectPrime(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.selectedPrimeFocal == id) ? .on : .off
            lensMenu.addItem(item)
        }
        let lensParent = NSMenuItem(title: "📷 Объектив и Фокусное расстояние", action: nil, keyEquivalent: "")
        lensParent.submenu = lensMenu
        menu.addItem(lensParent)

        let lutMenu = NSMenu()
        let luts: [(String, String)] = [
            ("🎬 Sony Alpha S-Cinetone", "sony"),
            ("✨ Tiffen Black Pro-Mist", "promist"),
            ("🎞 Kodak 2383 Film Print", "kodak"),
            ("🔥 Teal & Orange", "teal"),
            ("⚫️⚪️ Leica Monochrome", "leica"),
            ("🚫 Без LUT (Чистый Rec.709)", "none")
        ]
        for (title, id) in luts {
            let item = NSMenuItem(title: title, action: #selector(menuSelectLut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.selectedLUT == id) ? .on : .off
            lutMenu.addItem(item)
        }
        let lutParent = NSMenuItem(title: "🎨 Кино-стиль (3D LUT)", action: nil, keyEquivalent: "")
        lutParent.submenu = lutMenu
        menu.addItem(lutParent)

        let lightMenu = NSMenu()
        let lights: [(String, String)] = [
            ("☀️ Дневной офис", "day"),
            ("🌆 Вечер / Тёплый", "evening"),
            ("🖥 Свет от монитора", "monitor"),
            ("🎙 Кино-Подкаст", "podcast")
        ]
        for (title, id) in lights {
            let item = NSMenuItem(title: title, action: #selector(menuSelectLight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (ctrl.activeLightingPreset == id) ? .on : .off
            lightMenu.addItem(item)
        }
        let lightParent = NSMenuItem(title: "☀️ Сценарий освещения", action: nil, keyEquivalent: "")
        lightParent.submenu = lightMenu
        menu.addItem(lightParent)

        menu.addItem(NSMenuItem.separator())

        let fps60Item = NSMenuItem(title: "⚡ 60 FPS Ultra-Low-Latency (~35 мс задержка)", action: #selector(menuSet60Fps), keyEquivalent: "")
        fps60Item.target = self
        fps60Item.state = ctrl.is60FpsMode ? .on : .off
        menu.addItem(fps60Item)

        let fps30Item = NSMenuItem(title: "🎥 30 FPS Studio (~65 мс задержка)", action: #selector(menuSet30Fps), keyEquivalent: "")
        fps30Item.target = self
        fps30Item.state = !ctrl.is60FpsMode ? .on : .off
        menu.addItem(fps30Item)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "🚪 Выйти из PixelProCam Studio", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc func toggleMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func menuTogglePin() { ctrl.setAlwaysOnTop(!ctrl.alwaysOnTop) }
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
    @objc func menuQuit() { NSApp.terminate(nil) }

    @objc func menuSelectLens(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            ctrl.selectPhysicalLens(id)
        }
    }

    @objc func menuSelectPrime(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            ctrl.selectPrimeFocalLength(id)
        }
    }

    @objc func menuSelectLut(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            ctrl.selectLUT(id)
        }
    }

    @objc func menuSelectLight(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            ctrl.applyLightingPreset(id)
        }
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

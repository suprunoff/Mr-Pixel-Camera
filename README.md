<p align="center">
  <a href="https://mrmo.es">
    <img src="assets/icons/mo_logo.png" alt="Mo. Logo — mrmo.es" width="84" style="border-radius: 18px;">
  </a>
</p>

<h1 align="center">Mr. Pixel Camera v2.2</h1>

<p align="center">
  <b>Low-Latency, True 1080p @ 60 FPS Cinema Control Center for Google Pixel USB Webcam + macOS + OBS Studio + RØDE DSP</b><br>
  <i>No phone app required • Black Pro-Mist 1/4 &amp; Kodak 35mm GPU Shaders • 3D Cinema LUTs • Apple Vision AI • EN / RU</i><br><br>
  🌐 Built by <a href="https://mrmo.es"><b>mrmo.es</b></a>
</p>

<p align="center">
  <img src="assets/screenshots/studio_ui_v2.2.png" alt="Mr. Pixel Camera v2.2 macOS Pro Cinema Dark UI" width="760">
</p>

---

## ⚡ Why Mr. Pixel Camera Beats Camo / Iriun / DroidCam

Third-party webcam apps (`Camo`, `Iriun`, `DroidCam`) force you to install a heavy Android app that grabs frames via user-space `Camera2`, encodes them into inter-frame `H.264`, pushes packets over a proprietary `TCP / Android Open Accessory` socket, and decodes them again on your Mac — adding **90–140 ms of latency**, compression macroblocking, and heating the phone up to `43–45°C`.

**Mr. Pixel Camera** uses a fundamentally cleaner architecture built specifically for **Google Pixel (Android 14–17)** + **Apple Silicon Macs**:
1. **Kernel-Level UVC Video Pipe (`~32–35 ms` at `60 FPS`):** Video flows directly from Google Tensor's **Lyric Camera HAL** into Linux kernel V4L2 `/dev/video*` UVC and straight into macOS **`macos-avcapture-fast` (`IOSurface` zero-copy GPU textures)** with buffering disabled.
2. **Direct Hardware Control over USB (`ADB`):** Switches physical Pixel lenses (`0.5x Ultra-Wide 12mm`, `1x Main 50MP 24mm f/1.68`, `2x Optical In-Sensor 50mm`, `5x Telephoto 113mm`, `42MP Front Selfie`), triggers Face/Eye Tap-Autofocus, toggles `HQ` mode, and enables `Stay-On USB` + `OLED Blackout` without any third-party app running on the phone.
3. **16-Core Apple Neural Engine Auto-Framing (`Vision`):** Face tracking (`Center Stage`) runs on the Mac's **Apple Neural Engine (`VNDetectFaceRectanglesRequest`)** with `< 0.5% CPU` overhead and smooth cubic-bezier Dolly Zoom interpolation.

| Metric | **Mr. Pixel Camera v2.1 (Native UVC + OBS GPU)** | Camo Studio Pro / Iriun / DroidCam |
| :--- | :--- | :--- |
| **End-to-End Video Latency** | **`~32–35 ms` (at `1080p @ 60 FPS`)** | `90–140 ms` (H.264 GOP buffer + TCP socket) |
| **Phone App Required** | **None (`0 MB` — uses built-in Android `DeviceAsWebcam`)** | Requires background `.apk` service |
| **Phone Temperature (1h+ stream)** | **`35–36°C` (Battery stays at `100%` via 15W USB-PD)** | `42–45°C` |
| **Color Pipeline** | **33×33×33 `.cube` 3D LUTs on Apple Silicon GPU (`IOSurface`)** | Locked behind \$40–\$50/yr paywall |
| **Face Tracking (`Center Stage`)** | **macOS Apple Vision Neural Engine + Smooth Dolly Zoom** | Paid tier / CPU-heavy |
| **Audio Lip-Sync Calibration** | **Hardware millisecond offset (`+35 ms` @ 60fps / `+65 ms` @ 30fps)** | None |

---

## ✨ What's New in v2.2 Cinema Optics Edition

- **✨ Black Pro-Mist 1/4 GPU Optical Halation (`obs-shaderfilter`):** Custom 12-tap dual-ring optical diffusion shader with warm filmic halation and shadow black protection — renders in `< 1.5 ms` at locked `60.0 FPS` on Apple Silicon (`OpenGL` hardware NV12).
- **🎞 Kodak 35mm Organic Film Grain GPU Shader:** Luminance-weighted 24fps silver-halide emulsion texture that eliminates digital MJPEG banding while preserving natural detail.
- **🚀 Zero-Click Startup & Smart Auto-Recovery:** Sets native Android `screen_unlocked_functions=uvc` so Pixel enters Webcam mode automatically upon unlock, auto-heals `adb offline`, auto-starts `OBS Studio` (`--startvirtualcam`) + `OBS Virtual Camera`, and syncs FPS/Resolution/Shader states on connect.
- **📐 Hardware UVC Resolution Switcher (`1080p` / `720p` / `480p` / `360p`) & True `60 FPS`:** Pixel 10 Pro streams true hardware `1080p @ 60 FPS` (`HQ: OFF`) or `30 FPS` enhanced HDR (`HQ: ON`) with automatic OBS cover scaling.
- **🌐 Instant `EN / RU` Language Switcher:** Auto-detects macOS locale on first run (`EN` / `RU`) with a 1-click switcher in both the title bar and top macOS Menu Bar.
- **📺 Collapsible Live Studio Monitor (`Preview`) + `3×3` Rule-of-Thirds Grid:** View your final color-graded OBS output directly inside `Mr. Pixel Camera` (0% CPU when collapsed — safely hide OBS with `⌘H`).
- **🎛 Interactive 2D Framing Trackpad:** Drag the purple crop viewport anywhere to pan in real time; double-click to recenter smoothly.
- **🎨 Cinema Color Swatch Cards (`3D LUTs`):** Visual palette strips on all 6 one-click look cards (`Sony S-Cinetone`, `Black Pro-Mist Warm`, `Kodak 2383`, `Teal & Orange`, `Leica Monochrome B&W`, `Pure Rec.709`) + `35mm f/1.4` Optical Vignette & `2.35:1 Anamorphic Scope`.
- **💾 3 Custom User Memory Slots (`M1` / `M2` / `M3`):** Save and recall your complete look (`LUT + Pro-Mist + 35mm Grain + Exposure + WB + Zoom + Pan + 2.35:1`) in 1 click.
- **▫ Compact Mini Deck Mode (`Mini`):** Collapses the studio panel into a sleek single-row floating control strip above Zoom / Google Meet / Telegram.
- **🎥 Persistent macOS Menu Bar Extra (`NSStatusItem`):** Close the main window anytime and control everything from the top macOS Menu Bar.
- **🎙 RØDE NT1 5th Gen Native APHEX® Bypass + Hardware Lip-Sync (`+35 ms` / `+65 ms`):** Clean pass-through for `RØDE Central` onboard DSP without double-compression + millisecond lip-sync alignment.
- **📸 1-Click Studio Photo (`1920×1080 PNG`) & 🔴 Video Recording (`Apple VT HEVC`):** Saves directly into `./Captures`.

---

## 🎚 Companion App: Mr. Audio Meters v2.5 (RØDE NT1 5th Gen Studio)

<p align="center">
  <img src="assets/screenshots/audio_meters_quad.png" alt="Mr. Audio Meters v2.5 Studio Analyzer & Direct RØDE NT1 DSP" width="760">
</p>

Included alongside `Mr. Pixel Camera` (launchable in 1 click via the **`Meters`** button or standalone):
- **MiniMeters + FabFilter Pro-Q 4 + TDR Prism + Youlean Loudness UI:** Multi-band frequency-colored waveform with live Noise Gate threshold line, 64-band smooth vector FFT spectrum (`0 / +3 / +4.5 dB/oct` tilt + Vocal Target Curve), Mel spectrogram waterfall, pitch-locked oscilloscope, Lissajous stereometer, and scrolling EBU R128 LUFS history.
- **Direct RØDE NT1 5th Gen Hardware Control (`IOKit USB HID` + `CoreAudio HAL`):** Real-time bi-directional control of onboard `Input Gain`, `HPF (Off / 75 / 150 Hz)`, `Noise Gate` (with live `OPEN / CLOSED` indicator), `Compressor`, `APHEX Big Bottom™`, and `APHEX Aural Exciter™` — plus **A / B** comparison slots, **Room Acoustic Profiles** (`Construction`, `Quiet Studio`, `Echo`, `Office`), **Mic Voice Presets** (`Radio`, `Podcast`, `Calls`, `Bright`, `ASMR`, `Raw`), **5s Noise Auto-Scanner**, **Clap RT60 Room Echo Test**, **5s Instant Headphone Voice Check**, **OBS AI RNNoise** turbo integration, **macOS System Audio (`ScreenCaptureKit`)** mode, and global **`⌘⇧M` Hardware Mute**.

---

## 🚀 Quick Start (1-Click Install)

### Prerequisites
1. **macOS 13.0+** (Apple Silicon M1/M2/M3/M4 recommended) with **OBS Studio 30+** installed.
2. **Google Pixel (8 / 9 / 10 Pro)** connected via USB-C with:
   - USB preference set to **Webcam (`Веб-камера`)** in the Android USB notification.
   - **USB Debugging (`Отладка по USB`)** enabled in Developer Options (for physical lens switching & autofocus).

### Installation
```bash
git clone https://github.com/suprunoff/Mr-Pixel-Camera.git
cd Mr-Pixel-Camera
chmod +x install.sh
./install.sh
```

`install.sh` automatically copies all 3D LUTs, custom cinema GPU shaders, and optical overlays into OBS Studio, compiles the native **`Mr. Pixel Camera.app`** bundle using `/usr/bin/swiftc`, enables OBS WebSocket on port `4455`, and launches the studio deck.

### Recommended Apple Silicon OBS Plugins (Optional for GPU Shaders & Transitions)
- [`obs-shaderfilter`](https://github.com/exeldro/obs-shaderfilter) — powers `Black Pro-Mist 1/4` optical halation & `Kodak 35mm Film Grain` shaders
- [`obs-composite-blur`](https://github.com/FiniteSingularity/obs-composite-blur) — GPU Dual-Kawase / Gaussian blur
- [`obs-advanced-masks`](https://github.com/FiniteSingularity/obs-advanced-masks) — GPU optical shapes & gradient masks
- [`move-transition`](https://github.com/exeldro/obs-move-transition) & [`source-clone`](https://github.com/exeldro/obs-source-clone) — smooth multi-angle transitions & conflict-free camera cloning

---

## 📁 Repository Structure

```text
Mr-Pixel-Camera/
├── macos/
│   ├── PixelProCamStudio.swift      # Native macOS SwiftUI + AppKit + Vision AI Studio Deck (EN/RU)
│   └── MrAudioMeters.swift          # Native macOS Audio Analyzer + Direct RØDE NT1 5th Gen USB HID DSP
├── assets/
│   ├── luts/                        # 33x33x33 3D Cinema LUTs (.cube)
│   ├── shaders/                     # Black Pro-Mist 1/4 Halation & Kodak 35mm Film Grain (.shader)
│   ├── overlays/                    # 35mm Optical Vignette, 2.35:1 Letterbox & Privacy Standby (.png)
│   ├── icons/                       # Multi-resolution Retina AppIcon.icns
│   └── screenshots/                 # Retina UI preview
├── install.sh                       # 1-click macOS builder & OBS installer
└── LICENSE                          # MIT License
```

---

## 👤 Author & Links
- **Website:** **[https://mrmo.es](https://mrmo.es)**
- **GitHub:** **[@suprunoff](https://github.com/suprunoff)**
- **License:** MIT License — free for personal and commercial studio use.

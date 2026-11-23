package com.pixelprocam

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.view.Surface
import org.json.JSONObject
import java.io.BufferedReader
import java.io.DataOutputStream
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

class UsbStreamServer(
    private val cameraController: Camera2Controller,
    private val renderer: GlLutRenderer,
    private val onUiStateChanged: () -> Unit
) {
    private val running = AtomicBoolean(false)
    private var codec: MediaCodec? = null
    var encoderInputSurface: Surface? = null
        private set

    private var videoServerSocket: ServerSocket? = null
    private var controlServerSocket: ServerSocket? = null
    private var cachedCodecConfig: ByteArray? = null

    fun start(width: Int = 1920, height: Int = 1080, bitrate: Int = 25_000_000) {
        if (running.getAndSet(true)) return

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // Realtime priority
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }

        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val inputSurface = encoder.createInputSurface()
        encoderInputSurface = inputSurface
        renderer.setEncoderSurface(inputSurface)
        encoder.start()
        codec = encoder

        Thread({ runVideoStreamLoop(encoder) }, "PixelProCam-UsbVideoThread").start()
        Thread({ runControlServerLoop() }, "PixelProCam-UsbControlThread").start()
    }

    fun stop() {
        running.set(false)
        try { videoServerSocket?.close() } catch (_: Exception) {}
        try { controlServerSocket?.close() } catch (_: Exception) {}
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Exception) {}
        codec = null
    }

    fun requestInstantKeyframe() {
        try {
            val params = Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            codec?.setParameters(params)
        } catch (_: Exception) {}
    }

    private fun runVideoStreamLoop(encoder: MediaCodec) {
        try {
            val server = ServerSocket(5555)
            videoServerSocket = server
            val bufferInfo = MediaCodec.BufferInfo()

            while (running.get()) {
                val client = server.accept()
                client.tcpNoDelay = true
                client.sendBufferSize = 256 * 1024
                val out = DataOutputStream(client.getOutputStream())

                // Send cached SPS/PPS immediately on connection and request IDR frame
                cachedCodecConfig?.let { configBytes ->
                    out.writeInt(configBytes.size)
                    out.writeLong(0L)
                    out.write(configBytes)
                    out.flush()
                }
                requestInstantKeyframe()

                try {
                    while (running.get() && !client.isClosed) {
                        val outIndex = encoder.dequeueOutputBuffer(bufferInfo, 10_000)
                        if (outIndex >= 0) {
                            val encodedData: ByteBuffer? = encoder.getOutputBuffer(outIndex)
                            if (encodedData != null && bufferInfo.size > 0) {
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                val bytes = ByteArray(bufferInfo.size)
                                encodedData.get(bytes)

                                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                    cachedCodecConfig = bytes
                                }

                                out.writeInt(bytes.size)
                                out.writeLong(bufferInfo.presentationTimeUs)
                                out.write(bytes)
                                out.flush()
                            }
                            encoder.releaseOutputBuffer(outIndex, false)
                        }
                    }
                } catch (_: Exception) {
                } finally {
                    try { client.close() } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
    }

    private fun runControlServerLoop() {
        try {
            val server = ServerSocket(5556)
            controlServerSocket = server
            while (running.get()) {
                val client = server.accept()
                client.tcpNoDelay = true
                Thread {
                    try {
                        val reader = BufferedReader(InputStreamReader(client.getInputStream()))
                        val writer = PrintWriter(client.getOutputStream(), true)
                        var line: String?
                        while (running.get() && reader.readLine().also { line = it } != null) {
                            val cmd = JSONObject(line!!)
                            handleRemoteCommand(cmd)
                            writer.println(buildTelemetryJson().toString())
                        }
                    } catch (_: Exception) {
                    } finally {
                        try { client.close() } catch (_: Exception) {}
                    }
                }.start()
            }
        } catch (_: Exception) {}
    }

    private fun handleRemoteCommand(cmd: JSONObject) {
        when (cmd.optString("action")) {
            "set_lut" -> {
                renderer.selectBuiltInLut(cmd.optString("lut", "sony_scinetone"))
                if (cmd.has("intensity")) {
                    renderer.lutIntensity = cmd.optDouble("intensity", 0.78).toFloat()
                }
            }
            "set_shader" -> {
                if (cmd.has("lut_intensity")) renderer.lutIntensity = cmd.optDouble("lut_intensity").toFloat()
                if (cmd.has("promist")) renderer.proMistAmount = cmd.optDouble("promist").toFloat()
                if (cmd.has("vignette")) renderer.vignetteAmount = cmd.optDouble("vignette").toFloat()
                if (cmd.has("contrast")) renderer.contrastBoost = cmd.optDouble("contrast").toFloat()
                if (cmd.has("saturation")) renderer.saturationBoost = cmd.optDouble("saturation").toFloat()
            }
            "set_auto_framing" -> {
                renderer.autoFramingEnabled = cmd.optBoolean("enabled", true)
                if (cmd.has("zoom")) renderer.manualZoom = cmd.optDouble("zoom", 1.0).toFloat()
            }
            "set_focus" -> {
                when (cmd.optString("mode")) {
                    "face" -> {
                        cameraController.focusMode = FocusMode.FACE_AF
                        cameraController.applyCameraParameters()
                    }
                    "lock" -> cameraController.lockFocusAtCurrentDistance()
                    "manual" -> cameraController.setFocusDistanceCm(cmd.optInt("cm", 65))
                }
            }
            "set_exposure" -> {
                cameraController.aeLocked = cmd.optBoolean("ae_lock", cameraController.aeLocked)
                cameraController.manualExposureEnabled = cmd.optBoolean("manual", cameraController.manualExposureEnabled)
                if (cmd.has("iso")) cameraController.manualIso = cmd.optInt("iso", 160)
                if (cmd.has("shutter_hz")) {
                    val hz = cmd.optInt("shutter_hz", 120).coerceIn(30, 1000)
                    cameraController.manualShutterNs = 1_000_000_000L / hz
                }
                if (cmd.has("ev")) cameraController.evCompensationIndex = cmd.optInt("ev", 0)
                cameraController.applyCameraParameters()
            }
            "set_wb" -> {
                cameraController.awbLocked = cmd.optBoolean("awb_lock", cameraController.awbLocked)
                cameraController.manualWbEnabled = cmd.optBoolean("manual", cameraController.manualWbEnabled)
                if (cmd.has("kelvin")) cameraController.manualWbKelvin = cmd.optInt("kelvin", 5200)
                cameraController.applyCameraParameters()
            }
            "set_oversharpen_off" -> {
                cameraController.disableAndroidOversharpen = cmd.optBoolean("enabled", true)
                cameraController.applyCameraParameters()
            }
            "apply_preset" -> {
                cameraController.applyLightingPreset(cmd.optString("preset", "day"))
            }
            "set_blackout" -> {
                renderer.oledBlackout = cmd.optBoolean("enabled", false)
            }
        }
        onUiStateChanged()
    }

    fun buildTelemetryJson(): JSONObject {
        return JSONObject().apply {
            put("lut", renderer.activeLutName)
            put("lut_intensity", renderer.lutIntensity)
            put("promist", renderer.proMistAmount)
            put("vignette", renderer.vignetteAmount)
            put("auto_framing", renderer.autoFramingEnabled)
            put("face_detected", renderer.faceDetected)
            put("zoom", renderer.manualZoom)
            put("focus_mode", cameraController.focusMode.name)
            put("focus_cm", cameraController.currentFocusCm)
            put("iso", cameraController.currentLiveIso)
            put("shutter_ms", cameraController.currentLiveShutterMs)
            put("wb_kelvin", cameraController.manualWbKelvin)
            put("ae_locked", cameraController.aeLocked)
            put("awb_locked", cameraController.awbLocked)
            put("oled_blackout", renderer.oledBlackout)
        }
    }
}

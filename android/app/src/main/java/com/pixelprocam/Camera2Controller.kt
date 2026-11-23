package com.pixelprocam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.hardware.camera2.*
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.RggbChannelVector
import android.hardware.camera2.params.SessionConfiguration
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.view.Surface
import java.util.concurrent.Executors
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

enum class FocusMode {
    FACE_AF,
    AF_LOCK,
    MANUAL
}

class Camera2Controller(
    private val context: Context,
    private val renderer: GlLutRenderer
) {
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var requestBuilder: CaptureRequest.Builder? = null
    private var outputSurface: Surface? = null

    private var sensorArraySize: Rect = Rect(0, 0, 4000, 3000)
    private var minFocusDistanceDiopters: Float = 10.0f // ~10 cm

    // Live camera settings
    @Volatile var focusMode: FocusMode = FocusMode.FACE_AF
    @Volatile var manualFocusDiopters: Float = 1.5f // ~66 cm default desk distance
    @Volatile var lastMeasuredFocusDiopters: Float = 1.5f

    @Volatile var disableAndroidOversharpen: Boolean = true
    @Volatile var aeLocked: Boolean = false
    @Volatile var manualExposureEnabled: Boolean = false
    @Volatile var manualIso: Int = 160
    @Volatile var manualShutterNs: Long = 1_000_000_000L / 120L // 1/120s for 60fps
    @Volatile var evCompensationIndex: Int = 0

    @Volatile var awbLocked: Boolean = false
    @Volatile var manualWbEnabled: Boolean = false
    @Volatile var manualWbKelvin: Int = 5200

    // Telemetry readbacks
    @Volatile var currentLiveIso: Int = 160
    @Volatile var currentLiveShutterMs: Float = 8.3f
    @Volatile var currentFocusCm: Int = 65

    private var lastFaceRect: MeteringRectangle? = null

    fun start(surface: Surface) {
        outputSurface = surface
        val thread = HandlerThread("PixelProCam-Camera2Thread")
        thread.start()
        cameraThread = thread
        val handler = Handler(thread.looper)
        cameraHandler = handler
        handler.post { openMainBackCamera() }
    }

    fun stop() {
        try {
            captureSession?.close()
            captureSession = null
            cameraDevice?.close()
            cameraDevice = null
        } catch (_: Exception) {}
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    @SuppressLint("MissingPermission")
    private fun openMainBackCamera() {
        val backCameraId = findBestBackMainCameraId() ?: return
        val chars = cameraManager.getCameraCharacteristics(backCameraId)
        sensorArraySize = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: Rect(0, 0, 4000, 3000)
        minFocusDistanceDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 10.0f

        cameraManager.openCamera(backCameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCaptureSession(camera)
            }
            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                cameraDevice = null
            }
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                cameraDevice = null
            }
        }, cameraHandler)
    }

    private fun findBestBackMainCameraId(): String? {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                return id // Primary 1x 50MP Samsung GNV sensor on Pixel 10 Pro is always the main back logical ID ("0")
            }
        }
        return cameraManager.cameraIdList.firstOrNull()
    }

    private fun createCaptureSession(camera: CameraDevice) {
        val surface = outputSurface ?: return
        val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        builder.addTarget(surface)
        requestBuilder = builder

        val outConfig = OutputConfiguration(surface)
        val executor = Executors.newSingleThreadExecutor()
        val sessionConfig = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            listOf(outConfig),
            executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    applyCameraParameters()
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {}
            }
        )
        camera.createCaptureSession(sessionConfig)
    }

    fun applyCameraParameters() {
        cameraHandler?.post {
            val session = captureSession ?: return@post
            val builder = requestBuilder ?: return@post

            // 1. Lock 60 FPS hardware sensor readout
            builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(60, 60))

            // 2. Disable artificial Android oversharpening ("plastic skin" fix)
            if (disableAndroidOversharpen) {
                builder.set(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_OFF)
            } else {
                builder.set(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_FAST)
            }
            builder.set(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_FAST)

            // 3. Enable Tensor ISP hardware face detection (60 Hz, 0% CPU cost)
            builder.set(CaptureRequest.STATISTICS_FACE_DETECT_MODE, CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE)

            // 4. Autofocus Mode
            when (focusMode) {
                FocusMode.FACE_AF -> {
                    builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    lastFaceRect?.let { faceMetering ->
                        builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(faceMetering))
                    }
                }
                FocusMode.AF_LOCK -> {
                    builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                    builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, manualFocusDiopters.coerceIn(0f, minFocusDistanceDiopters))
                }
                FocusMode.MANUAL -> {
                    builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                    builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, manualFocusDiopters.coerceIn(0f, minFocusDistanceDiopters))
                }
            }

            // 5. Exposure Control (Auto / AE Lock / Full Manual ISO & Shutter)
            if (manualExposureEnabled) {
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                builder.set(CaptureRequest.SENSOR_SENSITIVITY, manualIso.coerceIn(50, 3200))
                builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, manualShutterNs.coerceIn(1_000_000L, 33_333_333L))
            } else {
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                builder.set(CaptureRequest.CONTROL_AE_LOCK, aeLocked)
                builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, evCompensationIndex.coerceIn(-6, 6))
                if (!aeLocked) {
                    lastFaceRect?.let { faceMetering ->
                        builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(faceMetering))
                    }
                }
            }

            // 6. White Balance Control (Auto / AWB Lock / Manual Kelvin)
            if (manualWbEnabled) {
                builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
                builder.set(CaptureRequest.COLOR_CORRECTION_MODE, CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
                builder.set(CaptureRequest.COLOR_CORRECTION_GAINS, kelvinToRggbGains(manualWbKelvin))
            } else {
                builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AWB_LOCK, awbLocked)
            }

            try {
                session.setRepeatingRequest(builder.build(), captureCallback, cameraHandler)
            } catch (_: Exception) {}
        }
    }

    fun lockFocusAtCurrentDistance() {
        manualFocusDiopters = lastMeasuredFocusDiopters
        focusMode = FocusMode.AF_LOCK
        applyCameraParameters()
    }

    fun setFocusDistanceCm(cm: Int) {
        val clampedCm = cm.coerceIn(12, 300)
        manualFocusDiopters = (100.0f / clampedCm.toFloat()).coerceIn(0.0f, minFocusDistanceDiopters)
        focusMode = FocusMode.MANUAL
        applyCameraParameters()
    }

    fun applyLightingPreset(presetName: String) {
        when (presetName) {
            "day" -> {
                manualWbEnabled = true
                manualWbKelvin = 5400
                manualExposureEnabled = false
                evCompensationIndex = 0
                renderer.selectBuiltInLut("sony_scinetone")
                renderer.lutIntensity = 0.75f
            }
            "evening" -> {
                manualWbEnabled = true
                manualWbKelvin = 3600
                manualExposureEnabled = false
                evCompensationIndex = 1
                renderer.selectBuiltInLut("cinema_promist")
                renderer.lutIntensity = 0.75f
            }
            "monitor" -> {
                manualWbEnabled = true
                manualWbKelvin = 4600
                manualExposureEnabled = false
                evCompensationIndex = -1
                renderer.selectBuiltInLut("sony_scinetone")
                renderer.lutIntensity = 0.80f
            }
        }
        applyCameraParameters()
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult
        ) {
            result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { diopters ->
                if (diopters > 0.05f) {
                    lastMeasuredFocusDiopters = diopters
                    currentFocusCm = (100f / diopters).roundToInt().coerceIn(10, 500)
                }
            }
            result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { currentLiveIso = it }
            result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { currentLiveShutterMs = it / 1_000_000f }

            val faces = result.get(CaptureResult.STATISTICS_FACES)
            if (!faces.isNullOrEmpty()) {
                // Pick largest face in frame
                val primaryFace = faces.maxByOrNull { it.bounds.width() * it.bounds.height() }!!
                val b = primaryFace.bounds
                val w = sensorArraySize.width().toFloat().coerceAtLeast(1f)
                val h = sensorArraySize.height().toFloat().coerceAtLeast(1f)

                val normX = (b.centerX() - sensorArraySize.left) / w
                val normY = (b.centerY() - sensorArraySize.top) / h
                val heightRatio = b.height() / h

                renderer.updateFaceTarget(normX, normY, heightRatio, true)

                val paddedRect = Rect(
                    b.left.coerceIn(sensorArraySize.left, sensorArraySize.right - 10),
                    b.top.coerceIn(sensorArraySize.top, sensorArraySize.bottom - 10),
                    b.right.coerceIn(sensorArraySize.left + 10, sensorArraySize.right),
                    b.bottom.coerceIn(sensorArraySize.top + 10, sensorArraySize.bottom)
                )
                val newMetering = MeteringRectangle(paddedRect, MeteringRectangle.METERING_WEIGHT_MAX)
                val prev = lastFaceRect
                lastFaceRect = newMetering
                // Update AF region on face movement > 4% of sensor width
                if (focusMode == FocusMode.FACE_AF && (prev == null || kotlin.math.abs(prev.rect.centerX() - paddedRect.centerX()) > w * 0.04f)) {
                    applyCameraParameters()
                }
            } else {
                renderer.updateFaceTarget(0.5f, 0.5f, 0.35f, false)
            }
        }
    }

    private fun kelvinToRggbGains(kelvin: Int): RggbChannelVector {
        val temp = (kelvin.coerceIn(2500, 8500) / 100.0)
        val r = if (temp <= 66.0) 255.0 else 329.698727446 * (temp - 60.0).pow(-0.1332047592)
        val g = if (temp <= 66.0) {
            99.4708025861 * ln(temp) - 161.1195681661
        } else {
            288.1221695283 * (temp - 60.0).pow(-0.0755148492)
        }
        val b = when {
            temp >= 66.0 -> 255.0
            temp <= 19.0 -> 0.0
            else -> 138.5177312231 * ln(temp - 10.0) - 305.0447927307
        }
        val rNorm = (r / 255.0).coerceIn(0.4, 2.5).toFloat()
        val gNorm = (g / 255.0).coerceIn(0.4, 2.5).toFloat()
        val bNorm = (b / 255.0).coerceIn(0.4, 2.5).toFloat()

        // Inverse relative to green to compensate ambient color temperature
        val rGain = (gNorm / rNorm) * 1.65f
        val bGain = (gNorm / bNorm) * 1.55f
        return RggbChannelVector(rGain.coerceIn(0.8f, 3.8f), 1.0f, 1.0f, bGain.coerceIn(0.8f, 3.8f))
    }
}

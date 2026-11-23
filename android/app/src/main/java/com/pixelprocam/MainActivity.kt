package com.pixelprocam

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.*
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {

    private lateinit var renderer: GlLutRenderer
    private lateinit var cameraController: Camera2Controller
    private lateinit var streamServer: UsbStreamServer

    private lateinit var surfaceView: SurfaceView
    private lateinit var controlsContainer: LinearLayout
    private lateinit var blackoutOverlay: FrameLayout
    private lateinit var statusLabel: TextView

    private val pickCubeLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) {
            renderer.loadCustomLutUri(uri)
            updateStatusText()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        renderer = GlLutRenderer(this)
        cameraController = Camera2Controller(this, renderer)
        streamServer = UsbStreamServer(cameraController, renderer) {
            runOnUiThread { syncUiWithState() }
        }

        buildStudioUi()

        renderer.onCameraSurfaceReady = { camSurface ->
            cameraController.start(camSurface)
            streamServer.start(1920, 1080, 25_000_000)
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            renderer.start()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 101)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 101 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            renderer.start()
        }
    }

    private fun buildStudioUi() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                renderer.setPreviewSurface(holder.surface, surfaceView.width, surfaceView.height)
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                renderer.setPreviewSurface(holder.surface, width, height)
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                renderer.setPreviewSurface(null, 0, 0)
            }
        })
        root.addView(surfaceView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))

        // Top HUD & Quick Studio Controls bar
        controlsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#990F1117"))
            setPadding(36, 24, 36, 24)
        }

        statusLabel = TextView(this).apply {
            setTextColor(Color.parseColor("#4ADE80"))
            textSize = 13f
            text = "PIXEL 10 PRO STUDIO • 60 FPS • SONY S-CINETONE • FACE AF"
        }
        controlsContainer.addView(statusLabel)

        val btnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 16, 0, 0)
        }

        fun makeBtn(title: String, onClick: () -> Unit): Button {
            return Button(this).apply {
                text = title
                textSize = 11f
                setOnClickListener {
                    onClick()
                    updateStatusText()
                }
            }
        }

        btnRow.addView(makeBtn("Face AF / Автокадр") {
            cameraController.focusMode = FocusMode.FACE_AF
            renderer.autoFramingEnabled = !renderer.autoFramingEnabled
            cameraController.applyCameraParameters()
        })
        btnRow.addView(makeBtn("AF LOCK") {
            cameraController.lockFocusAtCurrentDistance()
        })
        btnRow.addView(makeBtn("AE/AWB LOCK") {
            cameraController.aeLocked = !cameraController.aeLocked
            cameraController.awbLocked = cameraController.aeLocked
            cameraController.applyCameraParameters()
        })
        btnRow.addView(makeBtn("Sony LUT") {
            renderer.selectBuiltInLut("sony_scinetone")
        })
        btnRow.addView(makeBtn("Pro-Mist LUT") {
            renderer.selectBuiltInLut("cinema_promist")
        })
        btnRow.addView(makeBtn("Kodak 2383") {
            renderer.selectBuiltInLut("kodak_2383")
        })
        btnRow.addView(makeBtn("Свой .cube") {
            pickCubeLauncher.launch("*/*")
        })
        btnRow.addView(makeBtn("OLED Blackout") {
            setOledBlackout(true)
        })

        controlsContainer.addView(btnRow)
        root.addView(controlsContainer, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP
        ))

        // True #000000 OLED Blackout Layer (wakes on single tap)
        blackoutOverlay = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
            val dot = TextView(context).apply {
                text = "● 60 FPS STREAMING (Коснитесь экрана для пробуждения)"
                setTextColor(Color.parseColor("#33FFFFFF"))
                textSize = 12f
                gravity = Gravity.CENTER
            }
            addView(dot, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            ))
            setOnClickListener {
                setOledBlackout(false)
            }
        }
        root.addView(blackoutOverlay, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))

        setContentView(root)
    }

    private fun setOledBlackout(enabled: Boolean) {
        renderer.oledBlackout = enabled
        blackoutOverlay.visibility = if (enabled) View.VISIBLE else View.GONE
        val lp = window.attributes
        lp.screenBrightness = if (enabled) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = lp
    }

    private fun syncUiWithState() {
        blackoutOverlay.visibility = if (renderer.oledBlackout) View.VISIBLE else View.GONE
        updateStatusText()
    }

    private fun updateStatusText() {
        val af = cameraController.focusMode.name
        val frameStr = if (renderer.autoFramingEnabled) "AUTO-FRAME 4K→1080p" else "ZOOM ${"%.2f".format(renderer.manualZoom)}x"
        val lockStr = if (cameraController.aeLocked) "AE/AWB LOCKED" else "AE AUTO"
        statusLabel.text = "PIXEL 10 PRO • 60 FPS • LUT: ${renderer.activeLutName} (${(renderer.lutIntensity * 100).toInt()}%) • $af (${cameraController.currentFocusCm}cm) • $frameStr • $lockStr"
    }

    override fun onDestroy() {
        super.onDestroy()
        streamServer.stop()
        cameraController.stop()
        renderer.stop()
    }
}

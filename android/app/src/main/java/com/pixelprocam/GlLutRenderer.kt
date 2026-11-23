package com.pixelprocam

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.hypot

class GlLutRenderer(private val context: Context) : SurfaceTexture.OnFrameAvailableListener {

    private var renderThread: HandlerThread? = null
    private var renderHandler: Handler? = null

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null

    private var previewEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var encoderEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var previewWidth = 1920
    private var previewHeight = 1080
    private val encoderWidth = 1920
    private val encoderHeight = 1080

    private var oesTextureId = 0
    private var lutTextureId = 0
    var cameraSurfaceTexture: SurfaceTexture? = null
        private set
    var cameraInputSurface: Surface? = null
        private set

    private var programId = 0
    private lateinit var vertexBuffer: FloatBuffer
    private val stMatrix = FloatArray(16)

    // Shader parameters (thread-safe volatile)
    @Volatile var lutIntensity: Float = 0.78f
    @Volatile var proMistAmount: Float = 0.35f
    @Volatile var vignetteAmount: Float = 0.32f
    @Volatile var contrastBoost: Float = 0.03f
    @Volatile var saturationBoost: Float = 0.04f
    @Volatile var activeLutName: String = "sony_scinetone"
    @Volatile var oledBlackout: Boolean = false

    // Auto-framing & Zoom state (4K -> 1080p)
    @Volatile var autoFramingEnabled: Boolean = true
    @Volatile var manualZoom: Float = 1.0f

    // Smooth critically-damped spring state for Auto-Framing
    private var currentCenterX = 0.5f
    private var currentCenterY = 0.5f
    private var currentZoom = 1.15f
    private var velX = 0f
    private var velY = 0f
    private var velZoom = 0f

    @Volatile private var targetFaceX = 0.5f
    @Volatile private var targetFaceY = 0.5f
    @Volatile private var targetFaceZoom = 1.18f
    @Volatile var faceDetected = false

    var onCameraSurfaceReady: ((Surface) -> Unit)? = null

    fun start() {
        val thread = HandlerThread("PixelProCam-GLThread")
        thread.start()
        renderThread = thread
        val handler = Handler(thread.looper)
        renderHandler = handler
        handler.post {
            initEgl()
            initGlResources()
        }
    }

    fun stop() {
        renderHandler?.post {
            releaseGl()
        }
        renderThread?.quitSafely()
        renderThread = null
        renderHandler = null
    }

    fun setPreviewSurface(surface: Surface?, width: Int, height: Int) {
        renderHandler?.post {
            if (previewEglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, previewEglSurface)
                previewEglSurface = EGL14.EGL_NO_SURFACE
            }
            if (surface != null && surface.isValid) {
                previewWidth = width
                previewHeight = height
                val attribs = intArrayOf(EGL14.EGL_NONE)
                previewEglSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, attribs, 0)
            }
        }
    }

    fun setEncoderSurface(surface: Surface?) {
        renderHandler?.post {
            if (encoderEglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, encoderEglSurface)
                encoderEglSurface = EGL14.EGL_NO_SURFACE
            }
            if (surface != null && surface.isValid) {
                val attribs = intArrayOf(EGL14.EGL_NONE)
                encoderEglSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, attribs, 0)
            }
        }
    }

    fun selectBuiltInLut(name: String) {
        activeLutName = name
        renderHandler?.post {
            makeCurrent(pbufferSurface)
            val lutData = when (name) {
                "sony_scinetone" -> LutLoader.loadFromAssets(context, "luts/sony_scinetone.cube")
                "cinema_promist" -> LutLoader.loadFromAssets(context, "luts/cinema_promist.cube")
                "kodak_2383" -> LutLoader.loadFromAssets(context, "luts/kodak_2383.cube")
                else -> LutLoader.createIdentityLut(17)
            }
            lutTextureId = LutLoader.uploadToGlTexture3D(lutData, lutTextureId)
        }
    }

    fun loadCustomLutUri(uri: Uri) {
        activeLutName = "custom_cube"
        renderHandler?.post {
            try {
                makeCurrent(pbufferSurface)
                val lutData = LutLoader.loadFromUri(context, uri)
                lutTextureId = LutLoader.uploadToGlTexture3D(lutData, lutTextureId)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun updateFaceTarget(normCenterX: Float, normCenterY: Float, faceHeightRatio: Float, detected: Boolean) {
        faceDetected = detected
        if (!detected) {
            targetFaceX = 0.5f
            targetFaceY = 0.5f
            targetFaceZoom = 1.12f
            return
        }
        // Ideal framing: eyes/face centered horizontally, slightly above vertical center (rule of thirds)
        targetFaceX = normCenterX.coerceIn(0.25f, 0.75f)
        targetFaceY = (normCenterY - 0.04f).coerceIn(0.25f, 0.75f)
        // Target face height ~ 36% of frame height, zoom bounded to [1.05x .. 1.85x] so 4K->1080p stays 100% lossless!
        val desiredZoom = (0.36f / faceHeightRatio.coerceAtLeast(0.12f)).coerceIn(1.05f, 1.85f)
        targetFaceZoom = desiredZoom
    }

    override fun onFrameAvailable(surfaceTexture: SurfaceTexture?) {
        renderHandler?.post {
            renderFrame()
        }
    }

    private fun updateAutoFramePhysics(dt: Float = 1f / 60f) {
        val goalX: Float
        val goalY: Float
        val goalZ: Float

        if (autoFramingEnabled) {
            // Deadzone of 3.2% so normal talking/nodding doesn't move the camera at all
            val dist = hypot((targetFaceX - currentCenterX).toDouble(), (targetFaceY - currentCenterY).toDouble()).toFloat()
            if (dist < 0.032f && abs(targetFaceZoom - currentZoom) < 0.05f) {
                goalX = currentCenterX
                goalY = currentCenterY
                goalZ = currentZoom
            } else {
                goalX = targetFaceX
                goalY = targetFaceY
                goalZ = targetFaceZoom
            }
        } else {
            goalX = 0.5f
            goalY = 0.5f
            goalZ = manualZoom.coerceIn(1.0f, 2.0f)
        }

        // Critically damped spring (omega = 3.2 rad/s -> ultra-smooth cinema dolly motion)
        val omega = if (autoFramingEnabled) 2.8f else 8.0f
        val damping = 2.0f * omega

        val ax = (goalX - currentCenterX) * (omega * omega) - velX * damping
        val ay = (goalY - currentCenterY) * (omega * omega) - velY * damping
        val az = (goalZ - currentZoom) * (omega * omega) - velZoom * damping

        velX += ax * dt
        velY += ay * dt
        velZoom += az * dt

        currentCenterX += velX * dt
        currentCenterY += velY * dt
        currentZoom = (currentZoom + velZoom * dt).coerceIn(1.0f, 2.0f)

        // Clamp crop center so crop window never leaves [0, 1] sensor bounds
        val halfSpan = 0.5f / currentZoom
        currentCenterX = currentCenterX.coerceIn(halfSpan, 1.0f - halfSpan)
        currentCenterY = currentCenterY.coerceIn(halfSpan, 1.0f - halfSpan)
    }

    private fun renderFrame() {
        val st = cameraSurfaceTexture ?: return
        makeCurrent(pbufferSurface)
        try {
            st.updateTexImage()
            st.getTransformMatrix(stMatrix)
        } catch (e: Exception) {
            return
        }

        updateAutoFramePhysics(1f / 60f)
        val timestampNs = st.timestamp

        // 1. Render to local phone preview surface (skip when OLED Blackout is active!)
        if (!oledBlackout && previewEglSurface != EGL14.EGL_NO_SURFACE) {
            if (makeCurrent(previewEglSurface)) {
                GLES30.glViewport(0, 0, previewWidth, previewHeight)
                drawShaderQuad()
                EGL14.eglSwapBuffers(eglDisplay, previewEglSurface)
            }
        }

        // 2. Render to low-latency MediaCodec H.264/HEVC encoder surface (always 1920x1080 @ 60fps)
        if (encoderEglSurface != EGL14.EGL_NO_SURFACE) {
            if (makeCurrent(encoderEglSurface)) {
                GLES30.glViewport(0, 0, encoderWidth, encoderHeight)
                drawShaderQuad()
                EGLExt.eglPresentationTimeANDROID(eglDisplay, encoderEglSurface, timestampNs)
                EGL14.eglSwapBuffers(eglDisplay, encoderEglSurface)
            }
        }
    }

    private fun drawShaderQuad() {
        GLES30.glUseProgram(programId)

        val aPos = GLES30.glGetAttribLocation(programId, "aPosition")
        val aTex = GLES30.glGetAttribLocation(programId, "aTexCoord")

        vertexBuffer.position(0)
        GLES30.glEnableVertexAttribArray(aPos)
        GLES30.glVertexAttribPointer(aPos, 2, GLES30.GL_FLOAT, false, 16, vertexBuffer)

        vertexBuffer.position(2)
        GLES30.glEnableVertexAttribArray(aTex)
        GLES30.glVertexAttribPointer(aTex, 2, GLES30.GL_FLOAT, false, 16, vertexBuffer)

        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(programId, "uSTMatrix"), 1, false, stMatrix, 0)
        GLES30.glUniform3f(
            GLES30.glGetUniformLocation(programId, "uCropTransform"),
            currentCenterX,
            currentCenterY,
            currentZoom
        )
        GLES30.glUniform1f(GLES30.glGetUniformLocation(programId, "uLutIntensity"), lutIntensity)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(programId, "uProMist"), proMistAmount)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(programId, "uVignette"), vignetteAmount)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(programId, "uContrast"), contrastBoost)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(programId, "uSaturation"), saturationBoost)

        // Bind Camera OES texture to Unit 0
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programId, "uCameraTex"), 0)

        // Bind 3D LUT texture to Unit 1
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTextureId)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programId, "uLutTex"), 1)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(aPos)
        GLES30.glDisableVertexAttribArray(aTex)
    }

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGLExt.EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
        eglConfig = configs[0]

        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)

        val pbufAttribs = intArrayOf(EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE)
        pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufAttribs, 0)
        makeCurrent(pbufferSurface)
    }

    private fun initGlResources() {
        val quadCoords = floatArrayOf(
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f
        )
        vertexBuffer = ByteBuffer.allocateDirect(quadCoords.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(quadCoords)
                position(0)
            }

        programId = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)

        val texIds = IntArray(1)
        GLES30.glGenTextures(1, texIds, 0)
        oesTextureId = texIds[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        // Load default Sony S-Cinetone 3D LUT
        val initialLut = try {
            LutLoader.loadFromAssets(context, "luts/sony_scinetone.cube")
        } catch (e: Exception) {
            LutLoader.createIdentityLut(17)
        }
        lutTextureId = LutLoader.uploadToGlTexture3D(initialLut, 0)

        val st = SurfaceTexture(oesTextureId)
        st.setDefaultBufferSize(3840, 2160)
        st.setOnFrameAvailableListener(this, renderHandler)
        cameraSurfaceTexture = st
        val surface = Surface(st)
        cameraInputSurface = surface
        onCameraSurfaceReady?.invoke(surface)
    }

    private fun makeCurrent(surface: EGLSurface): Boolean {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || surface == EGL14.EGL_NO_SURFACE) return false
        return EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)
    }

    private fun buildProgram(vsSource: String, fsSource: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vsSource)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fsSource)
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        return prog
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)
        return shader
    }

    private fun releaseGl() {
        cameraInputSurface?.release()
        cameraSurfaceTexture?.release()
        if (previewEglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, previewEglSurface)
        if (encoderEglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, encoderEglSurface)
        if (pbufferSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) EGL14.eglTerminate(eglDisplay)
    }

    companion object {
        private const val VERTEX_SHADER = """#version 300 es
            in vec4 aPosition;
            in vec2 aTexCoord;
            uniform mat4 uSTMatrix;
            uniform vec3 uCropTransform; // (centerX, centerY, zoom)
            out vec2 vCameraUV;
            out vec2 vScreenUV;

            void main() {
                gl_Position = aPosition;
                vScreenUV = aTexCoord;
                // Apply smooth 4K -> 1080p Auto-Framing crop around (centerX, centerY) with zoom
                vec2 centered = (aTexCoord - vec2(0.5)) / max(uCropTransform.z, 1.0);
                vec2 croppedUV = clamp(uCropTransform.xy + centered, 0.0, 1.0);
                vCameraUV = (uSTMatrix * vec4(croppedUV, 0.0, 1.0)).xy;
            }
        """

        private const val FRAGMENT_SHADER = """#version 300 es
            #extension GL_OES_EGL_image_external_essl3 : require
            precision highp float;
            precision highp sampler3D;

            in vec2 vCameraUV;
            in vec2 vScreenUV;
            uniform samplerExternalOES uCameraTex;
            uniform sampler3D uLutTex;

            uniform float uLutIntensity;
            uniform float uProMist;
            uniform float uVignette;
            uniform float uContrast;
            uniform float uSaturation;

            out vec4 fragColor;

            void main() {
                vec3 rgb = texture(uCameraTex, vCameraUV).rgb;

                // 1. Black Pro-Mist 1/8 Optical Filter: Soft Skin Micro-Contrast + Highlight Halation
                if (uProMist > 0.01) {
                    vec2 texel = vec2(1.0 / 1920.0, 1.0 / 1080.0) * 1.6;
                    vec3 b1 = texture(uCameraTex, vCameraUV + vec2( texel.x,  texel.y)).rgb;
                    vec3 b2 = texture(uCameraTex, vCameraUV + vec2(-texel.x,  texel.y)).rgb;
                    vec3 b3 = texture(uCameraTex, vCameraUV + vec2( texel.x, -texel.y)).rgb;
                    vec3 b4 = texture(uCameraTex, vCameraUV + vec2(-texel.x, -texel.y)).rgb;
                    vec3 blur = (b1 + b2 + b3 + b4) * 0.25;

                    // Detect skin tone region (R > G > B) to gently smooth harsh digital pore sharpness while keeping eyes sharp
                    float skinMask = clamp((rgb.r - rgb.g) * 2.5, 0.0, 1.0) * clamp((rgb.g - rgb.b) * 2.0, 0.0, 1.0);
                    float detailDiff = length(rgb - blur);
                    // Edge-preserving skin smoothing (bilateral weight)
                    float edgeGuard = 1.0 - smoothstep(0.04, 0.14, detailDiff);
                    rgb = mix(rgb, blur, skinMask * edgeGuard * uProMist * 0.45);

                    // Warm highlight halation bloom (Pro-Mist glow around bright highlights)
                    float blurLuma = dot(blur, vec3(0.2126, 0.7152, 0.0722));
                    float bloomMask = smoothstep(0.70, 0.98, blurLuma);
                    vec3 warmBloom = blur * vec3(1.04, 0.99, 0.94);
                    rgb = mix(rgb, max(rgb, warmBloom), bloomMask * uProMist * 0.35);
                }

                // 2. Hardware Trilinear 3D LUT Color Grading
                if (uLutIntensity > 0.005) {
                    // Offset by half-texel inside 33^3 3D texture to prevent border clamping artifacts
                    vec3 lutCoord = clamp(rgb, 0.0, 1.0) * (32.0 / 33.0) + (0.5 / 33.0);
                    vec3 graded = texture(uLutTex, lutCoord).rgb;
                    rgb = mix(rgb, graded, clamp(uLutIntensity, 0.0, 1.0));
                }

                // 3. Fine Contrast & Saturation polish
                float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
                rgb = mix(vec3(luma), rgb, 1.0 + uSaturation);
                rgb = clamp((rgb - 0.45) * (1.0 + uContrast) + 0.45, 0.0, 1.0);

                // 4. Optical 35mm f/1.4 Full-Frame Lens Vignette
                if (uVignette > 0.01) {
                    vec2 d = (vScreenUV - vec2(0.5)) * vec2(1.76, 1.92);
                    float r = length(d);
                    float vig = smoothstep(0.58, 1.35, r);
                    float falloff = 1.0 - (vig * vig * uVignette * 0.45);
                    rgb *= falloff;
                }

                fragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
            }
        """
    }
}

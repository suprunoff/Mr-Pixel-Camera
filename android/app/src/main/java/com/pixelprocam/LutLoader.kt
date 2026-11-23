package com.pixelprocam

import android.content.Context
import android.net.Uri
import android.opengl.GLES30
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

data class Lut3DData(
    val size: Int,
    val rgbaBuffer: ByteBuffer
)

object LutLoader {

    fun loadFromAssets(context: Context, assetPath: String): Lut3DData {
        context.assets.open(assetPath).use { stream ->
            return parseCubeStream(stream)
        }
    }

    fun loadFromUri(context: Context, uri: Uri): Lut3DData {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            return parseCubeStream(stream)
        } ?: throw IllegalArgumentException("Cannot open LUT URI: $uri")
    }

    fun createIdentityLut(size: Int = 17): Lut3DData {
        val total = size * size * size * 4
        val buf = ByteBuffer.allocateDirect(total).order(ByteOrder.nativeOrder())
        val maxF = (size - 1).toFloat()
        for (b in 0 until size) {
            for (g in 0 until size) {
                for (r in 0 until size) {
                    buf.put(((r / maxF) * 255f).roundToInt().coerceIn(0, 255).toByte())
                    buf.put(((g / maxF) * 255f).roundToInt().coerceIn(0, 255).toByte())
                    buf.put(((b / maxF) * 255f).roundToInt().coerceIn(0, 255).toByte())
                    buf.put(255.toByte())
                }
            }
        }
        buf.position(0)
        return Lut3DData(size, buf)
    }

    private fun parseCubeStream(stream: InputStream): Lut3DData {
        val reader = BufferedReader(InputStreamReader(stream))
        var size = 33
        var buf: ByteBuffer? = null
        var line: String?

        while (reader.readLine().also { line = it } != null) {
            val trimmed = line!!.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("TITLE") || trimmed.startsWith("DOMAIN")) {
                continue
            }
            if (trimmed.startsWith("LUT_3D_SIZE")) {
                val parts = trimmed.split(Regex("\\s+"))
                if (parts.size >= 2) {
                    size = parts[1].toIntOrNull() ?: 33
                    buf = ByteBuffer.allocateDirect(size * size * size * 4).order(ByteOrder.nativeOrder())
                }
                continue
            }
            val firstChar = trimmed[0]
            if (firstChar.isDigit() || firstChar == '-' || firstChar == '.') {
                if (buf == null) {
                    buf = ByteBuffer.allocateDirect(size * size * size * 4).order(ByteOrder.nativeOrder())
                }
                if (buf.remaining() >= 4) {
                    val parts = trimmed.split(Regex("\\s+"))
                    if (parts.size >= 3) {
                        val r = ((parts[0].toFloatOrNull() ?: 0f).coerceIn(0f, 1f) * 255f).roundToInt().toByte()
                        val g = ((parts[1].toFloatOrNull() ?: 0f).coerceIn(0f, 1f) * 255f).roundToInt().toByte()
                        val b = ((parts[2].toFloatOrNull() ?: 0f).coerceIn(0f, 1f) * 255f).roundToInt().toByte()
                        buf.put(r)
                        buf.put(g)
                        buf.put(b)
                        buf.put(255.toByte())
                    }
                }
            }
        }

        val finalBuf = buf ?: return createIdentityLut(17)
        finalBuf.position(0)
        return Lut3DData(size, finalBuf)
    }

    fun uploadToGlTexture3D(lut: Lut3DData, existingTexId: Int = 0): Int {
        val texIds = IntArray(1)
        if (existingTexId == 0) {
            GLES30.glGenTextures(1, texIds, 0)
        } else {
            texIds[0] = existingTexId
        }
        val texId = texIds[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, texId)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_R, GLES30.GL_CLAMP_TO_EDGE)

        lut.rgbaBuffer.position(0)
        GLES30.glTexImage3D(
            GLES30.GL_TEXTURE_3D,
            0,
            GLES30.GL_RGBA8,
            lut.size,
            lut.size,
            lut.size,
            0,
            GLES30.GL_RGBA,
            GLES30.GL_UNSIGNED_BYTE,
            lut.rgbaBuffer
        )
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, 0)
        return texId
    }
}

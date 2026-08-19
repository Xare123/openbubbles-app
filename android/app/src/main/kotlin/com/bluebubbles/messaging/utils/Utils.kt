package com.bluebubbles.messaging.utils

import android.content.Context
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.media.AudioManager
import android.os.Build
import androidx.core.graphics.drawable.IconCompat
import com.bluebubbles.messaging.services.firebase.FirebaseAuthHandler
import com.bluebubbles.messaging.services.firebase.ServerUrlRequestHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

fun AudioManager.getStreamMinVolumeCompat(stream: Int): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        getStreamMinVolume(stream)
    } else {
        0
    }
}

object Utils {
    internal fun calculateScaledDimensions(width: Int, height: Int, targetSize: Int): Pair<Int, Int>? {
        if (width <= 0 || height <= 0 || targetSize <= 0) return null

        val scale = targetSize.toFloat() / maxOf(width, height).toFloat()
        return Pair(
            (width * scale).toInt().coerceAtLeast(1),
            (height * scale).toInt().coerceAtLeast(1),
        )
    }

    fun getAdaptiveIconFromByteArray(data: ByteArray): IconCompat? {
        if (data.isEmpty()) return null
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
        // Scale the bitmap to 108x108dp to comply with adaptive icon guidelines
        // Start by scaling the inner image to 72x72dp
        val targetSize = (72 * Resources.getSystem().displayMetrics.density).toInt().coerceAtLeast(1)
        val (width, height) = calculateScaledDimensions(bitmap.width, bitmap.height, targetSize)
            ?: return null
        val scaledBitmap = Bitmap.createScaledBitmap(bitmap, width, height, true)
        // Add transparent padding to achieve 108x108dp
        val padding = ((108 - 72) * Resources.getSystem().displayMetrics.density).toInt();
        val adaptiveBitmap = Bitmap.createBitmap(scaledBitmap.width + padding, scaledBitmap.height + padding, Bitmap.Config.ARGB_8888)
        val tempCanvas = Canvas(adaptiveBitmap)
        tempCanvas.drawBitmap(scaledBitmap, (padding / 2).toFloat(), (padding / 2).toFloat(), null)
        return IconCompat.createWithAdaptiveBitmap(adaptiveBitmap)
    }

    fun getServerUrl(context: Context, result: MethodChannel.Result) {
        FirebaseAuthHandler().handleMethodCall(MethodCall("", null), object : MethodChannel.Result {
            override fun success(temp: Any?) {
                ServerUrlRequestHandler().handleMethodCall(MethodCall("", null), result, context)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        }, context)
    }
}

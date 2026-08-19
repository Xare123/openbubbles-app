package com.bluebubbles.messaging.services.facetime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import com.bluebubbles.messaging.R

class FaceTimeInCallService: Service() {

    companion object {
        const val ACTION_REFRESH_FOREGROUND_TYPES =
            "com.bluebubbles.messaging.facetime.REFRESH_FOREGROUND_TYPES"
    }

    @RequiresApi(Build.VERSION_CODES.O)
    fun createNotificationChannel() {
        val importance = NotificationManager.IMPORTANCE_LOW
        val channel = NotificationChannel(IN_CALL_CHANNEL, "In Call", importance).apply {
            description = "Shows the state of an in-progress FaceTime call"
        }
        // Register the channel with the system
        val notificationManager: NotificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
    }

    val IN_CALL_CHANNEL = "com.bluebubbles.in_call_channel";
    @RequiresApi(Build.VERSION_CODES.O)
    fun notifyForeground() {
        createNotificationChannel()
        val notification: Notification = Notification.Builder(this, IN_CALL_CHANNEL)
            .setContentTitle("FaceTime call in progress")
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .build()

        var type = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            type = faceTimeForegroundServiceType(
                hasCameraPermission = checkSelfPermission(android.Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED,
                hasMicrophonePermission = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED,
            )
        }

        // Notification ID cannot be 0.
        startForeground(3884786, notification, type)
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifyForeground()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            intent?.action == ACTION_REFRESH_FOREGROUND_TYPES) {
            notifyForeground()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
}

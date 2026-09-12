package cn.local.bili_live_relay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// 前台保活服务：弹幕连接建立时拉起，把进程提到前台优先级，
/// 切后台 / 锁屏 / 省电策略下连接不被系统回收。
/// 服务本身不持有连接（连接在 Flutter 侧），只负责进程优先级与常驻通知。
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(
                CHANNEL_ID, "弹幕连接保活", NotificationManager.IMPORTANCE_MIN
            )
            ch.setShowBadge(false)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val room = intent?.getStringExtra("room") ?: ""
        val b = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("弹幕空间运行中")
            .setContentText(if (room.isEmpty()) "保持直播连接" else "已连接房间 $room，保持弹幕连接")
            .setOngoing(true)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIF_ID, b.build(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, b.build())
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "keepalive"
        const val NOTIF_ID = 1001
    }
}

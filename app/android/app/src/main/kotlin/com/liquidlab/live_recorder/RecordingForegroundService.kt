package com.liquidlab.live_recorder

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log

/**
 * 常驻前台服务：只要仍在录制，就保住进程不被系统回收。
 * 由 Flutter 侧通过 MethodChannel 启停。
 *
 * **为什么必须持 WakeLock（2026-11-03 修）**：
 * 前台服务只能把进程优先级提到"前台"，**并不会阻止 CPU 息屏休眠**。
 * 之前没有 WakeLock：屏幕一关、设备进入浅睡，Dart 定时器（断流退避重试、
 * 心跳写 session.json）全部停摆 —— 表现就是用户说的
 * 「后台根本不会自动重试，必须我打开 App 才重试」。打开 App 时 CPU 被唤醒，
 * 定时器补跑，于是"一进软件就恢复"。
 *
 * 现在录制期间持有 PARTIAL_WAKE_LOCK（CPU 常亮）+ WifiLock（Wi-Fi 射频不休眠），
 * 停止录制时释放；进程被杀时内核会自动释放，不会耗电泄漏。
 */
class RecordingForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "live_recorder_service"
        const val NOTIFICATION_ID = 0x4C52 // "LR"
        const val ACTION_START = "com.liquidlab.live_recorder.START"
        const val ACTION_STOP = "com.liquidlab.live_recorder.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        private const val TAG = "LiveRecorderSvc"

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, RecordingForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingForegroundService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "直播录制中"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在录制直播间"
        startForeground(NOTIFICATION_ID, buildNotification(title, text))
        acquireRecordingLocks()
        return START_NOT_STICKY
    }

    /**
     * 录制期间持锁：CPU 不休眠 + Wi-Fi 射频不省电。
     *
     * 不设超时（acquire() 无参）：服务停止 / 进程被杀时由系统释放。
     * 这是「后台自动重试」能成立的前提——没有它，息屏后 Dart 定时器根本不会跑。
     */
    @SuppressLint("WakelockTimeout")
    private fun acquireRecordingLocks() {
        if (wakeLock == null) {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "live_recorder:recording",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "partial wake lock acquired")
            } catch (e: Exception) {
                Log.w(TAG, "acquire wake lock failed: ${e.message}")
            }
        }
        if (wifiLock == null) {
            try {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "live_recorder:wifi",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "wifi lock acquired")
            } catch (e: Exception) {
                Log.w(TAG, "acquire wifi lock failed: ${e.message}")
            }
        }
    }

    private fun releaseRecordingLocks() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
                Log.i(TAG, "partial wake lock released")
            }
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            wifiLock?.let {
                if (it.isHeld) it.release()
                Log.i(TAG, "wifi lock released")
            }
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    /**
     * 用户从最近任务划掉：直接停服务、退出进程，录到哪算哪（文件每秒 flush，最多丢 1 秒）。
     *
     * FlutterEngine 现在是进程级缓存（见 MainActivity），进程不会随 Activity 自动退出，
     * 所以这里必须显式结束进程，否则"划掉即停"会退化成"划掉后继续偷偷录"。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        releaseRecordingLocks()
        stopForegroundCompat()
        stopSelf()
        super.onTaskRemoved(rootIntent)
        Handler(Looper.getMainLooper()).postDelayed({
            Process.killProcess(Process.myPid())
        }, 400L)
    }

    override fun onDestroy() {
        releaseRecordingLocks()
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "直播录制",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持直播录制在后台持续运行"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder.setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true) // 「重连中」文案频繁更新时不要反复响/弹
            .setShowWhen(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setCategory(Notification.CATEGORY_SERVICE)
        }
        if (pending != null) builder.setContentIntent(pending)
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }
}

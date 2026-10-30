package com.liquidlab.live_recorder

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 单 Activity 宿主。
 *
 * **关键：FlutterEngine 缓存在进程级，Activity 销毁时不能销毁引擎。**
 *
 * 录制、弹幕 WebView、本地预览服务全部活在 Dart isolate 里。默认的 FlutterActivity
 * 会在 `onDestroy()` 里 `flutterEngine.destroy()`；而前台服务只保住"进程和通知"，
 * 保不住 Dart isolate —— 于是切后台被系统回收 / 通知栏重新拉起创建第二个实例时，
 * 通知还在、录制却已经悄悄停了，回到 App 又是全新 `main()` → `restore()` 把任务标成中断。
 *
 * 因此这里改成：引擎由宿主提供（`provideFlutterEngine`）+ `shouldDestroyEngineWithHost() = false`，
 * Activity 重建只会重新 attach，不会重启 Dart；`android:launchMode="singleTask"` 进一步保证
 * 通知栏 / 桌面图标永远复用同一个实例（走 `onNewIntent`），不会出现第二个引擎。
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val channelName = "live_recorder/foreground"

        @Volatile
        private var sharedEngine: FlutterEngine? = null

        /** 进程内唯一的 FlutterEngine：保证只有一个 Dart isolate / 一个 RecordingManager。 */
        private fun obtainEngine(context: Context): FlutterEngine {
            sharedEngine?.let { return it }
            synchronized(MainActivity::class.java) {
                sharedEngine?.let { return it }
                val created = FlutterEngine(context.applicationContext)
                sharedEngine = created
                return created
            }
        }
    }

    /** 通过 `am start ... --es autostart <链接>` 传入的待录制链接（自动化测试/分享入口用）。 */
    private var launchUrl: String? = null
    private var probeUrl: String? = null
    private var launchWithComments: Boolean = false

    /** 本次 Activity 是否复用了已有引擎（true 表示 Dart 侧 main() 已经跑过）。 */
    private var reusedEngine: Boolean = false

    private var channel: MethodChannel? = null

    /** 本 Activity 注册的 channel（销毁时只清理自己那一份，避免误删新实例的）。 */
    private var myChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        launchUrl = intent?.getStringExtra("autostart") ?: viewUrlOf(intent)
        probeUrl = intent?.getStringExtra("probe")
        launchWithComments = intent?.getBooleanExtra("comments", false) ?: false
        super.onCreate(savedInstanceState)
        // Android 13+ 必须动态申请通知权限，否则前台服务的常驻通知不显示。
        requestNotificationPermissionIfNeeded()
    }

    /**
     * 只有"从分享面板/浏览器用 VIEW 打开直播间链接"才算待录制链接。
     * 桌面图标 / 通知栏的 launcher intent 是 ACTION_MAIN，没有 data；
     * 万一其它入口塞了 data，也不能被当成 autostart 去新建一个录制任务。
     */
    private fun viewUrlOf(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        return intent.dataString
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        reusedEngine = sharedEngine != null
        return obtainEngine(context)
    }

    /** 引擎由宿主持有：Activity 销毁（切后台被回收 / 旋转 / 新建任务）时不要销毁它。 */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission("android.permission.POST_NOTIFICATIONS") !=
                PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 1002)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val url = intent.getStringExtra("autostart") ?: viewUrlOf(intent)
        val probe = intent.getStringExtra("probe")
        val action = intent.getStringExtra("action")
        if (action != null) {
            invokeDart("incomingAction", action)
        }
        if (probe != null) {
            invokeDart("incomingProbe", probe)
        }
        if (url != null) {
            // 直接投递，不再写回 pending 字段：否则 onResume 时 Dart 侧 getLaunchUrl
            // 会把同一条链接再取一次，重复开录。
            invokeDart("incomingUrl", url)
        }
    }

    private fun invokeDart(method: String, argument: Any?) {
        val ch = channel ?: return
        try {
            ch.invokeMethod(method, argument)
        } catch (_: Exception) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        myChannel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getLaunchUrl" -> {
                        result.success(launchUrl)
                        launchUrl = null
                    }
                    "getProbeUrl" -> {
                        result.success(probeUrl)
                        probeUrl = null
                    }
                    "getLaunchComments" -> {
                        result.success(launchWithComments)
                        launchWithComments = false
                    }
                    "start", "update" -> {
                        val title = call.argument<String>("title") ?: "直播录制中"
                        val text = call.argument<String>("text") ?: "正在录制直播间"
                        RecordingForegroundService.start(applicationContext, title, text)
                        result.success(true)
                    }
                    "stop" -> {
                        RecordingForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
                    "requestStoragePermission" -> {
                        requestStoragePermission()
                        result.success(true)
                    }
                    "isStorageReady" -> {
                        result.success(isStorageReady())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("FOREGROUND_ERROR", e.message, null)
            }
        }

        // 引擎已在运行、只是 Activity 被重建（或从通知栏新建任务）时，main() 不会再跑，
        // Dart 侧也就不会再调用 getLaunchUrl —— 这里把本次 intent 里的参数补投一次。
        if (reusedEngine) {
            val url = launchUrl
            val probe = probeUrl
            val withComments = launchWithComments
            launchUrl = null
            probeUrl = null
            launchWithComments = false
            if (url != null || probe != null) {
                Handler(Looper.getMainLooper()).postDelayed({
                    if (url != null && withComments) {
                        // 先告知"带弹幕"，再投 url，Dart 侧按最新值处理。
                        ch.invokeMethod("incomingComments", withComments)
                    }
                    if (probe != null) ch.invokeMethod("incomingProbe", probe)
                    if (url != null) ch.invokeMethod("incomingUrl", url)
                }, 800L)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // configureFlutterEngine 每次 attach 都会注册新 handler，这里把旧的摘掉，
        // 避免持有已销毁的 Activity；只清理本实例注册的那一份。
        if (channel === myChannel) {
            channel?.setMethodCallHandler(null)
            channel = null
        }
        myChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** 部分机型需要用户手动允许通知，否则前台服务通知不可见。 */
    private fun openNotificationSettings() {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                }
            }
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    /**
     * 申请写公共 Movies 目录的权限：
     * - Android 11+：跳转“所有文件访问权限”设置页；
     * - Android 9/10：动态申请存储权限。
     */
    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (Environment.isExternalStorageManager()) return
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Exception) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (_: Exception) {
                }
            }
        } else {
            if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            @Suppress("DEPRECATION")
            requestPermissions(
                arrayOf(
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ),
                1001
            )
        }
    }

    private fun isStorageReady(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }
}

package com.liquidlab.live_recorder

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "live_recorder/foreground"

    /** 通过 `am start ... --es autostart <链接>` 传入的待录制链接（自动化测试/分享入口用）。 */
    private var launchUrl: String? = null
    private var probeUrl: String? = null
    private var launchWithComments: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        launchUrl = intent?.getStringExtra("autostart")
        probeUrl = intent?.getStringExtra("probe")
        launchWithComments = intent?.getBooleanExtra("comments", false) ?: false
        super.onCreate(savedInstanceState)
        // Android 13+ 必须动态申请通知权限，否则前台服务的常驻通知不显示。
        requestNotificationPermissionIfNeeded()
    }

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
        val url = intent.getStringExtra("autostart") ?: intent.dataString
        val probe = intent.getStringExtra("probe")
        val action = intent.getStringExtra("action")
        if (action != null) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, channelName).invokeMethod("incomingAction", action)
            }
        }
        if (probe != null) {
            probeUrl = probe
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, channelName).invokeMethod("incomingProbe", probe)
            }
        }
        if (url != null) {
            launchUrl = url
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, channelName).invokeMethod("incomingUrl", url)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
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
                            RecordingForegroundService.start(this, title, text)
                            result.success(true)
                        }
                        "stop" -> {
                            RecordingForegroundService.stop(this)
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

package com.liquidlab.live_recorder.player

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.ConcurrentHashMap

/**
 * Flutter 平台视图 + MethodChannel 接入。
 *
 * Dart 侧创建 `AndroidView(viewType = "live_recorder/flv_player",
 * creationParams = {playerId, ...})`，随后通过 `live_recorder/player` 调用
 * open / play / pause / seekTo / setVolume / setMuted / release。
 * 原生侧用同一个 channel 的 `state` 方法回传状态（字段对齐 player.html）。
 */
object FlvPlayerPlugin {
    const val VIEW_TYPE = "live_recorder/flv_player"
    const val CHANNEL = "live_recorder/player"

    private val attachedEngines: MutableMap<FlutterEngine, Boolean> =
        Collections.synchronizedMap(WeakHashMap<FlutterEngine, Boolean>())

    fun attach(engine: FlutterEngine) {
        if (!attachedEngines.containsKey(engine)) {
            try {
                engine.platformViewsController.registry.registerViewFactory(
                    VIEW_TYPE,
                    FlvPlayerViewFactory(engine.dartExecutor.binaryMessenger),
                )
                attachedEngines[engine] = true
                logi("platform view factory registered")
            } catch (e: Exception) {
                // 引擎复用 / Activity 重建时重复注册同一个 viewType 会抛异常，忽略即可。
                logi("platform view factory already registered? ${e.message}")
                attachedEngines[engine] = true
            }
        }

        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            handleCall(call, result)
        }
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val playerId = (args?.get("playerId") as? Number)?.toInt()
            ?: FlvPlayerRegistry.lastPlayerId
        val engine = FlvPlayerRegistry.get(playerId)
        try {
            when (call.method) {
                "open" -> {
                    if (engine == null) {
                        result.error("NO_PLAYER", "播放器视图尚未创建", null)
                        return
                    }
                    val src = args?.get("src") as? String
                    if (src.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "缺少播放地址", null)
                        return
                    }
                    val isLive = args["isLive"] == true
                    val startMs = (args["startMs"] as? Number)?.toLong() ?: 0L
                    val muted = args["muted"] as? Boolean ?: true
                    val volume = (args["volume"] as? Number)?.toFloat() ?: 1f
                    engine.open(src, isLive, startMs, muted, volume)
                    result.success(true)
                }
                "play" -> {
                    engine?.play()
                    result.success(true)
                }
                "pause" -> {
                    engine?.pause()
                    result.success(true)
                }
                "seekTo" -> {
                    val ms = (args?.get("ms") as? Number)?.toLong() ?: 0L
                    engine?.seekTo(ms)
                    result.success(true)
                }
                "setVolume" -> {
                    val volume = (args?.get("volume") as? Number)?.toFloat() ?: 1f
                    engine?.setVolume(volume)
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = args?.get("muted") as? Boolean ?: false
                    engine?.setMuted(muted)
                    result.success(true)
                }
                "release" -> {
                    engine?.release()
                    FlvPlayerRegistry.remove(playerId)
                    result.success(true)
                }
                "getState" -> {
                    result.success(engine?.snapshot() ?: emptyMap<String, Any?>())
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            logw("channel ${call.method} failed: ${e.message}")
            result.error("PLAYER_ERROR", e.message, null)
        }
    }
}

internal object FlvPlayerRegistry {
    private val engines = ConcurrentHashMap<Int, FlvPlayerEngine>()

    @Volatile
    var lastPlayerId: Int = -1
        private set

    fun register(engine: FlvPlayerEngine) {
        engines[engine.playerId] = engine
        lastPlayerId = engine.playerId
        logi("player registered id=${engine.playerId} total=${engines.size}")
    }

    fun get(playerId: Int?): FlvPlayerEngine? {
        if (playerId == null || playerId < 0) return null
        return engines[playerId]
    }

    fun remove(playerId: Int?) {
        if (playerId == null) return
        engines.remove(playerId)
    }
}

private class FlvPlayerViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        val playerId = (params?.get("playerId") as? Number)?.toInt() ?: viewId
        return FlvPlayerPlatformView(context, playerId, messenger)
    }
}

private class FlvPlayerPlatformView(
    context: Context,
    private val playerId: Int,
    messenger: BinaryMessenger,
) : PlatformView, TextureView.SurfaceTextureListener {
    private val textureView = TextureView(context)
    private val channel = MethodChannel(messenger, FlvPlayerPlugin.CHANNEL)
    private val engine: FlvPlayerEngine

    init {
        textureView.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        textureView.surfaceTextureListener = this
        engine = FlvPlayerEngine(context.applicationContext, playerId) { state ->
            try {
                channel.invokeMethod("state", state)
            } catch (_: Exception) {
            }
        }
        FlvPlayerRegistry.register(engine)
        logi("platform view created id=$playerId")
    }

    override fun getView(): View = textureView

    override fun dispose() {
        logi("platform view dispose id=$playerId")
        try {
            engine.release()
        } catch (_: Exception) {
        }
        FlvPlayerRegistry.remove(playerId)
        textureView.surfaceTextureListener = null
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        engine.setSurface(surface, width, height)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        logi("surface size changed ${width}x$height")
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        engine.clearSurface()
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
        // 不在主线程做任何事；TextureView 自己消费帧。
    }
}

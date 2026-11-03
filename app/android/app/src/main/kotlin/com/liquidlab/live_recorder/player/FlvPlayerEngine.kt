package com.liquidlab.live_recorder.player

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * 原生 FLV 播放内核（MediaCodec 硬解 + AudioTrack）。
 *
 * 线程模型：
 * - IO 线程：读 FLV（本地文件 RandomAccessFile / 直播 HTTP 增长流），把音视频 tag
 *   分别塞进两个有界队列；文件模式先建关键帧索引。
 * - 播放线程：唯一持有 MediaCodec 的线程（喂输入、取输出、按 PTS 渲染、写 AudioTrack），
 *   这样 seek 时 flush/release 不会和输出线程打架。
 *
 * 时钟：有音频时以 AudioTrack.playbackHeadPosition 为主时钟；无音频时用
 * System.nanoTime() 锚定首个视频 PTS。暂停/seek 都重置锚点。
 */
internal class FlvPlayerEngine(
    context: Context,
    val playerId: Int,
    private val stateSink: (Map<String, Any?>) -> Unit,
) {
    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    // ---- 对外状态 ----
    @Volatile private var running = false
    @Volatile private var released = false
    @Volatile private var src: String = ""
    @Volatile private var live: Boolean = false
    @Volatile private var paused: Boolean = false
    @Volatile private var muted: Boolean = true
    @Volatile private var volume: Float = 1f
    @Volatile private var phase: String = "loading"
    @Volatile private var message: String = ""
    @Volatile private var retry: Int = 0
    @Volatile private var width: Int = 0
    @Volatile private var height: Int = 0
    @Volatile private var durationMs: Long = 0L
    @Volatile private var positionMs: Long = 0L
    @Volatile private var decoderName: String = ""
    @Volatile private var videoFrames: Long = 0L
    @Volatile private var audioFrames: Long = 0L
    @Volatile private var audioStarted: Boolean = false
    @Volatile private var videoCodecId: Int = -1

    // ---- Surface ----
    @Volatile private var surfaceReady = false
    @Volatile private var surface: Surface? = null
    @Volatile private var surfaceTexture: SurfaceTexture? = null
    @Volatile private var surfaceGen: Int = 0
    private var codecSurfaceGen: Int = -1

    // ---- 数据源 ----
    @Volatile private var index: FlvIndex? = null
    @Volatile private var indexReady = false
    @Volatile private var fileEof = false
    @Volatile private var requestedSeekOffset: Long = -1L
    @Volatile private var seekRequestMs: Long = -1L
    @Volatile private var skipUntilPtsUs: Long = 0L
    @Volatile private var waitingForKeyframe = false
    @Volatile private var baseTsMs: Long = -1L
    @Volatile private var lastTagAtMs: Long = 0L
    @Volatile private var lastFrameAtMs: Long = 0L
    @Volatile private var renderedPtsUs: Long = -1L
    @Volatile private var videoFedPtsUs: Long = Long.MIN_VALUE
    @Volatile private var audioFedPtsUs: Long = Long.MIN_VALUE
    @Volatile private var audioDisabled = false

    // ---- 时钟 ----
    @Volatile private var videoAnchorNs = 0L
    @Volatile private var audioAnchorPtsUs = -1L
    @Volatile private var audioAnchorHead = 0L
    @Volatile private var sampleRate = 0
    @Volatile private var audioChannels = 0
    @Volatile private var audioPcmEncoding = AudioFormat.ENCODING_PCM_16BIT
    @Volatile private var pauseStartedNs = 0L
    @Volatile private var firstVideoSeenAtMs = 0L

    // ---- Codec ----
    private var videoCodec: MediaCodec? = null
    private var audioCodec: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var videoCsd: ByteArray? = null
    private var audioCsd: ByteArray? = null
    private var nalLengthSize = 4
    private var videoMime = "video/hevc"
    private var videoWidthHint = 0
    private var videoHeightHint = 0
    private val videoInfo = MediaCodec.BufferInfo()
    private val audioInfo = MediaCodec.BufferInfo()

    private data class PendingVideo(val index: Int, val ptsUs: Long)

    private data class PendingAudio(
        val index: Int,
        val ptsUs: Long,
        val data: ByteArray,
        var written: Int = 0,
    )

    private val videoQ = ArrayBlockingQueue<FlvTag>(96)
    private val audioQ = ArrayBlockingQueue<FlvTag>(96)
    private var pendingVideoTag: FlvTag? = null
    private var pendingAudioTag: FlvTag? = null
    private var pendingVideoOut: PendingVideo? = null
    private var pendingAudioOut: PendingAudio? = null

    private var ioThread: Thread? = null
    private var playbackThread: Thread? = null
    @Volatile private var fileReader: FileFlvReader? = null
    @Volatile private var liveReader: LiveFlvReader? = null
    private var lastPublishMs = 0L
    private var lastDebugAtMs = 0L
    private var queuedVideoFrames = 0
    private var dequeueVideoLogs = 0
    private var videoEosQueued = false
    private var videoEosSeen = false
    private var audioEosQueued = false
    private var rebuildAfterSurfaceChange = false

    // -----------------------------------------------------------------------
    // 对外 API（主线程调用）
    // -----------------------------------------------------------------------

    fun setSurface(texture: SurfaceTexture?, viewWidth: Int, viewHeight: Int) {
        if (released) return
        if (texture == null) {
            clearSurface()
            return
        }
        try {
            val safeW = if (viewWidth > 0) viewWidth else 1920
            val safeH = if (viewHeight > 0) viewHeight else 1080
            texture.setDefaultBufferSize(safeW, safeH)
            val newSurface = Surface(texture)
            val old = surface
            surface = newSurface
            surfaceTexture = texture
            surfaceReady = true
            surfaceGen += 1
            try {
                old?.release()
            } catch (_: Exception) {
            }
            logi(
                "surface available ${viewWidth}x$viewHeight gen=$surfaceGen " +
                    "valid=${newSurface.isValid} buffer=${safeW}x$safeH",
            )
        } catch (e: Exception) {
            logw("surface 创建失败：${e.message}")
        }
    }

    fun clearSurface() {
        surfaceReady = false
        surfaceGen += 1
        logi("surface destroyed gen=$surfaceGen")
    }

    @Synchronized
    fun open(source: String, isLive: Boolean, startMs: Long, muted: Boolean, volume: Float) {
        stopPipeline(keepSurface = true)
        src = source
        live = isLive
        this.muted = muted
        this.volume = volume.coerceIn(0f, 1f)
        resetPlaybackState()
        running = true
        released = false
        phase = "loading"
        message = if (isLive) "连接直播流…" else "正在建立关键帧索引…"
        logi("open playerId=$playerId live=$isLive startMs=$startMs src=$source")
        publishState()
        startThreads(startMs)
    }

    fun play() {
        if (released) return
        if (phase == "ended") {
            seekTo(0L)
        }
        if (!paused) return
        paused = false
        val now = System.nanoTime()
        if (pauseStartedNs > 0L && videoAnchorNs != 0L) {
            videoAnchorNs += now - pauseStartedNs
        }
        pauseStartedNs = 0L
        try {
            audioTrack?.play()
        } catch (_: Exception) {
        }
        if (phase == "paused") phase = "playing"
        publishState()
    }

    fun pause() {
        if (released || paused) return
        paused = true
        pauseStartedNs = System.nanoTime()
        try {
            audioTrack?.pause()
        } catch (_: Exception) {
        }
        phase = "paused"
        publishState()
        logi("pause position=${positionMs}ms")
    }

    fun seekTo(ms: Long) {
        if (released || live) return // 直播流不支持进度拖动
        seekRequestMs = ms.coerceAtLeast(0L)
        logi("seekTo ${ms}ms requested")
    }

    fun setMuted(value: Boolean) {
        muted = value
        applyVolume()
        publishState()
    }

    fun setVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        if (volume > 0f && muted) muted = false
        applyVolume()
        publishState()
    }

    fun snapshot(): Map<String, Any?> = buildStateMap()

    @Synchronized
    fun release() {
        if (released && !running) return
        released = true
        logi("release playerId=$playerId")
        stopPipeline(keepSurface = false)
        val s = surface
        surface = null
        surfaceTexture = null
        try {
            s?.release()
        } catch (_: Exception) {
        }
        surfaceReady = false
    }

    // -----------------------------------------------------------------------
    // 生命周期 / 线程
    // -----------------------------------------------------------------------

    private fun resetPlaybackState() {
        paused = false
        retry = 0
        width = 0
        height = 0
        durationMs = 0L
        positionMs = 0L
        decoderName = ""
        videoFrames = 0L
        audioFrames = 0L
        audioStarted = false
        videoCodecId = -1
        index = null
        indexReady = false
        fileEof = false
        requestedSeekOffset = -1L
        seekRequestMs = -1L
        skipUntilPtsUs = 0L
        waitingForKeyframe = false
        baseTsMs = -1L
        lastTagAtMs = SystemClock.elapsedRealtime()
        lastFrameAtMs = 0L
        renderedPtsUs = -1L
        videoFedPtsUs = Long.MIN_VALUE
        audioFedPtsUs = Long.MIN_VALUE
        audioDisabled = false
        videoAnchorNs = 0L
        audioAnchorPtsUs = -1L
        audioAnchorHead = 0L
        sampleRate = 0
        audioChannels = 0
        audioPcmEncoding = AudioFormat.ENCODING_PCM_16BIT
        pauseStartedNs = 0L
        firstVideoSeenAtMs = 0L
        videoCsd = null
        audioCsd = null
        nalLengthSize = 4
        videoWidthHint = 0
        videoHeightHint = 0
        videoQ.clear()
        audioQ.clear()
        pendingVideoTag = null
        pendingAudioTag = null
        pendingVideoOut = null
        pendingAudioOut = null
        lastPublishMs = 0L
        lastDebugAtMs = 0L
        queuedVideoFrames = 0
        dequeueVideoLogs = 0
        videoEosQueued = false
        videoEosSeen = false
        audioEosQueued = false
        rebuildAfterSurfaceChange = false
    }

    private fun startThreads(startMs: Long) {
        if (startMs > 0 && !live) seekRequestMs = startMs
        ioThread = Thread({
            if (live) liveIoLoop() else fileIoLoop()
        }, "flv-io-$playerId").apply {
            isDaemon = true
            start()
        }
        playbackThread = Thread({ playbackLoop() }, "flv-play-$playerId").apply {
            isDaemon = true
            start()
        }
    }

    @Synchronized
    private fun stopPipeline(keepSurface: Boolean) {
        running = false
        val io = ioThread
        val playback = playbackThread
        ioThread = null
        playbackThread = null
        try {
            io?.interrupt()
        } catch (_: Exception) {
        }
        try {
            playback?.interrupt()
        } catch (_: Exception) {
        }
        try {
            liveReader?.close()
        } catch (_: Exception) {
        }
        try {
            fileReader?.close()
        } catch (_: Exception) {
        }
        fileReader = null
        liveReader = null
        try {
            io?.join(1200)
        } catch (_: InterruptedException) {
        }
        try {
            playback?.join(1200)
        } catch (_: InterruptedException) {
        }
        teardownCodecs()
        videoQ.clear()
        audioQ.clear()
        pendingVideoTag = null
        pendingAudioTag = null
        pendingVideoOut = null
        pendingAudioOut = null
        if (!keepSurface) {
            surfaceReady = false
        }
    }

    private fun teardownCodecs() {
        try {
            videoCodec?.stop()
        } catch (_: Exception) {
        }
        try {
            videoCodec?.release()
        } catch (_: Exception) {
        }
        videoCodec = null
        pendingVideoOut = null
        try {
            audioCodec?.stop()
        } catch (_: Exception) {
        }
        try {
            audioCodec?.release()
        } catch (_: Exception) {
        }
        audioCodec = null
        pendingAudioOut = null
        try {
            audioTrack?.pause()
        } catch (_: Exception) {
        }
        try {
            audioTrack?.flush()
        } catch (_: Exception) {
        }
        try {
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
        audioStarted = false
        audioAnchorPtsUs = -1L
        audioAnchorHead = 0L
        sampleRate = 0
        codecSurfaceGen = -1
    }

    // -----------------------------------------------------------------------
    // IO 线程
    // -----------------------------------------------------------------------

    private fun fileIoLoop() {
        try {
            val idx = buildFlvIndex(src)
            index = idx
            if (live) return
            baseTsMs = if (idx.firstVideoTsMs >= 0) idx.firstVideoTsMs else 0L
            durationMs = idx.durationMs
            width = idx.width
            height = idx.height
            videoWidthHint = idx.width
            videoHeightHint = idx.height
            videoCsd = idx.videoCsd
            audioCsd = idx.audioCsd
            videoCodecId = idx.videoCodecId
            nalLengthSize = if (idx.videoCodecId == 12) {
                hevcNalLengthSize(idx.videoCsd)
            } else {
                avcNalLengthSize(idx.videoCsd)
            }
            indexReady = true
            logi(
                "index built: codec=${codecName(idx.videoCodecId)} frames=${idx.videoFrameCount} " +
                    "keyframes=${idx.keyframes.size} duration=${idx.durationMs}ms " +
                    "firstTs=${idx.firstVideoTsMs} size=${idx.width}x${idx.height} " +
                    "audio=${idx.audioCodecId} audioRate=${idx.audioSampleRate}",
            )
            publishState()

            val reader = FileFlvReader(src)
            fileReader = reader
            var lastLength = reader.length
            while (running) {
                val req = requestedSeekOffset
                if (req >= 0L) {
                    reader.seekTo(req)
                    requestedSeekOffset = -1L
                    fileEof = false
                    lastLength = reader.length
                    logi("file reader seek -> offset=$req")
                }
                val length = reader.refreshLength()
                if (length != lastLength) lastLength = length
                if (reader.offset >= length) {
                    fileEof = true
                    Thread.sleep(25)
                    continue
                }
                val tag = try {
                    reader.readTag()
                } catch (_: EOFException) {
                    null
                } catch (e: IOException) {
                    if (running) logw("读取文件失败：${e.message}")
                    null
                }
                if (tag == null) {
                    fileEof = true
                    Thread.sleep(25)
                    continue
                }
                fileEof = false
                enqueue(tag)
            }
        } catch (e: Exception) {
            if (running) fail("读取视频失败：${e.message ?: e.javaClass.simpleName}")
        } finally {
            try {
                fileReader?.close()
            } catch (_: Exception) {
            }
            fileReader = null
        }
    }

    private fun liveIoLoop() {
        var attempt = 0
        while (running) {
            val reader = LiveFlvReader(src)
            liveReader = reader
            try {
                phase = if (attempt == 0) "loading" else "buffering"
                message = if (attempt == 0) "连接直播流…" else "重新连接直播流…"
                publishState()
                val input = reader.open()
                logi("live stream connected: $src offset=${reader.offset}")
                attempt = 0
                retry = 0
                phase = "buffering"
                message = ""
                lastTagAtMs = SystemClock.elapsedRealtime()
                publishState()
                while (running) {
                    val tag = try {
                        reader.readTag(input)
                    } catch (_: EOFException) {
                        null
                    }
                    if (tag == null) break
                    lastTagAtMs = SystemClock.elapsedRealtime()
                    enqueue(tag)
                }
            } catch (e: Exception) {
                if (running) logw("live read error: ${e.message}")
            } finally {
                reader.close()
                liveReader = null
            }
            if (!running) break
            attempt += 1
            retry = attempt
            phase = "buffering"
            message = "直播流断开，正在重连（第 $attempt 次）"
            publishState()
            try {
                Thread.sleep(1000)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    private fun enqueue(tag: FlvTag) {
        val queue = when (tag.type) {
            FLV_TAG_VIDEO -> videoQ
            FLV_TAG_AUDIO -> audioQ
            else -> return
        }
        while (running) {
            try {
                if (queue.offer(tag, 100, TimeUnit.MILLISECONDS)) return
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    // -----------------------------------------------------------------------
    // 播放线程
    // -----------------------------------------------------------------------

    private fun playbackLoop() {
        try {
            while (running) {
                if (!live && !indexReady) {
                    Thread.sleep(15)
                    continue
                }
                if (seekRequestMs >= 0L) {
                    val target = seekRequestMs
                    seekRequestMs = -1L
                    performSeekInternal(target)
                    continue
                }
                if (paused) {
                    Thread.sleep(20)
                    continue
                }
                if (phase == "error") {
                    Thread.sleep(50)
                    continue
                }
                val worked = step()
                val now = SystemClock.elapsedRealtime()
                updatePhase(now)
                if (now - lastPublishMs >= 220L) {
                    publishState()
                    lastPublishMs = now
                }
                if (!worked) Thread.sleep(2)
            }
        } catch (_: InterruptedException) {
        } catch (e: Throwable) {
            if (running) {
                logw("playback loop crashed: ${e.message}")
                fail("播放器异常：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    private fun step(): Boolean {
        var worked = false
        if (videoCodec != null && codecSurfaceGen != surfaceGen) {
            teardownVideoCodecOnly()
            rebuildAfterSurfaceChange = true
            worked = true
        }
        // Surface 被重建 / codec 因 surface 变化被回收后，队列可能已经空了：
        // 这里主动重建一次，并从当前播放位置重新喂关键帧（否则会永久 0 帧）。
        if (videoCodec == null && surfaceReady && videoCsd != null) {
            if (ensureVideoCodec()) {
                worked = true
                if (rebuildAfterSurfaceChange) {
                    rebuildAfterSurfaceChange = false
                    if (renderedPtsUs >= 0L || positionMs > 0L) {
                        seekRequestMs = positionMs.coerceAtLeast(0L)
                        logi("codec rebuilt after surface change, re-seek to ${positionMs}ms")
                    }
                }
            }
        }
        if (drainVideoOutput()) worked = true
        if (drainAudioOutput()) worked = true
        if (feedVideoInput()) worked = true
        if (feedAudioInput()) worked = true
        val now = SystemClock.elapsedRealtime()
        if (now - lastDebugAtMs >= 2000L) {
            lastDebugAtMs = now
            logi(
                "tick phase=$phase vidQ=${videoQ.size} audQ=${audioQ.size} " +
                    "pendingTag=${pendingVideoTag != null} codec=${videoCodec != null} " +
                    "surface=$surfaceReady frames=$videoFrames audioQ2=${audioQ.size} " +
                    "fedV=${videoFedPtsUs / 1000} clock=${clockUs() / 1000} " +
                    "fileEof=$fileEof eos=$videoEosSeen rendered=${renderedPtsUs / 1000} " +
                    "dur=$durationMs pendingA=${pendingAudioOut != null} " +
                    "pendingV=${pendingVideoOut != null} audioDisabled=$audioDisabled",
            )
        }
        return worked
    }

    private fun clockUs(): Long {
        val track = audioTrack
        if (track != null && sampleRate > 0 && audioAnchorPtsUs >= 0) {
            val head = track.playbackHeadPosition.toLong() and 0xffffffffL
            val delta = head - audioAnchorHead
            if (delta >= 0) {
                return audioAnchorPtsUs + delta * 1_000_000L / sampleRate
            }
        }
        if (videoAnchorNs != 0L) {
            return (System.nanoTime() - videoAnchorNs) / 1000L
        }
        return -1L
    }

    private fun ensureVideoClock(ptsUs: Long) {
        if (videoAnchorNs == 0L && audioTrack == null) {
            videoAnchorNs = System.nanoTime() - ptsUs * 1000L
        }
    }

    private fun drainVideoOutput(): Boolean {
        val codec = videoCodec ?: return false
        if (!surfaceReady) return false
        pendingVideoOut?.let { pending ->
            val clock = clockUs()
            if (clock < 0L) {
                maybeStartFallbackClock(pending.ptsUs)
                return false
            }
            if (pending.ptsUs - clock > 4000L) return false
            releaseVideo(pending.index, pending.ptsUs)
            pendingVideoOut = null
            return true
        }
        var worked = false
        for (i in 0 until 8) {
            val outIndex = try {
                codec.dequeueOutputBuffer(videoInfo, 0)
            } catch (e: IllegalStateException) {
                logw("dequeueVideoOutput failed: ${e.message}")
                return worked
            }
            if (dequeueVideoLogs < 30) {
                dequeueVideoLogs += 1
                logi(
                    "dequeueVideo #$dequeueVideoLogs -> $outIndex " +
                        "size=${videoInfo.size} flags=${videoInfo.flags} pts=${videoInfo.presentationTimeUs / 1000}",
                )
            }
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    onVideoFormatChanged()
                    worked = true
                }
                outIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                    logi("dequeueVideo -> INFO_OUTPUT_BUFFERS_CHANGED")
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                outIndex >= 0 -> {
                    if ((videoInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        logi("dequeueVideo -> END_OF_STREAM")
                        videoEosSeen = true
                        try {
                            codec.releaseOutputBuffer(outIndex, false)
                        } catch (_: Exception) {
                        }
                        break
                    }
                    val pts = videoInfo.presentationTimeUs
                    if (firstVideoSeenAtMs == 0L) firstVideoSeenAtMs = SystemClock.elapsedRealtime()
                    if (videoAnchorNs == 0L && audioTrack == null) {
                        videoAnchorNs = System.nanoTime() - pts * 1000L
                    }
                    val clock = clockUs()
                    if (clock < 0L) {
                        pendingVideoOut = PendingVideo(outIndex, pts)
                        maybeStartFallbackClock(pts)
                        break
                    }
                    if (pts - clock > 4000L) {
                        pendingVideoOut = PendingVideo(outIndex, pts)
                        break
                    }
                    releaseVideo(outIndex, pts)
                    worked = true
                }
            }
        }
        return worked
    }

    private fun maybeStartFallbackClock(ptsUs: Long) {
        if (videoAnchorNs != 0L) return
        val first = firstVideoSeenAtMs
        if (first == 0L) return
        if (SystemClock.elapsedRealtime() - first > 1200L) {
            videoAnchorNs = System.nanoTime() - ptsUs * 1000L
            logw("audio clock 未就绪，回退到视频时钟")
        }
    }

    private fun releaseVideo(index: Int, ptsUs: Long) {
        val codec = videoCodec ?: return
        try {
            codec.releaseOutputBuffer(index, true)
        } catch (e: IllegalStateException) {
            logw("releaseOutputBuffer failed: ${e.message}")
            return
        }
        renderedPtsUs = ptsUs
        videoFrames += 1L
        lastFrameAtMs = SystemClock.elapsedRealtime()
        // ptsUs 是相对首个视频 DTS 的时间（processVideoTag 已归一化）。
        val pos = ptsUs / 1000L
        if (pos >= 0) positionMs = pos
        if (videoFrames == 1L || videoFrames % 60L == 0L) {
            logi(
                "decoded frames=$videoFrames position=${positionMs}ms " +
                    "size=${width}x$height decoder=$decoderName",
            )
        }
    }

    private fun onVideoFormatChanged() {
        val codec = videoCodec ?: return
        val format = codec.outputFormat
        val newWidth = intOr(format, MediaFormat.KEY_WIDTH, width)
        val newHeight = intOr(format, MediaFormat.KEY_HEIGHT, height)
        width = newWidth
        height = newHeight
        decoderName = try {
            codec.name
        } catch (_: Exception) {
            decoderName
        }
        logi("MediaCodec output format ${width}x$height decoder=$decoderName")
        message = ""
        publishState()
    }

    private fun drainAudioOutput(): Boolean {
        val codec = audioCodec ?: return false
        if (audioDisabled) return false
        pendingAudioOut?.let { return writePendingAudio(it) }
        var worked = false
        for (i in 0 until 4) {
            val outIndex = try {
                codec.dequeueOutputBuffer(audioInfo, 0)
            } catch (_: IllegalStateException) {
                return worked
            }
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    setupAudioTrack(codec.outputFormat)
                    worked = true
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                outIndex >= 0 -> {
                    if (audioInfo.size <= 0) {
                        try {
                            codec.releaseOutputBuffer(outIndex, false)
                        } catch (_: Exception) {
                        }
                        continue
                    }
                    val buffer = codec.getOutputBuffer(outIndex) ?: continue
                    buffer.position(audioInfo.offset)
                    buffer.limit(audioInfo.offset + audioInfo.size)
                    val data = ByteArray(audioInfo.size)
                    buffer.get(data)
                    pendingAudioOut = PendingAudio(outIndex, audioInfo.presentationTimeUs, data)
                    writePendingAudio(pendingAudioOut!!)
                    worked = true
                    break
                }
            }
        }
        return worked
    }

    private fun writePendingAudio(pending: PendingAudio): Boolean {
        val track = audioTrack
        if (track == null) {
            try {
                audioCodec?.releaseOutputBuffer(pending.index, false)
            } catch (_: Exception) {
            }
            pendingAudioOut = null
            return false
        }
        if (pending.written >= pending.data.size) {
            try {
                audioCodec?.releaseOutputBuffer(pending.index, false)
            } catch (_: Exception) {
            }
            pendingAudioOut = null
            return true
        }
        val remaining = pending.data.size - pending.written
        val written = try {
            track.write(
                ByteBuffer.wrap(pending.data, pending.written, remaining),
                remaining,
                AudioTrack.WRITE_NON_BLOCKING,
            )
        } catch (_: Exception) {
            -1
        }
        if (written < 0) {
            audioDisabled = true
            logw("AudioTrack 写入失败，关闭音频")
            return false
        }
        if (written > 0) {
            if (audioAnchorPtsUs < 0L) {
                audioAnchorPtsUs = pending.ptsUs
                audioAnchorHead = track.playbackHeadPosition.toLong() and 0xffffffffL
            }
            pending.written += written
            audioFrames += 1L
            if (audioFrames == 1L || audioFrames % 200L == 0L) {
                logi(
                    "AudioTrack frames=$audioFrames bytes=${pending.written} " +
                        "rate=$sampleRate channels=$audioChannels position=${pending.ptsUs / 1000}ms",
                )
            }
        }
        if (pending.written >= pending.data.size) {
            try {
                audioCodec?.releaseOutputBuffer(pending.index, false)
            } catch (_: Exception) {
            }
            pendingAudioOut = null
            return true
        }
        return written > 0
    }

    private fun setupAudioTrack(format: MediaFormat) {
        if (audioTrack != null) return
        val rate = intOr(format, MediaFormat.KEY_SAMPLE_RATE, 44100).coerceAtLeast(1)
        val channels = intOr(format, MediaFormat.KEY_CHANNEL_COUNT, 2).coerceIn(1, 2)
        val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else {
            AudioFormat.ENCODING_PCM_16BIT
        }
        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val bytesPerSample = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        val minBuffer = AudioTrack.getMinBufferSize(rate, channelMask, encoding)
        val bufferSize = maxOf(
            if (minBuffer > 0) minBuffer * 2 else 0,
            rate * channels * bytesPerSample / 4,
        )
        try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(encoding)
                        .setSampleRate(rate)
                        .setChannelMask(channelMask)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
                .build()
            track.setVolume(if (muted) 0f else volume)
            track.play()
            audioTrack = track
            audioStarted = true
            sampleRate = rate
            audioChannels = channels
            audioPcmEncoding = encoding
            audioAnchorPtsUs = -1L
            audioAnchorHead = 0L
            logi("AudioTrack started rate=$rate channels=$channels encoding=$encoding buffer=$bufferSize")
            publishState()
        } catch (e: Exception) {
            audioDisabled = true
            logw("AudioTrack 创建失败：${e.message}")
        }
    }

    private fun applyVolume() {
        try {
            audioTrack?.setVolume(if (muted) 0f else volume)
        } catch (_: Exception) {
        }
    }

    // -----------------------------------------------------------------------
    // 输入喂数据
    // -----------------------------------------------------------------------

    private fun feedVideoInput(): Boolean {
        var fed = 0
        while (fed < 10) {
            val tag = pendingVideoTag ?: videoQ.poll() ?: break
            if (!processVideoTag(tag)) {
                pendingVideoTag = tag
                break
            }
            pendingVideoTag = null
            fed += 1
        }
        if (!live && fileEof && videoQ.isEmpty() && pendingVideoTag == null &&
            !videoEosQueued && videoCodec != null
        ) {
            val codec = videoCodec!!
            val index = try {
                codec.dequeueInputBuffer(0)
            } catch (_: Exception) {
                -1
            }
            if (index >= 0) {
                try {
                    codec.queueInputBuffer(
                        index,
                        0,
                        0,
                        maxOf(videoFedPtsUs, 0L),
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                    videoEosQueued = true
                    logi("video EOS queued at ${videoFedPtsUs / 1000}ms")
                } catch (_: Exception) {
                }
            }
        }
        return fed > 0
    }

    private fun feedAudioInput(): Boolean {
        if (audioDisabled) return false
        var fed = 0
        while (fed < 24) {
            val tag = pendingAudioTag ?: audioQ.poll() ?: break
            if (!processAudioTag(tag)) {
                pendingAudioTag = tag
                break
            }
            pendingAudioTag = null
            fed += 1
        }
        if (!live && fileEof && audioQ.isEmpty() && pendingAudioTag == null &&
            !audioEosQueued && audioCodec != null
        ) {
            val codec = audioCodec!!
            val index = try {
                codec.dequeueInputBuffer(0)
            } catch (_: Exception) {
                -1
            }
            if (index >= 0) {
                try {
                    codec.queueInputBuffer(
                        index,
                        0,
                        0,
                        maxOf(audioFedPtsUs, 0L),
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                    audioEosQueued = true
                    logi("audio EOS queued at ${audioFedPtsUs / 1000}ms")
                } catch (_: Exception) {
                }
            }
        }
        return fed > 0
    }

    private fun processVideoTag(tag: FlvTag): Boolean {
        val payload = tag.payload
        if (payload.size < 5) return true
        val b0 = payload[0].toInt() and 0xff
        val frameType = b0 ushr 4
        val codecId = b0 and 0x0f
        if (codecId != 7 && codecId != 12) {
            fail("不支持的视频编码（codecId=$codecId）")
            return true
        }
        videoCodecId = codecId
        videoMime = if (codecId == 12) "video/hevc" else "video/avc"
        val packetType = payload[1].toInt() and 0xff
        if (packetType == 0) {
            val csd = payload.copyOfRange(5, payload.size)
            if (csd.isNotEmpty() && (videoCsd == null || !videoCsd!!.contentEquals(csd))) {
                videoCsd = csd
                nalLengthSize = if (codecId == 12) hevcNalLengthSize(csd) else avcNalLengthSize(csd)
                logi(
                    "video config codec=${codecName(codecId)} csd=${csd.size}B " +
                        "nalLengthSize=$nalLengthSize",
                )
            }
            if (baseTsMs < 0L) baseTsMs = tag.timestampMs
            if (videoWidthHint <= 0 && codecId == 12) {
                HevcSpsParser.parseWidthHeight(csd)?.let { (w, h) ->
                    videoWidthHint = w
                    videoHeightHint = h
                    width = w
                    height = h
                    logi("SPS parsed size=${w}x$h")
                }
            }
            ensureVideoCodec()
            return true
        }
        if (packetType != 1) return true
        if (videoCsd == null) {
            videoCsd = index?.videoCsd
            if (videoCsd == null) return true
        }
        if (videoCodec == null) {
            if (!ensureVideoCodec()) return false
        }
        val codec = videoCodec ?: return false
        if (baseTsMs < 0L) baseTsMs = tag.timestampMs
        val cts = signed24(payload, 2)
        val ptsUs = ((tag.timestampMs + cts) - baseTsMs) * 1000L
        if (ptsUs < skipUntilPtsUs - 1000L) return true
        if (waitingForKeyframe) {
            if (frameType != 1) return true
            waitingForKeyframe = false
            logi("keyframe reached pts=${ptsUs / 1000}ms")
        }
        val annex = naluToAnnexB(payload, 5, payload.size, nalLengthSize)
        if (annex.isEmpty()) return true
        val inputIndex = try {
            codec.dequeueInputBuffer(0L)
        } catch (_: IllegalStateException) {
            return false
        }
        if (inputIndex < 0) return false
        val inputBuffer = try {
            codec.getInputBuffer(inputIndex)
        } catch (_: Exception) {
            null
        }
        if (inputBuffer == null) {
            return false
        }
        inputBuffer.clear()
        inputBuffer.put(annex)
        val flags = if (frameType == 1) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        try {
            codec.queueInputBuffer(
                inputIndex,
                0,
                annex.size,
                ptsUs.coerceAtLeast(0L),
                flags,
            )
        } catch (e: IllegalStateException) {
            logw("queueVideoInput failed: ${e.message}")
            return false
        }
        videoFedPtsUs = ptsUs
        if (queuedVideoFrames < 5) {
            val head = annex.take(12).joinToString(" ") { "%02x".format(it) }
            logi(
                "queued video frame #$queuedVideoFrames pts=${ptsUs / 1000}ms " +
                    "annexB=${annex.size}B key=${frameType == 1} " +
                    "nalLengthSize=$nalLengthSize head=$head",
            )
        }
        queuedVideoFrames += 1
        return true
    }

    private fun processAudioTag(tag: FlvTag): Boolean {
        if (audioDisabled) return true
        val payload = tag.payload
        if (payload.size < 2) return true
        val soundFormat = (payload[0].toInt() and 0xff) ushr 4
        if (soundFormat != 10) return true
        val packetType = payload[1].toInt() and 0xff
        if (packetType == 0) {
            val csd = payload.copyOfRange(2, payload.size)
            if (csd.size >= 2) {
                audioCsd = csd
                if (baseTsMs < 0L) baseTsMs = tag.timestampMs
                logi("audio config AAC csd=${csd.size}B")
                ensureAudioCodec()
            }
            return true
        }
        if (packetType != 1) return true
        if (audioCsd == null) {
            audioCsd = index?.audioCsd
            if (audioCsd == null) return true
        }
        if (audioCodec == null && !ensureAudioCodec()) return true
        val codec = audioCodec ?: return true
        if (baseTsMs < 0L) baseTsMs = tag.timestampMs
        val ptsUs = (tag.timestampMs - baseTsMs) * 1000L
        if (ptsUs < skipUntilPtsUs - 1000L) return true
        val inputIndex = try {
            codec.dequeueInputBuffer(0L)
        } catch (_: IllegalStateException) {
            return false
        }
        if (inputIndex < 0) return false
        val inputBuffer = try {
            codec.getInputBuffer(inputIndex)
        } catch (_: Exception) {
            null
        }
        if (inputBuffer == null) return false
        inputBuffer.clear()
        inputBuffer.put(payload, 2, payload.size - 2)
        try {
            codec.queueInputBuffer(
                inputIndex,
                0,
                payload.size - 2,
                ptsUs.coerceAtLeast(0L),
                0,
            )
        } catch (e: IllegalStateException) {
            logw("queueAudioInput failed: ${e.message}")
            return false
        }
        audioFedPtsUs = ptsUs
        return true
    }

    private fun ensureVideoCodec(): Boolean {
        if (videoCodec != null) return true
        if (!surfaceReady || surface == null) return false
        val csd = videoCsd ?: index?.videoCsd ?: return false
        if (videoCodecId < 0) videoCodecId = index?.videoCodecId ?: (if (csd.size > 5 && csd[0].toInt() == 1) 12 else 7)
        val mime = if (videoCodecId == 12) "video/hevc" else "video/avc"
        videoMime = mime
        if (!hasDecoder(mime)) {
            if (videoCodecId == 12) {
                fail("当前设备不支持 H.265 硬解，无法播放该视频")
            } else {
                fail("当前设备不支持 H.264 硬解，无法播放该视频")
            }
            return false
        }
        val hintW = if (videoWidthHint > 0) videoWidthHint else if (width > 0) width else 1280
        val hintH = if (videoHeightHint > 0) videoHeightHint else if (height > 0) height else 720
        return try {
            // TextureView 的 SurfaceTexture 默认缓冲尺寸可能只有 1x1（或 view 尺寸），
            // 部分软解（OMX.google.hevc.decoder）在尺寸不匹配时会「吃输入但零输出」。
            // 用 SPS 解析出的真实分辨率重建一次 Surface。
            val texture = surfaceTexture
            if (texture != null) {
                texture.setDefaultBufferSize(hintW, hintH)
                val old = surface
                surface = Surface(texture)
                surfaceReady = true
                surfaceGen += 1
                try {
                    old?.release()
                } catch (_: Exception) {
                }
                logi("surface recreated for decoder buffer=${hintW}x$hintH gen=$surfaceGen valid=${surface?.isValid}")
            }
            val format = MediaFormat.createVideoFormat(mime, hintW, hintH)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
            if (videoCodecId == 12) {
                format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024)
            }
            val codec = MediaCodec.createDecoderByType(mime)
            val profiles = try {
                codec.codecInfo.getCapabilitiesForType(mime).profileLevels
                    .joinToString(",") { "${it.profile}/${it.level}" }
            } catch (_: Exception) {
                "unknown"
            }
            logi("decoder capabilities decoder=${codec.name} profiles=$profiles")
            codec.configure(format, surface, null, 0)
            codec.start()
            videoCodec = codec
            codecSurfaceGen = surfaceGen
            decoderName = codec.name
            logi(
                "video decoder started decoder=${codec.name} mime=$mime " +
                    "hint=${hintW}x$hintH csd=${csd.size} nalLengthSize=$nalLengthSize",
            )
            phase = if (paused) "paused" else "buffering"
            message = ""
            publishState()
            true
        } catch (e: Exception) {
            logw("video decoder init failed: ${e.message}")
            if (videoCodecId == 12) {
                fail("当前设备不支持 H.265 硬解，无法播放该视频（${e.message}）")
            } else {
                fail("视频解码器初始化失败：${e.message}")
            }
            false
        }
    }

    private fun ensureAudioCodec(): Boolean {
        if (audioCodec != null) return true
        if (audioDisabled) return false
        val csd = audioCsd ?: index?.audioCsd ?: return false
        return try {
            val asc = parseAudioSpecificConfig(csd)
            val rate = asc?.first ?: 44100
            val channels = asc?.second ?: 2
            val format = MediaFormat.createAudioFormat("audio/mp4a-latm", rate, channels)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
            val codec = MediaCodec.createDecoderByType("audio/mp4a-latm")
            codec.configure(format, null, null, 0)
            codec.start()
            audioCodec = codec
            logi("audio decoder started decoder=${codec.name} rate=$rate channels=$channels")
            true
        } catch (e: Exception) {
            audioDisabled = true
            logw("audio decoder init failed: ${e.message}")
            false
        }
    }

    // -----------------------------------------------------------------------
    // seek / 状态 / 收尾
    // -----------------------------------------------------------------------

    private fun performSeekInternal(ms: Long) {
        val idx = index
        if (idx == null) return
        val duration = idx.durationMs
        val target = if (duration > 0) ms.coerceIn(0L, duration) else ms.coerceAtLeast(0L)
        val absTs = idx.firstVideoTsMs + target
        val keyframe = idx.keyframeBefore(absTs)
        teardownCodecs()
        videoQ.clear()
        audioQ.clear()
        pendingVideoTag = null
        pendingAudioTag = null
        pendingVideoOut = null
        pendingAudioOut = null
        videoEosQueued = false
        videoEosSeen = false
        audioEosQueued = false
        rebuildAfterSurfaceChange = false
        dequeueVideoLogs = 0
        queuedVideoFrames = 0
        if (keyframe != null) {
            requestedSeekOffset = keyframe.offset
            skipUntilPtsUs = ((keyframe.timestampMs - idx.firstVideoTsMs) * 1000L).coerceAtLeast(0L)
        } else {
            requestedSeekOffset = 0L
            skipUntilPtsUs = 0L
        }
        waitingForKeyframe = true
        audioAnchorPtsUs = -1L
        audioAnchorHead = 0L
        sampleRate = 0
        videoAnchorNs = 0L
        renderedPtsUs = -1L
        videoFrames = 0L
        audioFrames = 0L
        audioStarted = false
        lastFrameAtMs = 0L
        firstVideoSeenAtMs = 0L
        fileEof = false
        positionMs = target
        phase = if (paused) "paused" else "buffering"
        message = "正在跳转到 ${target / 1000} 秒…"
        publishState()
        logi(
            "seekTo ${target}ms -> keyframe ts=${keyframe?.timestampMs} " +
                "offset=${keyframe?.offset} skipUntil=${skipUntilPtsUs / 1000}ms",
        )
    }

    private fun updatePhase(now: Long) {
        if (phase == "error" || phase == "ended" || released) return
        if (paused) {
            if (phase != "paused") {
                phase = "paused"
                publishState()
            }
            return
        }
        val playing = lastFrameAtMs > 0L && now - lastFrameAtMs < 900L
        if (playing) {
            if (phase != "playing") {
                phase = "playing"
                message = ""
                publishState()
                logi("phase=playing position=${positionMs}ms")
            }
            return
        }
        val idx = index
        val atEnd = !live && (fileEof || videoEosSeen) &&
            videoQ.isEmpty() && audioQ.isEmpty() && idx != null &&
            renderedPtsUs >= 0L &&
            (renderedPtsUs / 1000L) >= idx.durationMs - 500L
        if (atEnd) {
            if (phase != "ended") {
                phase = "ended"
                message = ""
                publishState()
                logi("phase=ended position=${positionMs}ms duration=${durationMs}ms")
            }
            return
        }
        if (live && now - lastTagAtMs > 2500L) {
            if (phase != "buffering") {
                phase = "buffering"
                message = "等待直播数据…"
                publishState()
            }
            return
        }
        if (phase == "playing") {
            phase = "buffering"
            publishState()
        }
    }

    private fun fail(msg: String) {
        if (phase == "error") return
        phase = "error"
        message = msg
        logw(msg)
        publishState()
    }

    private fun buildStateMap(): Map<String, Any?> = mapOf(
        "event" to "state",
        "playerId" to playerId,
        "phase" to phase,
        "position" to positionMs / 1000.0,
        "duration" to durationMs / 1000.0,
        "width" to width,
        "height" to height,
        "muted" to muted,
        "volume" to volume.toDouble(),
        "message" to message,
        "retry" to retry,
        "decoder" to decoderName,
        "frames" to videoFrames,
        "audioFrames" to audioFrames,
        "audio" to audioStarted,
        "codec" to codecName(videoCodecId),
        "live" to live,
        "paused" to paused,
    )

    private fun publishState() {
        val snapshot = buildStateMap()
        mainHandler.post {
            try {
                stateSink(snapshot)
            } catch (_: Exception) {
            }
        }
    }

    private fun teardownVideoCodecOnly() {
        try {
            videoCodec?.stop()
        } catch (_: Exception) {
        }
        try {
            videoCodec?.release()
        } catch (_: Exception) {
        }
        videoCodec = null
        pendingVideoOut = null
        codecSurfaceGen = -1
    }

    private fun hasDecoder(mime: String): Boolean {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            list.codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
        } catch (_: Exception) {
            true
        }
    }

    private fun codecName(codecId: Int): String = when (codecId) {
        7 -> "avc"
        12 -> "hevc"
        else -> "unknown"
    }

    /** MediaFormat.getInteger(key, default) 是 API 29+，minSdk 24 必须自己兜底。 */
    private fun intOr(format: MediaFormat, key: String, fallback: Int): Int {
        return if (format.containsKey(key)) {
            try {
                format.getInteger(key)
            } catch (_: Exception) {
                fallback
            }
        } else {
            fallback
        }
    }

    private fun hevcNalLengthSize(csd: ByteArray?): Int {
        if (csd == null || csd.size < 22) return 4
        return (csd[21].toInt() and 0x03) + 1
    }

    private fun avcNalLengthSize(csd: ByteArray?): Int {
        if (csd == null || csd.size < 5) return 4
        return (csd[4].toInt() and 0x03) + 1
    }
}

package com.liquidlab.live_recorder.player

import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * 极简 FLV 容器解析：只保留播放器需要的部分。
 *
 * 文件布局：
 *   FLV Header(9B) + PreviousTagSize0(4B) + Tag* + PreviousTagSize*
 *   Tag Header(11B) = type(1) + dataSize(3) + timestamp(3) + timestampExt(1) + streamId(3)
 *
 * 所有时间戳都来自 FLV 的毫秒时间戳；小红书流的起点可能是 82,468,566ms，
 * 因此播放器内部统一减去“首个视频 DTS”做归一化。
 */
internal const val FLV_LOG_TAG = "FlvNative"

internal const val FLV_TAG_AUDIO = 8
internal const val FLV_TAG_VIDEO = 9
internal const val FLV_TAG_SCRIPT = 18

internal class FlvTag(
    val type: Int,
    val timestampMs: Long,
    val payload: ByteArray,
    val tagOffset: Long,
    val tagEndOffset: Long,
)

internal data class Keyframe(val timestampMs: Long, val offset: Long)

internal class FlvIndex {
    val keyframes = ArrayList<Keyframe>()
    var videoCodecId: Int = -1
    var audioCodecId: Int = -1
    var videoCsd: ByteArray? = null
    var audioCsd: ByteArray? = null
    var firstVideoTsMs: Long = -1L
    var lastVideoTsMs: Long = -1L
    var videoFrameCount: Int = 0
    var audioFrameCount: Int = 0
    var tagCount: Int = 0
    var width: Int = 0
    var height: Int = 0
    var audioSampleRate: Int = 0
    var audioChannels: Int = 0
    var metaWidth: Int = 0
    var metaHeight: Int = 0
    var metaDurationMs: Long = 0L

    val durationMs: Long
        get() {
            val byVideo = if (firstVideoTsMs >= 0 && lastVideoTsMs >= firstVideoTsMs) {
                lastVideoTsMs - firstVideoTsMs
            } else {
                0L
            }
            return if (byVideo > 0) byVideo else metaDurationMs
        }

    fun keyframeBefore(timestampMs: Long): Keyframe? {
        if (keyframes.isEmpty()) return null
        var lo = 0
        var hi = keyframes.size - 1
        var best: Keyframe? = null
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val item = keyframes[mid]
            if (item.timestampMs <= timestampMs) {
                best = item
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best ?: keyframes.first()
    }
}

// ---------------------------------------------------------------------------
// FLV 读取
// ---------------------------------------------------------------------------

private fun readFully(input: InputStream, buf: ByteArray, off: Int = 0, len: Int = buf.size): Boolean {
    var read = 0
    while (read < len) {
        val n = input.read(buf, off + read, len - read)
        if (n < 0) return false
        read += n
    }
    return true
}

internal fun readFlvTag(input: InputStream, startOffset: Long): FlvTag? {
    val header = ByteArray(11)
    var read = 0
    while (read < 11) {
        val n = input.read(header, read, 11 - read)
        if (n < 0) {
            if (read == 0) return null
            throw EOFException("FLV tag 头被截断")
        }
        read += n
    }
    val type = header[0].toInt() and 0xff
    val size = ((header[1].toInt() and 0xff) shl 16) or
        ((header[2].toInt() and 0xff) shl 8) or
        (header[3].toInt() and 0xff)
    val timestamp = ((header[4].toInt() and 0xff).toLong() shl 16) or
        ((header[5].toInt() and 0xff).toLong() shl 8) or
        (header[6].toInt() and 0xff).toLong() or
        ((header[7].toInt() and 0xff).toLong() shl 24)
    if (size < 0 || size > 64 * 1024 * 1024) {
        throw IOException("FLV tag 长度异常：$size")
    }
    val payload = ByteArray(size)
    if (size > 0 && !readFully(input, payload)) return null
    val prev = ByteArray(4)
    if (!readFully(input, prev)) return null
    return FlvTag(type, timestamp, payload, startOffset, startOffset + 11 + size + 4)
}

private fun readFlvHeader(input: InputStream): Boolean {
    val header = ByteArray(9)
    if (!readFully(input, header)) throw EOFException("FLV 头不完整")
    if (header[0] != 'F'.code.toByte() ||
        header[1] != 'L'.code.toByte() ||
        header[2] != 'V'.code.toByte()
    ) {
        return false
    }
    val dataOffset = ((header[5].toInt() and 0xff) shl 24) or
        ((header[6].toInt() and 0xff) shl 16) or
        ((header[7].toInt() and 0xff) shl 8) or
        (header[8].toInt() and 0xff)
    var skip = dataOffset - 9
    if (skip < 0) throw IOException("FLV dataOffset 异常：$dataOffset")
    val scratch = ByteArray(4096)
    while (skip > 0) {
        val n = input.read(scratch, 0, minOf(skip, scratch.size))
        if (n < 0) throw EOFException("FLV 头被截断")
        skip -= n
    }
    val prev = ByteArray(4)
    if (!readFully(input, prev)) throw EOFException("FLV PreviousTagSize0 缺失")
    return true
}

internal class FileFlvReader(path: String) : Closeable {
    private val raf = RandomAccessFile(path, "r")
    var length: Long = raf.length()
        private set
    var offset: Long = 0L
        private set

    init {
        if (length < 13) throw IOException("文件太小，不是有效的 FLV")
        val header = ByteArray(9)
        raf.readFully(header)
        if (header[0] != 'F'.code.toByte() ||
            header[1] != 'L'.code.toByte() ||
            header[2] != 'V'.code.toByte()
        ) {
            throw IOException("不是有效的 FLV 文件")
        }
        val dataOffset = ((header[5].toInt() and 0xff) shl 24) or
            ((header[6].toInt() and 0xff) shl 16) or
            ((header[7].toInt() and 0xff) shl 8) or
            (header[8].toInt() and 0xff)
        if (dataOffset < 9 || dataOffset + 4 > length) throw IOException("FLV 头长度异常")
        raf.seek(dataOffset.toLong())
        val prev = ByteArray(4)
        raf.readFully(prev)
        offset = dataOffset + 4L
        raf.seek(offset)
    }

    fun refreshLength(): Long {
        length = raf.length()
        return length
    }

    fun seekTo(position: Long) {
        val safe = position.coerceIn(0L, maxOf(0L, length))
        raf.seek(safe)
        offset = safe
    }

    /** 返回 null 表示当前已到文件尾；文件仍在增长时调用方应等待后重试。 */
    fun readTag(): FlvTag? {
        if (offset >= length) return null
        val header = ByteArray(11)
        try {
            raf.readFully(header)
        } catch (_: EOFException) {
            return null
        }
        val type = header[0].toInt() and 0xff
        val size = ((header[1].toInt() and 0xff) shl 16) or
            ((header[2].toInt() and 0xff) shl 8) or
            (header[3].toInt() and 0xff)
        val timestamp = ((header[4].toInt() and 0xff).toLong() shl 16) or
            ((header[5].toInt() and 0xff).toLong() shl 8) or
            (header[6].toInt() and 0xff).toLong() or
            ((header[7].toInt() and 0xff).toLong() shl 24)
        if (size < 0 || size > 64 * 1024 * 1024) throw IOException("FLV tag 长度异常：$size")
        if (offset + 11 + size + 4 > length) return null
        val payload = ByteArray(size)
        raf.readFully(payload)
        raf.readFully(ByteArray(4))
        val start = offset
        offset += 11L + size + 4L
        return FlvTag(type, timestamp, payload, start, offset)
    }

    override fun close() {
        try {
            raf.close()
        } catch (_: Exception) {
        }
    }
}

/**
 * 直播 HTTP 源：连接本地 `/live/<taskId>.flv` 增长流。
 *
 * `offset` 用于断线续读（本地服务支持 `?offset=`），避免重连后从头再播。
 */
internal class LiveFlvReader(private val url: String) {
    private var connection: HttpURLConnection? = null
    private var stream: BufferedInputStream? = null
    var offset: Long = 0L
        private set

    fun open(): BufferedInputStream {
        val target = if (offset > 0) {
            val sep = if (url.contains('?')) '&' else '?'
            "$url${sep}offset=$offset"
        } else {
            url
        }
        val conn = (URL(target).openConnection() as HttpURLConnection).apply {
            connectTimeout = 5000
            readTimeout = 8000
            requestMethod = "GET"
            setRequestProperty("Accept", "*/*")
        }
        conn.connect()
        val code = conn.responseCode
        if (code !in 200..299) {
            conn.disconnect()
            throw IOException("直播 HTTP $code")
        }
        val input = BufferedInputStream(conn.inputStream, 128 * 1024)
        if (offset == 0L) {
            if (!readFlvHeader(input)) {
                conn.disconnect()
                throw IOException("直播流不是 FLV")
            }
        } else {
            // 服务端若不认识 offset，会从文件头重新开始；这里兼容一下。
            input.mark(3)
            val sig = ByteArray(3)
            val n = input.read(sig)
            input.reset()
            if (n == 3 && sig[0] == 'F'.code.toByte() && sig[1] == 'L'.code.toByte() &&
                sig[2] == 'V'.code.toByte()
            ) {
                if (!readFlvHeader(input)) throw IOException("直播流不是 FLV")
                offset = 0L
            }
        }
        connection = conn
        stream = input
        return input
    }

    fun readTag(input: InputStream): FlvTag? {
        val tag = readFlvTag(input, offset) ?: return null
        offset = tag.tagEndOffset
        return tag
    }

    fun close() {
        try {
            stream?.close()
        } catch (_: Exception) {
        }
        try {
            connection?.disconnect()
        } catch (_: Exception) {
        }
        stream = null
        connection = null
    }
}

// ---------------------------------------------------------------------------
// 索引扫描（RandomAccessFile 跳过 payload，1GB 文件也只需要读每个 tag 头）
// ---------------------------------------------------------------------------

internal fun buildFlvIndex(path: String): FlvIndex {
    val index = FlvIndex()
    RandomAccessFile(path, "r").use { raf ->
        val length = raf.length()
        if (length < 13) throw IOException("文件太小，不是有效的 FLV")
        val header = ByteArray(9)
        raf.readFully(header)
        if (header[0] != 'F'.code.toByte() ||
            header[1] != 'L'.code.toByte() ||
            header[2] != 'V'.code.toByte()
        ) {
            throw IOException("不是有效的 FLV 文件")
        }
        val dataOffset = ((header[5].toInt() and 0xff) shl 24) or
            ((header[6].toInt() and 0xff) shl 16) or
            ((header[7].toInt() and 0xff) shl 8) or
            (header[8].toInt() and 0xff)
        if (dataOffset < 9 || dataOffset + 4 > length) throw IOException("FLV 头长度异常")
        raf.seek(dataOffset.toLong())
        raf.readFully(ByteArray(4))

        var pos = dataOffset + 4L
        val tagHeader = ByteArray(11)
        while (pos + 11 <= length) {
            raf.seek(pos)
            try {
                raf.readFully(tagHeader)
            } catch (_: EOFException) {
                break
            }
            val type = tagHeader[0].toInt() and 0xff
            val size = ((tagHeader[1].toInt() and 0xff) shl 16) or
                ((tagHeader[2].toInt() and 0xff) shl 8) or
                (tagHeader[3].toInt() and 0xff)
            val timestamp = ((tagHeader[4].toInt() and 0xff).toLong() shl 16) or
                ((tagHeader[5].toInt() and 0xff).toLong() shl 8) or
                (tagHeader[6].toInt() and 0xff).toLong() or
                ((tagHeader[7].toInt() and 0xff).toLong() shl 24)
            if (size < 0 || pos + 11L + size + 4L > length) break

            if (type == FLV_TAG_VIDEO && size >= 5) {
                val head = ByteArray(5)
                raf.seek(pos + 11L)
                raf.readFully(head)
                val b0 = head[0].toInt() and 0xff
                val frameType = b0 ushr 4
                val codecId = b0 and 0x0f
                val packetType = head[1].toInt() and 0xff
                if (index.videoCodecId < 0) index.videoCodecId = codecId
                if (index.firstVideoTsMs < 0) index.firstVideoTsMs = timestamp
                if (timestamp > index.lastVideoTsMs) index.lastVideoTsMs = timestamp
                if (packetType == 0 && index.videoCsd == null) {
                    val payload = ByteArray(size)
                    raf.seek(pos + 11L)
                    raf.readFully(payload)
                    index.videoCsd = payload.copyOfRange(5, payload.size)
                } else if (packetType == 1) {
                    index.videoFrameCount += 1
                    if (frameType == 1) index.keyframes.add(Keyframe(timestamp, pos))
                }
            } else if (type == FLV_TAG_AUDIO && size >= 2) {
                val head = ByteArray(2)
                raf.seek(pos + 11L)
                raf.readFully(head)
                val soundFormat = (head[0].toInt() and 0xff) ushr 4
                val packetType = head[1].toInt() and 0xff
                if (index.audioCodecId < 0) index.audioCodecId = soundFormat
                if (soundFormat == 10) {
                    if (packetType == 0 && index.audioCsd == null) {
                        val payload = ByteArray(size)
                        raf.seek(pos + 11L)
                        raf.readFully(payload)
                        index.audioCsd = payload.copyOfRange(2, payload.size)
                        val asc = parseAudioSpecificConfig(index.audioCsd!!)
                        if (asc != null) {
                            index.audioSampleRate = asc.first
                            index.audioChannels = asc.second
                        }
                    } else if (packetType == 1) {
                        index.audioFrameCount += 1
                    }
                }
            } else if (type == FLV_TAG_SCRIPT && size in 1 until 256 * 1024 && index.metaWidth == 0) {
                val payload = ByteArray(size)
                raf.seek(pos + 11L)
                raf.readFully(payload)
                val meta = parseAmfMetadata(payload)
                if (meta.isNotEmpty()) {
                    val w = meta["width"]
                    val h = meta["height"]
                    val d = meta["duration"]
                    if (w != null && w > 0) index.metaWidth = w.toInt()
                    if (h != null && h > 0) index.metaHeight = h.toInt()
                    if (d != null && d > 0) index.metaDurationMs = (d * 1000).toLong()
                }
            }
            index.tagCount += 1
            pos += 11L + size + 4L
        }

        if (index.videoCodecId == 12) {
            index.videoCsd?.let { csd ->
                HevcSpsParser.parseWidthHeight(csd)?.let { (w, h) ->
                    index.width = w
                    index.height = h
                }
            }
        }
        if (index.width <= 0) index.width = index.metaWidth
        if (index.height <= 0) index.height = index.metaHeight
    }
    return index
}

// ---------------------------------------------------------------------------
// AAC AudioSpecificConfig
// ---------------------------------------------------------------------------

private val AAC_SAMPLE_RATES = intArrayOf(
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0, 0,
)

internal fun parseAudioSpecificConfig(csd: ByteArray): Pair<Int, Int>? {
    if (csd.size < 2) return null
    val b0 = csd[0].toInt() and 0xff
    val b1 = csd[1].toInt() and 0xff
    val audioObjectType = b0 ushr 3
    val sampleRateIndex = ((b0 and 0x07) shl 1) or (b1 ushr 7)
    var channelConfig = (b1 ushr 3) and 0x0f
    var rate = if (sampleRateIndex in AAC_SAMPLE_RATES.indices) AAC_SAMPLE_RATES[sampleRateIndex] else 0
    var posBits = 13
    if (audioObjectType == 5 || audioObjectType == 29) {
        // SBR/PS：后面还有 extensionSamplingFrequencyIndex
        if (csd.size * 8 >= 16 + 4) {
            val extIndex = ((csd[1].toInt() and 0x07) shl 1) or (csd[2].toInt() ushr 7)
            if (extIndex in AAC_SAMPLE_RATES.indices && AAC_SAMPLE_RATES[extIndex] > 0) {
                rate = AAC_SAMPLE_RATES[extIndex]
            }
            posBits += 4
        }
    }
    if (channelConfig == 0) channelConfig = 2
    if (rate <= 0) rate = 44100
    return rate to channelConfig
}

// ---------------------------------------------------------------------------
// AMF0 metadata（仅取 width/height/duration）
// ---------------------------------------------------------------------------

private class AmfReader(private val data: ByteArray) {
    var pos: Int = 0
        private set

    fun readByte(): Int {
        if (pos >= data.size) throw EOFException()
        return data[pos++].toInt() and 0xff
    }

    fun readShort(): Int = (readByte() shl 8) or readByte()

    fun readInt(): Int = (readByte() shl 24) or (readByte() shl 16) or (readByte() shl 8) or readByte()

    fun readDouble(): Double {
        var bits = 0L
        for (i in 0 until 8) bits = (bits shl 8) or readByte().toLong()
        return java.lang.Double.longBitsToDouble(bits)
    }

    fun readString(length: Int): String {
        if (length < 0 || pos + length > data.size) throw EOFException()
        val text = String(data, pos, length, Charsets.UTF_8)
        pos += length
        return text
    }
}

internal fun parseAmfMetadata(payload: ByteArray): Map<String, Double> {
    val out = HashMap<String, Double>()
    try {
        val reader = AmfReader(payload)
        if (reader.readByte() != 0x02) return out
        reader.readString(reader.readShort())
        var marker = reader.readByte()
        if (marker == 0x08) {
            reader.readInt() // count
        } else if (marker == 0x03) {
            // object
        } else {
            return out
        }
        while (reader.pos + 2 <= payload.size) {
            val keyLength = reader.readShort()
            if (keyLength == 0) {
                if (reader.pos < payload.size) reader.readByte()
                break
            }
            val key = reader.readString(keyLength)
            val value = readAmfValue(reader)
            if (value is Double) out[key] = value
        }
    } catch (_: Exception) {
        // metadata 损坏不影响播放
    }
    return out
}

private fun readAmfValue(reader: AmfReader): Any? {
    return when (val marker = reader.readByte()) {
        0x00 -> reader.readDouble()
        0x01 -> reader.readByte() != 0
        0x02 -> reader.readString(reader.readShort())
        0x03, 0x08 -> {
            if (marker == 0x08) reader.readInt()
            while (true) {
                val keyLength = reader.readShort()
                if (keyLength == 0) {
                    if (reader.pos < Int.MAX_VALUE) {
                        // object end marker 0x09
                        try {
                            reader.readByte()
                        } catch (_: Exception) {
                        }
                    }
                    break
                }
                reader.readString(keyLength)
                readAmfValue(reader)
            }
            null
        }
        0x05, 0x06 -> null
        0x0A -> {
            val count = reader.readInt()
            for (i in 0 until count) readAmfValue(reader)
            null
        }
        0x0B -> {
            reader.readDouble()
            reader.readShort()
            null
        }
        else -> null
    }
}

// ---------------------------------------------------------------------------
// HEVC hvcC + SPS 宽高解析
// ---------------------------------------------------------------------------

internal class BitReader(private val data: ByteArray) {
    private var bitPos: Int = 0

    private fun readBit(): Int {
        val byteIndex = bitPos ushr 3
        if (byteIndex >= data.size) throw EOFException()
        val bit = (data[byteIndex].toInt() ushr (7 - (bitPos and 7))) and 1
        bitPos += 1
        return bit
    }

    fun readBits(count: Int): Int {
        var value = 0
        for (i in 0 until count) value = (value shl 1) or readBit()
        return value
    }

    fun readUe(): Int {
        var zeros = 0
        while (readBit() == 0) {
            zeros += 1
            if (zeros > 31) throw IOException("exp-golomb 溢出")
        }
        if (zeros == 0) return 0
        return (1 shl zeros) - 1 + readBits(zeros)
    }
}

internal object HevcSpsParser {
    fun parseWidthHeight(hvcCsd: ByteArray): Pair<Int, Int>? {
        val sps = extractSps(hvcCsd) ?: return null
        val rbsp = removeEmulationPrevention(sps)
        return try {
            val reader = BitReader(rbsp)
            reader.readBits(4) // sps_video_parameter_set_id
            val maxSubLayersMinus1 = reader.readBits(3)
            reader.readBits(1) // sps_temporal_id_nesting_flag
            // profile_tier_level(1, maxSubLayersMinus1)
            reader.readBits(2) // general_profile_space
            reader.readBits(1) // general_tier_flag
            reader.readBits(5) // general_profile_idc
            reader.readBits(32) // compatibility flags
            reader.readBits(48) // constraint flags
            reader.readBits(8) // general_level_idc
            for (i in 0 until maxSubLayersMinus1) {
                val profilePresent = reader.readBits(1)
                val levelPresent = reader.readBits(1)
                if (profilePresent == 1) reader.readBits(88)
                if (levelPresent == 1) reader.readBits(8)
            }
            if (maxSubLayersMinus1 > 0) {
                for (i in 0 until maxSubLayersMinus1) reader.readBits(2)
            }
            reader.readUe() // sps_seq_parameter_set_id
            val chromaFormatIdc = reader.readUe()
            if (chromaFormatIdc == 3) reader.readBits(1)
            var width = reader.readUe()
            var height = reader.readUe()
            if (reader.readBits(1) == 1) {
                val left = reader.readUe()
                val right = reader.readUe()
                val top = reader.readUe()
                val bottom = reader.readUe()
                val subWidthC = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
                val subHeightC = if (chromaFormatIdc == 1) 2 else 1
                width -= (left + right) * subWidthC
                height -= (top + bottom) * subHeightC
            }
            if (width in 1..8192 && height in 1..8192) width to height else null
        } catch (_: Exception) {
            null
        }
    }

    private fun extractSps(hvcCsd: ByteArray): ByteArray? {
        if (hvcCsd.size < 23) return null
        var pos = 22
        val numArrays = hvcCsd[pos].toInt() and 0xff
        pos += 1
        for (i in 0 until numArrays) {
            if (pos + 3 > hvcCsd.size) return null
            val nalType = hvcCsd[pos].toInt() and 0x3f
            val count = ((hvcCsd[pos + 1].toInt() and 0xff) shl 8) or
                (hvcCsd[pos + 2].toInt() and 0xff)
            pos += 3
            for (j in 0 until count) {
                if (pos + 2 > hvcCsd.size) return null
                val len = ((hvcCsd[pos].toInt() and 0xff) shl 8) or
                    (hvcCsd[pos + 1].toInt() and 0xff)
                pos += 2
                if (len <= 0 || pos + len > hvcCsd.size) return null
                if (nalType == 33) return hvcCsd.copyOfRange(pos, pos + len)
                pos += len
            }
        }
        return null
    }

    private fun removeEmulationPrevention(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(data.size)
        var zeros = 0
        for (byte in data) {
            val value = byte.toInt() and 0xff
            if (zeros >= 2 && value == 0x03) {
                zeros = 0
                continue
            }
            out.write(value)
            zeros = if (value == 0x00) zeros + 1 else 0
        }
        return out.toByteArray()
    }
}

// ---------------------------------------------------------------------------
// FLV tag -> MediaCodec 数据
// ---------------------------------------------------------------------------

internal fun signed24(data: ByteArray, offset: Int): Int {
    var value = ((data[offset].toInt() and 0xff) shl 16) or
        ((data[offset + 1].toInt() and 0xff) shl 8) or
        (data[offset + 2].toInt() and 0xff)
    if (value and 0x800000 != 0) value = value or -0x1000000
    return value
}

/** FLV 的 4 字节长度前缀 NALU -> Annex-B。 */
internal fun naluToAnnexB(data: ByteArray, start: Int, end: Int, lengthSize: Int): ByteArray {
    val out = ByteArrayOutputStream(maxOf(0, end - start) + 16)
    var pos = start
    val size = lengthSize.coerceIn(1, 4)
    while (pos + size <= end) {
        var nalLength = 0
        for (i in 0 until size) {
            nalLength = (nalLength shl 8) or (data[pos + i].toInt() and 0xff)
        }
        pos += size
        if (nalLength <= 0 || pos + nalLength > end) break
        out.write(0x00)
        out.write(0x00)
        out.write(0x00)
        out.write(0x01)
        out.write(data, pos, nalLength)
        pos += nalLength
    }
    return out.toByteArray()
}

internal fun awaitQueue(queue: java.util.concurrent.BlockingQueue<FlvTag>, timeoutMs: Long): FlvTag? {
    return try {
        queue.poll(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (_: InterruptedException) {
        null
    }
}

internal fun logi(message: String) {
    Log.i(FLV_LOG_TAG, message)
}

internal fun logw(message: String) {
    Log.w(FLV_LOG_TAG, message)
}

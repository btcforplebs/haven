package com.nostrvault.util

/**
 * Bech32 (BIP-173) encoding and decoding, as NIP-19 uses it.
 *
 * Lifted out of [com.nostrvault.relay.HavenBridge] unchanged. It was private
 * there, and HavenBridge cannot be loaded by a JVM unit test — its initializer
 * calls `Os.setenv` and `System.loadLibrary`. Nothing here touches Android or
 * the native relay, so keeping it separate is what makes the identifier
 * decoding in [com.nostrvault.data.model.QuoteReference] testable at all.
 */
object Bech32 {

    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    private fun polymod(values: IntArray): Int {
        var chk = 1
        for (v in values) {
            val b = chk ushr 25
            chk = ((chk and 0x1FFFFFF) shl 5) xor v
            if (b and 1 != 0) chk = chk xor 0x3B6A57B2.toInt()
            if (b and 2 != 0) chk = chk xor 0x26508E6D
            if (b and 4 != 0) chk = chk xor 0x1EA119FA
            if (b and 8 != 0) chk = chk xor 0x3D4233DD.toInt()
            if (b and 16 != 0) chk = chk xor 0x2A1462B3
        }
        return chk
    }

    private fun hrpExpand(hrp: String): IntArray {
        val ret = IntArray(hrp.length * 2 + 1)
        for (i in hrp.indices) {
            ret[i] = hrp[i].code ushr 5
            ret[i + hrp.length + 1] = hrp[i].code and 31
        }
        return ret
    }

    private fun convertBits8to5(data: ByteArray): ByteArray {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        for (b in data) {
            acc = (acc shl 8) or (b.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                result.add(((acc ushr bits) and 31).toByte())
            }
        }
        if (bits > 0) {
            result.add(((acc shl (5 - bits)) and 31).toByte())
        }
        return result.toByteArray()
    }

    private fun convertBits5to8(data: ByteArray): ByteArray {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        for (v in data) {
            acc = (acc shl 5) or (v.toInt() and 31)
            bits += 5
            while (bits >= 8) {
                bits -= 8
                result.add(((acc ushr bits) and 0xFF).toByte())
            }
        }
        return result.toByteArray()
    }

    fun encode(hrp: String, payload: ByteArray): String {
        val data5 = convertBits8to5(payload)
        val expanded = hrpExpand(hrp)
        val values = IntArray(expanded.size + data5.size + 6)
        expanded.copyInto(values)
        for (i in data5.indices) values[expanded.size + i] = data5[i].toInt()
        val checksumPolymod = polymod(values) xor 1
        val checksum = ByteArray(6) { ((checksumPolymod ushr (5 * (5 - it))) and 31).toByte() }
        val combined = data5 + checksum
        return buildString(hrp.length + 1 + combined.size) {
            append(hrp)
            append('1')
            for (b in combined) append(CHARSET[b.toInt() and 31])
        }
    }

    /** The human-readable part and the 8-bit payload, or null if the checksum fails. */
    fun decode(bech: String): Pair<String, ByteArray>? {
        val lower = bech.lowercase()
        val pos = lower.lastIndexOf('1')
        if (pos < 1 || pos + 7 > lower.length) return null
        val hrp = lower.substring(0, pos)
        val dataStr = lower.substring(pos + 1)
        val data5 = ByteArray(dataStr.length)
        for (i in dataStr.indices) {
            val idx = CHARSET.indexOf(dataStr[i])
            if (idx < 0) return null
            data5[i] = idx.toByte()
        }
        val expanded = hrpExpand(hrp)
        val values = IntArray(expanded.size + data5.size)
        expanded.copyInto(values)
        for (i in data5.indices) values[expanded.size + i] = data5[i].toInt()
        if (polymod(values) != 1) return null
        return Pair(hrp, convertBits5to8(data5.copyOfRange(0, data5.size - 6)))
    }
}

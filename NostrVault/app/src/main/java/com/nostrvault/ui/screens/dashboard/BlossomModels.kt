package com.nostrvault.ui.screens.dashboard

import java.util.UUID

data class MirrorInfo(
    val id: String = UUID.randomUUID().toString(),
    val url: String,
    val host: String = url.removePrefix("https://").removePrefix("http://").substringBefore("/"),
    var isHealthy: Boolean? = null,
    var responseTimeMs: Int? = null,
)

data class BlossomActivityLog(
    val id: String = UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis(),
    val message: String,
    val level: LogLevel,
) {
    enum class LogLevel { INFO, SUCCESS, WARNING, ERROR }
}

package com.nostrvault.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.nostrvault.MainActivity
import com.nostrvault.data.local.ConfigStore
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.Collections
import java.util.LinkedHashSet
import javax.inject.Inject
import javax.inject.Singleton
import android.app.NotificationManager as SystemNotificationManager

/**
 * Raises local Android system notifications for inbound Nostr events, with no
 * remote push server. The embedded Go relay runs 24/7 in [com.nostrvault.relay.RelayForegroundService]
 * and logs a machine-parseable `🔔NOTIFY|...` marker (see haven-go/import.go) for
 * every newly-imported inbox/chat event. The single relay log poller
 * ([com.nostrvault.relay.LogStore]) forwards those lines here via [onLogLine].
 *
 * Gating mirrors the (server-based) iOS push design: the global
 * `enablePushNotifications` master toggle plus the per-account [com.nostrvault.relay.PushPrefs]
 * per-type switches from Settings. Heads-up notifications are suppressed while the
 * app is in the foreground (the in-app relay-activity dot already covers that).
 */
@Singleton
class LocalNotificationService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: Lazy<NostrService>,
) {
    companion object {
        private const val CHANNEL_ID = "nostrvault_events"
        private const val MARKER = "🔔NOTIFY|"
        private const val PREVIEW_MARKER = "|preview="
        private const val MAX_SEEN = 500

        /**
         * Set from [MainActivity]'s lifecycle. When true, the app is on screen and
         * we skip system notifications to avoid doubling up with the in-app dot.
         */
        @Volatile
        var appInForeground: Boolean = false
    }

    // Dedup guard. The Go relay only logs NOTIFY for genuinely new events (it
    // skips duplicates before publishing), but a service restart could re-emit;
    // this keeps the most recent event ids to be safe.
    private val seen: MutableSet<String> = Collections.synchronizedSet(LinkedHashSet())

    /** Create the notification channel (idempotent). Safe to call repeatedly. */
    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mentions & messages",
            SystemNotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Mentions, replies, DMs, zaps, reactions, and reposts"
            enableVibration(true)
        }
        mgr.createNotificationChannel(channel)
    }

    /**
     * Feed every relay log line here. Only `🔔NOTIFY|...` markers are acted on;
     * everything else is ignored cheaply.
     */
    fun onLogLine(raw: String) {
        val idx = raw.indexOf(MARKER)
        if (idx < 0) return
        handle(raw.substring(idx + MARKER.length))
    }

    private fun handle(body: String) {
        // `preview` is always the LAST field and may contain spaces, so split it off
        // before parsing the simple key=value head fields.
        val pIdx = body.indexOf(PREVIEW_MARKER)
        val head = if (pIdx >= 0) body.substring(0, pIdx) else body
        val preview = if (pIdx >= 0) body.substring(pIdx + PREVIEW_MARKER.length) else ""

        val fields = HashMap<String, String>()
        for (part in head.split("|")) {
            val eq = part.indexOf('=')
            if (eq > 0) fields[part.substring(0, eq)] = part.substring(eq + 1)
        }
        val type = fields["type"] ?: return
        val author = fields["author"].orEmpty()
        val id = fields["id"] ?: return
        if (id.isEmpty()) return

        if (!markSeen(id)) return

        val config = configStore.config.value
        if (!config.enablePushNotifications) return
        val prefs = config.pushPrefsFor(config.activeOrOwnerNpub())

        val allowed = when (type) {
            "mention" -> prefs.mentions
            "reply" -> prefs.replies
            "dm", "giftwrap" -> prefs.dms
            "zap" -> prefs.zaps
            "reaction" -> prefs.reactions
            "repost" -> prefs.reposts
            else -> false
        }
        if (!allowed) return

        // The in-app dot already signals activity while the app is open.
        if (appInForeground) return

        val name = resolveName(author)
        val (title, text) = buildContent(type, name, preview)
        post(id, title, text, type, author)
    }

    /** Returns true if this id is newly seen (and records it); false if a duplicate. */
    private fun markSeen(id: String): Boolean = synchronized(seen) {
        if (!seen.add(id)) return false
        if (seen.size > MAX_SEEN) {
            val it = seen.iterator()
            val target = MAX_SEEN / 2
            while (seen.size > target && it.hasNext()) {
                it.next()
                it.remove()
            }
        }
        true
    }

    private fun resolveName(authorHex: String): String? {
        if (authorHex.length != 64) return null
        return nostrService.get().profiles.value[authorHex]?.bestName
    }

    private fun buildContent(type: String, name: String?, preview: String): Pair<String, String> {
        val who = name ?: "Someone"
        return when (type) {
            "mention" -> "$who mentioned you" to preview.ifBlank { "You were mentioned in a note" }
            "reply" -> "$who replied to your note" to preview.ifBlank { "Tap to view the reply" }
            "dm", "giftwrap" -> {
                val title = if (name != null) "Message from $who" else "New message"
                title to "You have a new encrypted message"
            }
            "zap" -> "⚡ New zap" to if (name != null) "$who zapped you" else "You received a zap"
            "reaction" -> "$who reacted ${preview.ifBlank { "❤️" }}" to "Tap to view your note"
            "repost" -> "$who reposted your note" to "Tap to view"
            else -> "New activity" to "Tap to view"
        }
    }

    @SuppressLint("MissingPermission") // guarded by the runtime check below
    private fun post(id: String, title: String, text: String, type: String, author: String) {
        ensureChannel()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("notif_type", type)
            putExtra("notif_event_id", id)
            putExtra("notif_author", author)
        }
        val pending = PendingIntent.getActivity(
            context,
            id.hashCode(),
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setContentIntent(pending)
            .build()

        // Stable per-event notification id so the same event never double-posts.
        NotificationManagerCompat.from(context).notify(id.hashCode(), notification)
    }
}

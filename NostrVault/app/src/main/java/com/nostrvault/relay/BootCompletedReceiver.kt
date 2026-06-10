package com.nostrvault.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Auto-start the relay service when the device boots.
 * This is user-toggleable via settings.
 */
class BootCompletedReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        // TODO: Check user preference for auto-start (ConfigStore, Phase 4)
        val autoStartEnabled = true

        if (autoStartEnabled) {
            Log.i(TAG, "Boot completed -- starting relay service")
            RelayForegroundService.start(context)
        } else {
            Log.d(TAG, "Boot completed -- auto-start disabled, skipping")
        }
    }
}

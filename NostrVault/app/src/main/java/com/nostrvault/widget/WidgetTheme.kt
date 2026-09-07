package com.nostrvault.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.sp
import androidx.glance.action.Action
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.text.FontWeight
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider

/**
 * Shared look and behaviour for the home-screen widgets.
 *
 * The colours are the app icon's: the near-black of the arch's opening and the
 * Sunset Orange of the light inside it, so a widget reads as the same object as
 * the icon sitting next to it on the home screen.
 */
object WidgetTheme {
    val Background = Color(0xFF0A0602)
    val Accent = Color(0xFFFA9447)
    val Primary = Color(0xFFF2EAE2)
    val Secondary = Color(0xFF9A8B7D)

    val Title = TextStyle(
        color = ColorProvider(Primary),
        fontSize = 13.sp,
        fontWeight = FontWeight.Medium,
    )
    val Value = TextStyle(
        color = ColorProvider(Accent),
        fontSize = 22.sp,
        fontWeight = FontWeight.Bold,
    )
    val Caption = TextStyle(color = ColorProvider(Secondary), fontSize = 11.sp)
    val Body = TextStyle(color = ColorProvider(Primary), fontSize = 12.sp)
}

/**
 * Every widget tap opens the app through the same `nostrvault://` links the
 * DeepLinkRouter serves — the widgets get no private entry point of their own,
 * so there is one mapping to keep right.
 */
fun openApp(context: Context, destination: String): Action =
    actionStartActivity(
        Intent(Intent.ACTION_VIEW, Uri.parse("nostrvault://$destination")).apply {
            setPackage(context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    )

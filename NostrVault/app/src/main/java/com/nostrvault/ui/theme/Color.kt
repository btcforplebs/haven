package com.nostrvault.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Port of Theming.swift + PlatformCompat.swift color definitions.
 * All hex values match the iOS app exactly.
 */

// ---------------------------------------------------------------------------
// Theme color schemes (port of AppTheme enum in Theming.swift)
// ---------------------------------------------------------------------------

data class NostrVaultColorScheme(
    val primary: Color,
    val primaryLight: Color,
    val primaryDark: Color,
    val primaryPale: Color,
)

/**
 * The app has exactly one appearance: OLED black with the orange accent.
 *
 * This was a six-way colour picker (purple/blue/green/orange/pink/slate) paired
 * with an OLED toggle. Both are gone. The enum survives only so `themeColor`
 * keeps resolving — a config saved under any retired key falls through
 * [fromKey] to [DEFAULT], so old installs migrate silently.
 */
enum class AppTheme(
    val key: String,
    val displayName: String,
    val colors: NostrVaultColorScheme,
) {
    SUNSET_ORANGE(
        key = "orange",
        displayName = "Sunset Orange",
        colors = NostrVaultColorScheme(
            primary = Color(0xFFE67326),
            primaryLight = Color(0xFFFA9447),
            primaryDark = Color(0xFFB35214),
            primaryPale = Color(0xFFE67326).copy(alpha = 0.10f),
        ),
    ),
    ;

    companion object {
        val DEFAULT = SUNSET_ORANGE

        fun fromKey(key: String): AppTheme =
            entries.find { it.key == key } ?: DEFAULT
    }
}

// ---------------------------------------------------------------------------
// Platform background colors (port of PlatformCompat.swift)
// ---------------------------------------------------------------------------

val WindowBackground = Color(0xFF141419)
val SecondaryGroupedBg = Color(0xFF1F1F29)
val TertiaryGroupedBg = Color(0xFF262633)
val SeparatorColor = Color(0xFF333338)

// Standard card
val CardBackground = Color(0xFF1F1F1F).copy(alpha = 0.60f)
val CardBorder = Color.White.copy(alpha = 0.04f)

// OLED variants (toggled by user preference)
val OledCardBackground = Color(0xFF0F0F0F)
val OledCardBorder = Color.White.copy(alpha = 0.08f)

// Console / dashboard
val ConsoleHeaderBg = Color(0xFF1F1F26)

// Text colors
val PrimaryText = Color.White
val SecondaryText = Color.White.copy(alpha = 0.60f)
val TertiaryText = Color.White.copy(alpha = 0.40f)
val PlaceholderText = Color.White.copy(alpha = 0.25f)

// Status colors
val SuccessGreen = Color(0xFF34C759)
val WarningYellow = Color(0xFFFFCC00)
val ErrorRed = Color(0xFFFF3B30)
val InfoBlue = Color(0xFF007AFF)

// Engagement action colors
val LikeRed = Color(0xFFFF3B30)
val RepostGreen = Color(0xFF34C759)
val ZapOrange = Color(0xFFFF9500)

// Wizard accent (setup flow)
val WizardOrange = Color(0xFFF59E0B)
val WizardOrangeDark = Color(0xFFEA580C)

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

enum class AppTheme(
    val key: String,
    val displayName: String,
    val colors: NostrVaultColorScheme,
) {
    HAVEN_PURPLE(
        key = "purple",
        displayName = "Haven Purple",
        colors = NostrVaultColorScheme(
            primary = Color(0xFF6B2D8F),
            primaryLight = Color(0xFF8A4DB0),
            primaryDark = Color(0xFF542370),
            primaryPale = Color(0xFF6B2D8F).copy(alpha = 0.10f),
        ),
    ),
    OCEAN_BLUE(
        key = "blue",
        displayName = "Ocean Blue",
        colors = NostrVaultColorScheme(
            primary = Color(0xFF1773BD),
            primaryLight = Color(0xFF3394E0),
            primaryDark = Color(0xFF0D528C),
            primaryPale = Color(0xFF1773BD).copy(alpha = 0.10f),
        ),
    ),
    EMERALD_GREEN(
        key = "green",
        displayName = "Emerald Green",
        colors = NostrVaultColorScheme(
            primary = Color(0xFF219469),
            primaryLight = Color(0xFF38BA87),
            primaryDark = Color(0xFF146B4A),
            primaryPale = Color(0xFF219469).copy(alpha = 0.10f),
        ),
    ),
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
    ROSE_PINK(
        key = "pink",
        displayName = "Rose Pink",
        colors = NostrVaultColorScheme(
            primary = Color(0xFFE03870),
            primaryLight = Color(0xFFF25994),
            primaryDark = Color(0xFFAE214F),
            primaryPale = Color(0xFFE03870).copy(alpha = 0.10f),
        ),
    ),
    MONOCHROME_SLATE(
        key = "slate",
        displayName = "Monochrome Slate",
        colors = NostrVaultColorScheme(
            primary = Color(0xFF73808C),
            primaryLight = Color(0xFF94A1AE),
            primaryDark = Color(0xFF525E69),
            primaryPale = Color(0xFF73808C).copy(alpha = 0.10f),
        ),
    );

    companion object {
        /** Default theme if none is configured. Matches iOS default (orange). */
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

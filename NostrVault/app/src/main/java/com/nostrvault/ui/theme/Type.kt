package com.nostrvault.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Port of Font.appSystem() scaling system from Theming.swift.
 *
 * Maps iOS semantic font styles to Material 3 Typography slots:
 *   displayLarge  = appLargeTitle (34sp)
 *   headlineLarge = appTitle      (28sp)
 *   headlineMedium = appTitle2    (22sp)
 *   headlineSmall = appTitle3     (20sp)
 *   titleLarge    = appHeadline   (17sp, semibold)
 *   titleMedium   = appBody       (17sp)
 *   titleSmall    = appCallout    (16sp)
 *   bodyLarge     = appSubheadline(15sp)
 *   bodyMedium    = appFootnote   (13sp)
 *   bodySmall     = appCaption    (12sp)
 *   labelSmall    = appCaption2   (11sp)
 */
fun nostrVaultTypography(scale: Float = 1.0f): Typography = Typography(
    displayLarge = TextStyle(
        fontSize = (34 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (41 * scale).sp,
    ),
    headlineLarge = TextStyle(
        fontSize = (28 * scale).sp,
        fontWeight = FontWeight.Bold,
        lineHeight = (34 * scale).sp,
    ),
    headlineMedium = TextStyle(
        fontSize = (22 * scale).sp,
        fontWeight = FontWeight.Bold,
        lineHeight = (28 * scale).sp,
    ),
    headlineSmall = TextStyle(
        fontSize = (20 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (25 * scale).sp,
    ),
    titleLarge = TextStyle(
        fontSize = (17 * scale).sp,
        fontWeight = FontWeight.SemiBold,
        lineHeight = (22 * scale).sp,
    ),
    titleMedium = TextStyle(
        fontSize = (17 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (22 * scale).sp,
    ),
    titleSmall = TextStyle(
        fontSize = (16 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (21 * scale).sp,
    ),
    bodyLarge = TextStyle(
        fontSize = (15 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (20 * scale).sp,
    ),
    bodyMedium = TextStyle(
        fontSize = (13 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (18 * scale).sp,
    ),
    bodySmall = TextStyle(
        fontSize = (12 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (16 * scale).sp,
    ),
    labelSmall = TextStyle(
        fontSize = (11 * scale).sp,
        fontWeight = FontWeight.Normal,
        lineHeight = (13 * scale).sp,
    ),
)

/** Monospace variant for stats, amounts, hex strings, and code blocks. */
fun monoTextStyle(scale: Float = 1.0f): TextStyle = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = (14 * scale).sp,
    fontWeight = FontWeight.Normal,
    lineHeight = (18 * scale).sp,
)

package com.nostrvault.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

/**
 * Corner radius tokens matching the iOS app's shape language.
 */
object NostrVaultShapes {
    val Small = RoundedCornerShape(4.dp)       // Filter badges
    val Standard = RoundedCornerShape(6.dp)    // Buttons, small cards
    val Medium = RoundedCornerShape(8.dp)      // Link previews
    val Large = RoundedCornerShape(10.dp)      // Stats cards
    val Pill = RoundedCornerShape(20.dp)       // Mode buttons, capsules
    val Section = RoundedCornerShape(16.dp)    // Major containers
    val Circle = RoundedCornerShape(50)        // Avatars, circular buttons
}

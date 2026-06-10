package com.nostrvault.ui.theme

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween

/**
 * Animation tokens ported from the iOS app's spring/easing specs.
 *
 * iOS uses SwiftUI .spring(response:dampingFraction:) which maps
 * to Compose spring(dampingRatio:stiffness:).
 */
object NostrVaultMotion {

    // Spring animations
    val SnapSpring = spring<Float>(
        dampingRatio = 0.75f,
        stiffness = Spring.StiffnessHigh,         // ~0.25s response
    )
    val StandardSpring = spring<Float>(
        dampingRatio = 0.75f,
        stiffness = Spring.StiffnessMedium,        // ~0.35s
    )
    val ElasticSpring = spring<Float>(
        dampingRatio = 0.6f,
        stiffness = Spring.StiffnessMediumLow,     // ~0.5s
    )
    val HeroSpring = spring<Float>(
        dampingRatio = 0.7f,
        stiffness = Spring.StiffnessLow,           // ~0.6s
    )

    // Tween animations
    val QuickEase = tween<Float>(
        durationMillis = 150,
        easing = FastOutSlowInEasing,
    )
    val StandardEase = tween<Float>(
        durationMillis = 200,
        easing = FastOutSlowInEasing,
    )
    val NotificationEase = tween<Float>(
        durationMillis = 300,
        easing = FastOutSlowInEasing,
    )
}

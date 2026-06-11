package com.nostrvault.ui.navigation

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.glassPillBackground
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText

/**
 * Floating pill-shaped bottom navigation bar matching the iOS tab structure.
 * Tab order: Feed | Search | Profile (center, avatar) | Media | Relay
 *
 * Profile tab shows user avatar with a colored ring and supports
 * long-press to trigger account switching.
 */

data class BottomNavItem(
    val screen: Screen,
    val label: String,
    val icon: ImageVector,
)

val bottomNavItems = listOf(
    BottomNavItem(Screen.Feed, "Feed", NostrVaultIcons.Feed),
    BottomNavItem(Screen.Search, "Search", NostrVaultIcons.Search),
    BottomNavItem(Screen.Profile, "Profile", NostrVaultIcons.Profile), // center
    BottomNavItem(Screen.MediaGallery, "Media", NostrVaultIcons.Media),
    BottomNavItem(Screen.Dashboard, "Relay", NostrVaultIcons.Relay),
)

@Composable
fun BottomNavBar(
    currentRoute: String?,
    activeAccountPubkey: String,
    isOwner: Boolean,
    hasUnreadDMs: Boolean = false,
    hasNewRelayActivity: Boolean = false,
    onNavigate: (Screen) -> Unit,
    onReselect: (Screen) -> Unit = {},
    onAccountSwitcher: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val isOled = LocalOledMode.current

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .glassPillBackground(isOled = isOled, accentColor = colors.primary)
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (item in bottomNavItems) {
                val isProfileTab = item.screen == Screen.Profile
                val selected = if (isProfileTab) {
                    currentRoute?.startsWith("profile") == true
                } else {
                    currentRoute == item.screen.route
                }

                if (isProfileTab) {
                    ProfileTab(
                        selected = selected,
                        selectedColor = colors.primary,
                        isOwner = isOwner,
                        showBadge = hasUnreadDMs,
                        onClick = {
                            if (selected) {
                                onReselect(Screen.Profile)
                            } else {
                                onNavigate(Screen.Profile)
                            }
                        },
                        onLongClick = onAccountSwitcher,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    NavTab(
                        icon = item.icon,
                        label = item.label,
                        selected = selected,
                        selectedColor = colors.primary,
                        showBadge = item.screen == Screen.Dashboard && hasNewRelayActivity,
                        onClick = {
                            if (selected) {
                                onReselect(item.screen)
                            } else {
                                onNavigate(item.screen)
                            }
                        },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun NavTab(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    selectedColor: Color,
    showBadge: Boolean = false,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.1f else 1.0f,
        animationSpec = tween(150),
        label = "tabScale",
    )

    Column(
        modifier = modifier
            .clip(CircleShape)
            .semantics { role = Role.Tab }
            .combinedClickableCompat(onClick = onClick)
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Box {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = if (selected) selectedColor else SecondaryText,
                modifier = Modifier
                    .size(31.dp)
                    .scale(scale),
            )
            if (showBadge) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }
        Text(
            text = label,
            fontSize = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) selectedColor else SecondaryText,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProfileTab(
    selected: Boolean,
    selectedColor: Color,
    isOwner: Boolean,
    showBadge: Boolean = false,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.1f else 1.0f,
        animationSpec = tween(150),
        label = "profileScale",
    )
    val ringColor = if (isOwner) selectedColor else Color(0xFFFF9500)

    Column(
        modifier = modifier
            .clip(CircleShape)
            .semantics { role = Role.Tab }
            .combinedClickable(
                onClick = onClick,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onLongClick()
                },
            )
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        // Avatar placeholder with ring
        Box {
            Box(
                modifier = Modifier
                    .size(31.dp)
                    .scale(scale)
                    .border(
                        width = if (selected) 1.5.dp else 0.dp,
                        color = if (selected) ringColor else Color.Transparent,
                        shape = CircleShape,
                    )
                    .padding(1.dp)
                    .clip(CircleShape)
                    .background(SecondaryGroupedBg),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = NostrVaultIcons.AccountCircle,
                    contentDescription = "Profile",
                    tint = if (selected) selectedColor else SecondaryText,
                    modifier = Modifier.size(25.dp),
                )
            }
            if (showBadge) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }
        Text(
            text = "Profile",
            fontSize = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) selectedColor else SecondaryText,
        )
    }
}

/**
 * Compatibility wrapper for combinedClickable that only uses onClick
 * (no long-press) — avoids the ExperimentalFoundationApi for non-profile tabs.
 */
@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(
    onClick: () -> Unit,
): Modifier = this.combinedClickable(onClick = onClick)

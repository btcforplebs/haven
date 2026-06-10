package com.nostrvault.ui.navigation

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.screens.*
import com.nostrvault.ui.screens.dm.DMInboxScreen
import com.nostrvault.ui.screens.dm.DMThreadScreen
import com.nostrvault.ui.screens.feed.FeedScreen
import com.nostrvault.ui.screens.groups.GroupBrowserScreen
import com.nostrvault.ui.screens.groups.GroupChatScreen
import com.nostrvault.ui.screens.groups.GroupInfoScreen
import com.nostrvault.ui.screens.groups.GroupListScreen
import com.nostrvault.ui.screens.profile.ProfileEditScreen
import com.nostrvault.ui.screens.profile.ProfileScreen
import com.nostrvault.ui.screens.settings.AccountSettingsScreen
import com.nostrvault.ui.screens.settings.AppearanceSettingsScreen
import com.nostrvault.ui.screens.settings.RelayListEditorScreen
import com.nostrvault.ui.screens.settings.SettingsScreen
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Root composable that manages navigation state and the floating bottom nav pill.
 * Uses a Box overlay so the pill floats over content.
 */
@Composable
fun NostrVaultNavHost(
    isSetupComplete: Boolean,
    modifier: Modifier = Modifier,
    configStore: ConfigStore,
) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    // Bottom bar visible only on top-level tab screens
    val showBottomBar = currentRoute in listOf(
        Screen.Feed.route,
        Screen.Search.route,
        Screen.MediaGallery.route,
        Screen.Dashboard.route,
        Screen.Profile.route,
    )

    val startDestination = if (isSetupComplete) Screen.Feed.route else Screen.SetupWizard.route

    // Account switcher state
    var showAccountSwitcher by remember { mutableStateOf(false) }
    val config by configStore.config.collectAsState()
    val activeHex by configStore.activeAccountHexPubkey.collectAsState()
    val isOwner = config.activeAccountNpub.isNullOrBlank()

    Box(modifier = modifier.fillMaxSize()) {
        NavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.fillMaxSize(),
            enterTransition = {
                slideInHorizontally(initialOffsetX = { it }, animationSpec = tween(300))
            },
            exitTransition = {
                slideOutHorizontally(targetOffsetX = { -it / 3 }, animationSpec = tween(300))
            },
            popEnterTransition = {
                slideInHorizontally(initialOffsetX = { -it / 3 }, animationSpec = tween(300))
            },
            popExitTransition = {
                slideOutHorizontally(targetOffsetX = { it }, animationSpec = tween(300))
            },
        ) {
            // ── Setup ─────────────────────────────────────────────
            composable(Screen.SetupWizard.route) {
                SetupWizardScreen(
                    onComplete = {
                        navController.navigate(Screen.Feed.route) {
                            popUpTo(Screen.SetupWizard.route) { inclusive = true }
                        }
                    },
                )
            }

            // ── Bottom nav tabs ───────────────────────────────────
            composable(Screen.Feed.route) {
                FeedScreen(
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onCompose = {
                        navController.navigate(Screen.ComposeNote.createRoute())
                    },
                    onReply = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
                    },
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
                    },
                    onNavigateToDashboard = {
                        navController.navigate(Screen.Dashboard.route)
                    },
                )
            }

            composable(Screen.Search.route) {
                SearchScreen(
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                )
            }

            composable(Screen.MediaGallery.route) {
                MediaGalleryScreen(
                    onMediaClick = { index ->
                        navController.navigate(Screen.MediaViewer.createRoute(index))
                    },
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onBlossomClick = {
                        navController.navigate(Screen.BlossomDashboard.route)
                    },
                )
            }

            composable(Screen.DMInbox.route) {
                DMInboxScreen(
                    onConversationClick = { pubkey ->
                        navController.navigate(Screen.DMThread.createRoute(pubkey))
                    },
                )
            }

            composable(
                route = Screen.Profile.route,
                arguments = listOf(navArgument("pubkey") { type = NavType.StringType }),
            ) { entry ->
                val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
                ProfileScreen(
                    pubkey = pubkey,
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onProfileClick = { pk ->
                        navController.navigate(Screen.Profile.createRoute(pk))
                    },
                    onEditProfile = {
                        navController.navigate(Screen.ProfileEdit.route)
                    },
                    onNavigateToDMs = {
                        navController.navigate(Screen.DMInbox.route)
                    },
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Detail screens ────────────────────────────────────
            composable(
                route = Screen.NoteDetail.route,
                arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
            ) { entry ->
                val noteId = entry.arguments?.getString("noteId") ?: return@composable
                NoteDetailScreen(
                    noteId = noteId,
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onNoteClick = { id ->
                        navController.navigate(Screen.NoteDetail.createRoute(id))
                    },
                    onReply = { id ->
                        navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = id))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.DMThread.route,
                arguments = listOf(navArgument("pubkey") { type = NavType.StringType }),
            ) { entry ->
                val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
                DMThreadScreen(
                    counterpartyPubkey = pubkey,
                    onProfileClick = { pk ->
                        navController.navigate(Screen.Profile.createRoute(pk))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.ComposeNote.route,
                arguments = listOf(
                    navArgument("replyTo") { type = NavType.StringType; nullable = true; defaultValue = null },
                ),
            ) { entry ->
                ComposeNoteScreen(
                    onPublished = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.ProfileEdit.route) {
                ProfileEditScreen(
                    onSaved = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Groups ────────────────────────────────────────────
            composable(Screen.GroupList.route) {
                GroupListScreen(
                    onGroupClick = { groupId, relayUrl ->
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupChat.createRoute(groupId, encoded))
                    },
                    onBrowse = {
                        navController.navigate(Screen.GroupBrowser.route)
                    },
                    onCreate = {
                        navController.navigate(Screen.GroupCreate.route)
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.GroupChat.route,
                arguments = listOf(
                    navArgument("groupId") { type = NavType.StringType },
                    navArgument("relayUrl") { type = NavType.StringType },
                ),
            ) { entry ->
                val groupId = entry.arguments?.getString("groupId") ?: return@composable
                val relayUrl = URLDecoder.decode(
                    entry.arguments?.getString("relayUrl") ?: return@composable, "UTF-8"
                )
                GroupChatScreen(
                    groupId = groupId,
                    relayUrl = relayUrl,
                    onInfo = {
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupInfo.createRoute(groupId, encoded))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.GroupInfo.route,
                arguments = listOf(
                    navArgument("groupId") { type = NavType.StringType },
                    navArgument("relayUrl") { type = NavType.StringType },
                ),
            ) { entry ->
                val groupId = entry.arguments?.getString("groupId") ?: return@composable
                val relayUrl = URLDecoder.decode(
                    entry.arguments?.getString("relayUrl") ?: return@composable, "UTF-8"
                )
                GroupInfoScreen(
                    groupId = groupId,
                    relayUrl = relayUrl,
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.GroupBrowser.route) {
                GroupBrowserScreen(
                    onGroupClick = { groupId, relayUrl ->
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupChat.createRoute(groupId, encoded))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.GroupCreate.route) {
                GroupCreateScreen(
                    onCreated = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Wallet ────────────────────────────────────────────
            composable(Screen.Wallet.route) {
                WalletScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.BitcoinSweep.route) {
                BitcoinSweepScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Settings ──────────────────────────────────────────
            composable(Screen.Settings.route) {
                SettingsScreen(
                    onNavigate = { screen -> navController.navigate(screen.route) },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.AppearanceSettings.route) {
                AppearanceSettingsScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.AccountSettings.route) {
                AccountSettingsScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.RelayListEditor.route) {
                RelayListEditorScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Dashboard ─────────────────────────────────────────
            composable(Screen.Dashboard.route) {
                DashboardScreen(
                    onNavigate = { screen -> navController.navigate(screen.route) },
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onCompose = {
                        navController.navigate(Screen.ComposeNote.createRoute())
                    },
                    onReply = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.BlossomDashboard.route) {
                BlossomDashboardScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Media viewer ──────────────────────────────────────
            composable(
                route = Screen.MediaViewer.route,
                arguments = listOf(navArgument("index") { type = NavType.IntType }),
            ) { entry ->
                val index = entry.arguments?.getInt("index") ?: 0
                MediaViewerScreen(
                    initialIndex = index,
                    onBack = { navController.popBackStack() },
                )
            }
        }

        // Floating bottom nav pill overlay
        if (showBottomBar) {
            Box(modifier = Modifier.align(Alignment.BottomCenter)) {
                BottomNavBar(
                    currentRoute = currentRoute,
                    activeAccountPubkey = activeHex,
                    isOwner = isOwner,
                    onNavigate = { screen ->
                        val route = if (screen == Screen.Profile) {
                            Screen.Profile.createRoute(activeHex)
                        } else {
                            screen.route
                        }
                        navController.navigate(route) {
                            popUpTo(Screen.Feed.route) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    onAccountSwitcher = { showAccountSwitcher = true },
                )
            }
        }
    }

    // Account switcher bottom sheet
    if (showAccountSwitcher) {
        val ownerNpub = config.ownerNpub
        val accounts = buildList {
            add(
                AccountInfo(
                    npub = ownerNpub,
                    hexPubkey = activeHex,
                    displayName = "Owner",
                    isOwner = true,
                    isActive = isOwner,
                    hasKey = true,
                )
            )
            config.whitelistedNpubs?.forEach { npub ->
                if (npub != ownerNpub) {
                    add(
                        AccountInfo(
                            npub = npub,
                            hexPubkey = "",
                            displayName = npub.take(16) + "...",
                            isOwner = false,
                            isActive = config.activeAccountNpub == npub,
                            hasKey = false,
                        )
                    )
                }
            }
        }

        AccountSwitcherSheet(
            accounts = accounts,
            onSelectAccount = { npub ->
                configStore.update { it.copy(activeAccountNpub = npub) }
            },
            onDismiss = { showAccountSwitcher = false },
        )
    }
}

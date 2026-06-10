package com.nostrvault.ui.navigation

/**
 * Sealed class route definitions for Jetpack Compose Navigation.
 * Matches the iOS tab/screen structure.
 */
sealed class Screen(val route: String) {
    // Bottom nav tabs
    data object Feed : Screen("feed")
    data object Search : Screen("search")
    data object MediaGallery : Screen("media")
    data object DMInbox : Screen("dm_inbox")
    data object Profile : Screen("profile/{pubkey}") {
        fun createRoute(pubkey: String) = "profile/$pubkey"
    }

    // Detail screens
    data object NoteDetail : Screen("note/{noteId}") {
        fun createRoute(noteId: String) = "note/$noteId"
    }
    data object DMThread : Screen("dm_thread/{pubkey}") {
        fun createRoute(pubkey: String) = "dm_thread/$pubkey"
    }
    data object ComposeNote : Screen("compose?replyTo={replyTo}") {
        fun createRoute(replyToNoteId: String? = null): String {
            return if (replyToNoteId != null) "compose?replyTo=$replyToNoteId" else "compose"
        }
    }
    data object ProfileEdit : Screen("profile_edit")

    // Groups
    data object GroupList : Screen("groups")
    data object GroupChat : Screen("group_chat/{groupId}/{relayUrl}") {
        fun createRoute(groupId: String, relayUrl: String) = "group_chat/$groupId/$relayUrl"
    }
    data object GroupInfo : Screen("group_info/{groupId}/{relayUrl}") {
        fun createRoute(groupId: String, relayUrl: String) = "group_info/$groupId/$relayUrl"
    }
    data object GroupBrowser : Screen("group_browser")
    data object GroupCreate : Screen("group_create")

    // Wallet
    data object Wallet : Screen("wallet")
    data object BitcoinSweep : Screen("bitcoin_sweep")

    // Settings
    data object Settings : Screen("settings")
    data object AppearanceSettings : Screen("settings/appearance")
    data object AccountSettings : Screen("settings/accounts")
    data object RelayListEditor : Screen("settings/relays")

    // Dashboard
    data object Dashboard : Screen("dashboard")
    data object BlossomDashboard : Screen("blossom_dashboard")

    // Setup
    data object SetupWizard : Screen("setup")

    // Media viewer
    data object MediaViewer : Screen("media_viewer/{index}") {
        fun createRoute(index: Int) = "media_viewer/$index"
    }
}

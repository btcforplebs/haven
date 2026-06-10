package com.nostrvault

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.AmberResultBridge
import com.nostrvault.ui.navigation.NostrVaultNavHost
import com.nostrvault.ui.theme.NostrVaultTheme
import com.nostrvault.ui.theme.WindowBackground
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject lateinit var configStore: ConfigStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Must register before Activity reaches STARTED state
        AmberResultBridge.initialize(this)

        enableEdgeToEdge()

        // Load persisted config so hasCompletedSetup reflects saved state
        configStore.reload()

        setContent {
            val config by configStore.config.collectAsState()

            // Start relay service when setup completes (or on subsequent launches).
            // Both full and browse modes start the relay — browse mode only needs the
            // npub to import notes and cache media (no private key required).
            LaunchedEffect(config.hasCompletedSetup) {
                if (config.hasCompletedSetup) {
                    RelayForegroundService.start(this@MainActivity)
                }
            }

            NostrVaultTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = WindowBackground,
                ) {
                    NostrVaultNavHost(
                        isSetupComplete = config.hasCompletedSetup,
                        configStore = configStore,
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        AmberResultBridge.detach()
    }
}

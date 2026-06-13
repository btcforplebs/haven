package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.relay.RelayLogParser
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Orchestrates relay import/export operations, coordinating with
 * RelayForegroundService lifecycle and HavenBridge Go functions.
 *
 * Import flow: stop relay -> set env -> start in import mode -> poll progress -> restart relay
 * Export flow: call HavenBridge.backupDatabase() or zipDirectory() on IO dispatcher
 */
@Singleton
class RelayImportService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val logStore: LogStore,
) {
    companion object {
        private const val TAG = "RelayImportService"
        private const val IMPORT_POLL_INTERVAL_MS = 300L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // ── Import state ─────────────────────────────────────────────

    private val _isImporting = MutableStateFlow(false)
    val isImporting: StateFlow<Boolean> = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(0f)
    val importProgress: StateFlow<Float> = _importProgress.asStateFlow()

    private val _importStatusMessage = MutableStateFlow("")
    val importStatusMessage: StateFlow<String> = _importStatusMessage.asStateFlow()

    private val _importCompleted = MutableStateFlow(false)
    val importCompleted: StateFlow<Boolean> = _importCompleted.asStateFlow()

    // ── Export state ─────────────────────────────────────────────

    private val _isExporting = MutableStateFlow(false)
    val isExporting: StateFlow<Boolean> = _isExporting.asStateFlow()

    private val _exportStatusMessage = MutableStateFlow("")
    val exportStatusMessage: StateFlow<String> = _exportStatusMessage.asStateFlow()

    private var importJob: Job? = null

    /**
     * Import notes from seed relays. Stops the running relay, starts it
     * in import mode, polls for progress, then restarts normally.
     */
    fun importNotes() {
        if (_isImporting.value || _isExporting.value) return

        importJob = scope.launch {
            _isImporting.value = true
            _importProgress.value = 0f
            _importStatusMessage.value = "Preparing import..."
            _importCompleted.value = false

            try {
                // 1. Stop the running relay
                _importStatusMessage.value = "Stopping relay..."
                RelayForegroundService.stop(context)
                delay(2000) // Wait for service to fully stop

                // 2. Set up environment for import mode
                val config = configStore.config.value
                val relayDataDir = File(context.filesDir, "relay_data")
                RelayConfiguration.ensureDirectories(relayDataDir)
                val envDict = RelayConfiguration.generateEnvDictionary(config, relayDataDir)
                envDict.forEach { (key, value) ->
                    HavenBridge.setEnv(key, value)
                }

                // 3. Start relay in import mode on IO thread
                _importStatusMessage.value = "Importing notes from seed relays..."
                logStore.clear()

                withContext(Dispatchers.IO) {
                    // Start polling for progress in parallel
                    val pollJob = launch {
                        pollImportProgress()
                    }

                    // This blocks until import completes
                    HavenBridge.startRelay(importMode = true)

                    pollJob.cancel()
                }

                _importProgress.value = 1f
                _importStatusMessage.value = "Import completed"
                _importCompleted.value = true
                Log.i(TAG, "Note import completed successfully")

            } catch (e: CancellationException) {
                _importStatusMessage.value = "Import cancelled"
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Import failed: ${e.message}", e)
                _importStatusMessage.value = "Import failed: ${e.message}"
            } finally {
                _isImporting.value = false
                // 4. Restart relay in normal mode
                _importStatusMessage.value = "Restarting relay..."
                delay(1000)
                RelayForegroundService.start(context)
            }
        }
    }

    /**
     * Export relay database as a compressed JSONL zip backup.
     * @param outputPath absolute path for the output zip file
     */
    fun exportDatabase(outputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
            _exportStatusMessage.value = "Exporting database..."

            try {
                val result = withContext(Dispatchers.IO) {
                    HavenBridge.backupDatabase(outputPath)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Database exported successfully"
                    Log.i(TAG, "Database export completed: $outputPath")
                } else {
                    _exportStatusMessage.value = "Database export failed"
                    Log.e(TAG, "Database export failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Database export error: ${e.message}", e)
                _exportStatusMessage.value = "Export error: ${e.message}"
            } finally {
                _isExporting.value = false
            }
        }
    }

    /**
     * Export Blossom media files as a zip archive.
     * @param outputPath absolute path for the output zip file
     */
    fun exportBlossom(outputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
            _exportStatusMessage.value = "Exporting media files..."

            try {
                val config = configStore.config.value
                val relayDataDir = File(context.filesDir, "relay_data")
                val blossomDir = File(relayDataDir, "blossom").absolutePath

                val result = withContext(Dispatchers.IO) {
                    HavenBridge.zipDirectory(blossomDir, outputPath)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Media exported successfully"
                    Log.i(TAG, "Blossom export completed: $outputPath")
                } else {
                    _exportStatusMessage.value = "Media export failed"
                    Log.e(TAG, "Blossom export failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Blossom export error: ${e.message}", e)
                _exportStatusMessage.value = "Export error: ${e.message}"
            } finally {
                _isExporting.value = false
            }
        }
    }

    /**
     * Restore the relay database from a Nostr Vault JSONL backup zip.
     * @param inputPath absolute path to the backup file
     */
    fun importDatabase(inputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
            _exportStatusMessage.value = "Restoring database..."

            try {
                val result = withContext(Dispatchers.IO) {
                    HavenBridge.restoreDatabase(inputPath)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Database restored successfully"
                    Log.i(TAG, "Database restore completed: $inputPath")
                } else {
                    _exportStatusMessage.value = "Database restore failed"
                    Log.e(TAG, "Database restore failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Database restore error: ${e.message}", e)
                _exportStatusMessage.value = "Restore error: ${e.message}"
            } finally {
                _isExporting.value = false
            }
        }
    }

    /**
     * Restore Blossom media files from a zip backup into the blossom directory.
     * @param inputPath absolute path to the backup zip
     */
    fun importBlossom(inputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
            _exportStatusMessage.value = "Restoring media files..."

            try {
                val relayDataDir = File(context.filesDir, "relay_data")
                val blossomDir = File(relayDataDir, "blossom").absolutePath

                val result = withContext(Dispatchers.IO) {
                    HavenBridge.unzipDirectory(inputPath, blossomDir)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Media restored successfully"
                    Log.i(TAG, "Blossom restore completed: $inputPath")
                } else {
                    _exportStatusMessage.value = "Media restore failed"
                    Log.e(TAG, "Blossom restore failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Blossom restore error: ${e.message}", e)
                _exportStatusMessage.value = "Restore error: ${e.message}"
            } finally {
                _isExporting.value = false
            }
        }
    }

    /**
     * Dismiss the import completed state so the progress section hides.
     */
    fun dismissImportProgress() {
        _importCompleted.value = false
        _importProgress.value = 0f
        _importStatusMessage.value = ""
    }

    /**
     * Dismiss the export status message.
     */
    fun dismissExportStatus() {
        _exportStatusMessage.value = ""
    }

    /** Whether any operation is active (import or export). */
    val isBusy: Boolean
        get() = _isImporting.value || _isExporting.value

    // ── Internal ─────────────────────────────────────────────────

    private suspend fun pollImportProgress() {
        while (true) {
            try {
                val message = withContext(Dispatchers.IO) {
                    if (HavenBridge.isLoaded) HavenBridge.getImportLog() else null
                }
                if (!message.isNullOrBlank()) {
                    val entry = RelayLogParser.LogEntry.parse(message)
                    logStore.addEntry(entry)

                    // Extract progress from log messages
                    val batch = RelayLogParser.BatchedStateUpdate()
                    RelayLogParser.collectStateChanges(message, batch)

                    val progress = batch.importProgress
                    if (progress != null && progress > 0.0) {
                        _importProgress.value = progress.toFloat()
                    }
                    val statusMsg = batch.importStatusMessage
                    if (!statusMsg.isNullOrBlank()) {
                        _importStatusMessage.value = statusMsg
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Import poll error: ${e.message}")
            }
            delay(IMPORT_POLL_INTERVAL_MS)
        }
    }
}

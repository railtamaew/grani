package com.granivpn.mobile

import android.app.Activity
import android.content.Context
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import java.util.UUID

class QuickTileToggleActivity : AppCompatActivity() {
    companion object {
        private const val TAG = "QuickTileToggleActivity"
    }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocaleHelper.wrapContext(newBase))
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                startVpnFromPrefs()
            } else {
                finish()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            permissionLauncher.launch(permissionIntent)
        } else {
            startVpnFromPrefs()
        }
    }

    private fun startVpnFromPrefs() {
        if (NativeVpnRuntimeState.isAnyGraniVpnLikelyActive(this)) {
            QuickTileService.notifyVpnStateChanged(applicationContext)
            finish()
            return
        }

        val lastConfig = VpnPlugin.loadLastConfig(this)
        if (lastConfig == null) {
            Log.i(TAG, "quick_tile_permission: missing_last_config")
            QuickTileService.showQuickTileNotice(this, getString(R.string.quick_tile_missing_config))
            finish()
            return
        }

        Thread {
            val sessionId = newQuickTileSessionId()
            try {
                val result = VpnRuntimeCoordinator.connect(
                    applicationContext,
                    lastConfig.config,
                    lastConfig.protocol,
                    lastConfig.mtu,
                    source = "quick_tile_cached",
                    connectionSessionId = sessionId,
                    awaitReady = true,
                )
                if (!result.started) {
                    throw IllegalStateException(
                        "cached_config_start_failed_${result.backend}_" +
                            "${result.status?.name?.lowercase() ?: "unknown"}" +
                            (result.error?.let { "_$it" } ?: "")
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "quick_tile_permission_connect_failed", e)
                ProtocolRuntimeContract.markError(
                    applicationContext,
                    backend = null,
                    protocol = lastConfig.protocol,
                    sessionId = sessionId,
                    source = "quick_tile_cached_permission",
                    error = e.message ?: "quick_tile_permission_connect_failed",
                )
                QuickTileService.showQuickTileNotice(
                    applicationContext,
                    getString(R.string.quick_tile_connect_failed)
                )
            } finally {
                QuickTileService.notifyVpnStateChanged(applicationContext)
            }
        }.start()
        finish()
    }

    private fun newQuickTileSessionId(): String {
        return "qt-${UUID.randomUUID()}"
    }
}

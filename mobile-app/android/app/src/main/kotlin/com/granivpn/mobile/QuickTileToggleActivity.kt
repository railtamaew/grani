package com.granivpn.mobile

import android.app.Activity
import android.content.Context
import android.net.VpnService
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity

class QuickTileToggleActivity : AppCompatActivity() {

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
            QuickTileService.showQuickTileNotice(this, getString(R.string.quick_tile_no_config))
            finish()
            return
        }

        Thread {
            try {
                VpnRuntimeCoordinator.connect(
                    applicationContext,
                    lastConfig.config,
                    lastConfig.protocol,
                    lastConfig.mtu,
                    source = "quick_tile_cached",
                )
            } finally {
                QuickTileService.notifyVpnStateChanged(applicationContext)
            }
        }.start()
        finish()
    }
}

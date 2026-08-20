package com.granivpn.mobile

import android.app.Application
import android.util.Log
import io.flutter.app.FlutterApplication

/**
 * Avoid bootstrapping the Flutter engine in the isolated tun2socks worker.
 *
 * The worker only exposes a small AIDL service and loads libtun2socks. Running
 * FlutterLoader/Firebase initialization there makes every VLESS reconnect pay
 * the full application cold-start cost and can delay ServiceConnection long
 * enough to hit the binder timeout on slower devices.
 */
class GraniApplication : FlutterApplication() {
    override fun onCreate() {
        val processName = try {
            Application.getProcessName()
        } catch (_: Exception) {
            null
        }
        if (processName?.endsWith(":tun2socks") == true) {
            Log.i("GraniApplication", "lightweight worker bootstrap process=$processName")
            return
        }
        super.onCreate()
    }
}

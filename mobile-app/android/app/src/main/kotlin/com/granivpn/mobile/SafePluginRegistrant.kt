package com.granivpn.mobile

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine

object SafePluginRegistrant {
    private const val TAG = "SafePluginRegistrant"

    fun registerWith(flutterEngine: FlutterEngine) {
        register("connectivity_plus") {
            flutterEngine.plugins.add(dev.fluttercommunity.plus.connectivity.ConnectivityPlugin())
        }
        register("device_info_plus") {
            flutterEngine.plugins.add(dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin())
        }
        register("firebase_analytics") {
            flutterEngine.plugins.add(io.flutter.plugins.firebase.analytics.FlutterFirebaseAnalyticsPlugin())
        }
        register("firebase_core") {
            flutterEngine.plugins.add(io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin())
        }
        register("firebase_messaging") {
            flutterEngine.plugins.add(io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingPlugin())
        }
        register("flutter_secure_storage") {
            flutterEngine.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
        }
        register("google_sign_in_android") {
            flutterEngine.plugins.add(io.flutter.plugins.googlesignin.GoogleSignInPlugin())
        }
        register("in_app_purchase_android") {
            flutterEngine.plugins.add(io.flutter.plugins.inapppurchase.InAppPurchasePlugin())
        }
        register("package_info_plus") {
            flutterEngine.plugins.add(dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin())
        }
        register("path_provider_android") {
            flutterEngine.plugins.add(io.flutter.plugins.pathprovider.PathProviderPlugin())
        }
        register("share_plus") {
            flutterEngine.plugins.add(dev.fluttercommunity.plus.share.SharePlusPlugin())
        }
        register("shared_preferences_android") {
            flutterEngine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        }
        register("sqflite_android") {
            flutterEngine.plugins.add(com.tekartik.sqflite.SqflitePlugin())
        }
        register("url_launcher_android") {
            flutterEngine.plugins.add(io.flutter.plugins.urllauncher.UrlLauncherPlugin())
        }
        register("webview_flutter_android") {
            flutterEngine.plugins.add(io.flutter.plugins.webviewflutter.WebViewFlutterPlugin())
        }

        // Intentionally skipped:
        // billion.group.wireguard_flutter.WireguardFlutterPlugin()
        // This plugin assumes FlutterActivity and crashes with ClassCastException
        // on our FlutterFragmentActivity-based MainActivity.
    }

    private inline fun register(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.e(TAG, "Error registering plugin $name", e)
        }
    }
}

package com.granivpn.mobile

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * Синхронизирует [Configuration] нативного контекста с языком приложения из SharedPreferences Flutter
 * ([LocaleController], ключ `app_locale` → `flutter.app_locale`), чтобы системные диалоги
 * (VPN, уведомления, Google Sign-In) чаще совпадали с выбранным в приложении языком.
 */
object AppLocaleHelper {
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val APP_LOCALE_KEY = "flutter.app_locale"

    fun wrapContext(context: Context): Context {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val code = prefs.getString(APP_LOCALE_KEY, null)
            ?: prefs.getString("app_locale", null)
            ?: ""
        val lang = if (code.isNotEmpty()) code else "en"
        val locale = Locale.forLanguageTag(lang)
        Locale.setDefault(locale)
        val config = Configuration(context.resources.configuration)
        config.setLocale(locale)
        return context.createConfigurationContext(config)
    }
}

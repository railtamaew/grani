import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../storage/shared_preferences_holder.dart';

class LocaleController extends ChangeNotifier {
  static const _storageKey = 'app_locale';
  static const _fallbackLanguageCode = 'en';
  static const _supportedLanguageCodes = {'en', 'ru'};

  Locale _locale = const Locale(_fallbackLanguageCode);

  Locale get locale => _locale;
  bool get isRussian => _locale.languageCode == 'ru';

  Future<void> init() async {
    final prefs = await getSharedPreferences();
    final code = prefs.getString(_storageKey);
    if (code == null || code.isEmpty) {
      final platformCode =
          ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
      final initialCode = _supportedLanguageCodes.contains(platformCode)
          ? platformCode
          : _fallbackLanguageCode;
      _locale = Locale(initialCode);
      await prefs.setString(_storageKey, initialCode);
      return;
    }
    _locale = Locale(
        _supportedLanguageCodes.contains(code) ? code : _fallbackLanguageCode);
  }

  Future<void> setLocale(Locale locale) async {
    if (_locale.languageCode == locale.languageCode) return;
    _locale = locale;
    final prefs = await getSharedPreferences();
    await prefs.setString(_storageKey, locale.languageCode);
    // Только перестроение Flutter-дерева (MaterialApp.locale). Без Activity.recreate —
    // иначе сбрасывается engine и рвётся VPN / bootstrap.
    notifyListeners();
  }
}

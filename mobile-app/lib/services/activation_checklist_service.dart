import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/localized_messages.dart';
import 'in_app_event_banner_service.dart';

/// One lightweight, local-only activation step after the first proven tunnel.
/// No timer, polling, network request or background service is created.
class ActivationChecklistService {
  ActivationChecklistService._();

  static const _firstProofShownKey =
      'grani_activation_first_proof_banner_shown_v1';

  static Future<void> markFirstProofAndShow() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_firstProofShownKey) == true) return;
    await prefs.setBool(_firstProofShownKey, true);
    final isRu = LocalizedMessages.currentLanguageCode == 'ru';
    InAppEventBannerService.instance.show(
      title: isRu
          ? 'Первое подключение подтверждено'
          : 'First connection verified',
      body: isRu
          ? 'Шаг 1 из 2 готов. До конца пробного доступа проверьте GRANI ещё раз — в мобильной сети или на другом Wi‑Fi.'
          : 'Step 1 of 2 is complete. Before the trial ends, try GRANI again on mobile data or another Wi-Fi network.',
      data: const <String, dynamic>{
        'event': 'activation_first_proof',
        'activation_step': 1,
        'activation_target': 2,
      },
      actionLabel: isRu ? 'Понятно' : 'Got it',
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/l10n/app_localizations_ru.dart';
import 'package:mobile_app/l10n/app_localizations_en.dart';
import 'package:mobile_app/screens/main/vpn_shell_ui_helpers.dart';

void main() {
  test('release 44 connection context uses localized user-facing labels', () {
    final ru = AppLocalizationsRu();
    final en = AppLocalizationsEn();
    for (final l10n in [ru, en]) {
      expect(VpnShellUiHelpers.simpleConnectionBadge('Быстрое восстановление', l10n),
          l10n.vpnBadgeFastReconnect);
      expect(VpnShellUiHelpers.simpleConnectionBadge('Первичная настройка', l10n),
          l10n.vpnBadgeFirstSetup);
      expect(VpnShellUiHelpers.simpleConnectionBadge(null, l10n), isNull);
      expect(VpnShellUiHelpers.simpleConnectionBadge('', l10n), isNull);
    }
    expect(VpnShellUiHelpers.simpleConnectionBadge('Неизвестная внутренняя метка', en),
        isNull);
  });
}

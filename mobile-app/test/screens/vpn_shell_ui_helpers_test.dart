import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/l10n/app_localizations_ru.dart';
import 'package:mobile_app/screens/main/vpn_shell_ui_helpers.dart';

void main() {
  final l10n = AppLocalizationsRu();

  test('cache implementation labels are not shown as connection modes', () {
    expect(
      VpnShellUiHelpers.simpleConnectionBadge(
        'Быстрое восстановление',
        l10n,
      ),
      isNull,
    );
    expect(
      VpnShellUiHelpers.simpleConnectionBadge(
        'Первичная настройка',
        l10n,
      ),
      isNull,
    );
  });
}

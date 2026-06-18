/// Один бейдж «Это устройство» на списке для одной установки приложения:
/// сравниваем с локальным [currentDeviceId] из secure storage.
///
/// Если на аккаунте два *разных* [device_id] (клон приложения, вторая установка,
/// старый баг без слияния) — бейдж только у строки, совпадающей с локальным id;
/// у второго UUID бейджа не будет (это ожидаемо: «текущее» — то, что в storage).
///
/// Если API всё же вернул несколько строк с *одним* тем же [device_id] (наследие БД),
/// бейдж только у строки с максимальным числовым [id] (каноническая запись).
bool isCurrentDeviceCard(
  Map<String, dynamic> device,
  String? currentDeviceId,
  List<Map<String, dynamic>> allDevices,
) {
  final cur = currentDeviceId?.trim();
  if (cur == null || cur.isEmpty) return false;
  final apiId = (device['device_id'] as String? ?? '').trim();
  if (apiId.isEmpty || apiId != cur) return false;

  int rowId(Map<String, dynamic> x) {
    final v = x['id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? -1;
  }

  var bestId = -1;
  for (final x in allDevices) {
    if ((x['device_id'] as String? ?? '').trim() != apiId) continue;
    final id = rowId(x);
    if (id > bestId) bestId = id;
  }
  if (bestId < 0) return true;
  return rowId(device) == bestId;
}

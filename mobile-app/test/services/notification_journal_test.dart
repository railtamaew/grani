import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';
import 'package:mobile_app/services/notification_journal_service.dart';
import 'package:mobile_app/services/fcm_journal_policy.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async => (await getSharedPreferences()).clear());
  test('concurrent first writes survive reload and push plus sync deduplicate', () async {
    final journal = NotificationJournalService.test();
    await journal.setAccount('1');
    await Future.wait(List.generate(20, (i) => journal.append(
      title: 'Event $i', body: 'Body', source: 'in_app', eventId: '$i')));
    await journal.append(title: 'Event 1', body: 'Body', source: 'server', eventId: '1');
    expect(journal.entries.length, 20);
    final loaded = NotificationJournalService.test();
    await loaded.setAccount('1');
    expect(loaded.entries.length, 20);
  });
  test('account switch rejects late push or sync from previous account', () async {
    final journal = NotificationJournalService.test();
    await journal.setAccount('1');
    await journal.append(title: 'Gift', body: '', source: 'server', accountId: '1');
    await journal.setAccount('2');
    await journal.append(title: 'Late', body: '', source: 'server', accountId: '1');
    expect(journal.entries, isEmpty);
    await journal.setAccount('1');
    expect(journal.entries.single.title, 'Gift');
  });
  test('clear survives restart and server history does not reappear', () async {
    final journal = NotificationJournalService.test();
    await journal.setAccount('1');
    final past = DateTime.now().subtract(const Duration(minutes: 1));
    await journal.append(title: 'Old', body: '', source: 'server', receivedAt: past);
    await journal.clearAll();
    final loaded = NotificationJournalService.test();
    await loaded.setAccount('1');
    await loaded.append(title: 'Old', body: '', source: 'server', receivedAt: past);
    expect(loaded.entries, isEmpty);
    await loaded.append(title: 'New', body: '', source: 'in_app');
    expect(loaded.entries.single.title, 'New');
  });
  test('gift events and ordinary visible pushes are accepted, silent data is not', () {
    expect(FcmJournalPolicy.shouldAppendToJournal(const RemoteMessage(
      data: {'event': 'referral_gift_received'})), isTrue);
    expect(FcmJournalPolicy.shouldAppendToJournal(const RemoteMessage(
      notification: RemoteNotification(title: 'News'))), isTrue);
    expect(FcmJournalPolicy.shouldAppendToJournal(const RemoteMessage(
      data: {'internal': 'silent'})), isFalse);
  });
}

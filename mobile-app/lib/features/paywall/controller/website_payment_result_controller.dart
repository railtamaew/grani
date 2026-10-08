import 'package:flutter/foundation.dart';
import '../../../services/auth_service.dart';
import '../../../services/regional_checkout_service.dart';
import '../model/regional_checkout.dart';

/// Checks an existing purchase independently of eligibility for a new one.
class WebsitePaymentResultController extends ChangeNotifier {
  WebsitePaymentResultController({required this.auth, required this.service})
      : _accountId = auth.user?.id;
  final AuthService auth;
  final RegionalCheckoutService service;
  final String? _accountId;
  Map<String, dynamic>? context;
  RegionalOrder? order;
  bool loading = false;
  bool failed = false;
  bool checked = false;
  bool accessSynced = false;
  bool _disposed = false;

  bool get sameAccount => _accountId != null && auth.user?.id == _accountId;
  bool get paid => context?['state'] == 'completed' && order?.paid == true;
  bool get updatingAccess => order?.status == 'paid' && !paid;

  Future<void> refresh({bool reconcile = false}) async {
    if (loading || _disposed) return;
    if (!sameAccount) {
      context = null;
      order = null;
      failed = true;
      checked = true;
      notifyListeners();
      return;
    }
    loading = true;
    failed = false;
    notifyListeners();
    try {
      final previous = order;
      if (reconcile && previous != null && !previous.paid) {
        try {
          await service.status(previous.id, expectedEnvironment: 'production');
        } catch (_) {
          // The owned intent below remains authoritative; no order is created.
        }
      }
      final result = await service.websitePaymentResultContext();
      if (_disposed || !sameAccount) return;
      final raw = result?['order'];
      final parsed = raw is Map
          ? RegionalOrder.fromJson({
              ...Map<String, dynamic>.from(raw),
              'access_pending': result?['state'] == 'updating_access',
            })
          : null;
      if (parsed != null && parsed.environment != 'production') {
        throw const FormatException('Invalid result environment');
      }
      context = result;
      order = parsed;
      if (paid && !accessSynced) {
        try {
          await auth.refreshUserStatus(force: true);
          if (!_disposed && sameAccount) {
            accessSynced = auth.hasActiveSubscription;
          }
        } catch (_) {
          // Payment is verified, but local access must be refreshed separately.
        }
      }
    } catch (_) {
      if (!_disposed) failed = true;
    } finally {
      if (!_disposed) {
        if (!sameAccount) {
          context = null;
          order = null;
          accessSynced = false;
          failed = true;
        }
        loading = false;
        checked = true;
        notifyListeners();
      }
    }
  }

  Future<void> acknowledgeCompleted() async {
    if (sameAccount && paid && accessSynced) {
      await service.acknowledgePaymentResult(context!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

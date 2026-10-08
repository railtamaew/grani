import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/gift_receive_state.dart';
import '../services/gift_presentation_policy.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../core/session/post_auth_preparation_coordinator.dart';
import '../services/auth_service.dart';
import '../services/referral_service.dart';
import '../services/install_attribution_service.dart';
import '../widgets/grani_gift_art.dart';
import '../theme.dart';

enum GiftScreenMode { send, receive, bonuses }

String giftDuration(int seconds, bool ru) {
  final minutes = (seconds.clamp(0, 1 << 40) / 60).floor();
  final days = minutes ~/ 1440;
  final hours = (minutes % 1440) ~/ 60;
  String dayWord(int n) => n % 100 >= 11 && n % 100 <= 14
      ? 'дней'
      : n % 10 == 1
          ? 'день'
          : n % 10 >= 2 && n % 10 <= 4
              ? 'дня'
              : 'дней';
  if (days > 0)
    return ru
        ? '$days ${dayWord(days)}${hours > 0 ? ' $hours ч' : ''}'
        : '$days ${days == 1 ? 'day' : 'days'}${hours > 0 ? ' $hours h' : ''}';
  if (hours > 0)
    return ru ? '$hours ч ${minutes % 60} мин' : '$hours h ${minutes % 60} min';
  if (seconds > 0 && minutes == 0)
    return ru ? 'Меньше минуты' : 'Less than a minute';
  if (minutes > 0) return ru ? '$minutes мин' : '$minutes min';
  return ru ? '0 дней' : '0 days';
}

class ReferralsScreen extends StatefulWidget {
  const ReferralsScreen({
    super.key,
    this.service,
    this.mode = GiftScreenMode.send,
  });
  final ReferralService? service;
  final GiftScreenMode mode;
  @override
  State<ReferralsScreen> createState() => _ReferralsScreenState();
}

class _ReferralsScreenState extends State<ReferralsScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _offer;
  String? _error;
  String? _notice;
  String? _pending;
  bool _loading = true;
  bool _busy = false;
  bool _celebrate = false;
  int _loadId = 0;
  AuthService? _auth;
  String? _authIdentity;
  String _identity(AuthService auth) =>
      auth.isAuthenticated && auth.token != null
          ? service.presentationAccount(auth.token!)
          : 'signed_out';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthService>();
    if (!identical(_auth, auth)) {
      _auth?.removeListener(_authChanged);
      _auth = auth;
      _authIdentity = _identity(auth);
      auth.addListener(_authChanged);
    }
  }

  void _authChanged() {
    final auth = _auth;
    if (!mounted || auth == null || _authIdentity == _identity(auth)) return;
    _authIdentity = _identity(auth);
    _loadId++;
    setState(() {
      _data = null;
      _offer = null;
      _notice = null;
      _error = null;
      _pending = null;
      _code.clear();
      _celebrate = false;
      _loading = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  final _code = TextEditingController();
  final _noticeKey = GlobalKey();
  ReferralService get service => widget.service ?? ReferralService.instance;
  bool get ru => Localizations.localeOf(context).languageCode == 'ru';
  String t(String a, String b) => ru ? a : b;
  int get reward =>
      (_data?['reward_days'] as num? ?? _offer?['reward_days'] as num? ?? 3)
          .toInt();
  int get limit => (_data?['monthly_limit'] as num? ?? 5).toInt();
  int get remaining => (_data?['rewards_remaining'] as num? ?? 0).toInt();
  Map? get received =>
      _data?['received'] is Map ? _data!['received'] as Map : null;
  String date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return t('уточняется', 'updating');
    return DateFormat(
      'd MMM y, HH:mm',
      ru ? 'ru' : 'en',
    ).format(parsed.toLocal());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth?.removeListener(_authChanged);
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_busy && !_loading)
      _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final request = ++_loadId;
    final auth = context.read<AuthService>();
    final identity = _identity(auth);
    bool current() =>
        mounted && request == _loadId && identity == _identity(auth);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var pending = await service.pendingCode();
      Map<String, dynamic>? data;
      Map<String, dynamic>? offer;
      String? notice;
      var celebrate = false;
      if (auth.isAuthenticated) {
        await auth.ensureValidToken();
        if (!current()) return;
        final token = auth.token;
        if (token == null) throw const ReferralFailure('account_unverified');
        if (widget.mode == GiftScreenMode.receive) {
          if (await service.claimPending(token))
            await auth.refreshUserStatus(force: true);
          notice = await service.claimNotice(token);
          pending = await service.pendingCode();
        }
        data = await service.summary(token);
        if (!current()) return;
        final result = data['received'];
        if (widget.mode == GiftScreenMode.receive &&
            result is Map &&
            notice == 'applied') {
          celebrate = await consumeGiftCelebration(
            service.presentationAccount(token),
            result,
          );
        }
        if (widget.mode == GiftScreenMode.receive && pending == null) {
          await service.finishGiftView();
          await InstallAttributionService.instance.clearGiftRoute();
        }
      } else if (widget.mode == GiftScreenMode.receive && pending != null) {
        offer = await service.offer(pending);
      }
      if (!current()) return;
      _data = data;
      _offer = offer;
      _notice = notice;
      _pending = pending;
      _celebrate = celebrate;
      await InstallAttributionService.instance.logLifecycleEvent(
        'referral_screen_view',
        once: false,
        extra: {'surface': widget.mode.name},
      );
    } catch (_) {
      if (current())
        _error = t(
          'Не удалось проверить приглашение. Оно сохранено — повторите проверку.',
          'Could not check your invitation. It is saved — try again.',
        );
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  String failure(String code) => switch (code) {
        'invalid_code' => t(
            'Проверьте код приглашения.',
            'Check your invitation code.',
          ),
        'invitation_unavailable' => t(
            'Это приглашение недоступно. Попросите друга прислать другое.',
            'This invitation is unavailable. Ask your friend for another one.',
          ),
        'self_referral' => t(
            'Это ваш код. Для получения нужен подарок от друга.',
            'This is your code. Use a friend’s invitation.',
          ),
        'already_claimed' => t(
            'Вы уже получили подарок по другому приглашению.',
            'You have already received a gift from another invitation.',
          ),
        'claim_window_expired' => t(
            'Срок получения подарка для этого аккаунта закончился.',
            'The gift claim period for this account has ended.',
          ),
        'existing_customer' => t(
            'Этот подарок предназначен для новых пользователей.',
            'This gift is for new users.',
          ),
        'device_already_used' => t(
            'Это устройство уже участвовало в программе подарков.',
            'This device has already participated in the gift program.',
          ),
        'campaign_limit' => t(
            'Все подарки этой программы уже разобрали.',
            'All gifts in this campaign have been claimed.',
          ),
        'account_unverified' => t(
            'Войдите и подтвердите аккаунт.',
            'Sign in and verify your account.',
          ),
        'campaign_unavailable' => t(
            'Подарки временно недоступны. Приглашение сохранено.',
            'Gifts are temporarily unavailable. Your invitation is saved.',
          ),
        _ => t(
            'Пока не удалось применить подарок. Повторите попытку.',
            'We could not apply your gift yet. Please try again.',
          ),
      };

  Future<void> _claim() async {
    if (_busy) return;
    final auth = context.read<AuthService>();
    final identity = _identity(auth);
    bool current() => mounted && identity == _identity(auth);
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (!auth.isAuthenticated) {
        if (ReferralService.normalizeCode(_code.text) == null)
          throw const ReferralFailure('invalid_code');
        await service.replacePendingCode(_code.text);
        await _load();
        return;
      }
      await auth.ensureValidToken();
      if (!current()) return;
      final token = auth.token;
      // Save before the request so a lost response/process restart can be retried.
      if (ReferralService.normalizeCode(_code.text) == null)
        throw const ReferralFailure('invalid_code');
      await service.replacePendingCode(_code.text);
      if (!current()) return;
      await service.claimPending(token);
      if (!current()) return;
      await _load();
      if (current() && received != null) {
        await auth.refreshUserStatus(force: true);
      }
    } on ReferralFailure catch (e) {
      if (current()) _notice = e.code;
    } catch (_) {
      if (current()) _notice = 'network_error';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final c = _noticeKey.currentContext;
          if (c != null)
            Scrollable.ensureVisible(
              c,
              duration: const Duration(milliseconds: 200),
              alignment: .7,
            );
        });
      }
    }
  }

  Future<void> _googleSignIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final auth = context.read<AuthService>();
      await service.rememberGiftReturn();
      final result = await auth.signInWithGoogle();
      if (!mounted) return;
      if (result.isSuccess) {
        Navigator.pushNamedAndRemoveUntil(
          context,
          '/post-auth-preparation',
          (_) => false,
          arguments: const PostAuthPreparationArguments(source: 'gift_google'),
        );
      } else if (result.isError) {
        setState(
          () => _error = result.errorMessage ??
              t(
                'Не удалось войти. Попробуйте ещё раз.',
                'Could not sign in. Try again.',
              ),
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error = t(
            'Не удалось войти. Попробуйте ещё раз.',
            'Could not sign in. Try again.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy || _data?['enabled'] != true || _data?['share_url'] is! String)
      return;
    setState(() => _busy = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      final benefit = remaining > 0
          ? t(
              '\nПосле твоего первого подключения длительностью от минуты мне начислят $reward бонусных дня.',
              '\nAfter your first connection lasting at least a minute, I’ll receive $reward bonus days.',
            )
          : '';
      final text = t(
        'Приглашаю тебя в GRANI VPN 🎁\n7 дней пробного доступа для новых пользователей. Открой ссылку и войди в GRANI. Карта не нужна.$benefit\n${_data!['share_url']}',
        'Try GRANI VPN with my invitation 🎁\nA 7-day trial for new users. Open the link and sign in to GRANI. No card needed.$benefit\n${_data!['share_url']}',
      );
      await InstallAttributionService.instance.logLifecycleEvent(
        'referral_share_open',
        once: false,
      );
      await Share.share(
        text,
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _error = t(
            'Не удалось открыть меню отправки.',
            'Could not open the share menu.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    bool secondary = false,
  }) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      backgroundColor:
          secondary ? GraniTheme.surfaceControl : GraniTheme.buttonPrimary,
      foregroundColor: secondary ? GraniTheme.primaryText : GraniTheme.white,
      disabledBackgroundColor: GraniTheme.surfaceInset,
      disabledForegroundColor: GraniTheme.secondaryText,
      textStyle: GraniTheme.bodyMedium.copyWith(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
        side: secondary
            ? const BorderSide(color: GraniTheme.surfaceControlBorder)
            : BorderSide.none,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: FilledButton(
        style: style,
        onPressed: _busy ? null : onPressed,
        child: Text(
          label,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _text(String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(
          value,
          style: GraniTheme.bodyMedium.copyWith(
            fontSize: 15,
            height: 1.45,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
  Widget _title(String value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          value,
          style: GraniTheme.detailPageTitle.copyWith(height: 1.25),
        ),
      );
  Widget _errorMessage(String value) => Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: GraniTheme.errorBackground,
            borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline,
                  color: GraniTheme.errorText, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  value,
                  style: GraniTheme.bodyMedium.copyWith(
                    fontSize: 15,
                    height: 1.45,
                    color: GraniTheme.errorText,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  Widget _card(List<Widget> children, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: GraniTheme.graniSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  void _rules() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: GraniTheme.surfaceBase,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GraniTheme.radiusSurface),
          ),
        ),
        builder: (c) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _title(t('Условия подарка', 'Gift terms')),
                _text(
                  t(
                    'Один подарок для нового аккаунта без истории подписок. Подарок предоставляет GRANI — дни отправителя не расходуются.',
                    'One gift for a new account with no subscription history. GRANI provides the gift; the sender’s days are not used.',
                  ),
                ),
                _text(
                  (_data?['claim_policy'] ?? _offer?['claim_policy']) ==
                          'first_trial'
                      ? t(
                          'Примите подарок до окончания обычного первого триала. Общая длительность увеличится до 7 дней с начала триала; дата старта не меняется.',
                          'Accept before your first standard trial ends. Its total duration becomes 7 days from the original trial start; it does not restart.',
                        )
                      : t(
                          'Код можно применить в первые 24 часа после регистрации. Доступ длится 7 дней всего с начала триала; дата старта не меняется.',
                          'Apply within 24 hours of registration. Access lasts 7 days total from the original trial start; it does not restart.',
                        ),
                ),
                _text(
                  t(
                    'За первое подключение друга длительностью от минуты в течение подарочного периода — $reward бонусных дня после проверки сервером. До $limit наград за календарный месяц UTC. После месячного лимита можно продолжать дарить, пока программа доступна.',
                    'After a friend’s first connection lasting at least a minute during the gift period, the server confirms $reward bonus days. Up to $limit rewards per UTC calendar month. You can keep giving gifts after your monthly reward limit while the campaign is available.',
                  ),
                ),
                _text(
                  t(
                    'Количество подарков программы ограничено. Карта не нужна, автоматической оплаты за пробный доступ нет. Бонусные дни используются после текущего доступа; новые покупки сохраняют их на будущее.',
                    'Campaign gifts are limited. No card or automatic trial charge. Bonus days are used after current access; new purchases preserve them for later.',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  List<Widget> _sender(bool authenticated) => [
        const Center(child: GraniGiftArt(size: 148)),
        _title(t('Другу — 7 дней GRANI', '7 days of GRANI for a friend')),
        _text(
          t(
            'Бесплатный пробный доступ для нового пользователя. Карта не нужна.',
            'A free trial for a new user. No card needed.',
          ),
        ),
        _card([
          _text(
            t('Вам — $reward бонусных дня', '$reward bonus days for you'),
            bold: true,
          ),
          _text(
            t(
              'Начислим после первого подключения друга длительностью от минуты.',
              'Earn them after your friend’s first connection lasting at least a minute.',
            ),
          ),
          _text(
            t(
              'Подарок предоставляет GRANI. Ваши дни не расходуются.',
              'GRANI provides the gift. Your days are not used.',
            ),
          ),
        ]),
        if (!authenticated)
          _button(
            t('Войти и подарить', 'Sign in to give a gift'),
            () => Navigator.pushNamed(context, '/'),
          )
        else if (_data?['enabled'] == true)
          _button(t('Отправить подарок', 'Send a gift'), _share)
        else
          _text(
            _data?['unavailable_reason'] == 'update_required'
                ? t(
                    'Обновите GRANI, чтобы отправлять подарки.',
                    'Update GRANI to send gifts.',
                  )
                : t(
                    'Новые подарки временно недоступны. Уже полученный доступ сохраняется.',
                    'New gifts are temporarily unavailable. Existing access is preserved.',
                  ),
          ),
        if (authenticated && _data != null)
          _text(
            remaining > 0
                ? t(
                    'В этом месяце можно получить ещё $remaining из $limit наград за друзей.',
                    'You can earn $remaining more of $limit friend rewards this month.',
                  )
                : t(
                    'Лимит наград на месяц достигнут. Друг всё ещё может получить подарок, пока программа доступна.',
                    'Your monthly reward limit is reached. Friends can still receive gifts while the campaign is available.',
                  ),
          ),
        TextButton(
          onPressed: _rules,
          child: Text(t('Условия подарка', 'Gift terms')),
        ),
        if (authenticated)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Мои бонусы', 'My bonuses')),
            subtitle: (_data?['bonus_seconds'] as num? ?? 0) > 0
                ? Text(
                    giftDuration((_data!['bonus_seconds'] as num).toInt(), ru))
                : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/gift/bonuses'),
          ),
      ];

  Future<void> _exitGift() async {
    await service.finishGiftView();
    await InstallAttributionService.instance.clearGiftRoute();
    if (mounted)
      Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
  }

  Future<void> _anotherCode() async {
    await service.clearClaimNotice();
    if (mounted)
      setState(() {
        _notice = null;
        _code.clear();
      });
  }

  Future<void> _pasteCode() async {
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = (value?.text ?? '').trim().toUpperCase();
    _code.text = text.substring(0, text.length.clamp(0, 16));
    setState(() => _notice = null);
  }

  Widget _codeForm({String? error}) => _card([
        TextField(
          controller: _code,
          maxLength: 16,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          onChanged: (_) => setState(() {
            if (_notice == 'invalid_code') _notice = null;
          }),
          decoration: InputDecoration(
            counterText: '',
            labelText: t('Код приглашения', 'Invitation code'),
            errorText: error,
            labelStyle: GraniTheme.bodyMedium.copyWith(height: 1.25),
            filled: true,
            fillColor: GraniTheme.surfaceRaised,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
              borderSide:
                  const BorderSide(color: GraniTheme.surfaceControlBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
              borderSide:
                  const BorderSide(color: GraniTheme.buttonPrimary, width: 1.5),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _busy ? null : _pasteCode,
            icon: const Icon(Icons.content_paste),
            label: Text(t('Вставить код', 'Paste code')),
          ),
        ),
        _button(
          t('Применить код', 'Apply code'),
          ReferralService.normalizeCode(_code.text) == null ? null : _claim,
        ),
      ], key: _noticeKey);

  List<Widget> _receiver(bool authenticated) {
    final eligibility =
        _data?['eligibility'] is Map ? _data!['eligibility'] as Map : null;
    final state = giftReceiveState(
      authenticated: authenticated,
      hasInvitation: _pending != null,
      eligibility: eligibility,
      received: received,
      offer: _offer ?? _data,
      notice: _notice,
      requestFailed: _error != null,
    );
    final canReplace = !authenticated || canEnterAnotherGiftCode(eligibility);
    final body = <Widget>[];
    if (state == GiftReceiveState.activated ||
        state == GiftReceiveState.ended) {
      final ended = state == GiftReceiveState.ended;
      body.addAll([
        Center(
          child: GraniGiftArt(
            key: ValueKey('gift-result-$_celebrate'),
            size: 148,
            animate: _celebrate && !ended,
          ),
        ),
        _title(
          ended
              ? t('Подарочный период завершён', 'Gift period ended')
              : t('Подарок активирован', 'Gift activated'),
        ),
        _text(
          ended
              ? t(
                  'Подарочный доступ действовал до ${date(received!['trial_expires_at'])}.',
                  'Gift access ended on ${date(received!['trial_expires_at'])}.',
                )
              : t(
                  'GRANI доступен до ${date(received!['trial_expires_at'])}.',
                  'GRANI access until ${date(received!['trial_expires_at'])}.',
                ),
          bold: true,
        ),
        if (!ended)
          _text(
            t(
              'Ваш пробный период увеличен до 7 дней. Можно пользоваться VPN — карта не нужна.',
              'Your trial has been extended to 7 days. You can use VPN — no card needed.',
            ),
          ),
        _button(t('Перейти к VPN', 'Go to VPN'), _exitGift),
        if (!ended && received!['status'] == 'pending')
          _text(
            t(
              'После минуты подключения друг получит ${received!['reward_days'] ?? reward} бонусных дня.',
              'After a one-minute connection, your friend will earn ${received!['reward_days'] ?? reward} bonus days.',
            ),
          ),
        if (!ended && received!['status'] == 'monthly_limit')
          _text(
            t(
              'Друг достиг месячного лимита наград. Ваш подарок действует.',
              'Your friend reached the monthly reward limit. Your gift remains valid.',
            ),
          ),
      ]);
    } else {
      body.add(
        Center(
          child: state == GiftReceiveState.accountUnavailable
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Icon(
                    Icons.error_outline,
                    size: 72,
                    color: GraniTheme.errorText,
                  ),
                )
              : const GraniGiftArt(size: 148, animate: false),
        ),
      );
      switch (state) {
        case GiftReceiveState.ownInvitation:
          body.addAll([
            _title(t('Это ваше приглашение', 'This is your invitation')),
            _text(
              t(
                'Отправьте его другу — он сможет получить 7 дней GRANI. Активировать своё приглашение для себя нельзя.',
                'Send it to a friend so they can get 7 days of GRANI. You cannot activate your own invitation.',
              ),
            ),
            if (_data?['enabled'] == true)
              _button(t('Отправить другу', 'Send to a friend'), _share),
            if (authenticated && canEnterAnotherGiftCode(eligibility))
              TextButton(
                onPressed: _anotherCode,
                child: Text(
                  t(
                    'Ввести код от другого друга',
                    'Enter another friend’s code',
                  ),
                ),
              ),
          ]);
          break;
        case GiftReceiveState.accountUnavailable:
          final expired = DateTime.tryParse(
                eligibility?['claim_before']?.toString() ?? '',
              )?.isAfter(DateTime.now()) ==
              false;
          final reason = expired
              ? 'claim_window_expired'
              : eligibility?['reason']?.toString() ??
                  _notice ??
                  'existing_customer';
          body.addAll([
            _title(
              t(
                'Подарок недоступен этому аккаунту',
                'This account cannot receive a gift',
              ),
            ),
            _errorMessage(failure(reason)),
            _text(
              t(
                'Ваш действующий доступ не изменился.',
                'Your existing access has not changed.',
              ),
            ),
          ]);
          break;
        case GiftReceiveState.retry:
          body.addAll([
            _title(
              t(
                'Не удалось проверить приглашение',
                'Could not check the invitation',
              ),
            ),
            _text(
              t(
                'Приглашение сохранено. Проверьте соединение и повторите попытку.',
                'Your invitation is saved. Check your connection and try again.',
              ),
            ),
            _button(t('Повторить проверку', 'Try again'), _load),
          ]);
          break;
        case GiftReceiveState.campaignUnavailable:
          body.addAll([
            _title(
              t('Подарки сейчас недоступны', 'Gifts are unavailable right now'),
            ),
            _text(failure(_notice ?? 'campaign_unavailable')),
            _button(
              t('Проверить ещё раз', 'Check again'),
              _load,
              secondary: true,
            ),
          ]);
          break;
        case GiftReceiveState.signIn:
          body.addAll([
            _title(t('Вам прислали приглашение', 'You have an invitation')),
            _text(
              t(
                'Приглашение сохранено. После входа проверим аккаунт и покажем результат.',
                'Your invitation is saved. After sign-in, we will check your account and show the result.',
              ),
            ),
            if (!authenticated) ...[
              if (defaultTargetPlatform != TargetPlatform.windows)
                _button(
                  t('Продолжить с Google', 'Continue with Google'),
                  _googleSignIn,
                ),
              _button(t('Войти по email', 'Continue with email'), () async {
                await service.rememberGiftReturn();
                if (mounted) Navigator.pushNamed(context, '/auth-email');
              }, secondary: true),
            ] else
              _button(t('Проверить приглашение', 'Check invitation'), _load),
          ]);
          break;
        case GiftReceiveState.enterCode:
        case GiftReceiveState.invalidInvitation:
          body.addAll([
            _title(
              t('Есть приглашение от друга?', 'Have a friend’s invitation?'),
            ),
            _text(
              t(
                'Введите код, который вам прислали. По приглашению общий пробный период можно увеличить до 7 дней.',
                'Enter the code your friend sent. An invitation can extend your total trial to 7 days.',
              ),
            ),
            if (canReplace)
              _codeForm(
                error: state == GiftReceiveState.invalidInvitation
                    ? failure(
                        _offer?['reason'] == 'invitation_unavailable'
                            ? 'invitation_unavailable'
                            : 'invalid_code',
                      )
                    : null,
              ),
          ]);
          break;
        case GiftReceiveState.activated:
        case GiftReceiveState.ended:
          break;
      }
      if (authenticated)
        body.add(
          _button(
            t('Вернуться к VPN', 'Back to VPN'),
            _exitGift,
            secondary: true,
          ),
        );
    }
    body.add(
      TextButton(
        onPressed: _rules,
        child: Text(t('Условия подарка', 'Gift terms')),
      ),
    );
    return body;
  }

  List<Widget> _bonuses() {
    final seconds = (_data?['bonus_seconds'] as num? ?? 0).toInt();
    final rows =
        _data?['history'] is List ? _data!['history'] as List : const [];
    final mode = _data?['bonus_usage'];
    final renewing = _data?['subscription_auto_renew'] == true ||
        mode == 'after_renewal_stops';
    final explanation = seconds == 0
        ? t(
            'Здесь появятся дополнительные дни, когда ваши друзья примут приглашение и выполнят условие подключения.',
            'Additional days appear here when your friends accept an invitation and complete the connection requirement.',
          )
        : mode == 'active'
            ? t(
                'Бонусный доступ действует до ${date(_data?['bonus_expires_at'])}.',
                'Bonus access is active until ${date(_data?['bonus_expires_at'])}.',
              )
            : renewing
                ? t(
                    'Дни сохранены. Они начнут использоваться после окончания оплаченного доступа, если подписка больше не продлится. Пока подписка продлевается, бонусы ждут.',
                    'Your days are saved. They start after paid access ends if your subscription does not renew. Bonuses wait while it renews.',
                  )
                : t(
                    'Бонусные дни начнут использоваться ${date(_data?['bonus_starts_at'])}, после окончания текущего доступа.',
                    'Bonus days start on ${date(_data?['bonus_starts_at'])}, after your current access ends.',
                  );
    return [
      _text(
        t('Бонусы за приглашённых друзей', 'Bonuses for inviting friends'),
        bold: true,
      ),
      _card([
        _title(giftDuration(seconds, ru)),
        _text(explanation),
        if (seconds > 0 &&
            mode != 'active' &&
            !renewing &&
            _data?['bonus_expires_at'] != null)
          _text(
            t(
              'Если не будет новых покупок, доступ продлится до ${date(_data?['bonus_expires_at'])}.',
              'With no further purchases, access will last until ${date(_data?['bonus_expires_at'])}.',
            ),
            bold: true,
          ),
        if (seconds > 0 && mode != 'active')
          _text(
            t(
              'При новой покупке бонусы сохранятся и будут использованы позже.',
              'A new purchase preserves your bonuses and moves their use to a later date.',
            ),
          ),
        if (seconds > 0 && renewing)
          _text(
            t(
              'Дата списания подписки не меняется.',
              'Your subscription billing date does not change.',
            ),
          ),
      ]),
      if (received != null)
        _text(
          t(
            'Подарок, который вы получили, относится к вашему пробному доступу и не входит в этот баланс.',
            'The gift you received is part of your trial access and is separate from this balance.',
          ),
        ),
      _text(t('История начислений', 'Reward history'), bold: true),
      if (rows.isEmpty)
        _text(
          t(
            'Пока нет бонусов за приглашения друзей.',
            'No friend rewards yet.',
          ),
        ),
      for (final raw in rows)
        if (raw is Map)
          _card([
            _text(
                switch (raw['status']) {
                  'rewarded' => t(
                      '+${giftDuration((raw['reward_days'] as num).toInt() * 86400, ru)} за приглашение друга',
                      '+${giftDuration((raw['reward_days'] as num).toInt() * 86400, ru)} for inviting a friend',
                    ),
                  'monthly_limit' => t(
                      'Друг подключился. Месячный лимит наград достигнут.',
                      'Your friend connected. The monthly reward limit was reached.',
                    ),
                  'expired' => t(
                      'Срок подарка истёк. Подключение не подтверждено.',
                      'The gift expired without a verified connection.',
                    ),
                  'ineligible' => t(
                      'Бонус не начислен: условия участия не выполнены.',
                      'No reward: participation requirements were not met.',
                    ),
                  _ => t(
                      'Друг принял приглашение. Ждём подключения.',
                      'Your friend accepted. Waiting for their connection.',
                    ),
                },
                bold: true),
            if (raw['status'] == 'rewarded')
              _text(
                t(
                  'Друг выполнил условие подключения.',
                  'Your friend completed the connection requirement.',
                ),
              ),
            _text(date(raw['rewarded_at'] ?? raw['accepted_at'])),
          ]),
      if (rows.length >= 50)
        _text(
          t('Показаны последние 50 записей.', 'Showing the latest 50 entries.'),
        ),
      _button(
        t('Подарить другу', 'Give a friend a gift'),
        () => Navigator.pushNamed(context, '/referrals'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final authenticated = context.watch<AuthService>().isAuthenticated;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: GraniTheme.white,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: GraniTheme.surfaceBase,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: GraniTheme.surfaceBase,
        appBar: AppBar(
          backgroundColor: GraniTheme.white,
          foregroundColor: GraniTheme.primaryText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          title: Text(
            switch (widget.mode) {
              GiftScreenMode.send =>
                t('Подарить другу', 'Give a friend a gift'),
              GiftScreenMode.receive => t('Получить подарок', 'Receive a gift'),
              GiftScreenMode.bonuses => t('Мои бонусы', 'My bonuses'),
            },
            style: GraniTheme.detailPageTitle,
          ),
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: GraniTheme.devicesScreenBackgroundGradient,
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                          children: [
                            if (_error != null &&
                                widget.mode != GiftScreenMode.receive) ...[
                              _errorMessage(_error!),
                              _button(
                                t('Повторить', 'Try again'),
                                _load,
                                secondary: true,
                              ),
                            ],
                            ...switch (widget.mode) {
                              GiftScreenMode.send => _sender(authenticated),
                              GiftScreenMode.receive =>
                                _receiver(authenticated),
                              GiftScreenMode.bonuses => authenticated
                                  ? _bonuses()
                                  : [
                                      _button(
                                        t('Войти', 'Sign in'),
                                        () => Navigator.pushNamed(context, '/'),
                                      ),
                                    ],
                            },
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

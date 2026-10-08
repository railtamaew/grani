import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../models/profile_access_snapshot.dart';
import '../grani_avatar.dart';
import 'access_avatar_policy.dart';

/// The existing 58px circle. Identity and earned appearance never grant access.
class GraniAccessAvatar extends StatefulWidget {
  static const enabledByDefault =
      bool.fromEnvironment('GRANI_PROFILE_AVATARS', defaultValue: true);
  const GraniAccessAvatar(
      {super.key,
      required this.access,
      required this.kind,
      this.accountKey = '',
      this.charactersEnabled = enabledByDefault});
  final ProfileAccessSnapshot access;
  final ProfileAccessKind kind;
  final String accountKey;
  final bool charactersEnabled;
  @override
  State<GraniAccessAvatar> createState() => _GraniAccessAvatarState();
}

class _GraniAccessAvatarState extends State<GraniAccessAvatar> {
  ScrollPosition? _position;
  bool _visible = false, _checkScheduled = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_scheduleVisibility);
      _position = position;
      position?.addListener(_scheduleVisibility);
    }
    _scheduleVisibility();
  }

  void _scheduleVisibility() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final avatarRect = MatrixUtils.transformRect(
          box.getTransformTo(null), Offset.zero & box.size);
      final viewport = RenderAbstractViewport.maybeOf(box);
      final viewportObject = viewport is RenderObject ? viewport : null;
      final viewportRect = viewportObject == null
          ? Offset.zero & MediaQuery.sizeOf(context)
          : MatrixUtils.transformRect(
              viewportObject.getTransformTo(null), viewportObject.paintBounds);
      final visible = avatarRect.overlaps(viewportRect) &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          TickerMode.of(context);
      if (visible != _visible) setState(() => _visible = visible);
    });
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleVisibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleVisibility();
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    final correctAccount = widget.accountKey.isEmpty ||
        widget.access.accountKey == widget.accountKey;
    final type = widget.charactersEnabled && correctAccount
        ? accessAvatarType(widget.access, widget.access.capturedAt)
        : null;
    final paid = widget.kind == ProfileAccessKind.paid;
    const fallback = _OfficialMark();
    final names = ru
        ? const [
            'Искра',
            'Проводник',
            'Навигатор',
            'Хранитель',
            'Мастер граней',
            'Легенда'
          ]
        : const [
            'Spark',
            'Guide',
            'Navigator',
            'Keeper',
            'Master of Facets',
            'Legend'
          ];
    final art = type == null
        ? Semantics(
            label: ru ? 'Аватар GRANI' : 'GRANI avatar',
            image: true,
            child: const ExcludeSemantics(child: fallback))
        : GraniAvatar(
            key: ValueKey('avatar-${widget.accountKey}-${type.name}'),
            type: type,
            size: 58,
            isVisible: _visible,
            placeholder: fallback,
            semanticLabel: ru
                ? 'Аватар ${names[type.index]}'
                : '${names[type.index]} avatar',
            semanticHint: ru ? 'Воспроизвести реакцию' : 'Play reaction');
    return SizedBox.square(
        dimension: 58,
        child: DecoratedBox(
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    paid ? const Color(0xFFFFE9B9) : const Color(0xFFD8EDF7)),
            child: Stack(fit: StackFit.expand, children: [
              ClipOval(child: art),
              IgnorePointer(
                  child: DecoratedBox(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              width: 1.5,
                              color: paid
                                  ? const Color(0xFFB58A48)
                                  : const Color(0xFF80B4CE))))),
            ])));
  }
}

class _OfficialMark extends StatelessWidget {
  const _OfficialMark();
  @override
  Widget build(BuildContext context) => Center(
      child: SvgPicture.asset('assets/images/logo_new.svg',
          width: 30, height: 30, excludeFromSemantics: true));
}

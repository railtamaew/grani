import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/privacy_policy_document.dart';
import 'tv_ui.dart';

class TvPrivacyScreen extends StatefulWidget {
  const TvPrivacyScreen({super.key});
  @override
  State<TvPrivacyScreen> createState() => _TvPrivacyScreenState();
}

class _TvPrivacyScreenState extends State<TvPrivacyScreen> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TvPage(
        title: tvText(context, 'Конфиденциальность', 'Privacy'),
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent || !_scroll.hasClients)
              return KeyEventResult.ignored;
            final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
                ? 1
                : event.logicalKey == LogicalKeyboardKey.arrowUp
                    ? -1
                    : 0;
            if (direction == 0) return KeyEventResult.ignored;
            final next = (_scroll.offset + direction * 140).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            );
            if (next == _scroll.offset) return KeyEventResult.ignored;
            _scroll.jumpTo(next);
            return KeyEventResult.handled;
          },
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: SingleChildScrollView(
              controller: _scroll,
              child: const PrivacyPolicyDocument(),
            ),
          ),
        ),
      );
}

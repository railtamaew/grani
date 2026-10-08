import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/profile/profile_ui_kit.dart';

const tvBackground = GraniTheme.surfaceBase;
const tvSurface = GraniTheme.surfaceSoft;
const tvAccent = GraniTheme.warmAccent;
const tvMuted = GraniTheme.secondaryText;
String tvText(BuildContext context, String ru, String en) =>
    Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

// The phone theme is the single source of visual tokens.
ThemeData tvTheme() => GraniTheme.theme.copyWith(
      scaffoldBackgroundColor: tvBackground,
      dialogTheme: const DialogThemeData(
          backgroundColor: GraniTheme.surfaceRaised,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(22)))),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: const TextStyle(color: tvMuted, fontWeight: FontWeight.w300),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(32)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(32),
            borderSide:
                const BorderSide(color: GraniTheme.surfaceControlBorder)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(32),
            borderSide:
                const BorderSide(color: GraniTheme.primaryText, width: 1.5)),
      ),
    );

class TvPage extends StatelessWidget {
  const TvPage(
      {super.key,
      required this.title,
      required this.child,
      this.actions = const [],
      this.leading,
      this.showBack = true,
      this.contentWidth = 640});
  final String title;
  final Widget child;
  final List<Widget> actions;
  final Widget? leading;
  final bool showBack;
  final double contentWidth;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
            decoration: const BoxDecoration(
                gradient: GraniTheme.startScreenBackgroundGradient),
            child: SafeArea(
                child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                        height: 60,
                        child: Row(children: [
                          Expanded(
                              child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: leading ??
                                      (showBack &&
                                              Navigator.of(context).canPop()
                                          ? TvButton(
                                              label: tvText(
                                                  context, 'Назад', 'Back'),
                                              compact: true,
                                              icon: Icons.arrow_back_rounded,
                                              onPressed: () =>
                                                  Navigator.of(context).pop())
                                          : const SizedBox.shrink()))),
                          Image.asset('assets/images/figma/logo_grani_new.png',
                              width: GraniTheme.logoWidth * 1.08,
                              height: GraniTheme.logoHeight * 1.08,
                              fit: BoxFit.contain,
                              semanticLabel: 'GRANI'),
                          Expanded(
                              child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: actions)),
                        ])),
                    const SizedBox(height: 12),
                    if (title.isNotEmpty) ...[
                      Text(title,
                          textAlign: TextAlign.center,
                          style: GraniTheme.headingSmall.copyWith(height: 1.2)),
                      const SizedBox(height: 20),
                    ],
                    Expanded(
                        child: Align(
                            alignment: Alignment.topCenter,
                            child:
                                SizedBox(width: contentWidth, child: child))),
                  ]),
            ))),
      );
}

/// Adds one remote focus target without changing the mobile artwork.
/// Excluding child focus targets ensures OK activates the control only once.
class TvRemoteControl extends StatefulWidget {
  const TvRemoteControl(
      {super.key,
      required this.child,
      required this.onPressed,
      this.autofocus = false,
      this.circular = false,
      this.label});
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final bool circular;
  final String? label;
  @override
  State<TvRemoteControl> createState() => _TvRemoteControlState();
}

class _TvRemoteControlState extends State<TvRemoteControl> {
  late final _focus = FocusNode(onKeyEvent: (_, event) {
    if (const [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space
    ].contains(event.logicalKey)) {
      if (event is KeyDownEvent) {
        debugPrint('TvRemote: activate key=${event.logicalKey.keyLabel} '
            'synthesized=${event.synthesized} enabled=${widget.onPressed != null}');
        widget.onPressed?.call();
      }
      // Consume the complete press, including a held remote button, before
      // another shortcut or an embedded mobile control can activate it.
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  });
  bool _focused = false;
  @override
  void didUpdateWidget(TvRemoteControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onPressed == null &&
        widget.onPressed != null &&
        widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final current = FocusManager.instance.primaryFocus;
        if (current == null || current is FocusScopeNode) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        // Keep the main connection target focused while a stop/restoration
        // temporarily disables its action. Otherwise Android TV traversal
        // jumps to the gift/profile control when the button becomes busy.
        enabled: widget.onPressed != null || widget.autofocus,
        autofocus: widget.autofocus,
        focusNode: _focus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          })
        },
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused)
            Scrollable.ensureVisible(context,
                alignment: .5, duration: const Duration(milliseconds: 100));
        },
        child: Semantics(
            button: true,
            enabled: widget.onPressed != null,
            onTap: widget.onPressed,
            label: widget.label,
            child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                    shape:
                        widget.circular ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius:
                        widget.circular ? null : BorderRadius.circular(22),
                    border: Border.all(
                        width: 2,
                        color: _focused
                            ? GraniTheme.connectionButtonRingBlue
                            : Colors.transparent)),
                child: ExcludeFocus(child: widget.child))),
      );
}

class TvButton extends StatefulWidget {
  const TvButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.icon,
      this.autofocus = false,
      this.primary = false,
      this.selected = false,
      this.focusNode,
      this.compact = false,
      this.textOnly = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool autofocus, primary, selected, compact, textOnly;
  final FocusNode? focusNode;
  @override
  State<TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<TvButton> {
  final _ownedFocus = FocusNode();
  @override
  void didUpdateWidget(TvButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onPressed == null &&
        widget.onPressed != null &&
        widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            widget.onPressed == null ||
            ModalRoute.of(context)?.isCurrent != true) return;
        final current = FocusManager.instance.primaryFocus;
        if (current == null || current is FocusScopeNode) {
          (widget.focusNode ?? _ownedFocus).requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        onFocusChange: (focused) {
          if (focused)
            Scrollable.ensureVisible(context,
                alignment: .5, duration: const Duration(milliseconds: 100));
        },
        child: DecoratedBox(
          decoration: widget.primary || widget.textOnly
              ? const BoxDecoration()
              : GraniTheme.graniSurfaceDecoration(
                  radius:
                      widget.compact ? GraniTheme.selectorButtonRadius : 22),
          child: FilledButton(
            autofocus: widget.autofocus,
            focusNode: widget.focusNode ?? _ownedFocus,
            onPressed: widget.onPressed,
            style: ButtonStyle(
              minimumSize:
                  WidgetStatePropertyAll(Size(0, widget.compact ? 42 : 56)),
              padding: WidgetStatePropertyAll(EdgeInsets.symmetric(
                  horizontal: widget.compact ? 16 : 22,
                  vertical: widget.compact ? 10 : 16)),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(widget.primary ? 32 : 22))),
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  widget.primary
                      ? GraniTheme.buttonPrimary.withValues(
                          alpha: states.contains(WidgetState.disabled) ? .4 : 1)
                      : Colors.transparent),
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  (widget.primary ? Colors.white : GraniTheme.primaryText)
                      .withValues(
                          alpha:
                              states.contains(WidgetState.disabled) ? .45 : 1)),
              overlayColor: WidgetStatePropertyAll(
                  GraniTheme.primaryText.withValues(alpha: .06)),
              side: WidgetStateProperty.resolveWith((states) => BorderSide(
                  width: 2,
                  color: states.contains(WidgetState.focused)
                      ? GraniTheme.connectionButtonRingBlue
                      : widget.selected
                          ? tvAccent
                          : Colors.transparent)),
            ),
            child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: widget.compact ? 18 : 22),
                    const SizedBox(width: 10)
                  ],
                  Flexible(
                      child: Text(widget.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: widget.compact
                                  ? GraniTheme.selectorButtonTextSize
                                  : 16,
                              height: 1.2,
                              fontWeight: widget.compact
                                  ? FontWeight.w600
                                  : FontWeight.w400))),
                ]),
          ),
        ),
      );
}

class TvNotice extends StatelessWidget {
  const TvNotice(this.message, {super.key, this.error = false});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(18),
      decoration: GraniTheme.graniSurfaceDecoration(
          borderColor: error ? GraniTheme.errorCoral : null),
      child: Text(message,
          style: TextStyle(
              fontSize: 16,
              height: 1.35,
              color: error ? GraniTheme.errorCoral : GraniTheme.primaryText)));
}

Future<void> showTvNotice(BuildContext context, String message) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(message,
                style: const TextStyle(fontSize: 16, height: 1.4))),
        actions: [
          TvButton(
              label: tvText(context, 'Понятно', 'OK'),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop())
        ],
      ),
    );

/// The phone profile row and its SVG icons, with remote activation.
class TvProfileRow extends StatelessWidget {
  const TvProfileRow(
      {super.key,
      required this.label,
      required this.asset,
      required this.onPressed,
      this.autofocus = false});
  final String label, asset;
  final VoidCallback? onPressed;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TvRemoteControl(
        autofocus: autofocus,
        onPressed: onPressed,
        child: GraniSectionCard(
            padding: EdgeInsets.zero,
            child: GraniSectionRow(
                iconSvg: 'assets/images/figma/profile/$asset',
                label: label,
                onTap: onPressed,
                enabled: onPressed != null)),
      );
}

import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Decode at display resolution and play a single cycle while this route is visible.
/// The original transparent artwork is bundled unchanged; no animation dependency.
class GraniGiftArt extends StatefulWidget {
  const GraniGiftArt({super.key, this.size = 72, this.animate = true});
  final double size;
  final bool animate;
  @override
  State<GraniGiftArt> createState() => _GraniGiftArtState();
}

class _GraniGiftArtState extends State<GraniGiftArt>
    with WidgetsBindingObserver {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  int _index = 0;
  bool _loading = false;
  bool _nextInFlight = false;
  bool _motion = false;
  bool _foreground = true;
  bool _failed = false;
  Duration _duration = const Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion =
        widget.animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context);
    if (!_loading && _codec == null && !_failed) {
      _load();
    }
    if (!_motion) {
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  @override
  void didUpdateWidget(covariant GraniGiftArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion =
        widget.animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context);
    if (!_motion) {
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  Future<void> _load() async {
    _loading = true;
    final pixels = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    try {
      final bytes = await rootBundle.load(
        'assets/images/gift/grani_gift_lid_open.webp',
      );
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        targetWidth: pixels,
      );
      if (!mounted) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _next();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _schedule() {
    if (!mounted ||
        !_foreground ||
        !_motion ||
        _failed ||
        _codec == null ||
        _nextInFlight ||
        _index >= _codec!.frameCount ||
        _timer != null)
      return;
    _timer = Timer(_duration, () {
      _timer = null;
      _next();
    });
  }

  Future<void> _next() async {
    final codec = _codec;
    if (codec == null || _nextInFlight) return;
    _nextInFlight = true;
    try {
      final result = await codec.getNextFrame();
      if (!mounted) {
        result.image.dispose();
        return;
      }
      final old = _frame;
      setState(() {
        _frame = result.image;
        _index++;
        _duration = result.duration;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _nextInFlight = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _codec?.dispose();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: _frame != null
              ? Stack(
                  children: [
                    Positioned.fill(
                      child: RawImage(image: _frame, fit: BoxFit.contain),
                    ),
                    // The original animation has a baked Russian label.
                    // Keep its gift artwork and halo; render the label in
                    // Flutter for both languages, without another icon.
                    Positioned(
                      left: widget.size * .23,
                      top: widget.size * .644,
                      width: widget.size * .55,
                      height: widget.size * .18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            widget.size * .09,
                          ),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xffff7b00), Color(0xffff5b00)],
                          ),
                          border: Border.all(
                            color: Colors.white.withOpacity(.8),
                            width: widget.size * .002,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            ru ? '7 дней' : '7 days',
                            maxLines: 1,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              fontFamily: 'GraniGiftMontserrat',
                              fontSize: widget.size * .098,
                              height: 1,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.card_giftcard,
                      size: widget.size * .48,
                      color: const Color(0xffff6b00),
                    ),
                    Text(
                      ru ? '7 дней' : '7 days',
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        fontFamily: 'GraniGiftMontserrat',
                        fontSize: widget.size * .16,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xffdf5100),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// Approved GRANI layers and gestures, adapted for the existing profile circle.
// This renderer has no billing, network, rank storage or entitlement logic.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

enum GraniAvatarType { iskra, guide, navigator, keeper, master, legend }

class GraniAvatarViewport {
  const GraniAvatarViewport(this.center, this.zoom);
  final Offset center;
  final double zoom;
  static const values = {
    GraniAvatarType.iskra: GraniAvatarViewport(Offset(218, 239), 1.18),
    GraniAvatarType.guide: GraniAvatarViewport(Offset(218, 239), 1.13),
    GraniAvatarType.navigator: GraniAvatarViewport(Offset(224, 238), 1),
    GraniAvatarType.keeper: GraniAvatarViewport(Offset(224, 239), 1.16),
    GraniAvatarType.master: GraniAvatarViewport(Offset(224, 237), 1.09),
    GraniAvatarType.legend: GraniAvatarViewport(Offset(228, 242), .98),
  };
}

class GraniAvatar extends StatefulWidget {
  const GraniAvatar(
      {super.key,
      required this.type,
      this.size = 58,
      this.assetRoot = 'assets/grani_avatars',
      this.playToken = 0,
      this.retryToken = 0,
      this.animateOnTap = true,
      this.motionEnabled = true,
      this.isVisible = true,
      this.semanticLabel,
      this.semanticHint,
      this.placeholder = const SizedBox.shrink(),
      this.onTap,
      @visibleForTesting this.previewProgress})
      : assert(size > 0);
  final GraniAvatarType type;
  final double size;
  final String assetRoot;
  final int playToken, retryToken;
  final bool animateOnTap, motionEnabled, isVisible;
  final String? semanticLabel, semanticHint;
  final Widget placeholder;
  final VoidCallback? onTap;
  final double? previewProgress;
  @override
  State<GraniAvatar> createState() => _GraniAvatarState();
}

class _GraniAvatarState extends State<GraniAvatar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  Map<String, ui.Image> _images = {};
  _AvatarSpec? _spec;
  String? _loadKey;
  AssetBundle? _bundle;
  int _generation = 0;
  bool _foreground = true, _allowed = true, _failed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final life = WidgetsBinding.instance.lifecycleState;
    _foreground = life == null || life == AppLifecycleState.resumed;
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1700));
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) _controller.value = 0;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshPermission();
    _ensureAssets();
  }

  @override
  void didUpdateWidget(covariant GraniAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshPermission();
    if (oldWidget.type != widget.type ||
        oldWidget.assetRoot != widget.assetRoot ||
        oldWidget.size != widget.size) {
      _stop();
      _ensureAssets();
    } else if (oldWidget.retryToken != widget.retryToken ||
        (!oldWidget.isVisible && widget.isVisible && _failed)) {
      _ensureAssets(retry: true);
    }
    if (oldWidget.playToken != widget.playToken) _play();
  }

  void _refreshPermission() {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _allowed = widget.motionEnabled &&
        widget.isVisible &&
        !reduced &&
        _foreground &&
        TickerMode.of(context);
    if (!_allowed) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) setState(_refreshPermission);
  }

  void _disposeAfterPaint(Map<String, ui.Image> images) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in images.values) {
        image.dispose();
      }
    });
  }

  void _ensureAssets({bool retry = false}) {
    final bundle = DefaultAssetBundle.of(context);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    final zoom = GraniAvatarViewport.values[widget.type]!.zoom;
    final physical = (widget.size * zoom * dpr).ceil().clamp(1, 384).toInt();
    final key = '${widget.assetRoot}/${widget.type.name}/$physical';
    if (_loadKey == key && identical(_bundle, bundle) && !(_failed && retry))
      return;
    _loadKey = key;
    _bundle = bundle;
    _failed = false;
    _disposeAfterPaint(_images);
    _images = {};
    _spec = null;
    _load(bundle, key, ++_generation, physical, widget.type);
  }

  Future<void> _load(AssetBundle bundle, String key, int ticket, int physical,
      GraniAvatarType type) async {
    final loaded = <String, ui.Image>{};
    try {
      final raw = await bundle.loadString('${widget.assetRoot}/manifest.json',
          cache: false);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final coordinateSize = (json['coordinateSize'] as num).toDouble();
      if (coordinateSize != 448)
        throw const FormatException('Unsupported avatar coordinates');
      final data = (json['avatars'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((row) => row['id'] == type.name);
      final spec = _AvatarSpec.fromJson(data);
      if (!spec.layers.any((l) => l.name == 'body') ||
          !spec.layers.any((l) => l.name == 'head') ||
          spec.durationMs < 100 ||
          spec.durationMs > 5000) {
        throw const FormatException('Invalid avatar layers');
      }
      for (final layer in spec.layers) {
        if (!RegExp(r'^[a-zA-Z0-9_]+\.webp$').hasMatch(layer.file) ||
            !layer.rect.width.isFinite ||
            layer.rect.width <= 0) {
          throw const FormatException('Invalid avatar asset');
        }
        final buffer = await bundle.load('${widget.assetRoot}/${layer.file}');
        final width =
            math.max(1, (layer.rect.width / coordinateSize * physical).ceil());
        final codec = await ui.instantiateImageCodec(
            buffer.buffer
                .asUint8List(buffer.offsetInBytes, buffer.lengthInBytes),
            targetWidth: width,
            allowUpscaling: false);
        try {
          loaded[layer.file] = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
        if (!mounted || ticket != _generation) {
          for (final image in loaded.values) {
            image.dispose();
          }
          return;
        }
      }
      if (!mounted || ticket != _generation || _loadKey != key) {
        for (final image in loaded.values) {
          image.dispose();
        }
        return;
      }
      setState(() {
        _images = loaded;
        _spec = spec;
        _controller.duration = Duration(milliseconds: spec.durationMs);
      });
    } catch (error) {
      for (final image in loaded.values) {
        image.dispose();
      }
      if (mounted && ticket == _generation) {
        setState(() => _failed = true);
        debugPrint('GRANI avatar: failed to load $key: $error');
      }
    }
  }

  bool _play() {
    if (!_allowed || _controller.isAnimating || _spec == null) return false;
    _controller.forward(from: 0);
    return true;
  }

  void _tap() {
    if (!_allowed || _controller.isAnimating || _spec == null) return;
    if (widget.animateOnTap) _play();
    widget.onTap?.call();
  }

  void _stop() {
    _controller.stop();
    _controller.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final interactive = _allowed &&
        spec != null &&
        (widget.animateOnTap || widget.onTap != null);
    final label = widget.semanticLabel ?? 'GRANI avatar';
    final progress = widget.previewProgress == null
        ? _controller
        : AlwaysStoppedAnimation<double>(
            widget.previewProgress!.clamp(0, 1).toDouble());
    return Semantics(
        label: label,
        hint: interactive ? widget.semanticHint : null,
        button: interactive,
        image: !interactive,
        onTap: interactive ? _tap : null,
        child: ExcludeSemantics(
            child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: interactive ? _tap : null,
                child: RepaintBoundary(
                    child: SizedBox.square(
                        dimension: widget.size,
                        child: spec == null
                            ? widget.placeholder
                            : CustomPaint(
                                key: ValueKey('grani-avatar-art-${spec.id}'),
                                painter: _AvatarPainter(
                                    spec: spec,
                                    index: widget.type.index,
                                    images: _images,
                                    progress: progress,
                                    viewport: GraniAvatarViewport
                                        .values[widget.type]!),
                                isComplex: true))))));
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }
}

class _Layer {
  _Layer(this.name, this.file, this.rect);
  final String name;
  final String file;
  final Rect rect;
  factory _Layer.fromJson(Map<String, dynamic> j) {
    final r = (j['rect'] as List<dynamic>).cast<num>();
    return _Layer(
        j['name'] as String,
        j['file'] as String,
        Rect.fromLTWH(r[0].toDouble(), r[1].toDouble(), r[2].toDouble(),
            r[3].toDouble()));
  }
}

class _AvatarSpec {
  _AvatarSpec(this.id, this.name, this.durationMs, this.accent, this.headPivot,
      this.seam, this.layers);
  final String id;
  final String name;
  final int durationMs;
  final Color accent;
  final Offset headPivot;
  final List<Offset> seam;
  final List<_Layer> layers;
  factory _AvatarSpec.fromJson(Map<String, dynamic> j) {
    Offset point(dynamic value) {
      final p = (value as List<dynamic>).cast<num>();
      return Offset(p[0].toDouble(), p[1].toDouble());
    }

    return _AvatarSpec(
        j['id'] as String,
        j['name'] as String,
        (j['durationMs'] as num).toInt(),
        Color(int.parse((j['accent'] as String).replaceFirst('#', 'ff'),
            radix: 16)),
        point(j['headPivot']),
        (j['seam'] as List<dynamic>).map(point).toList(),
        (j['layers'] as List<dynamic>)
            .map((e) => _Layer.fromJson(e as Map<String, dynamic>))
            .toList());
  }
  _Layer layer(String name) => layers.firstWhere((l) => l.name == name);
}

double _clamp(double v) => v.clamp(0.0, 1.0).toDouble();
double _smooth(double v) {
  v = _clamp(v);
  return v * v * (3 - 2 * v);
}

double _phase(double p, double a, double b) => _smooth((p - a) / (b - a));
double _bump(double p, double a, double b, double c, double d) =>
    _phase(p, a, b) * (1 - _phase(p, c, d));
double _blink(double p, double c, double w) =>
    1 - .93 * math.exp(-math.pow((p - c) / w, 4));

class _Pose {
  double headAngle = 0,
      headX = 0,
      headY = 0,
      eyeScale = 1,
      gaze = 0,
      open = 0,
      signal = 0,
      route = 0;
}

_Pose _pose(int index, double progress) {
  final p = _clamp(progress), r = _Pose();
  if (p == 0 || p == 1) return r;
  final a = _bump(p, .05, .27, .66, .98);
  final b = _bump(p, .12, .4, .64, .98);
  switch (index) {
    case 0:
      r.headAngle = (-1.55 * a + .55 * b) * math.pi / 180;
      r.headY = -1.5 * a;
      r.eyeScale = _blink(p, .36, .046);
      r.gaze = 2.5 * b;
      r.signal = .24 * b;
      break;
    case 1:
      r.headAngle = .75 * a * math.pi / 180;
      r.headY = -a;
      r.signal = _bump(p, .06, .23, .74, .98);
      r.eyeScale = _blink(p, .79, .04);
      break;
    case 2:
      r.headAngle = 1.8 * a * math.pi / 180;
      r.headX = 1.6 * a;
      r.gaze = 2.6 * a;
      r.route = _phase(p, .08, .9) * 2 * math.pi;
      r.signal = .6 * a;
      r.eyeScale = _blink(p, .87, .032);
      break;
    case 3:
      r.headAngle = -.7 * a * math.pi / 180;
      r.open = b;
      r.signal = .78 * b;
      r.eyeScale = _blink(p, .78, .04);
      break;
    case 4:
      r.headY = -1.3 * b;
      r.open = b;
      r.signal = .65 * b;
      r.eyeScale = _blink(p, .83, .034);
      break;
    case 5:
      r.headY = -2 * b;
      r.open = b;
      r.route = _phase(p, .08, .92) * 2 * math.pi;
      r.signal = .8 * b;
      r.eyeScale = _blink(p, .86, .035);
      break;
  }
  return r;
}

class _Transform {
  const _Transform(this.dx, this.dy, this.angle);
  final double dx, dy, angle;
}

_Transform _layerTransform(int index, String name, _Pose p) {
  if (name == 'frameL') {
    if (index == 3) return const _Transform(0, 0, 0);
    return _Transform(-(index == 5 ? 7 : 5) * p.open, -2 * p.open,
        -(index == 5 ? 5 : 3) * math.pi / 180 * p.open);
  }
  if (name == 'frameR') {
    return _Transform(
        (index == 5
                ? 7
                : index == 3
                    ? 4
                    : 5) *
            p.open,
        -2 * p.open,
        (index == 5
                ? 5
                : index == 3
                    ? 3.5
                    : 3) *
            math.pi /
            180 *
            p.open);
  }
  return const _Transform(0, 0, 0);
}

class _Ring {
  const _Ring(this.cx, this.cy, this.rx, this.ry, this.angle);
  final double cx, cy, rx, ry, angle;
  Offset at(double t) {
    final x = math.cos(t) * rx, y = math.sin(t) * ry;
    return Offset(cx + x * math.cos(angle) - y * math.sin(angle),
        cy + x * math.sin(angle) + y * math.cos(angle));
  }
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter(
      {required this.spec,
      required this.index,
      required this.images,
      required this.progress,
      required this.viewport})
      : super(repaint: progress);
  final _AvatarSpec spec;
  final int index;
  final Map<String, ui.Image> images;
  final Animation<double> progress;
  final GraniAvatarViewport viewport;
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  void _layer(Canvas c, _Layer l) {
    final im = images[l.file];
    if (im == null) return;
    c.drawImageRect(
        im,
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
        l.rect,
        _imagePaint);
  }

  void _transform(Canvas c, Offset pivot, double dx, double dy, double angle,
      VoidCallback draw) {
    c.save();
    c.translate(pivot.dx + dx, pivot.dy + dy);
    c.rotate(angle);
    c.translate(-pivot.dx, -pivot.dy);
    draw();
    c.restore();
  }

  Path _polyline(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  Offset _onPath(List<Offset> points, double t) {
    final lengths = <double>[];
    for (var i = 0; i < points.length - 1; i++) {
      lengths.add((points[i + 1] - points[i]).distance);
    }
    var distance = _clamp(t) * lengths.fold(0.0, (a, b) => a + b);
    for (var i = 0; i < lengths.length; i++) {
      if (distance <= lengths[i] || i == lengths.length - 1) {
        final u = _clamp(distance / lengths[i]);
        return Offset.lerp(points[i], points[i + 1], u)!;
      }
      distance -= lengths[i];
    }
    return points.first;
  }

  void _dot(
      Canvas c, Offset point, double radius, Color color, double opacity) {
    if (opacity <= 0) return;
    final alpha = _clamp(opacity), extent = radius * 3.3;
    final paint = Paint()
      ..shader = ui.Gradient.radial(point, extent, [
        color.withOpacity(alpha),
        color.withOpacity(alpha * .75),
        color.withOpacity(0)
      ], [
        0,
        .25,
        1
      ]);
    c.drawCircle(point, extent, paint);
    c.drawCircle(point, radius * .63,
        Paint()..color = const Color(0xfffffef5).withOpacity(alpha));
  }

  void _seam(Canvas c, _Pose p, double value) {
    if (p.signal < .001) return;
    final path = _polyline(spec.seam);
    c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = spec.accent.withOpacity(p.signal)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = spec.accent.withOpacity(p.signal));
    c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xfffff8df).withOpacity(p.signal));
    _dot(c, _onPath(spec.seam, _phase(value, .12, .78)), 3.5, spec.accent,
        p.signal);
  }

  _Ring? get _ring {
    if (index == 2) return _Ring(223, 219, 191, 55, -21 * math.pi / 180);
    if (index == 5) return _Ring(228, 258, 193, 52, -4 * math.pi / 180);
    return null;
  }

  void _drawRing(Canvas c, _Pose p, bool front) {
    final r = _ring;
    if (r == null || (index == 2 && front)) return;
    final start = index == 2
        ? 0.0
        : front
            ? 0.0
            : math.pi;
    final end = index == 2
        ? 2 * math.pi
        : front
            ? math.pi
            : 2 * math.pi;
    final points = List<Offset>.generate(
        101, (k) => r.at(start + (end - start) * k / 100));
    final path = _polyline(points);
    c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
              const Offset(50, 160), const Offset(400, 310), [
            const Color(0xff407d99),
            const Color(0xffb8edfb),
            const Color(0xff34b3de)
          ], [
            0,
            .45,
            1
          ]));
    c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xffdffaff));
    final theta = (index == 2 ? -.12 : 0.0) + p.route;
    final t = ((theta % (2 * math.pi)) + 2 * math.pi) % (2 * math.pi);
    final visible = index == 2 || (front ? t <= math.pi : t >= math.pi);
    if (visible) {
      final point = r.at(theta);
      if (index == 2) {
        final next = r.at(theta + .015);
        final angle = math.atan2(next.dy - point.dy, next.dx - point.dx);
        c.save();
        c.translate(point.dx, point.dy);
        c.rotate(angle);
        final arrow = Path()
          ..moveTo(16, 0)
          ..lineTo(-13, -10)
          ..lineTo(-7, 0)
          ..lineTo(-13, 10)
          ..close();
        c.drawPath(
            arrow,
            Paint()
              ..color = const Color(0x70f8ac48)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
        c.drawPath(
            arrow,
            Paint()
              ..shader = ui.Gradient.linear(
                  const Offset(-13, -10),
                  const Offset(15, 9),
                  [const Color(0xffffd092), const Color(0xffdf7317)]));
        c.drawPath(
            arrow,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = .8
              ..color = const Color(0xfffff2d7));
        c.restore();
      } else {
        _dot(c, point, 7, const Color(0xff27b7eb), 1);
      }
    }
    if (index == 2 || front) {
      _dot(c, r.at(math.pi), index == 2 ? 7 : 4.5, const Color(0xffffad33), 1);
    }
  }

  void _frameLights(Canvas c, _Pose p) {
    if (index < 3 || p.open < .001) return;
    for (final l in spec.layers.where((l) => l.name.startsWith('frame'))) {
      final left = l.name == 'frameL';
      if (index == 3 && left) continue;
      final tr = _layerTransform(index, l.name, p);
      final pivot = Offset(l.rect.center.dx, l.rect.bottom);
      final at = Offset(l.rect.left + l.rect.width * (left ? .36 : .65),
          l.rect.top + l.rect.height * .58);
      _transform(c, pivot, tr.dx, tr.dy, tr.angle,
          () => _dot(c, at, 3, spec.accent, .38 * p.open));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.width * viewport.zoom / 448);
    canvas.translate(-viewport.center.dx, -viewport.center.dy);
    final value = progress.value, p = _pose(index, value);
    _drawRing(canvas, p, false);
    for (final l in spec.layers.where((l) => l.name.startsWith('frame'))) {
      final tr = _layerTransform(index, l.name, p);
      _transform(canvas, Offset(l.rect.center.dx, l.rect.bottom), tr.dx, tr.dy,
          tr.angle, () => _layer(canvas, l));
    }
    _frameLights(canvas, p);
    _layer(canvas, spec.layer('body'));
    _transform(canvas, spec.headPivot, p.headX, p.headY, p.headAngle, () {
      _layer(canvas, spec.layer('head'));
      _seam(canvas, p, value);
      for (final eye in spec.layers.where((l) => l.name.startsWith('eye'))) {
        final center = eye.rect.center;
        canvas.save();
        canvas.translate(center.dx + p.gaze, center.dy);
        canvas.scale(1, p.eyeScale);
        canvas.translate(-center.dx, -center.dy);
        _layer(canvas, eye);
        canvas.restore();
      }
    });
    _drawRing(canvas, p, true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AvatarPainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.index != index ||
      !identical(oldDelegate.images, images) ||
      oldDelegate.progress != progress ||
      oldDelegate.viewport != viewport;
}

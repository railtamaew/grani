import 'dart:async';
import 'package:flutter/material.dart';

/// Виджет для анимации точек в тексте
/// 
/// Пример: "Подключение" → "Подключение." → "Подключение.." → "Подключение..." → "Подключение"
/// 
/// Анимация работает только когда isActive == true
/// При смене состояния анимация останавливается мгновенно
class DotsText extends StatefulWidget {
  /// Базовый текст без точек (например, "Подключение")
  final String baseText;
  
  /// Стиль текста
  final TextStyle? style;
  
  /// Активна ли анимация (true только в состоянии connecting)
  final bool isActive;
  
  /// Длительность одного шага (по умолчанию 280 мс)
  final Duration step;

  const DotsText({
    super.key,
    required this.baseText,
    required this.isActive,
    this.style,
    this.step = const Duration(milliseconds: 280),
  });

  @override
  State<DotsText> createState() => _DotsTextState();
}

class _DotsTextState extends State<DotsText> {
  Timer? _timer;
  int _dots = 0;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant DotsText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _sync();
    }
  }

  void _sync() {
    _timer?.cancel();
    if (!widget.isActive) {
      setState(() => _dots = 0);
      return;
    }
    _timer = Timer.periodic(widget.step, (_) {
      if (!mounted) return;
      setState(() => _dots = (_dots + 1) % 4); // 0..3
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.baseText + ('.' * _dots);
    return Text(text, style: widget.style);
  }
}




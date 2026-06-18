import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../theme.dart';

// Custom TextInputFormatter для обработки вставки из буфера обмена
class _PasteInputFormatter extends TextInputFormatter {
  final int index;
  final Function(String, int) onPaste;

  _PasteInputFormatter(this.index, this.onPaste);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Если вставлен текст длиной > 1, обрабатываем как вставку
    if (newValue.text.length > 1) {
      // Извлекаем только цифры из вставленного текста
      final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');

      if (digits.isNotEmpty) {
        // Вызываем обработчик вставки
        Future.microtask(() => onPaste(digits, index));
        // Возвращаем только первую цифру для текущей ячейки
        return TextEditingValue(
          text: digits[0],
          selection: TextSelection.collapsed(offset: 1),
        );
      }
    }
    return newValue;
  }
}

// Custom TextInputFormatter для обработки backspace на пустой ячейке
class _PinCodeInputFormatter extends TextInputFormatter {
  final int index;
  final Function(int) onBackspaceOnEmpty;

  _PinCodeInputFormatter(this.index, this.onBackspaceOnEmpty);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Если текст стал пустым (backspace), и ячейка уже была пуста
    if (newValue.text.isEmpty && oldValue.text.isEmpty && index > 0) {
      // Вызываем обработчик backspace на пустой ячейке
      Future.microtask(() => onBackspaceOnEmpty(index));
    }
    return newValue;
  }
}

// Intent для обработки backspace через Shortcuts
class _BackspaceIntent extends Intent {
  const _BackspaceIntent();
}

/// Виджет для ввода PIN-кода из 4 цифр
/// Автоматически переходит между ячейками при вводе
///
/// Согласно ТЗ:
/// - Размеры слота: 70×100px (60×85px для экранов <360px)
/// - Radius: 25px
/// - Gap между слотами: 10px (8px для маленьких экранов)
/// - Типографика: Montserrat 40px (24px для маленьких), weight 650-700, color #1A1A1A, line-height 120%
/// - Состояние ошибки: цвет #E63946, обводка #E63946 40%, вибрация, автоочистка — [GraniTheme.authPinErrorClearDelay]
class PinCodeInput extends StatefulWidget {
  const PinCodeInput({
    super.key,
    this.onCompleted,
    this.onChanged,
    this.onFocusChanged,
    this.autoFocus = true,
    this.isError = false,
    required this.scaleX,
    required this.scaleY,
  });

  final ValueChanged<String>? onCompleted;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChanged;
  final bool autoFocus;
  final bool isError;
  final double scaleX;
  final double scaleY;

  @override
  State<PinCodeInput> createState() => PinCodeInputState();
}

class PinCodeInputState extends State<PinCodeInput>
    with SingleTickerProviderStateMixin {
  final List<TextEditingController> _controllers = List.generate(
    4,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(
    4,
    (_) => FocusNode(),
  );
  final List<String> _pin = List.filled(4, '');
  bool _isErrorState = false;

  /// Один вызов onCompleted на полный PIN (listener + paste/autofill не дублируют POST).
  bool _completionNotified = false;
  Timer? _completionDebounce;
  Timer? _errorTimer;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _isErrorState = widget.isError;

    // Shake анимация для ошибки
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(
        parent: _shakeController,
        curve: Curves.elasticIn,
      ),
    );

    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNodes[0].requestFocus();
      });
    }

    // Добавляем слушатели для автоматического перехода
    for (int i = 0; i < 4; i++) {
      _controllers[i].addListener(() {
        _onTextChanged(i);
      });
      _focusNodes[i].addListener(() {
        if (!mounted) return;
        // Рамка активного слота зависит от hasFocus — перерисовываем сразу
        // при любом изменении фокуса, чтобы не было визуального "запаздывания".
        setState(() {});

        if (_focusNodes[i].hasFocus) {
          _controllers[i].selection = TextSelection.fromPosition(
            TextPosition(offset: _controllers[i].text.length),
          );
        }

        // Уведомляем родителя: есть ли фокус хотя бы в одном слоте.
        final hasAnyFocus = _focusNodes.any((node) => node.hasFocus);
        widget.onFocusChanged?.call(hasAnyFocus);
      });
    }
  }

  @override
  void didUpdateWidget(PinCodeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isError && !oldWidget.isError) {
      _handleError();
    } else if (!widget.isError && oldWidget.isError) {
      _clearError();
    }
  }

  @override
  void dispose() {
    _completionDebounce?.cancel();
    _errorTimer?.cancel();
    _shakeController.dispose();
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  void _handleError() {
    setState(() {
      _isErrorState = true;
    });

    // Вибрация: Haptic Light 30-40ms
    HapticFeedback.lightImpact();

    // Shake анимация (опционально)
    _shakeController.forward(from: 0).then((_) {
      _shakeController.reverse();
    });

    // Автоочистка после паузы на чтение (см. GraniTheme.authPinErrorClearDelay)
    _errorTimer?.cancel();
    _errorTimer = Timer(GraniTheme.authPinErrorClearDelay, () {
      if (mounted) {
        clear();
        setState(() {
          _isErrorState = false;
        });
      }
    });
  }

  void _clearError() {
    _errorTimer?.cancel();
    setState(() {
      _isErrorState = false;
    });
  }

  /// Схлопывает всплески listener’ов при вставке/autofill в один onCompleted.
  void _scheduleOnCompletedIfFull() {
    _completionDebounce?.cancel();
    final pinString = _pin.join('');
    if (pinString.length < 4 || _pin.contains('')) {
      _completionNotified = false;
      return;
    }
    _completionDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      final s = _pin.join('');
      if (s.length != 4 || _pin.contains('')) return;
      if (_completionNotified) return;
      _completionNotified = true;
      debugPrint('PinCodeInput: полный PIN (debounced), onCompleted "$s"');
      widget.onCompleted?.call(s);
    });
  }

  void _onTextChanged(int index) {
    final text = _controllers[index].text;

    // Ограничиваем до одной цифры
    if (text.length > 1) {
      _controllers[index].text = text.substring(0, 1);
      _controllers[index].selection = TextSelection.collapsed(offset: 1);
    }

    final digit = text.isNotEmpty ? text[0] : '';
    final wasEmpty = _pin[index].isEmpty;
    _pin[index] = digit;

    // Уведомляем об изменении
    final pinString = _pin.join('');
    if (pinString.length < 4 || _pin.contains('')) {
      _completionNotified = false;
      _completionDebounce?.cancel();
    }
    debugPrint(
        'PinCodeInput: ячейка $index изменена, digit="$digit", _pin=$_pin, pinString="$pinString" (длина: ${pinString.length})');
    widget.onChanged?.call(pinString);

    // Если текст стал пустым (backspace), просто переходим к предыдущей ячейке
    // НЕ очищаем предыдущую ячейку - это будет сделано в обработчиках backspace
    if (text.isEmpty && !wasEmpty && index > 0) {
      Future.microtask(() {
        if (mounted) {
          _focusNodes[index - 1].requestFocus();
        }
      });
      return; // Не переходим к следующей ячейке при backspace
    }

    // Переход к следующей ячейке только если введена цифра
    if (digit.isNotEmpty && index < 3) {
      Future.microtask(() {
        if (mounted) {
          _focusNodes[index + 1].requestFocus();
        }
      });
    }

    if (pinString.length == 4 && !_pin.contains('')) {
      _scheduleOnCompletedIfFull();
    }
  }

  void _handleBackspace(int index) {
    if (_pin[index].isNotEmpty) {
      // Если текущая ячейка не пуста, очищаем её сразу
      _controllers[index].clear();
      _pin[index] = '';
      widget.onChanged?.call(_pin.join(''));
    } else if (index > 0) {
      // Если текущая ячейка пуста, переходим к предыдущей и очищаем её сразу
      _focusNodes[index - 1].requestFocus();
      // Небольшая задержка для корректного перехода фокуса
      Future.microtask(() {
        if (mounted && _pin[index - 1].isNotEmpty) {
          _controllers[index - 1].clear();
          _pin[index - 1] = '';
          widget.onChanged?.call(_pin.join(''));
        }
      });
    }
  }

  String get pin => _pin.join('');

  void clear() {
    _completionDebounce?.cancel();
    _completionNotified = false;
    for (int i = 0; i < 4; i++) {
      _controllers[i].clear();
      _pin[i] = '';
    }
    widget.onChanged?.call('');
    // Устанавливаем фокус на первую ячейку синхронно
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNodes[0].requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    // Адаптация для маленьких экранов
    final fieldWidth = (isSmallScreen
            ? GraniTheme.pinCodeSlotWidthSmall
            : GraniTheme.pinCodeSlotWidth) *
        widget.scaleX;
    final fieldHeight = (isSmallScreen
            ? GraniTheme.pinCodeSlotHeightSmall
            : GraniTheme.pinCodeSlotHeight) *
        widget.scaleY;
    final borderRadius = GraniTheme.radiusButton * widget.scaleX; // 25px
    final gap =
        (isSmallScreen ? GraniTheme.pinCodeGapSmall : GraniTheme.pinCodeGap) *
            widget.scaleX;
    final fontSize = (isSmallScreen ? GraniTheme.pinCodeFontSizeSmall : 40.0) *
        widget.scaleX;

    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset:
              _isErrorState ? Offset(_shakeAnimation.value, 0) : Offset.zero,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (index) {
              return Padding(
                padding: EdgeInsets.only(
                  right: index < 3 ? gap : 0,
                ),
                child: _buildPinField(
                  index: index,
                  width: fieldWidth,
                  height: fieldHeight,
                  borderRadius: borderRadius,
                  fontSize: fontSize,
                ),
              );
            }),
          ),
        );
      },
    );
  }

  void _handlePaste(String digits, int startIndex) {
    // Распределяем цифры по ячейкам, начиная с текущей
    int currentIndex = startIndex;
    for (int i = 0; i < digits.length && currentIndex < 4; i++) {
      _controllers[currentIndex].text = digits[i];
      _pin[currentIndex] = digits[i];
      currentIndex++;
    }

    // Уведомляем об изменении
    final pinString = _pin.join('');
    if (pinString.length < 4 || _pin.contains('')) {
      _completionNotified = false;
      _completionDebounce?.cancel();
    }
    widget.onChanged?.call(pinString);

    // Устанавливаем фокус на последнюю заполненную ячейку или следующую пустую
    int focusIndex = currentIndex < 4 ? currentIndex : 3;
    Future.microtask(() {
      if (mounted) {
        _focusNodes[focusIndex].requestFocus();
        if (pinString.length == 4 && !_pin.contains('')) {
          _scheduleOnCompletedIfFull();
        }
      }
    });
  }

  void _handleBackspaceOnEmpty(int index) {
    if (index > 0 && _pin[index].isEmpty) {
      _focusNodes[index - 1].requestFocus();
      Future.microtask(() {
        if (mounted && _pin[index - 1].isNotEmpty) {
          _controllers[index - 1].clear();
          _pin[index - 1] = '';
          widget.onChanged?.call(_pin.join(''));
        }
      });
    }
  }

  Widget _buildPinField({
    required int index,
    required double width,
    required double height,
    required double borderRadius,
    required double fontSize,
  }) {
    final hasValue = _pin[index].isNotEmpty;
    final isError = _isErrorState && hasValue;
    final isFocused = _focusNodes[index].hasFocus;

    return GestureDetector(
      onTap: () {
        // При тапе по слоту активируем ближайшую пустую ячейку
        int targetIndex = index;
        for (int i = 0; i < 4; i++) {
          if (_pin[i].isEmpty) {
            targetIndex = i;
            break;
          }
        }
        _focusNodes[targetIndex].requestFocus();
      },
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: GraniTheme.surfaceControlGradient,
          borderRadius: BorderRadius.circular(borderRadius), // 25px
          border: isError
              ? Border.all(
                  color: GraniTheme.errorBorder.withOpacity(0.4), // #E63946 40%
                  width: 2,
                )
              : (isFocused
                  ? Border.all(
                      color: const Color(0xFF192F3F).withOpacity(0.35),
                      width: 1.5,
                    )
                  : Border.all(
                      color: GraniTheme.surfaceControlBorder.withOpacity(0.82),
                      width: 1,
                    )),
          boxShadow: isFocused
              ? GraniTheme.surfaceControlShadowStrong
              : GraniTheme.surfaceControlShadow,
        ),
        alignment: Alignment.center,
        child: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.backspace): _BackspaceIntent(),
          },
          child: Actions(
            actions: {
              _BackspaceIntent: CallbackAction<_BackspaceIntent>(
                onInvoke: (_) {
                  // Обрабатываем backspace независимо от состояния ячейки
                  if (_pin[index].isNotEmpty) {
                    // Если текущая ячейка заполнена, очищаем её
                    _controllers[index].clear();
                    _pin[index] = '';
                    widget.onChanged?.call(_pin.join(''));
                  } else if (index > 0) {
                    // Если текущая ячейка пуста, переходим к предыдущей и очищаем её
                    _focusNodes[index - 1].requestFocus();
                    Future.microtask(() {
                      if (mounted && _pin[index - 1].isNotEmpty) {
                        _controllers[index - 1].clear();
                        _pin[index - 1] = '';
                        widget.onChanged?.call(_pin.join(''));
                      }
                    });
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              onKeyEvent: (node, event) {
                // Дополнительная обработка backspace через Focus
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.backspace) {
                  if (_pin[index].isNotEmpty) {
                    _controllers[index].clear();
                    _pin[index] = '';
                    widget.onChanged?.call(_pin.join(''));
                  } else if (index > 0) {
                    _focusNodes[index - 1].requestFocus();
                    Future.microtask(() {
                      if (mounted && _pin[index - 1].isNotEmpty) {
                        _controllers[index - 1].clear();
                        _pin[index - 1] = '';
                        widget.onChanged?.call(_pin.join(''));
                      }
                    });
                  }
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _controllers[index],
                focusNode: _focusNodes[index],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                textAlignVertical: TextAlignVertical.center,
                scrollPadding: const EdgeInsets.only(bottom: 260),
                maxLength: 1,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  _PasteInputFormatter(index, _handlePaste),
                  _PinCodeInputFormatter(index, _handleBackspaceOnEmpty),
                ],
                style: isError
                    ? GraniTheme.pinCodeError.copyWith(
                        fontSize: fontSize,
                        height: 1.2, // line-height 120%
                      )
                    : GraniTheme.pinCodeActive.copyWith(
                        fontSize: fontSize,
                        height: 1.2, // line-height 120%
                      ),
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
                onChanged: (value) {
                  // Обработка через listener в _onTextChanged
                },
                onTap: () {
                  // При тапе выделяем весь текст для замены
                  _controllers[index].selection = TextSelection.fromPosition(
                    TextPosition(offset: _controllers[index].text.length),
                  );
                },
                onSubmitted: (value) {
                  // При нажатии Enter переходим к следующей ячейке
                  if (index < 3) {
                    _focusNodes[index + 1].requestFocus();
                  }
                },
                buildCounter: (context,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

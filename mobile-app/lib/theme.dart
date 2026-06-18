import 'package:flutter/material.dart';

class GraniTheme {
  // Основные цвета из Figma
  static const Color primaryBackground = Color(0xFFF7F4F8); // fill_F306V7
  static const Color cardBackground = Color(0xFFF4F6F8); // fill_NDO459
  static const Color primaryText = Color(0xFF192F3F); // fill_OT4RY4
  static const Color secondaryText = Color(0xFFA4ACB5); // fill_Z0PV1F
  static const Color white = Color(0xFFFFFFFF); // fill_O4LUGY
  static const Color black = Color(0xFF000000); // fill_M21GLO

  // GRANI surface system: общий язык мягких подложек, селекторов и профиля.
  static const Color surfaceBase = Color(0xFFF7F9FA);
  static const Color surfaceSoft = Color(0xFFF8FAFC);
  static const Color surfaceRaised = Color(0xFFFFFFFF);
  static const Color surfaceControl = Color(0xFFF6F8FA);
  static const Color surfaceInset = Color(0xFFEFF4F8);
  static const Color surfaceStroke = Color(0xFFE6EBF2);
  static const Color surfaceControlBorder = Color(0xFFDEE6EE);
  static const Color warmAccent = Color(0xFFFF7A00);
  static const Color warmAccentSoft = Color(0xFFFFB066);
  static const Color errorCoral = Color(0xFFE46E61);
  static const double radiusSurface = 22.0;
  static const double radiusControl = 18.0;
  static const double radiusPill = 999.0;

  static const List<BoxShadow> surfaceSoftShadow = [
    BoxShadow(
      color: Color(0x1206142E),
      offset: Offset(0, 10),
      blurRadius: 24,
      spreadRadius: -16,
    ),
    BoxShadow(
      color: Color(0xE6FFFFFF),
      offset: Offset(0, -5),
      blurRadius: 14,
      spreadRadius: -10,
    ),
  ];

  static const List<BoxShadow> surfaceRaisedShadow = [
    BoxShadow(
      color: Color(0x1A06142E),
      offset: Offset(0, 16),
      blurRadius: 36,
      spreadRadius: -20,
    ),
    BoxShadow(
      color: Color(0xF2FFFFFF),
      offset: Offset(0, -7),
      blurRadius: 20,
      spreadRadius: -14,
    ),
  ];

  static const List<BoxShadow> surfaceControlShadow = [
    BoxShadow(
      color: Color(0x1806142E),
      offset: Offset(0, 10),
      blurRadius: 22,
      spreadRadius: -14,
    ),
    BoxShadow(
      color: Color(0xE6FFFFFF),
      offset: Offset(0, -5),
      blurRadius: 14,
      spreadRadius: -10,
    ),
  ];

  static const List<BoxShadow> surfaceControlShadowStrong = [
    BoxShadow(
      color: Color(0x2006142E),
      offset: Offset(0, 10),
      blurRadius: 24,
      spreadRadius: -14,
    ),
    BoxShadow(
      color: Color(0xF2FFFFFF),
      offset: Offset(0, -6),
      blurRadius: 16,
      spreadRadius: -12,
    ),
  ];

  static const LinearGradient surfaceControlGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFFFFF),
      Color(0xFFF8FAFC),
      Color(0xFFF1F4F7),
    ],
    stops: [0.0, 0.52, 1.0],
  );

  static BoxDecoration graniSurfaceDecoration({
    double radius = radiusSurface,
    Color? borderColor,
    double borderOpacity = 0.86,
    double borderWidth = 1,
    List<BoxShadow> shadows = surfaceControlShadowStrong,
  }) {
    return BoxDecoration(
      gradient: surfaceControlGradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: (borderColor ?? surfaceControlBorder).withOpacity(borderOpacity),
        width: borderWidth,
      ),
      boxShadow: shadows,
    );
  }

  // Цвета протоколов
  static const Color xrayActive = Color(0xFF2EC07E); // fill_2TG6IQ
  static const Color protocolInactive = Color(0xFFD9D9D9); // fill_0HXKAS

  // Цвета кнопок
  static const Color buttonPrimary = Color(0xFF182D3D); // fill_IVTB46
  static const Color buttonSecondary = Color(0xFFF6F8F9); // fill_I4MEQS

  // Цвета статуса подключения
  static const Color connectedStatus = Color(0xFF20704C); // fill_0R36G7

  // Кнопка подключения VPN (Figma 939:555, figma_connection_button_design.json)
  static const Color connectionButtonRingBlue =
      Color(0xFF2A6882); // OFF: дуга с разрывом (ring stroke)
  /// Синее кольцо в состояниях CONNECTING/DISCONNECTING — темнее по макету (видно с обеих сторон оранжевой дуги)
  static const Color connectionButtonRingBlueDark = Color(0xFF153A47);
  static const Color connectionButtonRingOrange =
      Color(0xFFE8AC89); // ON: полное кольцо; CONNECTING/DISCONNECTING: дуга
  static const Color connectionButtonInnerFill =
      Color(0xFFF4F6F8); // заливка внутри кольца
  /// Толщина синего кольца в состоянии OFF (Figma 939:555 ring strokeWeight 12)
  static const double connectionButtonStrokeWidthOff = 12.0;

  /// Толщина синего кольца в CONNECTING/DISCONNECTING/ON — 10px
  static const double connectionButtonStrokeWidth = 10.0;

  /// Толщина оранжевого кольца в состоянии ON (Figma 7)
  static const double connectionButtonStrokeWidthConnected = 7.0;

  /// Толщина оранжевой дуги в CONNECTING/DISCONNECTING (тоньше, чтобы синее кольцо было видно с обеих сторон)
  static const double connectionButtonStrokeWidthConnectedArc = 5.0;

  /// Зазор между синим и оранжевым кольцом в CONNECTING/DISCONNECTING (px)
  static const double connectionButtonRingGap = 3.0;

  /// Разрыв кольца в состоянии OFF: по Figma Arc 97% дуга → 3% разрыв ≈ 10.8°
  static const double connectionButtonRingGapDegOff = 10.8;

  /// Угол начала дуги в OFF (градусы, 0 = 3ч); по Figma Arc start 49°
  static const double connectionButtonRingGapStartDegOff = 49.0;
  static const double connectionButtonSize = 205.0; // все состояния: 205×205
  static const double connectionButtonSizeConnected = 205.0;
  static const double connectionButtonLabelOffFontSize =
      28.0; // OFF: «подключить» 28px (Figma)
  static const double connectionButtonLabelStateFontSize =
      24.0; // «соединение...»/«подключено» 24px (Figma)
  static const FontWeight connectionButtonLabelFontWeight =
      FontWeight.w600; // Figma 600 для всех состояний
  /// Цвет текста кнопки в состояниях OFF/CONNECTING/DISCONNECTING (Figma 939:555 label fills #182D3D)
  static const Color connectionButtonLabelOffColor = Color(0xFF182D3D);
  static const Color connectionButtonLabelConnectedColor =
      Color(0xFF02222F); // ON: «подключено»

  // Кнопки выбора сервера и протокола: это основной объект управления после Connect.
  static const double selectorButtonWidth = 166.0;
  static const double selectorButtonHeight = 42.0;
  static const double selectorButtonRadius = 20.0;
  static const double selectorButtonGap = 22.0;
  static const double selectorButtonIconSize = 20.0;
  static const double selectorButtonPaddingH = 10.0;
  static const double selectorButtonPaddingV = 0.0;
  static const Color selectorButtonBackground = surfaceControl;
  static const Color selectorButtonBorder = surfaceControlBorder;
  static const double selectorButtonTextSize = 12.5;
  static const double selectorButtonIconGap = 8.0;

  /// Ранее использовался красный круг за флагом — по макету убран, флаг без фона
  static const Color selectorButtonIconServerBg = Color(0xFFDC2626);

  /// Отступ блока подключения от низа экрана (Trial и Home по макету 562:732)
  static const double vpnCardBottomMargin = 12.0;

  /// Зазор «Скорость» → кнопка подключения (Figma 562:732, 939:555)
  static const double connectionBlockGapSpeedToButton = 33.0;

  /// Зазор кнопка подключения → ряд «сервер/протокол» (Figma 562:732, 939:555)
  static const double connectionBlockGapButtonToControls = 38.0;

  /// Отступ от верха экрана до блока заголовка/описания: 343 px по макету (Figma 562:732, 958:337). Итого: 12+39+12+gap = 343 → gap = 280.
  static const double trialTitleBlockTopGap = 280.0;

  /// Размер шрифта заголовка («Подписка активна» и др.) во всех состояниях Trial и Home.
  static const double trialTitleFontSize = 30.0;

  /// Смещение текста кнопки подключения вниз от центра (по макету — визуально ниже).
  static const double connectionButtonLabelOffsetY = 6.0;
  static const Color selectorButtonIconProtocol = Color(0xFF182D3D);
  // Тени по макету: Drop shadow X:2 Y:2 Blur:0 Spread:0 #000000 10%; Inner shadow X:2 Y:2 Blur:0 Spread:0 #FFFFFF 100%
  static const List<BoxShadow> selectorButtonShadow =
      surfaceControlShadowStrong;

  // Цвета тарифов
  static const Color tariffYellow = Color(0xFFFFCA2D); // fill_AB0018
  static const Color tariffTeal = Color(0xFF58949E); // fill_0WHPNV

  // Profile bottom sheet (Figma 1040-107, 1117-296)
  static const Color premiumBadgeColor =
      Color(0xFFFFCA2D); // жёлтый бейдж Premium
  static const Color trialBadgeColor = Color(0xFF58949E); // голубой бейдж Trial
  static const Color statusGreen =
      Color(0xFF2EC07E); // зелёная точка «Активен до»
  static const Color statusBlue = Color(0xFF4A90D9); // синяя точка «Тест до»
  /// Информационный баннер (подсказка / оповещение, не ошибка) — см. `widgets/info_banner.dart`
  static const Color infoBannerBackground = Color(0xFFE8F2FC);
  static const Color infoBannerForeground = Color(0xFF1A4D6E);
  static const Color destructiveRed =
      Color(0xFFFD2F26); // кнопка Выйти (Figma 1040-107)
  static const Color successGreen =
      Color(0xFF2EC07E); // даты Premium, прогресс >30%
  static const Color warningOrange = Color(0xFFF59E0B); // предупреждение 10-30%
  static const Color dangerRed = Color(0xFFE63946); // критично <10%
  static const Color surfaceVariant = Color(0xFFE5E7EB); // трек линии прогресса

  // Device Limit Sheet (Figma 1118-106)
  static const Color deviceLimitErrorText =
      Color(0xFFDC2626); // #DC2626 кнопка Удалить
  static const Color deviceLimitErrorBg = Color(0xFFFEE2E2); // #FEE2E2
  static const Color deviceLimitDeleteBorder = Color(0xFFFCA5A5); // #FCA5A5
  static const Color deviceLimitIndicatorRed =
      Color(0xFFFF1904); // индикатор X/Y при превышении
  static const Color deviceLimitBadgeCurrent =
      Color(0xFF40484F); // бейдж «Это устройство»
  static const Color deviceLimitThisDeviceBorder =
      Color(0xFFDCE1E6); // border кнопки «Это устройство»

  // Devices screen (Figma 1143-193)
  static const Color devicesCountOrange =
      Color(0xFFEF7F34); // счётчик «X / Y» при лимите
  static const Color devicesActiveNowGreen =
      Color(0xFF48B14C); // «Активно сейчас»
  static const double sectionCardRadius = 18.0; // радиус карточек секций
  static const double profileCardRadius =
      22.0; // GRANI molecule surface radius for profile/menu cards
  static const double standardSectionPadding = 16.0; // внутренние отступы

  // TrialEndedScreen / paywall (Figma 562:488): карточки тарифов
  static const Color trialEndedTariffBadgeText =
      Color(0xFF004256); // бейдж: число и период
  static const Color trialEndedTariffPrice = Color(0xFF003244); // цена
  static const Color trialEndedTariffDescription =
      Color(0xFF19243F); // описание
  static const Color trialEndedTimer =
      Color(0xFFF65656); // Figma 562:488 timer_value #F65656

  // Дополнительные цвета из Figma Auth Flow
  static const Color privacyLinkColor = Color(
      0xFF4F6E84); // fill_V45IH6 - цвет ссылки "Подробнее о конфиденциальности"
  static const Color pinCodeTextColor =
      Color(0xFF023E53); // fill_WSITOH - цвет цифр в PIN-коде

  // Цвета для ошибок
  static const Color errorBackground = Color(0xFFFFDEDE); // #FFDEDE
  static const Color errorText = Color(0xFFB40000); // #B40000
  static const Color errorBorder = Color(0xFFE63946); // #E63946

  /// Экран ввода кода (email): автоочистка слотов PIN после ошибки; снятие плашки «неверный код».
  static const Duration authPinErrorClearDelay = Duration(milliseconds: 1500);
  static const Duration authCodeErrorBannerDismissDelay =
      Duration(milliseconds: 3000);

  // Цвета для активного текста
  static const Color activeText = Color(0xFF1A1A1A); // #1A1A1A

  // Тени и эффекты
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1)
      offset: Offset(9, 9),
      blurRadius: 6,
    ),
  ];

  static const List<BoxShadow> buttonShadow = [
    BoxShadow(
      color: Color(0x26000000), // rgba(0, 0, 0, 0.15)
      offset: Offset(2, 2),
      blurRadius: 0,
    ),
  ];

  static const List<BoxShadow> primaryButtonShadow = [
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1)
      offset: Offset(2, 2),
      blurRadius: 0,
    ),
  ];

  // Единые тени для кнопок и полей ввода с фоном F4F6F8
  // Inner shadow: X:2 Y:2 Blur:0 Spread:0 Color:#FFFFFF 100% (создает светлую грань слева и сверху)
  // Drop shadow: X:2 Y:2 Blur:0 Spread:0 Color:#000000 15%
  // Примечание: Используем два BoxShadow - один для внешней тени, один для внутренней (белая тень с отрицательным offset)
  static const List<BoxShadow> buttonShadowStandard = [
    // Drop shadow (внешняя тень) - создает темную грань справа и снизу
    BoxShadow(
      color: Color(0x26000000), // rgba(0, 0, 0, 0.15) = 15%
      offset: Offset(2, 2),
      blurRadius: 0,
      spreadRadius: 0,
    ),
    // Inner shadow (внутренняя тень) - создает светлую грань слева и сверху
    BoxShadow(
      color: Color(0xFFFFFFFF), // #FFFFFF 100%
      offset: Offset(-2, -2), // Отрицательный offset для внутреннего эффекта
      blurRadius: 0,
      spreadRadius: 0,
    ),
  ];

  // Тени для полей ввода (идентичны кнопкам)
  static const List<BoxShadow> inputFieldShadow = buttonShadowStandard;

  // Единые тени для подложки (Background Box)
  // Inner shadow: X:8 Y:8 Blur:6 Color:#FFFFFF
  // Drop shadow: X:9 Y:9 Blur:6 Color:#000000 10%
  // Примечание: Flutter не поддерживает inset тени напрямую, используем отрицательный spreadRadius для эмуляции
  static const List<BoxShadow> cardShadowWithInset = [
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1) = 10%
      offset: Offset(9, 9),
      blurRadius: 6,
    ),
    // Эмуляция inner shadow через светлую тень с отрицательным spreadRadius
    BoxShadow(
      color: Color(0x80FFFFFF), // Белый с прозрачностью для inner эффекта
      offset: Offset(-8, -8),
      blurRadius: 6,
      spreadRadius: -2, // Отрицательный spread для внутреннего эффекта
    ),
  ];

  // Тени для primary кнопок из Figma (effect_4Q172U для send_button)
  // 2px 2px 0px 0px rgba(0, 0, 0, 0.1), inset 2px 2px 0px 0px rgba(45, 85, 115, 1)
  // Примечание: Flutter не поддерживает inset тени напрямую, используем Container с margin для эмуляции
  static const List<BoxShadow> primaryButtonShadowWithInset = [
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1)
      offset: Offset(2, 2),
      blurRadius: 0,
      spreadRadius: 0,
    ),
  ];

  // Цвет для inset тени кнопки (rgba(45, 85, 115, 1) = #2D5573)
  static const Color buttonInsetShadowColor = Color(0xFF2D5573);

  // Текстовые стили из Figma
  static const TextStyle headingLarge = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 40,
    height: 0.9,
    letterSpacing: -0.04 * 40, // -4% от размера шрифта
    color: primaryText,
  );

  static const TextStyle headingMedium = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 32,
    height: 0.9,
    letterSpacing: -0.04,
    color: primaryText,
  );

  static const TextStyle headingSmall = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 24,
    height: 0.9,
    letterSpacing: -0.04,
    color: primaryText,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w300,
    fontSize: 16,
    height: 0.97,
    letterSpacing: 0.06 * 16, // +6% от размера шрифта
    color: primaryText,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 0.9,
    letterSpacing: -0.04,
    color: primaryText,
  );

  static const TextStyle bodySmall = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w300,
    fontSize: 14,
    height: 0.97,
    letterSpacing: 0.06,
    color: primaryText,
  );

  static const TextStyle buttonText = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600,
    fontSize: 24,
    height: 1.1,
    letterSpacing: 0.06,
    color: secondaryText,
  );

  static const TextStyle buttonTextSmall = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600,
    fontSize: 20,
    height: 1.1,
    letterSpacing: 0.06,
    color: secondaryText,
  );

  static const TextStyle protocolText = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 0.9,
    letterSpacing: -0.04,
    color: black,
  );

  static const TextStyle statusText = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 20,
    height: 0.9,
    letterSpacing: -0.04,
    color: primaryText,
  );

  static const TextStyle tariffPrice = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 28,
    height: 0.9,
    letterSpacing: -0.04,
    color: primaryText,
  );

  static const TextStyle tariffTitle = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w500,
    fontSize: 24,
    height: 0.84,
    letterSpacing: 0.06,
    color: buttonSecondary,
  );

  static const TextStyle tariffDescription = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600,
    fontSize: 12,
    height: 0.84,
    letterSpacing: 0.06,
    color: Color(0xFF75787C), // fill_X9PVI1
  );

  // Дополнительные текстовые стили из Figma Auth Flow
  // style_HVLEFR: Montserrat, 556, 22px, lineHeight: 1.1, letterSpacing: 6%
  static const TextStyle buttonTextMedium = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600, // 556 ≈ w600
    fontSize: 22,
    height: 1.1,
    letterSpacing: 0.06,
    color: white, // для primary кнопок
  );

  // Из Figma privacy_link: 14px, 300, #4F6E84; подчёркивание по макету.
  static const TextStyle privacyLinkText = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w300,
    fontSize: 14,
    height: 0.97,
    letterSpacing: 0.06,
    color: privacyLinkColor,
    decoration: TextDecoration.underline,
    decorationColor: privacyLinkColor,
  );

  // style_BU8S7A: Montserrat, 600, 48px, lineHeight: 1.1, letterSpacing: 6%
  static const TextStyle pinCodeNumber = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600,
    fontSize: 48,
    height: 1.1,
    letterSpacing: 0.06,
    color: pinCodeTextColor,
  );

  // style_S66OXA: Montserrat, 556, 20px, lineHeight: 1.1, letterSpacing: 6%
  static const TextStyle buttonTextSecondary = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600,
    fontSize: 20,
    height: 1.1,
    letterSpacing: 0.06,
    color: secondaryText,
  );

  /// Текст кнопок на стартовом экране: regular, крупнее (по макету).
  static const TextStyle buttonTextStartScreen = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w400,
    fontSize: 22,
    height: 1.1,
    letterSpacing: 0.06,
    color: secondaryText,
  );

  // Email placeholder: Montserrat 16px 400-500, color #A4ACB5, line-height 120%
  static const TextStyle emailPlaceholder = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w500, // 400-500
    fontSize: 16,
    height: 1.2, // 120%
    letterSpacing: 0,
    color: secondaryText, // #A4ACB5
  );

  // Email input text: Montserrat 16px 556, color #1A1A1A, line-height 120%
  static const TextStyle emailInputText = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w600, // 556 ≈ w600
    fontSize: 16,
    height: 1.2, // 120%
    letterSpacing: 0,
    color: activeText, // #1A1A1A
  );

  // PIN-код активный ввод: Montserrat 40px, weight 650-700, color #1A1A1A, line-height 120%
  static const TextStyle pinCodeActive = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w700, // 650-700 ≈ w700
    fontSize: 40,
    height: 1.2, // 120%
    letterSpacing: 0,
    color: activeText, // #1A1A1A
  );

  // PIN-код ошибка: color #E63946
  static const TextStyle pinCodeError = TextStyle(
    fontFamily: 'Montserrat',
    fontWeight: FontWeight.w700,
    fontSize: 40,
    height: 1.2,
    letterSpacing: 0,
    color: errorBorder, // #E63946
  );

  // Радиусы скругления из Figma
  static const double radiusSmall =
      18.0; // borderRadius: 18px для основных экранов
  static const double radiusMedium = 24.0; // borderRadius: 24px
  static const double radiusButton =
      25.0; // borderRadius из Figma button_google/button_email: 25
  static const double radiusButtonStartScreen =
      25.0; // из figma_start_screen_design.json
  static const double radiusLarge =
      28.0; // borderRadius: 28px для карточек (положка)
  static const double radiusXLarge = 50.0;

  // Отступы
  static const double paddingSmall = 8.0;
  static const double paddingMedium = 16.0;
  static const double paddingLarge = 20.0;
  static const double paddingXLarge = 24.0;

  // Размеры из Figma
  static const double buttonHeight = 62.0; // Высота кнопок из макета (62px)
  static const double buttonHeightLarge =
      70.0; // Высота больших кнопок (70px для start_screen)
  // connectionButtonSize задан выше (205, Figma 939:555)
  // Тень кнопки подключения (по макету)
  static const List<BoxShadow> connectionButtonShadow = [
    BoxShadow(
      color: Color(0x1A000000),
      offset: Offset(0, 4),
      blurRadius: 12,
    ),
  ];
  static const double inputHeight = 62.0; // Высота полей ввода
  static const double inputFieldHeight = 100.0; // Высота полей PIN-кода (100px)
  static const double protocolIndicatorSize = 19.0;

  // Размеры логотипа по макету Figma (figma_fetch_layout.py): 37×48 px
  static const double logoWidth = 37.0;
  static const double logoHeight = 48.0;
  // Стартовый экран: только данные из Figma (docs/figma_start_screen_design.json + figma_fetch_layout.py)
  static const double startScreenLogoTopOffset =
      74.4; // logo.y из макета 516:295
  static const double startScreenLogoToTitleGap =
      217.0; // logoToTitleGap из figma_fetch_layout.py

  // Отступы для экранов авторизации
  static const double logoTopOffset = 5.0; // Отступ сверху логотипа: 5px
  static const double logoToIllustrationGap =
      25.0; // Отступ от логотипа до иллюстрации: 25px
  static const double illustrationToTextGap =
      55.0; // Отступ от иллюстрации до текста: 55px
  static const double titleSubtitleGap =
      22.0; // Gap между заголовком и подзаголовком: 22px
  // Стартовый экран: из figma_start_screen_design.json (title bounds 339+70=409, subtitle y=426 → 17)
  static const double startScreenTitleSubtitleGap = 17.0;
  static const double startScreenGapSubtitleToButtons = 34.0; // 492 - 458
  static const double startScreenGapBetweenButtons = 16.0; // 570 - 492 - 62
  static const double startScreenGapButtonsToAccountLink = 34.0;
  static const double startScreenGapAccountLinkToPrivacy = 40.0;
  static const double startScreenTitleFontSize =
      40.0; // title.fontSize из Figma
  static const double startScreenSubtitleFontSize =
      16.0; // subtitle.fontSize из Figma
  static const double startScreenTitleLetterSpacing =
      -1.6; // title.letterSpacing из Figma
  static const double startScreenSubtitleLetterSpacing =
      0.96; // subtitle.letterSpacing из Figma

  // Шрифт таймера «осталось» и «Скорость» (Figma 562:732) — одинаково во всех состояниях Trial/Home
  static const double trialTimerFontSize = 18.0; // осталось: 10:00
  static const FontWeight trialTimerFontWeight = FontWeight.w400;
  static const double trialSpeedFontSize = 16.0; // Скорость: 0 Мбит/с

  // Размеры элементов
  static const double illustrationSize = 150.0; // Размер иллюстрации: 150×150px
  static const double textBlockWidth = 376.0; // Ширина текстового блока: 376px
  static const double backgroundBoxWidth = 372.0; // Ширина подложки: 372px
  /// Горизонтальный отступ контента. По макету Figma (textBlock.x, button x): 32px.
  static const double authScreenHorizontalPadding = 32.0;
  static const double startScreenHorizontalPadding =
      32.0; // из figma_start_screen_design.json (textBlock.x, button_google.x)
  static const double inputFieldWidth = 348.0; // Ширина полей ввода: 348px

  // Размеры PIN-кода
  static const double pinCodeSlotWidth = 70.0; // Ширина слота PIN-кода: 70px
  static const double pinCodeSlotHeight = 100.0; // Высота слота PIN-кода: 100px
  static const double pinCodeGap = 10.0; // Gap между слотами: 10px

  // Адаптация для маленьких экранов (<360px)
  static const double pinCodeSlotWidthSmall = 60.0; // Ширина слота: 60px
  static const double pinCodeSlotHeightSmall = 85.0; // Высота слота: 85px
  static const double pinCodeGapSmall = 8.0; // Gap: 8px
  static const double pinCodeFontSizeSmall = 24.0; // Размер шрифта: 24px

  static const double statusBarHeight = 40.0;
  static const double navigationBarHeight = 24.0; // Высота navigation bar

  // Точные размеры экрана из Figma
  static const double screenWidth = 412.0;
  static const double screenHeight = 917.0;

  // Размеры изображений
  static const double mainImageSize = 150.0;

  // Отступы из Figma
  static const double cardPadding = 20.0;
  static const double buttonPadding = 55.0;

  // Внутренние отступы кнопок
  static const double buttonPaddingLeft = 20.0; // Отступ слева: 20px
  static const double buttonPaddingRight = 14.0; // Отступ справа: 14px
  static const double buttonIconSize =
      20.0; // Размер иконки из Figma (button text 20)
  static const double buttonIconGap = 12.0; // Отступ от иконки до текста: 12px
  /// Фон кнопок стартового экрана из Figma (button_google.background_hex).
  static const Color startScreenButtonBackground = Color(0xFFF4F6F8);

  // Внутренние отступы подложки
  static const double backgroundBoxPadding = 20.0; // Внутренние отступы: 20px

  // Градиенты
  static const LinearGradient connectionGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF2EC07E), // Xray green
      Color(0xFF2EC07E), // Xray green
      Color(0xFFF9C57A), // Orange
    ],
    stops: [0.0, 0.5, 1.0],
  );

  /// Фоновый градиент экранов (редизайн): верх светлее, низ чуть темнее.
  /// Использовать в корне body как BoxDecoration(gradient: GraniTheme.backgroundGradient).
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFF7F4F8), // primaryBackground
      Color(0xFFF0ECF2),
      Color(0xFFE8E4ED),
    ],
    stops: [0.0, 0.5, 1.0],
  );

  /// Фон стартового экрана: цвет только если в макете нет градиента.
  static const Color startScreenBackground = Color(0xFFF4F6F8);

  /// Градиент фона экрана «Мои устройства» (Figma 1143-193: white → #F7F9FA).
  static const LinearGradient devicesScreenBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFFFFFFF),
      Color(0xFFF7F9FA),
    ],
    stops: [0.0, 1.0],
  );

  /// Градиент фона #StartScreen из Figma (Fill панели Design: 0% #FFFFFF, 100% #F7F9FA).
  static const LinearGradient startScreenBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFFFFFFF), // 0% white
      Color(0xFFF7F9FA), // 100% light blue-grey
    ],
    stops: [0.0, 1.0],
  );

  // Тема приложения
  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: primaryText,
        secondary: xrayActive,
        surface: cardBackground,
        background: primaryBackground,
        onPrimary: white,
        onSecondary: white,
        onSurface: primaryText,
        onBackground: primaryText,
      ),
      fontFamily: 'Montserrat',
      textTheme: const TextTheme(
        headlineLarge: headingLarge,
        headlineMedium: headingMedium,
        headlineSmall: headingSmall,
        bodyLarge: bodyLarge,
        bodyMedium: bodyMedium,
        bodySmall: bodySmall,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonPrimary,
          foregroundColor: white,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLarge),
          ),
          minimumSize: const Size(double.infinity, buttonHeight),
        ),
      ),
      cardTheme: CardThemeData(
        color: cardBackground,
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),
    );
  }
}

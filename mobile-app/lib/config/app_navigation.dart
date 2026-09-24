import 'package:flutter/material.dart';

/// Глобальный ключ навигатора для доступа к Navigator из любого контекста.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Глобальный ключ ScaffoldMessenger для лёгких in-app уведомлений из сервисов.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Наблюдатель маршрутов для сброса состояния при возврате на экран (didPopNext).
/// Используется TrialEndedScreen для сброса loading при закрытии Billing UI.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

import 'package:flutter/material.dart';

/// Глобальный ключ навигатора для доступа к Navigator из любого контекста.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Наблюдатель маршрутов для сброса состояния при возврате на экран (didPopNext).
/// Используется TrialEndedScreen для сброса loading при закрытии Billing UI.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

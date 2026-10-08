import 'package:flutter/material.dart';

/// Глобальный ключ навигатора для доступа к Navigator из любого контекста.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Глобальный ключ ScaffoldMessenger для лёгких in-app уведомлений из сервисов.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Наблюдатель маршрутов для сброса состояния при возврате на экран (didPopNext).
/// Используется TrialEndedScreen для сброса loading при закрытии Billing UI.
final GraniRouteObserver appRouteObserver = GraniRouteObserver();

class GraniRouteObserver extends RouteObserver<ModalRoute<void>> {
  String? currentRouteName;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = route.settings.name;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = previousRoute?.settings.name;
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    currentRouteName = newRoute?.settings.name;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

# VpnService and AuthService (dependency injection)

VpnService must not resolve AuthService from GetIt inside its constructor. The app singleton is created in mobile-app/lib/main.dart via _createVpnService with authService: auth, the same instance as in ChangeNotifierProvider AuthService.

In tests, every manual VpnService(...) call must pass authService (e.g. MockAuthForVpn). Search the repo for VpnService( in *.dart.

New screens: use Provider.of VpnService or context.read under the MultiProvider tree from main.dart.

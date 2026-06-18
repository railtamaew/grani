# Инвентаризация маршрутов Flutter (GRANI VPN)

Канонические имена для нового кода: **`/main`** (shell: trial/home через `MainContentScreen`), **`/trial-ended`** (paywall), **`/subscription`** (alias paywall с `SubscriptionScreenMode`), **`/`** (старт неавторизованных).

## Таблица: маршрут → виджет → назначение

| Маршрут | Виджет | Кто открывает / примечание |
|--------|--------|----------------------------|
| `/` | `StartScreen` | `initialRoute`, logout, ошибки device limit |
| `/auth-email` | `AuthEmailScreen` | StartScreen |
| `/auth-code` | `AuthCodeScreen` | AuthEmailScreen |
| `/main` | `MainContentScreen` | **Канонический shell** после входа (trial или home внутри) |
| `/home` | `MainContentScreen` | **Устаревший алиас** shell — слить вызовы в `/main` |
| `/trial-start` | `MainContentScreen` | **Устаревший алиас** |
| `/vpn-disconnected-trial` | `MainContentScreen` | **Устаревший алиас** (старые deep links) |
| `/vpn-connecting-trial` | `MainContentScreen` | **Устаревший алиас** |
| `/vpn-connected-trial` | `MainContentScreen` | **Устаревший алиас** |
| `/subscription-activated` | `MainContentScreen` | **Устаревший алиас** |
| `/vpn-connecting` | `MainContentScreen` | **Устаревший алиас** |
| `/vpn-connected` | `MainContentScreen` | **Устаревший алиас** |
| `/connecting` | `MainContentScreen` | **Устаревший алиас** |
| `/connected` | `MainContentScreen` | **Устаревший алиас** |
| `/trial-ended` | `TrialEndedScreen` | `GraniApp._getTargetRoute`, фоновый refresh, trial_unified |
| `/subscription` | `TrialEndedScreen` + `mode` | Профиль, paywall, Quick Tile (`QuickTileService` → `EXTRA_INITIAL_ROUTE`), payment_screen |
| `/profile` | `MainContentScreen` + post-frame `showProfileDrawer` | Deep link |
| `/device-limit` | `DeviceLimitScreen` | Маршрут с `arguments: List` (редко) |
| `/split-tunnel` | `SplitTunnelScreen` | Профиль |
| `/devices` | `DevicesScreen` (deferred) | Профиль |
| `/payment` | `PaymentScreen` (deferred) | — |
| `/privacy` | `PrivacyPolicyScreen` (deferred) | — |

## Android → Flutter

- **Quick Tile (без подписки)**: `QuickTileService` кладёт `EXTRA_INITIAL_ROUTE = "/subscription"`; читается в `main.dart` через `getLaunchInitialRoute` (`VpnPlugin.kt`).
- Прочих intent-filters с path под маршруты нет (только OAuth callback).

## Рекомендация

Новые вызовы использовать только **`/main`**, **`/trial-ended`**, **`/subscription`**, **`/`**, **`/auth-*`**. Алиасы в `onGenerateRoute` оставлены для совместимости (deep links, старый код); внутренние переходы после оплаты/активации подписки ведут на **`/main`** (см. `subscription_activated_screen.dart`).

## Обслуживание

- **2026-03:** В `lib/` нет `pushNamed` на устаревшие алиасы shell — только константа `_kRoutesToMainContentShell` в `main.dart`. Юнит-тесты маршрутизации целевого экрана приведены к канону **`/main`** для trial и подписки (`auth_service_trial_subscription_test.dart`).
- Алиасы (`/home`, `/trial-start`, …) не удалять без проверки внешних deep links и закладок; при снятии — обновить эту таблицу и changelog.

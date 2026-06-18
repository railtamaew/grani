# Google Play Billing — прод и чеклист

Сквозная трассировка: заголовок **`X-Request-ID`** (клиент → nginx → API). В логах API ищите **`[google-play-verify]`** и `req_id=`.

## Переменные окружения API

| Переменная | Назначение |
|------------|------------|
| `GOOGLE_PLAY_PACKAGE_NAME` | Идентификатор приложения в Play (по умолчанию в коде: `com.granivpn.mobile`). |
| `GOOGLE_PLAY_SERVICE_ACCOUNT` | Путь к JSON **service account** с доступом к Android Publisher API (linked app в Play Console). |

Поля в `core/config.py`: `google_play_package_name`, `google_play_service_account` (читаются из env автоматически через pydantic-settings).

## База: `plans.google_play_product_id`

Должны совпадать с **Product ID** в Google Play Console (как в клиенте `mobile-app/lib/config/subscription_products.dart`).

```sql
SELECT id, name, google_play_product_id, duration_days
FROM plans
WHERE google_play_product_id IS NOT NULL
ORDER BY id;
```

Ожидаемые примеры идентификаторов:

- `com.granivpn.mobile.subscription.monthly`
- `com.granivpn.mobile.subscription.6months`
- `com.granivpn.mobile.subscription.yearly`

## Сборка и трек

1. Сборка с актуальным клиентом (verify, таймаут buy, без лишнего UI).
2. **Internal / closed testing** в Play Console.
3. Сценарии: первая покупка; смена тарифа (upgrade); восстановление покупки; покупка при плохой сети (после появления сети — автоматический повтор verify из очереди в приложении).

## Наблюдаемость

- Успех: `POST /api/payments/google-play/verify` → **200**, строки **`[google-play-verify] ok`**, подписка в `subscriptions`, кэш пользователя инвалидирован.
- Ошибка: **400** — смотреть `detail` в JSON ответе; в логах — **`unknown_product`**, **`publisher_no_data`**, **`bad_payment_state`**.

## Google Sign-In (отдельно от биллинга)

На **релизных** сборках нужны SHA-1/256 **Play App Signing** и **upload key** в Firebase / OAuth client для `com.granivpn.mobile`, иначе `ApiException: 10`.

## Регресс (кратко)

- В приложении: подписка активна, доступ к VPN согласован.
- `GET /api/auth/me`: `hasActiveSubscription` / даты / план.
- Плитка / лимиты устройств при необходимости.

При старте API в production без service account в логах появится предупреждение **`GOOGLE_PLAY_PROD_CONFIG`** (не блокирует запуск).

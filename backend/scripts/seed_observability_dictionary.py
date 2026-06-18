#!/usr/bin/env python3
from core.database import SessionLocal
from core.observability import upsert_event_dictionary


SEED_ROWS = [
    (
        "VPN_CONNECT_REQUESTED",
        "Запрошено подключение VPN",
        "VPN connection requested",
        "Пользователь инициировал подключение",
        "Проверьте последующие события prepare/apply/tunnel",
        "info",
    ),
    (
        "VPN_CONNECT_PREPARE_STARTED",
        "Подготовка сессии начата",
        "Session prepare started",
        "Подготовка конфигурации на сервере началась",
        "Проверьте задержку до VPN_CONFIG_APPLY_*",
        "info",
    ),
    (
        "VPN_CONNECT_PREPARE_FINISHED",
        "Подготовка сессии завершена",
        "Session prepare finished",
        "Подготовка конфигурации завершена",
        "Если outcome=failure, проверяйте reason_code и server logs",
        "info",
    ),
    (
        "VPN_TUNNEL_ESTABLISHED",
        "Туннель установлен",
        "Tunnel established",
        "Клиент установил VPN туннель",
        "Проверьте наличие VPN_TUNNEL_CLOSED и traffic_first_seen",
        "info",
    ),
    (
        "VPN_TUNNEL_CLOSED",
        "Туннель закрыт",
        "Tunnel closed",
        "VPN сессия завершена",
        "Если частые циклы open/close — возможен reconnect storm",
        "info",
    ),
    (
        "VPN_CLIENT_CONNECTION_ERROR",
        "Ошибка подключения клиента",
        "Client connection error",
        "Клиент не смог установить стабильное соединение",
        "Сверьте reason_code, server health и конфликты конфигурации",
        "error",
    ),
    (
        "VPN_CONFIG_CONFLICT_DETECTED",
        "Конфликт конфигурации VPN",
        "VPN config conflict",
        "Ожидаемая конфигурация не совпала с фактической",
        "Проверьте hash/revision и очередь apply задач",
        "error",
    ),
]


def main() -> None:
    db = SessionLocal()
    try:
        for event_name, ru, en, template, hint, severity in SEED_ROWS:
            upsert_event_dictionary(
                db,
                event_name=event_name,
                display_name_ru=ru,
                display_name_en=en,
                default_comment_template=template,
                operator_hint=hint,
                severity_default=severity,
                commit=False,
            )
        db.commit()
        print(f"Seeded event dictionary rows: {len(SEED_ROWS)}")
    finally:
        db.close()


if __name__ == "__main__":
    main()

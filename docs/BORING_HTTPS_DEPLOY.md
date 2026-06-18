# Boring HTTPS (сценарий 4): развёртывание и диагностика

Цепочка: Android TUN -> POST /api/vpn/tunnel (4 байта длина + payload) -> gateway -> Unix-сокет -> TUN-хелпер (TUN на сервере) -> интернет. Без TUN-хелпера gateway возвращает пустой ответ, трафик не идёт.

## Переменные (backend)

- BORING_HTTPS_GATEWAY_URL — URL шлюза; если задан, протокол boring_https в supported_protocols.
- BORING_HTTPS_SNI — опционально (прикрытие).
- BORING_HTTPS_TUN_SOCKET — путь к Unix-сокету TUN-хелпера; если задан и сокет есть, пакеты пересылаются в хелпер.

## TUN-хелпер

Запуск с root (или CAP_NET_ADMIN):

  sudo python3 backend/scripts/boring_https_tun_helper.py --socket /run/grani/boring_https_tun.sock

С маршрутизацией в интернет (forwarding + NAT). Подсеть 10.0.0.1/30 совпадает с клиентом Android (10.0.0.2/30):

  sudo python3 backend/scripts/boring_https_tun_helper.py --socket /run/grani/boring_https_tun.sock --tun-ip 10.0.0.1/30 --setup-routing

После запуска в API задать BORING_HTTPS_TUN_SOCKET=/run/grani/boring_https_tun.sock и перезапустить API.

## Docker

- Хелпер на хосте: сокет в volume для API (например /run/grani на хосте в volume).
- Контейнер: использовать опциональный compose `server-config/docker/docker-compose.boring-https.yml`:
  `docker compose -f docker-compose.yml -f docker-compose.boring-https.yml up -d`
  Добавляется сервис boring_https_tun (NET_ADMIN, /dev/net/tun) и volume с сокетом для api. В .env задать BORING_HTTPS_TUN_SOCKET=/run/grani/boring_https_tun.sock.

## Диагностика

Логи API (docker logs): "Boring HTTPS gateway: tunnel frame #N, payload_len=L (маршрутизация: TUN-сокет|выключена)". Если выключена — сокет не задан или недоступен. Проверка сокета: ls -la /run/grani/boring_https_tun.sock.

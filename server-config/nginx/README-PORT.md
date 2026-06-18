# Порт бэкенда API

Nginx проксирует запросы `/api/` в upstream **api_backend** на `127.0.0.1:8010`.

Отдельных location для новых путей не нужно: например `POST /api/vpn/session/prepare` уходит на тот же upstream, что и остальной `/api/`.

- На проде бэкенд (uvicorn/systemd) должен слушать **порт 8010**, иначе логин в админку и API будут падать (502/connection refused).
- Админка в браузере порт не указывает: запросы идут на `https://admin.granilink.com/api/...` (порт 443), Nginx проксирует на 8010.

Если запускаете uvicorn вручную: `uvicorn main:app --host 0.0.0.0 --port 8010`

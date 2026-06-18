# Дальнейшие действия: Desktop GRANI VPN

## 1. Завершить push на GitHub

1. Создать репозиторий на https://github.com/new (если ещё нет)
2. Добавить remote: `git remote add origin https://github.com/YOUR_USERNAME/grani.git`
3. Добавить проект: `git add .` → `git commit -m "Add full project"` → `git push -u origin master`
4. Запустить workflow: **Actions** → **Desktop Build** → **Run workflow**
5. Скачать артефакты windows-release и macos-release

## 2. Apple Developer

- Включить Network Extension для App ID `com.granivpn.mobileApp` в Apple Developer Portal
- См. `mobile-app/docs/APPLE_DEVELOPER_SETUP.md`

## 3. Тестирование desktop

- **Windows:** собрать .exe, запуск от администратора, проверить GraniWG
- **macOS:** собрать .app, проверить GraniWG

## 4. AmneziaWG (опционально)

- Интегрировать amneziawg-go по `mobile-app/docs/AMNEZIAWG_INTEGRATION.md`
- Реализовать `_applyAmneziaWGConfig()` в `vpn_service.dart`

## 5. Подпись и распространение

- macOS: подпись и нотаризация по `mobile-app/docs/DESKTOP_DISTRIBUTION.md`

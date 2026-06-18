#!/bin/bash
# Скрипт для запуска веб-сервера раздачи APK

cd /opt/grani
exec /usr/bin/python3 -m http.server 8001

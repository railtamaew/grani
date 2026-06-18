#!/usr/bin/env python3
"""
Celery Beat для GraniVPN
Запуск: celery -A celery_beat beat --loglevel=info
"""

import os
import sys
from celery import Celery
from celery.schedules import crontab

# Добавляем текущую директорию в путь
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from services.celery_app import celery_app

# Настройка расписания задач
celery_app.conf.beat_schedule = {
    # Проверка истечения подписок каждый час
    'check-subscription-expiry': {
        'task': 'vpn.check_subscription_expiry',
        'schedule': 3600.0,  # 1 час
    },

    # Отправка предупреждений об истечении подписки каждый день в 9:00
    'send-subscription-warnings': {
        'task': 'notifications.send_subscription_expiry_warning',
        'schedule': crontab(hour=9, minute=0),  # Каждый день в 9:00
    },
    # Проверка истечения триалов каждые 15 минут
    'check-trial-expiry': {
        'task': 'notifications.check_trial_expiry',
        'schedule': 900.0,  # 15 минут
    },
    
    # Мониторинг серверов - обновление нагрузки каждые 30 секунд
    'update-server-load': {
        'task': 'server.update_server_load',
        'schedule': 30.0,  # 30 секунд
    },
    
    # Проверка здоровья серверов: ICMP + fallback TCP, обновление ping_ms в БД и сброс cache:servers:list
    'check-server-health': {
        'task': 'server.check_server_health',
        'schedule': 60.0,  # 1 минута
    },
    
    # Сбор статистики по протоколам каждый день в полночь
    'collect-protocol-stats': {
        'task': 'server.collect_protocol_stats',
        'schedule': crontab(hour=0, minute=0),  # Каждый день в 00:00
    },
    
    # Обновление статистики провайдеров каждые 5 минут
    'update-provider-stats': {
        'task': 'server.update_provider_stats',
        'schedule': 300.0,  # 5 минут
    },

    # Сбор ошибок пользователей из серверных логов каждые 2 минуты
    'collect-server-error-logs': {
        'task': 'server.collect_server_error_logs',
        'schedule': 120.0,  # 2 минуты
    },
    # Детекция инцидентов observability (duplicate/stale/config conflict)
    'detect-observability-incidents': {
        'task': 'observability.detect_incidents',
        'schedule': 60.0,  # 1 минута
    },
    # Оценка rollout policy: auto-promote / auto-rollback по SLI
    'evaluate-rollout-policy': {
        'task': 'observability.evaluate_rollout_policy',
        'schedule': 300.0,  # 5 минут
    },
}

if __name__ == '__main__':
    celery_app.start()










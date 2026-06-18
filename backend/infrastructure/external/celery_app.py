from celery import Celery
from core.config import settings

# Создаем экземпляр Celery
redis_url = getattr(settings, "redis_url", None) or getattr(settings, "REDIS_URL", None)
if not redis_url:
    raise ValueError("REDIS_URL is not configured for Celery")

celery_app = Celery(
    "granivpn",
    broker=redis_url,
    backend=redis_url,
    include=[
        'services.tasks.vpn_tasks',
        'services.tasks.server_monitoring_tasks',
    ]
)

# Конфигурация Celery
celery_app.conf.update(
    task_serializer='json',
    accept_content=['json'],
    result_serializer='json',
    timezone='UTC',
    enable_utc=True,
    task_track_started=True,
    task_time_limit=30 * 60,  # 30 минут
    task_soft_time_limit=25 * 60,  # 25 минут
    worker_prefetch_multiplier=1,
    worker_max_tasks_per_child=1000,
    broker_connection_retry_on_startup=True,
    result_expires=3600,  # 1 час
    task_routes={
        'services.tasks.vpn_tasks.*': {'queue': 'vpn'},
        'services.tasks.server_monitoring_tasks.*': {'queue': 'monitoring'},
    },
    task_default_queue='default',
    task_default_exchange='default',
    task_default_routing_key='default',
)

# Автоматическое обнаружение задач
celery_app.autodiscover_tasks()

if __name__ == '__main__':
    celery_app.start()










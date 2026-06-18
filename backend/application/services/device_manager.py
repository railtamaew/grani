"""
Менеджер для управления устройствами пользователей.

Отвечает за:
- Регистрацию устройств
- Получение списка устройств
- Обновление информации об устройствах
- Разрешение устройства по fingerprint (resolve после переустановки)
"""
import logging
import uuid
from typing import Dict, Any, List, Optional
from datetime import datetime
from sqlalchemy.orm import Session
from fastapi import HTTPException, status

from domain.models.user import User, Device
from infrastructure.repositories.device_repository import DeviceRepository
from core.error_types import AppException, ErrorCode

logger = logging.getLogger(__name__)


class DeviceManager:
    """
    Менеджер для управления устройствами пользователей.

    Инвариант: один логический клиент = один строковый ``device_id`` на пользователя
    в смысле «живой» список API (дубликаты строк в БД не создаём при prepare; старые
    неактивные дубли удаляются). Два разных ``device_id`` у одного аккаунта бывают
    только при разных установках приложения / клоне / смене хранилища без resolve —
    тогда в приложении «текущее» устройство — то, чей ``device_id`` в локальном
    secure storage (см. клиент ``isCurrentDeviceCard``).
    """
    
    _DEVICE_LIMIT = 5

    @staticmethod
    def _ensure_logical_client_id(device: Device) -> None:
        """
        Назначает стабильный логический client_id на уровне БД.
        Он не означает, что клиент уже применен на VPN-ноде.
        """
        if getattr(device, "vpn_client_id", None):
            return
        device.vpn_client_id = f"logical_{uuid.uuid4().hex}"

    @staticmethod
    def _dedupe_device_rows_for_list(devices: List[Device]) -> List[Device]:
        """
        Одна запись на строковый device_id для API/UI.
        При нескольких строках (история prepare, миграции) оставляем «лучшую»:
        сначала is_active, затем больший id.
        """
        ordered = sorted(
            devices,
            key=lambda d: ((d.is_active is True), d.id or 0),
            reverse=True,
        )
        seen: set[str] = set()
        out: List[Device] = []
        for d in ordered:
            did = (d.device_id or "").strip()
            if not did or did in seen:
                continue
            seen.add(did)
            out.append(d)
        out.sort(
            key=lambda d: ((d.last_connected or datetime.min), d.id or 0),
            reverse=True,
        )
        return out

    @staticmethod
    def _invalidate_devices_list_cache(user_id: int) -> None:
        try:
            from core.cache import cache_delete
            cache_delete(f"cache:devices:{user_id}")
        except Exception:
            pass
    
    def __init__(self, db: Session, wg_manager: Optional[object] = None):
        """
        Инициализация DeviceManager.
        
        Args:
            db: Сессия базы данных
            wg_manager: Deprecated, всегда None для Xray-only.
        """
        self.db = db
        self.wg_manager = wg_manager  # None для Xray-only — ключи WG не генерируются
        self.device_repo = DeviceRepository(db)
    
    def register_device(self, user: User, device_data: Dict[str, Any]) -> Device:
        """
        Регистрирует новое устройство пользователя.

        Если передан fingerprint и у пользователя уже есть устройство с тем же
        отпечатком, но другим строковым device_id (например после сброса данных
        приложения), обновляет строковый device_id у существующей записи вместо
        создания новой.

        Args:
            user: Пользователь
            device_data: Данные устройства:
                - name: str - название устройства
                - device_id: str - уникальный ID устройства
                - platform: str - платформа (ios, android, etc.)
                - fingerprint: str - опционально, для слияния после сброса хранилища

        Returns:
            Зарегистрированное устройство

        Raises:
            Exception: Если регистрация не удалась
        """
        try:
            # Проверяем, не зарегистрировано ли уже это устройство
            device_id = device_data.get('device_id')
            if not device_id:
                raise ValueError("device_id обязателен для регистрации устройства")

            # Слияние по fingerprint до поиска по device_id: иначе «лишняя» строка с новым UUID
            # перехватывает запрос раньше канонической записи с отпечатком.
            fingerprint_raw = device_data.get("fingerprint")
            if fingerprint_raw and str(fingerprint_raw).strip():
                fp = str(fingerprint_raw).strip()
                fp_dev = self.device_repo.get_by_user_and_fingerprint(user.id, fp)
                if fp_dev is not None and fp_dev.device_id != device_id:
                    other = self.device_repo.get_by_device_id(device_id, user.id)
                    if other is not None and other.id != fp_dev.id:
                        logger.info(
                            "register_device: найден дубликат строки устройства id=%s device_id=%s при слиянии по fingerprint в id=%s; оставляем строку (FK-safe), деактивируем",
                            other.id,
                            device_id,
                            fp_dev.id,
                        )
                        other.is_active = False
                        other.is_vpn_enabled = False
                        other.current_server_id = None
                        other.ip_address = None
                        other.vpn_protocol = None
                        self._ensure_logical_client_id(other)

                    fp_dev.device_id = device_id
                    fp_dev.device_fingerprint = fp
                    if device_data.get("name"):
                        fp_dev.device_name = device_data["name"]
                    if device_data.get("platform"):
                        fp_dev.platform = device_data["platform"]
                        fp_dev.device_type = device_data["platform"]

                    provided_public_m = device_data.get("public_key") or device_data.get("wireguard_public_key")
                    provided_private_m = device_data.get("private_key") or device_data.get("wireguard_private_key")
                    if provided_public_m and provided_private_m:
                        fp_dev.wireguard_public_key = provided_public_m
                        fp_dev.wireguard_private_key = provided_private_m

                    fp_dev.is_active = False
                    fp_dev.is_vpn_enabled = False
                    fp_dev.current_server_id = None
                    fp_dev.ip_address = None
                    fp_dev.vpn_protocol = None
                    self._ensure_logical_client_id(fp_dev)

                    self.db.commit()
                    self.db.refresh(fp_dev)
                    self._invalidate_devices_list_cache(user.id)
                    logger.info(
                        "register_device: слияние по fingerprint user_id=%s row_id=%s строковый device_id обновлён на %s",
                        user.id,
                        fp_dev.id,
                        device_id,
                    )
                    self._ensure_logical_client_id(fp_dev)
                    self.db.commit()
                    self.db.refresh(fp_dev)
                    return fp_dev

            existing_devices = self.device_repo.get_all_by_device_id(device_id)
            if existing_devices:
                existing_devices.sort(key=lambda d: d.created_at or datetime.min, reverse=True)
                primary_device = existing_devices[0]
                reassigned_from_other_user = primary_device.user_id != user.id

                if reassigned_from_other_user:
                    logger.warning(
                        f"Device_id уже был привязан к другому пользователю. "
                        f"Перепривязываем device_id={device_id} от user_id={primary_device.user_id} "
                        f"к user_id={user.id}"
                    )
                    primary_device.user_id = user.id

                if reassigned_from_other_user:
                    primary_device.is_active = False
                    primary_device.is_vpn_enabled = False
                    primary_device.current_server_id = None
                    primary_device.ip_address = None
                    primary_device.vpn_protocol = None

                if device_data.get("name"):
                    primary_device.device_name = device_data["name"]
                if device_data.get("platform"):
                    primary_device.platform = device_data["platform"]
                    primary_device.device_type = device_data["platform"]
                self._ensure_logical_client_id(primary_device)

                for duplicate in existing_devices[1:]:
                    duplicate.is_active = False
                    duplicate.is_vpn_enabled = False
                    duplicate.current_server_id = None
                    duplicate.ip_address = None
                    duplicate.vpn_protocol = None
                    self._ensure_logical_client_id(duplicate)

                if device_data.get('fingerprint'):
                    primary_device.device_fingerprint = device_data.get('fingerprint')
                self.db.commit()
                self.db.refresh(primary_device)
                self._invalidate_devices_list_cache(user.id)

                logger.info(
                    f"Устройство уже зарегистрировано: device_id={device_id}, existing_id={primary_device.id}"
                )
                self._ensure_logical_client_id(primary_device)
                self.db.commit()
                self.db.refresh(primary_device)
                return primary_device

            # Используем ключи WireGuard, если переданы, иначе пытаемся сгенерировать
            provided_public = device_data.get("public_key") or device_data.get("wireguard_public_key")
            provided_private = device_data.get("private_key") or device_data.get("wireguard_private_key")
            keys = None
            if provided_public and provided_private:
                keys = {"public_key": provided_public, "private_key": provided_private}
            elif self.wg_manager:
                try:
                    keys = self.wg_manager.generate_key_pair()
                except FileNotFoundError:
                    logger.warning(
                        "WireGuard binary not found during device registration; "
                        "registering device without WG keys."
                    )
                except Exception as e:
                    logger.warning(
                        f"Не удалось сгенерировать ключи WireGuard при регистрации устройства: {e}"
                    )

            device_count = self.device_repo.count_distinct_device_ids_by_user_id(user.id)
            if device_count >= self._DEVICE_LIMIT:
                # Строгий лимит: больше не выполняем «тихое переиспользование» неактивных устройств.
                # Всегда возвращаем DEVICE_LIMIT_EXCEEDED с перечнем устройств для явного выбора на клиенте.
                devices = self._dedupe_device_rows_for_list(
                    self.device_repo.get_by_user_id(user.id)
                )
                device_details = [
                    {
                        "device_id": device.device_id,
                        "device_name": device.device_name,
                        "device_type": device.device_type,
                        "is_active": device.is_active,
                        "created_at": (device.created_at.isoformat() if device.created_at else None),
                        "last_connected": (device.last_connected.isoformat() if device.last_connected else None),
                        "id": device.id,
                    }
                    for device in devices
                ]
                raise AppException(
                    code=ErrorCode.DEVICE_LIMIT_EXCEEDED,
                    message=f"Достигнут лимит устройств ({self._DEVICE_LIMIT})",
                    details={
                        "limit": self._DEVICE_LIMIT,
                        "current_count": device_count,
                        "devices": device_details,
                    },
                    status_code=400
                )
            
            # Создаем устройство
            device = Device(
                user_id=user.id,
                device_name=device_data.get('name', 'Unknown Device'),
                device_id=device_data.get('device_id'),
                device_type=device_data.get('platform'),
                platform=device_data.get('platform'),
                wireguard_public_key=keys.get('public_key') if keys else None,
                wireguard_private_key=keys.get('private_key') if keys else None,
                is_active=False,
                is_vpn_enabled=False,
                last_connected=None,
                device_fingerprint=device_data.get('fingerprint'),
                vpn_client_id=f"logical_{uuid.uuid4().hex}",
            )
            
            self.db.add(device)
            self.db.commit()
            self.db.refresh(device)
            self._invalidate_devices_list_cache(user.id)

            logger.info(f"Зарегистрировано устройство {device.id} для пользователя {user.id}")
            return device
            
        except Exception as e:
            self.db.rollback()
            logger.error(f"Ошибка регистрации устройства: {e}", exc_info=True)
            raise

    def _purge_duplicate_inactive_device_rows(
        self, user_id: int, device_id_str: str, keep_row_id: int
    ) -> int:
        """
        Нормализует прочие неактивные строки с тем же device_id (оставляем keep_row_id).

        ВАЖНО: не удаляем строки физически, т.к. исторические таблицы (client_logs,
        connection_logs) ссылаются на devices.id; delete может попытаться обнулить FK
        и вызвать NotNullViolation.
        """
        did = (device_id_str or "").strip()
        if not did:
            return 0
        dupes = (
            self.db.query(Device)
            .filter(
                Device.user_id == user_id,
                Device.device_id == did,
                Device.id != keep_row_id,
                Device.is_active == False,
            )
            .all()
        )
        removed = 0
        normalized_only = 0
        for d in dupes:
            # Prefer hard-delete so one logical device_id maps to one DB row.
            # If historical FK constraints prevent deletion, fallback to safe normalization.
            deleted = False
            try:
                with self.db.begin_nested():
                    self.db.delete(d)
                    self.db.flush()
                deleted = True
            except Exception:
                deleted = False

            if deleted:
                removed += 1
                continue

            d.is_active = False
            d.is_vpn_enabled = False
            d.current_server_id = None
            d.ip_address = None
            d.vpn_protocol = None
            d.vpn_client_id = None
            normalized_only += 1

        if removed or normalized_only:
            logger.info(
                "purge_duplicate_inactive_device_rows: user_id=%s device_id=%s deleted=%s normalized=%s keep_id=%s",
                user_id,
                did,
                removed,
                normalized_only,
                keep_row_id,
            )
        return removed

    def update_inactive_device_for_prepare(
        self, user: User, device: Device, device_data: Dict[str, Any]
    ) -> Device:
        """
        Обновляет уже найденную неактивную строку ``Device`` для session/prepare:
        не создаёт вторую строку с тем же ``device_id`` (источник дублей в UI и лимите).
        Чистит остальные неактивные дубли того же ``device_id``.
        """
        if not device.device_id:
            raise ValueError("device.device_id обязателен для update_inactive_device_for_prepare")
        if device.user_id != user.id:
            device.user_id = user.id
        if device_data.get("name"):
            device.device_name = device_data["name"]
        if device_data.get("platform"):
            device.platform = device_data["platform"]
            device.device_type = device_data["platform"]
        fp = device_data.get("fingerprint")
        if fp and str(fp).strip():
            device.device_fingerprint = str(fp).strip()
        pub = device_data.get("public_key") or device_data.get("wireguard_public_key")
        prv = device_data.get("private_key") or device_data.get("wireguard_private_key")
        if pub and prv:
            device.wireguard_public_key = pub
            device.wireguard_private_key = prv
        device.is_vpn_enabled = False
        device.current_server_id = None
        device.ip_address = None
        device.vpn_protocol = None
        device.vpn_client_id = None

        self._purge_duplicate_inactive_device_rows(
            user.id, device.device_id, keep_row_id=device.id
        )
        self.db.commit()
        self.db.refresh(device)
        self._invalidate_devices_list_cache(user.id)
        logger.info(
            "update_inactive_device_for_prepare: user_id=%s row_id=%s device_id=%s",
            user.id,
            device.id,
            device.device_id,
        )
        return device

    def create_new_device_row_for_prepare(self, user: User, device_data: Dict[str, Any]) -> Device:
        """
        Совместимость со старым именем: раньше делался INSERT дубля по неактивной строке.
        Сейчас — обновление существующей или register при отсутствии строки.
        """
        device_id = device_data.get("device_id")
        if not device_id:
            raise ValueError("device_id обязателен для create_new_device_row_for_prepare")
        existing = self.device_repo.get_by_device_id(device_id, user.id)
        if existing is not None:
            if getattr(existing, "is_active", False):
                logger.warning(
                    "create_new_device_row_for_prepare: device already active id=%s, returning as-is",
                    existing.id,
                )
                return existing
            return self.update_inactive_device_for_prepare(user, existing, device_data)
        return self.register_device(user, device_data)

    def resolve_device(
        self,
        user: User,
        fingerprint: str,
        name: Optional[str] = None,
        platform: Optional[str] = None,
    ) -> str:
        """
        Возвращает device_id для устройства по fingerprint (после переустановки/очистки).
        Если устройство с таким fingerprint уже есть — возвращаем его device_id и опционально обновляем поля.
        Если нет — создаём новую запись (с учётом лимита и переиспользования) и возвращаем device_id.
        """
        if not fingerprint or not fingerprint.strip():
            raise ValueError("fingerprint обязателен для resolve")
        fingerprint = fingerprint.strip()

        existing = self.device_repo.get_by_user_and_fingerprint(user.id, fingerprint)
        if existing:
            if name is not None:
                existing.device_name = name
            if platform is not None:
                existing.platform = platform
                existing.device_type = platform
            existing.last_connected = datetime.utcnow()
            self.db.commit()
            self.db.refresh(existing)
            self._invalidate_devices_list_cache(user.id)
            logger.info(f"Resolve: найдено устройство по fingerprint, device_id={existing.device_id}, user_id={user.id}")
            return existing.device_id

        # Создаём новое: генерируем device_id и регистрируем
        new_device_id = str(uuid.uuid4())
        payload = {
            "device_id": new_device_id,
            "name": name or f"Device {new_device_id[:8]}",
            "platform": platform or "unknown",
            "fingerprint": fingerprint,
        }
        device = self.register_device(user, payload)
        logger.info(f"Resolve: создано новое устройство по fingerprint, device_id={device.device_id}, user_id={user.id}")
        return device.device_id
    
    def get_user_devices(self, user: User) -> List[Dict[str, Any]]:
        """
        Получает список устройств пользователя с оптимизацией через кэширование.
        
        Args:
            user: Пользователь
        
        Returns:
            Список словарей с информацией об устройствах
        """
        try:
            from core.cache import cache_get, cache_set
            
            # Пытаемся получить из кэша
            cache_key = f"cache:devices:{user.id}"
            cached = cache_get(cache_key)
            if cached:
                logger.debug(f"Устройства пользователя {user.id} получены из кэша")
                return cached
            
            # Получаем устройства из репозитория (без дублей строк с одним device_id)
            devices = self._dedupe_device_rows_for_list(
                self.device_repo.get_by_user_id(user.id)
            )

            # Предзагружаем серверы одним запросом
            from models.server import Server
            server_ids = [d.current_server_id for d in devices if d.current_server_id]
            servers_dict = {}
            if server_ids:
                servers = self.db.query(Server).filter(Server.id.in_(server_ids)).all()
                servers_dict = {s.id: s for s in servers}
            
            result = []
            for device in devices:
                # Получаем сервер из предзагруженного словаря
                server = servers_dict.get(device.current_server_id) if device.current_server_id else None
                
                # Формируем статус устройства
                status = {
                    'connected': device.is_active,
                    'ip_address': device.ip_address,
                    'server': {
                        'id': server.id,
                        'name': server.name,
                        'country': server.country,
                        'city': server.city
                    } if server else None,
                    'connected_since': device.last_connected.isoformat() if device.last_connected else None
                } if device.is_active else {
                    'connected': False,
                    'ip_address': None,
                    'server': None
                }
                
                result.append({
                    'id': device.id,
                    'name': device.device_name,
                    'platform': device.device_type,
                    'device_name': device.device_name,
                    'device_type': device.device_type,
                    'device_id': device.device_id,
                    'is_active': device.is_active,
                    'last_connected': device.last_connected.isoformat() if device.last_connected else None,
                    'status': status
                })
            
            # Кэшируем результат на 60 секунд
            cache_set(cache_key, result, ttl=60)
            logger.debug(f"Устройства пользователя {user.id} загружены из БД и закэшированы: count={len(result)}")
            
            return result
            
        except Exception as e:
            logger.error(f"Ошибка получения устройств пользователя: {e}", exc_info=True)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Временная ошибка при загрузке списка устройств. Повторите попытку.",
            ) from e
    
    def get_device_by_id(self, device_id: int, user_id: Optional[int] = None) -> Optional[Device]:
        """
        Получает устройство по ID.
        
        Args:
            device_id: ID устройства
            user_id: ID пользователя (опционально, для проверки принадлежности)
        
        Returns:
            Устройство или None если не найдено
        """
        device = self.device_repo.get(device_id)
        
        if device and user_id and device.user_id != user_id:
            logger.warning(f"Попытка доступа к устройству {device_id} пользователем {user_id} (устройство принадлежит пользователю {device.user_id})")
            return None
        
        return device
    
    def update_device(self, device: Device, updates: Dict[str, Any]) -> Device:
        """
        Обновляет информацию об устройстве.
        
        Args:
            device: Устройство для обновления
            updates: Словарь с обновлениями
        
        Returns:
            Обновленное устройство
        """
        try:
            for key, value in updates.items():
                if hasattr(device, key):
                    setattr(device, key, value)
            
            self.db.commit()
            self.db.refresh(device)
            
            # Инвалидируем кэш устройств пользователя
            from core.cache import cache_delete
            cache_key = f"cache:devices:{device.user_id}"
            cache_delete(cache_key)
            
            logger.info(f"Устройство {device.id} обновлено")
            return device
            
        except Exception as e:
            self.db.rollback()
            logger.error(f"Ошибка обновления устройства {device.id}: {e}", exc_info=True)
            raise

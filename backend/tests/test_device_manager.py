"""
Интеграционные тесты для DeviceManager.
Проверяют регистрацию устройств, получение списка устройств и обновление.
"""
import pytest
from datetime import datetime
from sqlalchemy.orm import Session

from models.user import User, Device
from services.device_manager import DeviceManager
from services.wireguard_manager import WireGuardManager
from repositories.device_repository import DeviceRepository
from core.error_types import AppException, ErrorCode


@pytest.fixture
def device_manager(db_session: Session, test_user: User):
    """Создает DeviceManager для тестирования"""
    wg_manager = WireGuardManager()
    return DeviceManager(db_session, wg_manager)


class TestDeviceManager:
    """Тесты для DeviceManager"""
    
    def test_register_new_device(self, device_manager: DeviceManager, test_user: User):
        """Тест регистрации нового устройства"""
        device_data = {
            'name': 'Test Device',
            'device_id': 'test-device-123',
            'platform': 'android'
        }
        
        device = device_manager.register_device(test_user, device_data)
        
        assert device is not None
        assert device.user_id == test_user.id
        assert device.device_name == 'Test Device'
        assert device.device_id == 'test-device-123'
        assert device.device_type == 'android'
        assert device.wireguard_public_key is not None
        assert device.wireguard_private_key is not None
        assert device.is_active == False
    
    def test_register_existing_device(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест регистрации уже существующего устройства (должно вернуть существующее)"""
        device_data = {
            'name': 'Test Device',
            'device_id': 'test-device-456',
            'platform': 'ios'
        }
        
        # Регистрируем устройство первый раз
        device1 = device_manager.register_device(test_user, device_data)
        device_id_1 = device1.id
        
        # Пытаемся зарегистрировать снова
        device2 = device_manager.register_device(test_user, device_data)
        
        # Должно вернуть то же устройство
        assert device2.id == device_id_1
        assert device2.device_id == 'test-device-456'
    
    def test_get_user_devices_empty(self, device_manager: DeviceManager, test_user: User):
        """Тест получения списка устройств для пользователя без устройств"""
        devices = device_manager.get_user_devices(test_user)
        
        assert isinstance(devices, list)
        assert len(devices) == 0
    
    def test_get_user_devices_with_devices(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест получения списка устройств для пользователя с устройствами"""
        # Очищаем кэш перед тестом
        from core.cache import cache_delete
        cache_delete(f"cache:devices:{test_user.id}")
        
        # Регистрируем несколько устройств
        device1_data = {'name': 'Device 1', 'device_id': 'dev-1', 'platform': 'android'}
        device2_data = {'name': 'Device 2', 'device_id': 'dev-2', 'platform': 'ios'}
        
        device1 = device_manager.register_device(test_user, device1_data)
        device2 = device_manager.register_device(test_user, device2_data)
        db_session.refresh(device1)
        db_session.refresh(device2)
        
        # Очищаем кэш после регистрации, чтобы получить свежие данные
        cache_delete(f"cache:devices:{test_user.id}")
        
        devices = device_manager.get_user_devices(test_user)
        
        assert len(devices) == 2
        assert all('id' in d for d in devices)
        assert all('name' in d for d in devices)
        assert all('platform' in d for d in devices)
        assert all('device_id' in d for d in devices)
        assert all('is_active' in d for d in devices)
    
    def test_get_device_by_id_success(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест получения устройства по ID"""
        device_data = {'name': 'Test Device', 'device_id': 'test-device-789', 'platform': 'android'}
        created_device = device_manager.register_device(test_user, device_data)
        db_session.refresh(created_device)
        
        # get_device_by_id принимает (device_id, user_id)
        retrieved_device = device_manager.get_device_by_id(created_device.id, test_user.id)
        
        assert retrieved_device.id == created_device.id
        assert retrieved_device.device_id == 'test-device-789'
    
    def test_get_device_by_id_not_found(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест получения несуществующего устройства по ID"""
        from fastapi import HTTPException
        
        # Используем очень большое число, которое точно не существует
        # get_device_by_id возвращает None, а не HTTPException
        retrieved_device = device_manager.get_device_by_id(999999, test_user.id)
        assert retrieved_device is None
    
    def test_get_device_by_id_wrong_user(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест получения устройства другого пользователя"""
        from fastapi import HTTPException
        from models.user import User
        
        # Создаем другого пользователя
        other_user = User(
            email='other@test.com',
            password_hash='hash',
            is_verified=True,
            auth_provider='email'
        )
        db_session.add(other_user)
        db_session.commit()
        db_session.refresh(other_user)
        
        # Создаем устройство для другого пользователя напрямую
        from models.user import Device
        other_device = Device(
            user_id=other_user.id,
            device_name='Other Device',
            device_id='other-device',
            device_type='android',
            wireguard_public_key='pubkey',
            wireguard_private_key='privkey',
            is_active=False
        )
        db_session.add(other_device)
        db_session.commit()
        db_session.refresh(other_device)
        
        # Пытаемся получить устройство другого пользователя
        # get_device_by_id возвращает None, если устройство принадлежит другому пользователю
        retrieved_device = device_manager.get_device_by_id(other_device.id, test_user.id)
        assert retrieved_device is None
    
    def test_update_device(self, device_manager: DeviceManager, test_user: User):
        """Тест обновления устройства"""
        device_data = {'name': 'Original Name', 'device_id': 'test-device-update', 'platform': 'android'}
        device = device_manager.register_device(test_user, device_data)
        
        update_data = {'device_name': 'Updated Name', 'is_active': True}
        updated_device = device_manager.update_device(device, update_data)
        
        assert updated_device.device_name == 'Updated Name'
        assert updated_device.is_active == True
        assert updated_device.device_id == 'test-device-update'  # Не должно измениться

    def test_register_device_limit_exceeded(self, device_manager: DeviceManager, test_user: User, db_session: Session):
        """Тест превышения лимита устройств (все активны — переиспользовать нечего)"""
        for index in range(5):
            dev = device_manager.register_device(
                test_user,
                {
                    'name': f'Device {index}',
                    'device_id': f'limit-device-{index}',
                    'platform': 'android'
                }
            )
            dev.is_active = True
            db_session.commit()

        with pytest.raises(AppException) as exc_info:
            device_manager.register_device(
                test_user,
                {
                    'name': 'Device 6',
                    'device_id': 'limit-device-6',
                    'platform': 'android'
                }
            )

        assert exc_info.value.code == ErrorCode.DEVICE_LIMIT_EXCEEDED

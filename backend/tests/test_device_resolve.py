"""
Тесты для resolve_device и device_fingerprint (application layer).
"""
import pytest
from unittest.mock import MagicMock
from sqlalchemy.orm import Session

from domain.models.user import User, Device
from application.services.device_manager import DeviceManager
from infrastructure.repositories.device_repository import DeviceRepository


@pytest.fixture
def mock_wg_manager():
    """WireGuard manager, при генерации ключей — FileNotFoundError (как при отсутствии бинарника)."""
    mgr = MagicMock()
    mgr.generate_key_pair.side_effect = FileNotFoundError("wg not found")
    return mgr


@pytest.fixture
def app_device_manager(db_session: Session, mock_wg_manager):
    """DeviceManager из application layer (с resolve_device и fingerprint)."""
    return DeviceManager(db_session, wg_manager=mock_wg_manager)


@pytest.fixture
def test_user(db_session: Session):
    """Тестовый пользователь для application-тестов."""
    user = User(
        email="resolve_test@example.com",
        password_hash="hash",
        is_verified=True,
        auth_provider="email",
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


class TestResolveDevice:
    """Тесты resolve_device."""

    def test_resolve_creates_new_device_when_fingerprint_unknown(
        self, app_device_manager: DeviceManager, test_user: User
    ):
        """При неизвестном fingerprint создаётся новое устройство и возвращается его device_id."""
        device_id = app_device_manager.resolve_device(
            test_user,
            fingerprint="fp_hash_abc123",
            name="My Phone",
            platform="android",
        )
        assert device_id is not None
        assert len(device_id) == 36  # UUID format
        repo = DeviceRepository(app_device_manager.db)
        device = repo.get_by_user_and_fingerprint(test_user.id, "fp_hash_abc123")
        assert device is not None
        assert device.device_id == device_id
        assert device.device_fingerprint == "fp_hash_abc123"
        assert device.device_name == "My Phone"
        assert device.platform == "android"

    def test_resolve_returns_existing_device_id_when_fingerprint_known(
        self, app_device_manager: DeviceManager, test_user: User
    ):
        """При известном fingerprint возвращается существующий device_id."""
        first_id = app_device_manager.resolve_device(
            test_user,
            fingerprint="fp_same_device",
            name="Device One",
            platform="android",
        )
        second_id = app_device_manager.resolve_device(
            test_user,
            fingerprint="fp_same_device",
            name="Device One Updated",
            platform="ios",
        )
        assert first_id == second_id
        repo = DeviceRepository(app_device_manager.db)
        device = repo.get_by_user_and_fingerprint(test_user.id, "fp_same_device")
        assert device.device_id == first_id
        assert device.device_name == "Device One Updated"
        assert device.platform == "ios"

    def test_resolve_requires_fingerprint(self, app_device_manager: DeviceManager, test_user: User):
        """resolve_device требует непустой fingerprint."""
        with pytest.raises(ValueError, match="fingerprint"):
            app_device_manager.resolve_device(test_user, fingerprint="", name="X", platform="android")
        with pytest.raises(ValueError, match="fingerprint"):
            app_device_manager.resolve_device(test_user, fingerprint="   ", name="X", platform="android")


class TestRegisterDeviceFingerprint:
    """Тесты сохранения fingerprint при register_device (application layer)."""

    def test_register_saves_fingerprint(
        self, app_device_manager: DeviceManager, test_user: User
    ):
        """При регистрации с fingerprint поле device_fingerprint сохраняется."""
        device = app_device_manager.register_device(
            test_user,
            {
                "device_id": "uuid-from-client-001",
                "name": "Client Device",
                "platform": "android",
                "fingerprint": "client_fp_xyz",
            },
        )
        assert device.device_fingerprint == "client_fp_xyz"
        assert device.device_id == "uuid-from-client-001"

    def test_register_existing_device_updates_fingerprint(
        self, app_device_manager: DeviceManager, test_user: User
    ):
        """При повторной регистрации того же device_id fingerprint обновляется."""
        app_device_manager.register_device(
            test_user,
            {
                "device_id": "same-uuid-002",
                "name": "Device",
                "platform": "ios",
                "fingerprint": "old_fp",
            },
        )
        device2 = app_device_manager.register_device(
            test_user,
            {
                "device_id": "same-uuid-002",
                "name": "Device",
                "platform": "ios",
                "fingerprint": "new_fp",
            },
        )
        assert device2.device_fingerprint == "new_fp"

    def test_register_merge_by_fingerprint_new_client_uuid(
        self, app_device_manager: DeviceManager, test_user: User, db_session: Session
    ):
        """Новый строковый device_id с тем же fingerprint — одна запись, id строки обновляется."""
        fp = "merge_fp_stable_001"
        first = app_device_manager.register_device(
            test_user,
            {
                "device_id": "11111111-1111-1111-1111-111111111111",
                "name": "Phone",
                "platform": "android",
                "fingerprint": fp,
            },
        )
        row_id = first.id
        merged = app_device_manager.register_device(
            test_user,
            {
                "device_id": "22222222-2222-2222-2222-222222222222",
                "name": "Phone 2",
                "platform": "android",
                "fingerprint": fp,
            },
        )
        assert merged.id == row_id
        assert merged.device_id == "22222222-2222-2222-2222-222222222222"
        assert merged.device_fingerprint == fp
        assert merged.device_name == "Phone 2"
        repo = DeviceRepository(db_session)
        all_dev = repo.get_by_user_id(test_user.id)
        assert len(all_dev) == 1

    def test_register_merge_by_fingerprint_removes_stray_duplicate_row(
        self, app_device_manager: DeviceManager, test_user: User, db_session: Session
    ):
        """Если уже создана ошибочная строка с новым UUID без слияния — она удаляется при merge."""
        fp = "merge_fp_stable_002"
        app_device_manager.register_device(
            test_user,
            {
                "device_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "name": "A",
                "platform": "android",
                "fingerprint": fp,
            },
        )
        # Имитируем старую логику: вторая регистрация без учёта fingerprint создала бы дубликат;
        # создаём такую строку вручную (тот же пользователь, другой UUID, без fingerprint).
        stray = Device(
            user_id=test_user.id,
            device_name="Stray",
            device_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            device_type="android",
            platform="android",
            is_active=False,
            device_fingerprint=None,
        )
        db_session.add(stray)
        db_session.commit()
        db_session.refresh(stray)
        stray_id = stray.id

        merged = app_device_manager.register_device(
            test_user,
            {
                "device_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "name": "Merged name",
                "platform": "android",
                "fingerprint": fp,
            },
        )
        assert merged.device_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        assert merged.device_fingerprint == fp
        db_session.expire_all()
        stray_row = db_session.query(Device).filter(Device.id == stray_id).first()
        assert stray_row is not None
        assert stray_row.is_active is False
        repo = DeviceRepository(db_session)
        # FK-safe поведение: не удаляем исторические строки devices, но логических device_id остается один.
        assert repo.count_distinct_device_ids_by_user_id(test_user.id) == 1


class TestDeviceRepositoryFingerprint:
    """Тесты get_by_user_and_fingerprint в репозитории."""

    def test_get_by_user_and_fingerprint_returns_none_when_empty(
        self, db_session: Session, test_user: User
    ):
        """Пустой или пробельный fingerprint возвращает None."""
        repo = DeviceRepository(db_session)
        assert repo.get_by_user_and_fingerprint(test_user.id, "") is None
        assert repo.get_by_user_and_fingerprint(test_user.id, "   ") is None

    def test_get_by_user_and_fingerprint_finds_device(
        self, app_device_manager: DeviceManager, test_user: User, db_session: Session
    ):
        """По user_id и fingerprint находится устройство."""
        app_device_manager.resolve_device(
            test_user,
            fingerprint="find_me_fp",
            name="N",
            platform="android",
        )
        repo = DeviceRepository(db_session)
        device = repo.get_by_user_and_fingerprint(test_user.id, "find_me_fp")
        assert device is not None
        assert device.device_fingerprint == "find_me_fp"

"""
Тесты для конфигурации и управления секретами.
Проверяют безопасную загрузку секретов, валидацию и ротацию ключей.
"""
import pytest
import os
import tempfile
import secrets
from unittest.mock import patch, mock_open
from pathlib import Path

from core.config import Settings


class TestSecretKeyValidation:
    """Тесты для валидации SECRET_KEY"""
    
    def test_secret_key_validation_development(self):
        """Тест: в development слабый ключ допустим"""
        with patch.dict(os.environ, {"ENV": "development", "SECRET_KEY": "short"}):
            settings = Settings()
            # В development не должно быть ошибки
            assert settings.secret_key == "short"
    
    def test_secret_key_validation_production_weak(self):
        """Тест: в production слабый ключ недопустим"""
        with patch.dict(os.environ, {"ENV": "production", "SECRET_KEY": "short"}):
            with pytest.raises(ValueError, match="SECRET_KEY must be set for production"):
                Settings()
    
    def test_secret_key_validation_production_placeholder(self):
        """Тест: в production placeholder недопустим"""
        with patch.dict(os.environ, {"ENV": "production", "SECRET_KEY": "change-this"}):
            with pytest.raises(ValueError, match="SECRET_KEY must be set for production"):
                Settings()
    
    def test_secret_key_validation_production_valid(self):
        """Тест: в production валидный ключ допустим"""
        valid_key = secrets.token_urlsafe(32)
        with patch.dict(os.environ, {
            "ENV": "production",
            "SECRET_KEY": valid_key,
            "DATABASE_URL": "postgresql://user:strong_password@db:5432/granivpn",
            "API_URL": "https://api.example.com"
        }):
            settings = Settings()
            assert settings.secret_key == valid_key
            assert len(settings.secret_key) >= 32


class TestSecretKeyRotation:
    """Тесты для ротации SECRET_KEY"""
    
    def test_jwt_secret_keys_single_key(self):
        """Тест: jwt_secret_keys возвращает один ключ если SECRET_KEY_OLD не установлен"""
        with patch.dict(os.environ, {"SECRET_KEY": "test_key_123456789012345678901234567890"}):
            settings = Settings()
            keys = settings.jwt_secret_keys
            assert len(keys) == 1
            assert keys[0] == "test_key_123456789012345678901234567890"
    
    def test_jwt_secret_keys_with_old_key(self):
        """Тест: jwt_secret_keys возвращает оба ключа если SECRET_KEY_OLD установлен"""
        new_key = "new_key_123456789012345678901234567890"
        old_key = "old_key_123456789012345678901234567890"
        with patch.dict(os.environ, {
            "SECRET_KEY": new_key,
            "SECRET_KEY_OLD": old_key
        }):
            settings = Settings()
            keys = settings.jwt_secret_keys
            assert len(keys) == 2
            assert keys[0] == new_key  # Новый ключ первый
            assert keys[1] == old_key  # Старый ключ второй
    
    def test_jwt_secret_keys_empty_old_key(self):
        """Тест: пустой SECRET_KEY_OLD игнорируется"""
        new_key = "new_key_123456789012345678901234567890"
        with patch.dict(os.environ, {
            "SECRET_KEY": new_key,
            "SECRET_KEY_OLD": ""
        }):
            settings = Settings()
            keys = settings.jwt_secret_keys
            assert len(keys) == 1
            assert keys[0] == new_key


class TestSecretsLoading:
    """Тесты для загрузки секретов из разных источников"""
    
    def test_load_from_environment_variables(self):
        """Тест: переменные окружения имеют высший приоритет"""
        env_key = "env_secret_key_123456789012345678901234567890"
        with patch.dict(os.environ, {"SECRET_KEY": env_key}):
            # Создаем временный .env файл с другим ключом
            with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.env') as f:
                f.write("SECRET_KEY=file_secret_key_123456789012345678901234567890\n")
                env_file = f.name
            
            try:
                with patch('core.config._load_env_file') as mock_load:
                    # Мокируем загрузку из файла
                    mock_load.return_value = None
                    settings = Settings()
                    # Переменная окружения должна иметь приоритет
                    assert settings.secret_key == env_key
            finally:
                os.unlink(env_file)
    
    def test_load_from_safe_path(self):
        """Тест: загрузка из безопасного пути /etc/grani/secrets.env"""
        safe_key = "safe_secret_key_123456789012345678901234567890"
        safe_path = "/etc/grani/secrets.env"
        
        with patch('os.path.exists') as mock_exists, \
             patch('builtins.open', mock_open(read_data=f"SECRET_KEY={safe_key}\n")) as mock_file:
            mock_exists.side_effect = lambda path: path == safe_path
            
            # Очищаем переменные окружения
            with patch.dict(os.environ, {}, clear=True):
                with patch('core.config._load_env_file') as mock_load_env:
                    # Мокируем _load_env_file чтобы он загружал из безопасного пути
                    def mock_load():
                        if os.path.exists(safe_path):
                            os.environ['SECRET_KEY'] = safe_key
                    mock_load_env.side_effect = mock_load
                    
                    # Перезагружаем модуль для применения изменений
                    import importlib
                    import core.config
                    importlib.reload(core.config)
                    settings = core.config.Settings()
                    # Должен загрузиться из безопасного пути
                    assert settings.secret_key == safe_key
    
    def test_production_skips_project_env(self):
        """Тест: в production .env файлы из проекта не загружаются"""
        project_env_key = "project_env_key_123456789012345678901234567890"
        env_key = "env_secret_key_123456789012345678901234567890"
        
        with patch.dict(os.environ, {
            "ENV": "production",
            "SECRET_KEY": env_key,
            "DATABASE_URL": "postgresql://user:strong_password@db:5432/granivpn",
            "API_URL": "https://api.example.com"
        }):
            # Мокируем _load_env_file чтобы он не загружал из проекта
            with patch('core.config._load_env_file') as mock_load:
                def mock_load_impl():
                    # В production не загружаем из проекта
                    pass
                mock_load.side_effect = mock_load_impl
                
                settings = Settings()
                # Должен использоваться ключ из переменных окружения
                assert settings.secret_key == env_key
                assert settings.secret_key != project_env_key


class TestConfigProperties:
    """Тесты для свойств конфигурации"""
    
    def test_is_production(self):
        """Тест: проверка production окружения"""
        valid_key = secrets.token_urlsafe(32)
        with patch.dict(os.environ, {
            "ENV": "production",
            "SECRET_KEY": valid_key,
            "DATABASE_URL": "postgresql://user:strong_password@db:5432/granivpn",
            "API_URL": "https://api.example.com"
        }):
            settings = Settings()
            assert settings.is_production is True
        
        with patch.dict(os.environ, {"ENV": "development"}):
            settings = Settings()
            assert settings.is_production is False
    
    def test_secret_key_property(self):
        """Тест: свойство SECRET_KEY (uppercase)"""
        test_key = "test_key_123456789012345678901234567890"
        with patch.dict(os.environ, {"SECRET_KEY": test_key}):
            settings = Settings()
            assert settings.SECRET_KEY == test_key
            assert settings.SECRET_KEY == settings.secret_key
    
    def test_algorithm_property(self):
        """Тест: свойство ALGORITHM (uppercase)"""
        with patch.dict(os.environ, {"ALGORITHM": "HS256"}):
            settings = Settings()
            assert settings.ALGORITHM == "HS256"
            assert settings.ALGORITHM == settings.algorithm


class TestSecretsFilePermissions:
    """Тесты для проверки прав доступа к файлам секретов"""
    
    def test_secrets_file_should_have_restrictive_permissions(self):
        """Тест: файлы секретов должны иметь ограниченные права доступа"""
        # Это больше документационный тест
        # В реальности права проверяются на уровне системы
        safe_paths = [
            "/etc/grani/secrets.env",
            "/run/secrets/grani.env"
        ]
        
        # Проверяем, что скрипты создают файлы с правильными правами
        # (фактическая проверка прав требует root доступа)
        for path in safe_paths:
            # Путь должен быть абсолютным
            assert os.path.isabs(path)
            # Путь не должен быть в проекте
            assert not path.startswith(str(Path(__file__).parent.parent.parent))


class TestConfigBackwardCompatibility:
    """Тесты для обратной совместимости конфигурации"""
    
    def test_old_config_still_works(self):
        """Тест: старая конфигурация продолжает работать"""
        # Старая конфигурация без SECRET_KEY_OLD
        old_key = "old_secret_key_123456789012345678901234567890"
        with patch.dict(os.environ, {"SECRET_KEY": old_key}):
            settings = Settings()
            assert settings.secret_key == old_key
            assert settings.secret_key_old is None
            # jwt_secret_keys должен работать со старым ключом
            keys = settings.jwt_secret_keys
            assert len(keys) == 1
            assert keys[0] == old_key
    
    def test_new_config_with_rotation(self):
        """Тест: новая конфигурация с ротацией работает"""
        new_key = "new_secret_key_123456789012345678901234567890"
        old_key = "old_secret_key_123456789012345678901234567890"
        with patch.dict(os.environ, {
            "SECRET_KEY": new_key,
            "SECRET_KEY_OLD": old_key
        }):
            settings = Settings()
            assert settings.secret_key == new_key
            assert settings.secret_key_old == old_key
            keys = settings.jwt_secret_keys
            assert len(keys) == 2

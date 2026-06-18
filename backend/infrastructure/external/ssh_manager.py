import hashlib
import logging
import paramiko
import io
import socket
import threading
import time
from typing import Dict, Any, Optional, Callable, TypeVar
from paramiko import SSHClient, AutoAddPolicy
from paramiko.rsakey import RSAKey
from paramiko.ecdsakey import ECDSAKey
from paramiko.ed25519key import Ed25519Key

try:
    from infrastructure.external.ssh_retry_manager import SSHRetryManager
    RETRY_MANAGER_AVAILABLE = True
except ImportError:
    SSHRetryManager = None
    RETRY_MANAGER_AVAILABLE = False

logger = logging.getLogger(__name__)
T = TypeVar("T")

# Процесс-локальный пул: одно простаивающее SSH-соединение на ключ (host:port:user:auth).
# Снижает повторные TCP+handshake при prepare/create-client. Не разделяется между Gunicorn workers.
_POOL_MAX_IDLE_SEC = 120.0
_idle_pool: Dict[str, SSHClient] = {}
_pool_last_return: Dict[str, float] = {}
_pool_registry_lock = threading.Lock()
_key_locks: Dict[str, threading.RLock] = {}
_key_locks_mutex = threading.Lock()


def _ssh_pool_key(
    host: str,
    port: int,
    username: str,
    key_path: Optional[str],
    key_content: Optional[str],
    password: Optional[str],
) -> str:
    if key_content:
        auth = hashlib.sha256(
            key_content.encode("utf-8", errors="ignore")
        ).hexdigest()[:16]
    elif key_path:
        auth = f"path:{key_path}"
    else:
        auth = "pwd"
    return f"{host}:{int(port)}:{username}:{auth}"


def _get_ssh_pool_lock(pool_key: str) -> threading.RLock:
    with _key_locks_mutex:
        lk = _key_locks.get(pool_key)
        if lk is None:
            lk = threading.RLock()
            _key_locks[pool_key] = lk
        return lk


def _take_pooled_ssh_client(pool_key: str) -> Optional[SSHClient]:
    with _pool_registry_lock:
        client = _idle_pool.pop(pool_key, None)
        last_ret = _pool_last_return.get(pool_key, 0.0)
    if client is None:
        return None
    if time.monotonic() - last_ret > _POOL_MAX_IDLE_SEC:
        try:
            client.close()
        except Exception:
            pass
        return None
    try:
        transport = client.get_transport()
        if transport and transport.is_active():
            return client
    except Exception:
        pass
    try:
        client.close()
    except Exception:
        pass
    return None


def _return_pooled_ssh_client(pool_key: str, client: Optional[SSHClient]) -> None:
    if client is None:
        return
    try:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            client.close()
            return
    except Exception:
        try:
            client.close()
        except Exception:
            pass
        return
    with _pool_registry_lock:
        old = _idle_pool.pop(pool_key, None)
        if old is not None and old is not client:
            try:
                old.close()
            except Exception:
                pass
        _idle_pool[pool_key] = client
        _pool_last_return[pool_key] = time.monotonic()


class SSHManager:
    """Менеджер для работы с SSH соединениями через paramiko"""
    
    def __init__(self):
        self.timeout = 30  # Таймаут подключения в секундах
        self.command_timeout = 30
        self.sftp_timeout = 30
        self.keepalive_interval = 30  # Интервал keepalive в секундах
        self.max_retries = 3
        self.initial_delay = 1.0
        self.backoff_factor = 2.0

    def _is_retryable_exception(self, exc: Exception) -> bool:
        return isinstance(
            exc,
            (
                paramiko.ssh_exception.SSHException,
                EOFError,
                socket.timeout,
                OSError,
            ),
        )

    def _execute_with_retry(self, operation: Callable[[], Any], error_context: str) -> Any:
        if RETRY_MANAGER_AVAILABLE and SSHRetryManager:
            return SSHRetryManager.execute_with_retry(
                operation,
                max_retries=self.max_retries,
                initial_delay=self.initial_delay
            )
        delay = self.initial_delay
        last_exc = None
        for attempt in range(1, self.max_retries + 1):
            try:
                return operation()
            except Exception as exc:
                last_exc = exc
                if not self._is_retryable_exception(exc) or attempt >= self.max_retries:
                    break
                logger.warning(
                    f"SSH операция {error_context} не удалась (попытка {attempt}/{self.max_retries}): {exc}"
                )
                time.sleep(delay)
                delay *= self.backoff_factor
        raise last_exc
    
    def _get_ssh_client(self, host: str, port: int, username: str, 
                       key_path: Optional[str] = None,
                       key_content: Optional[str] = None,
                       password: Optional[str] = None) -> SSHClient:
        """Создает и настраивает SSH клиент"""
        client = SSHClient()
        client.set_missing_host_key_policy(AutoAddPolicy())
        
        try:
            # Определяем ключ для аутентификации
            pkey = None
            if key_content:
                # Используем содержимое ключа
                try:
                    key_file = io.StringIO(key_content)
                    # Пробуем разные форматы ключей
                    for key_class in [RSAKey, ECDSAKey, Ed25519Key]:
                        try:
                            key_file.seek(0)
                            pkey = key_class.from_private_key(key_file)
                            break
                        except (paramiko.ssh_exception.SSHException, ValueError):
                            continue
                    key_file.close()
                except Exception as e:
                    logger.warning(f"Не удалось загрузить SSH ключ из содержимого: {e}")
            elif key_path:
                # Используем путь к ключу
                try:
                    pkey = paramiko.RSAKey.from_private_key_file(key_path)
                except:
                    try:
                        pkey = paramiko.ECDSAKey.from_private_key_file(key_path)
                    except:
                        try:
                            pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
                        except Exception as e:
                            logger.warning(f"Не удалось загрузить SSH ключ из файла {key_path}: {e}")
            
            # Подключаемся
            client.connect(
                hostname=host,
                port=port,
                username=username,
                pkey=pkey,
                password=password,
                timeout=self.timeout,
                banner_timeout=self.timeout,
                auth_timeout=self.timeout,
                allow_agent=False,
                look_for_keys=False
            )

            transport = client.get_transport()
            if transport:
                transport.set_keepalive(self.keepalive_interval)

            return client
            
        except Exception as e:
            client.close()
            raise Exception(f"Ошибка SSH подключения к {host}:{port}: {e}")
    
    def with_connection(
        self,
        host: str,
        port: int,
        username: str,
        callback: Callable[[SSHClient], T],
        key_path: Optional[str] = None,
        key_content: Optional[str] = None,
        password: Optional[str] = None,
    ) -> T:
        """
        Одно SSH-соединение для callback (батч Xray create-client).
        При успехе соединение возвращается в процесс-локальный пул вместо закрытия.
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)
        with pool_lock:
            client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                host, port, username, key_path, key_content, password
            )
            ok = False
            try:
                out = callback(client)
                ok = True
                return out
            except Exception:
                try:
                    client.close()
                except Exception as e:
                    logger.debug("Ошибка закрытия SSH клиента после ошибки callback: %s", e)
                raise
            finally:
                if ok:
                    _return_pooled_ssh_client(pool_key, client)

    def execute_command(self, host: str, command: str, port: int, username: str,
                       key_path: Optional[str] = None,
                       key_content: Optional[str] = None,
                       password: Optional[str] = None) -> Dict[str, Any]:
        """
        Выполняет команду на удаленном сервере через SSH
        
        Returns:
            dict с ключами: 'success' (bool), 'stdout' (str), 'stderr' (str)
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)

        def execute_once() -> Dict[str, Any]:
            with pool_lock:
                client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                    host, port, username, key_path, key_content, password
                )
                try:
                    stdin, stdout, stderr = client.exec_command(
                        command, timeout=self.command_timeout
                    )
                    stdout.channel.settimeout(self.command_timeout)
                    stderr.channel.settimeout(self.command_timeout)
                    exit_status = stdout.channel.recv_exit_status()
                    stdout_text = stdout.read().decode("utf-8", errors="ignore")
                    stderr_text = stderr.read().decode("utf-8", errors="ignore")
                    result = {
                        "success": exit_status == 0,
                        "stdout": stdout_text,
                        "stderr": stderr_text,
                        "exit_status": exit_status,
                    }
                    _return_pooled_ssh_client(pool_key, client)
                    return result
                except Exception:
                    try:
                        client.close()
                    except Exception:
                        pass
                    raise

        try:
            return self._execute_with_retry(execute_once, f"execute_command:{host}")
        except Exception as e:
            logger.error(f"Ошибка выполнения команды на {host}: {e}")
            return {
                'success': False,
                'stdout': '',
                'stderr': str(e),
                'exit_status': -1
            }
    
    def download_content(self, host: str, remote_path: str, port: int, username: str,
                        key_path: Optional[str] = None,
                        key_content: Optional[str] = None,
                        password: Optional[str] = None) -> Optional[str]:
        """
        Скачивает содержимое файла с удаленного сервера
        
        Returns:
            Содержимое файла или None в случае ошибки
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)

        def download_once() -> str:
            with pool_lock:
                client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                    host, port, username, key_path, key_content, password
                )
                sftp = None
                try:
                    sftp = client.open_sftp()
                    sftp.get_channel().settimeout(self.sftp_timeout)
                    with sftp.file(remote_path, "r") as remote_file:
                        data = remote_file.read().decode("utf-8", errors="ignore")
                    if sftp:
                        sftp.close()
                        sftp = None
                    _return_pooled_ssh_client(pool_key, client)
                    return data
                except Exception:
                    if sftp:
                        try:
                            sftp.close()
                        except Exception:
                            pass
                    try:
                        client.close()
                    except Exception:
                        pass
                    raise

        try:
            return self._execute_with_retry(download_once, f"download_content:{host}:{remote_path}")
        except FileNotFoundError:
            logger.warning(f"Файл не найден на сервере: {remote_path}")
            return None
        except Exception as e:
            logger.error(f"Ошибка скачивания файла {remote_path} с {host}: {e}")
            return None
    
    def upload_content(self, host: str, content: str, remote_path: str, port: int, username: str,
                      key_path: Optional[str] = None,
                      key_content: Optional[str] = None,
                      password: Optional[str] = None) -> bool:
        """
        Загружает содержимое файла на удаленный сервер
        
        Returns:
            True в случае успеха, False в случае ошибки
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)

        def upload_once() -> bool:
            with pool_lock:
                client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                    host, port, username, key_path, key_content, password
                )
                sftp = None
                try:
                    sftp = client.open_sftp()
                    sftp.get_channel().settimeout(self.sftp_timeout)
                    remote_dir = "/".join(remote_path.split("/")[:-1])
                    if remote_dir:
                        self._ensure_remote_dir(sftp, remote_dir)
                    with sftp.file(remote_path, "w") as remote_file:
                        remote_file.write(content.encode("utf-8"))
                    with sftp.file(remote_path, "r") as remote_file:
                        uploaded = remote_file.read().decode("utf-8", errors="ignore")
                    if uploaded != content:
                        raise IOError("Проверка целостности файла не пройдена")
                    if sftp:
                        sftp.close()
                        sftp = None
                    _return_pooled_ssh_client(pool_key, client)
                    return True
                except Exception:
                    if sftp:
                        try:
                            sftp.close()
                        except Exception:
                            pass
                    try:
                        client.close()
                    except Exception:
                        pass
                    raise

        try:
            return self._execute_with_retry(upload_once, f"upload_content:{host}:{remote_path}")
        except Exception as e:
            logger.error(f"Ошибка загрузки файла {remote_path} на {host}: {e}")
            return False

    def upload_content_atomic(
        self,
        host: str,
        content: str,
        remote_path: str,
        port: int,
        username: str,
        key_path: Optional[str] = None,
        key_content: Optional[str] = None,
        password: Optional[str] = None,
    ) -> bool:
        """
        Загружает содержимое атомарно: write to .tmp → backup .bak → rename.
        Защита от Config EOF при сбое во время записи.
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)

        def upload_once() -> bool:
            with pool_lock:
                client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                    host, port, username, key_path, key_content, password
                )
                sftp = None
                try:
                    sftp = client.open_sftp()
                    sftp.get_channel().settimeout(self.sftp_timeout)
                    remote_dir = "/".join(remote_path.split("/")[:-1])
                    if remote_dir:
                        self._ensure_remote_dir(sftp, remote_dir)
                    temp_path = remote_path + ".tmp"
                    backup_path = remote_path + ".bak"
                    with sftp.file(temp_path, "w") as f:
                        f.write(content.encode("utf-8"))
                    try:
                        sftp.rename(remote_path, backup_path)
                    except (FileNotFoundError, IOError):
                        pass
                    sftp.rename(temp_path, remote_path)
                    with sftp.file(remote_path, "r") as f:
                        uploaded = f.read().decode("utf-8", errors="ignore")
                    if uploaded != content:
                        raise IOError("Проверка целостности файла не пройдена")
                    if sftp:
                        sftp.close()
                        sftp = None
                    _return_pooled_ssh_client(pool_key, client)
                    return True
                except Exception:
                    if sftp:
                        try:
                            sftp.close()
                        except Exception:
                            pass
                    try:
                        client.close()
                    except Exception:
                        pass
                    raise

        try:
            return self._execute_with_retry(upload_once, f"upload_content_atomic:{host}:{remote_path}")
        except Exception as e:
            logger.error(f"Ошибка атомарной загрузки {remote_path} на {host}: {e}")
            return False

    def _ensure_remote_dir(self, sftp: paramiko.SFTPClient, remote_dir: str) -> None:
        if not remote_dir or remote_dir == "/":
            return
        normalized = remote_dir.rstrip("/")
        parts = normalized.strip("/").split("/")
        current = ""
        for part in parts:
            current = f"{current}/{part}" if current else f"/{part}"
            try:
                sftp.stat(current)
            except IOError:
                sftp.mkdir(current)
    
    def test_connection(self, host: str, port: int, username: str,
                       password: Optional[str] = None,
                       key_path: Optional[str] = None,
                       key_content: Optional[str] = None) -> bool:
        """
        Тестирует SSH подключение к серверу
        
        Returns:
            True если подключение успешно, False в противном случае
        """
        pool_key = _ssh_pool_key(host, port, username, key_path, key_content, password)
        pool_lock = _get_ssh_pool_lock(pool_key)
        with pool_lock:
            try:
                client = _take_pooled_ssh_client(pool_key) or self._get_ssh_client(
                    host, port, username, key_path, key_content, password
                )
            except Exception as e:
                logger.debug(
                    "Тест подключения к %s:%s не удался: %s", host, port, e
                )
                return False
            _return_pooled_ssh_client(pool_key, client)
            return True
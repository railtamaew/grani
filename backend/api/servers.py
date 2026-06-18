from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from typing import Optional, List
from pydantic import BaseModel

from core.database import get_db
from sqlalchemy import text
# Импортируем все модели для правильной инициализации relationships
from models import user  # Импортируем user первым, чтобы User был в registry
from models.server import Server
from models.user import User
from schemas.user import UserResponse
from services.auth_service import AuthService
from services.remote_vpn_manager import RemoteVPNManager
from services.ssh_manager import SSHManager

router = APIRouter(prefix="")
security = HTTPBearer()

# Pydantic модели
class ServerCreate(BaseModel):
    name: str
    ip_address: str
    country: str
    city: Optional[str] = None
    ssh_host: Optional[str] = None
    ssh_port: int = 22
    ssh_user: str = "root"
    ssh_key_path: Optional[str] = None
    ssh_key_content: Optional[str] = None
    ssh_password: Optional[str] = None  # Временный пароль для тестирования
    wireguard_port: int = 51820
    supported_protocols: Optional[List[str]] = None
    is_local: bool = False

class ServerTestConnection(BaseModel):
    server_id: int

class ServerInstallWireGuard(BaseModel):
    server_id: int

def require_admin(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)) -> UserResponse:
    """Проверка прав администратора"""
    import logging
    logger = logging.getLogger(__name__)
    try:
        token = credentials.credentials
        # Безопасное логирование токена (показываем только длину и первые 4 символа)
        logger.info(f"require_admin: token length={len(token) if token else 0}, first 4 chars={token[:4] if token and len(token) >= 4 else 'None'}...")
        
        # Проверяем токен
        user_id = AuthService.verify_token(token)
        logger.info(f"require_admin: verified user_id={user_id}")
        
        if user_id is None:
            logger.warning("require_admin: token verification failed")
            raise HTTPException(status_code=401, detail="Неверный токен")
        
        # Получаем пользователя
        user = AuthService.get_current_user(token, db)
        logger.info(f"require_admin: user={user.email if hasattr(user, 'email') else 'NO EMAIL'}, type={type(user).__name__}")
        
        # TODO: Добавить проверку is_admin
        # if not user.is_admin:
        #     raise HTTPException(status_code=403, detail="Требуются права администратора")
        return user
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"require_admin error: {e}", exc_info=True)
        raise HTTPException(status_code=401, detail=f"Ошибка аутентификации: {str(e)}")

@router.post("/", response_model=dict)
async def create_server(
    server_data: ServerCreate,
    user: UserResponse = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Создание нового VPN сервера"""
    try:
        # Проверяем, не существует ли уже сервер с таким IP
        # Используем raw SQL для избежания проблем с отсутствующими колонками
        from sqlalchemy import text
        result = db.execute(
            text("SELECT id FROM servers WHERE ip_address = :ip"),
            {"ip": server_data.ip_address}
        )
        existing = result.fetchone()
        if existing:
            raise HTTPException(status_code=400, detail="Сервер с таким IP адресом уже существует")
        if existing_server:
            raise HTTPException(status_code=400, detail="Сервер с таким IP адресом уже существует")
        
        # Создаем сервер
        # Используем словарь для создания, чтобы избежать проблем с relationships
        server_dict = {
            "name": server_data.name,
            "ip_address": server_data.ip_address,
            "country": server_data.country,
            "city": server_data.city,
            "ssh_host": server_data.ssh_host or server_data.ip_address,
            "ssh_port": server_data.ssh_port,
            "ssh_user": server_data.ssh_user,
            "ssh_key_path": server_data.ssh_key_path,
            "ssh_key_content": server_data.ssh_key_content,
            "ssh_password": getattr(server_data, 'ssh_password', None),
            "wireguard_port": server_data.wireguard_port,
            "supported_protocols": server_data.supported_protocols or ["wireguard"],
            "is_local": server_data.is_local
        }
        
        server = Server(**server_dict)
        db.add(server)
        db.commit()
        db.refresh(server)
        
        return {
            "message": "Сервер создан",
            "server_id": server.id,
            "server": {
                "id": server.id,
                "name": server.name,
                "ip_address": server.ip_address,
                "country": server.country
            }
        }
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"Ошибка создания сервера: {str(e)}")

@router.post("/{server_id}/test-connection", response_model=dict)
async def test_server_connection(
    server_id: int,
    user: UserResponse = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Тестирование SSH подключения к серверу"""
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            raise HTTPException(status_code=404, detail="Сервер не найден")
        
        remote_manager = RemoteVPNManager()
        is_connected = remote_manager.test_connection(server)
        
        return {
            "server_id": server_id,
            "connected": is_connected,
            "message": "Подключение успешно" if is_connected else "Не удалось подключиться"
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Ошибка тестирования подключения: {str(e)}")

@router.post("/{server_id}/install-wireguard", response_model=dict)
async def install_wireguard_on_server(
    server_id: int,
    user: UserResponse = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Установка WireGuard на удаленном сервере"""
    try:
        server = db.query(Server).filter(Server.id == server_id).first()
        if not server:
            raise HTTPException(status_code=404, detail="Сервер не найден")
        
        if server.is_local:
            raise HTTPException(status_code=400, detail="Это локальный сервер, установка не требуется")
        
        remote_manager = RemoteVPNManager()
        
        # Проверяем подключение
        if not remote_manager.test_connection(server):
            raise HTTPException(status_code=400, detail="Не удалось подключиться к серверу по SSH")
        
        # Проверяем, установлен ли уже WireGuard
        ssh_config = remote_manager.get_ssh_config(server)
        ssh_manager = SSHManager()
        
        # Проверка наличия WireGuard
        check_result = ssh_manager.execute_command(
            ssh_config['host'],
            "which wg",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config['key_path'],
            ssh_config['key_content']
        )
        
        if check_result['success'] and check_result['stdout'].strip():
            return {
                "server_id": server_id,
                "installed": True,
                "message": "WireGuard уже установлен на сервере"
            }
        
        # Устанавливаем WireGuard
        install_commands = [
            "apt-get update",
            "apt-get install -y wireguard wireguard-tools",
            "modprobe wireguard",
            "echo 'wireguard' >> /etc/modules-load.d/wireguard.conf"
        ]
        
        for command in install_commands:
            result = ssh_manager.execute_command(
                ssh_config['host'],
                command,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                timeout=60
            )
            if not result['success']:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Ошибка установки WireGuard: {result['stderr']}"
                )
        
        # Генерируем ключи сервера, если их нет
        if not server.wireguard_private_key or not server.wireguard_public_key:
            keys = remote_manager.generate_wireguard_key_pair(server)
            server.wireguard_private_key = keys['private_key']
            server.wireguard_public_key = keys['public_key']
            db.commit()
        
        return {
            "server_id": server_id,
            "installed": True,
            "message": "WireGuard успешно установлен на сервере",
            "public_key": server.wireguard_public_key
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Ошибка установки WireGuard: {str(e)}")

@router.get("/", response_model=List[dict])
async def list_servers(
    user: UserResponse = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Список всех серверов"""
    try:
        # Используем raw SQL для избежания проблем с relationships
        result = db.execute(text("""
            SELECT 
                id, name, ip_address, country, city, is_active,
                COALESCE(is_local, false) as is_local,
                COALESCE(supported_protocols, '["wireguard"]'::jsonb) as supported_protocols,
                ssh_host, ssh_port, ssh_user,
                (ssh_key_path IS NOT NULL OR ssh_key_content IS NOT NULL) as has_ssh_key
            FROM servers
            ORDER BY id
        """))
        
        servers = []
        for row in result:
            protocols = row.supported_protocols
            if isinstance(protocols, str):
                import json
                try:
                    protocols = json.loads(protocols)
                except:
                    protocols = ["wireguard"]
            elif not isinstance(protocols, list):
                protocols = ["wireguard"]
                
            servers.append({
                "id": row.id,
                "name": row.name,
                "ip_address": row.ip_address,
                "country": row.country,
                "city": row.city,
                "is_active": row.is_active,
                "is_local": row.is_local,
                "supported_protocols": protocols,
                "ssh_host": row.ssh_host,
                "ssh_port": row.ssh_port or 22,
                "ssh_user": row.ssh_user or "root",
                "has_ssh_key": row.has_ssh_key
            })
        
        return servers
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=400, detail=f"Ошибка получения списка серверов: {str(e)}")


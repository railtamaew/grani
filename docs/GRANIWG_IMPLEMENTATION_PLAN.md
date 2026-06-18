# План реализации GRANIWG обфускации

## Текущее состояние

GRANIWG сейчас представляет собой только заглушку в коде:

```python
# backend/services/wireguard_manager.py
def create_graniwg_client_config(self, device, server, client_ip):
    # Проверяем, включен ли GRANIWG на сервере
    if not server.graniwg_enabled:
        return self.create_client_config(device, server, client_ip, "wireguard")
    
    # Базовый WireGuard конфиг
    base_config = f"""[Interface]
    ...
    """
    
    # Добавляем параметры обфускации в комментарии
    # В реальной реализации здесь будет интеграция с обфускацией
    if obfuscation_key:
        obfuscation_note = f"""
    # GRANIWG Configuration
    # Obfuscation Type: {obfuscation_type}
    # Obfuscation Key: {obfuscation_key}
    """
        return obfuscation_note + base_config
```

---

## Анализ AmneziaWG

### Основные техники обфускации

1. **Рандомизация заголовков пакетов**
   - Все типы пакетов (Init, Response, Data, Under-Load) получают случайные константы
   - Смещение offset'ов
   - Изменение идентифицируемых полей

2. **Переменная длина handshake**
   - Стандартный WireGuard: Init = 148 байт, Response = 92 байта
   - AmneziaWG: добавляет случайный префикс S1, S2 (до 64 байт)
   - Размеры варьируются для каждого пользователя

3. **Signature Packets (I1-I5)**
   - Цепочка пакетов перед handshake
   - Используют Custom Protocol Signatures (CPS)
   - Имитируют другие популярные протоколы

4. **Junk-Train**
   - Цепочка рандомизированных пакетов
   - Количество: Jc (случайное)
   - Размер: от Jmin до Jmax байт
   - Маскирует timing и характеристики трафика

5. **Under-Load Packet Obfuscation**
   - Рандомизация keep-alive пакетов
   - Изменение заголовков
   - Маскировка периодичности

6. **Protocol Impersonation**
   - Имитация QUIC, DNS и других протоколов
   - Изменение структуры пакетов

### Криптография

- **Остается неизменной**: Curve25519, ChaCha20-Poly1305
- Обфускация только на транспортном уровне
- Безопасность не снижается

---

## План реализации для GRANI VPN

### Этап 1: Базовая обфускация (udp2raw)

**Цель:** Быстрая реализация базовой обфускации

**Технология:** udp2raw (существующий инструмент)

**Реализация:**

1. **Установка udp2raw на сервере**
   ```bash
   # На VPN сервере
   wget https://github.com/wangyu-/udp2raw/releases/download/...
   chmod +x udp2raw
   mv udp2raw /usr/local/bin/
   ```

2. **Настройка сервера**
   ```python
   # backend/services/wireguard_manager.py
   def setup_graniwg_server(self, server):
       # Генерация ключа обфускации
       obfuscation_key = self._generate_obfuscation_key()
       
       # Запуск udp2raw на сервере
       # udp2raw -s -l 0.0.0.0:51820 -r 127.0.0.1:51821 -k {key} --raw-mode faketcp
       ssh_command = f"udp2raw -s -l 0.0.0.0:{server.wireguard_port} -r 127.0.0.1:51821 -k {obfuscation_key} --raw-mode faketcp"
       self.remote_manager.ssh_manager.execute_command(...)
   ```

3. **Конфигурация клиента**
   ```python
   def create_graniwg_client_config(self, device, server, client_ip):
       # WireGuard конфиг с измененным endpoint
       config = f"""[Interface]
       PrivateKey = {device.wireguard_private_key}
       Address = {client_ip}/32
       DNS = 8.8.8.8, 8.8.4.4
       
       [Peer]
       PublicKey = {server.wireguard_public_key}
       Endpoint = 127.0.0.1:51821  # Локальный endpoint для udp2raw
       AllowedIPs = 0.0.0.0/0
       """
       
       # Инструкции для клиента
       instructions = f"""
       # Для использования GRANIWG:
       # 1. Установите udp2raw на клиенте
       # 2. Запустите: udp2raw -c -l 127.0.0.1:51821 -r {server.ip_address}:{server.wireguard_port} -k {obfuscation_key} --raw-mode faketcp
       # 3. Подключитесь к WireGuard через 127.0.0.1:51821
       """
       
       return config + instructions
   ```

**Плюсы:**
- ✅ Быстрая реализация
- ✅ Использует проверенный инструмент
- ✅ Работает "из коробки"

**Минусы:**
- ❌ Требует установки udp2raw на клиенте
- ❌ Менее гибкая обфускация
- ❌ Не такая продвинутая как AmneziaWG

---

### Этап 2: Кастомная обфускация (как AmneziaWG)

**Цель:** Реализация продвинутой обфускации уровня AmneziaWG

**Подход:** Собственная реализация на Go или Rust

**Компоненты:**

1. **GRANIWG Server (Go/Rust)**
   ```go
   // graniwg-server/main.go
   package main
   
   type GRANIWGServer struct {
       wgInterface string
       obfuscationKey []byte
       signaturePackets []SignaturePacket
   }
   
   func (s *GRANIWGServer) HandlePacket(packet []byte) {
       // 1. Проверка signature packets (I1-I5)
       if s.isSignaturePacket(packet) {
           s.handleSignaturePacket(packet)
           return
       }
       
       // 2. Проверка junk-train
       if s.isJunkPacket(packet) {
           s.handleJunkPacket(packet)
           return
       }
       
       // 3. Декодирование обфусцированного пакета
       decoded := s.deobfuscate(packet)
       
       // 4. Передача в WireGuard
       s.forwardToWireGuard(decoded)
   }
   
   func (s *GRANIWGServer) deobfuscate(packet []byte) []byte {
       // Рандомизация заголовков
       // Извлечение реальных данных
       // Восстановление структуры пакета
   }
   ```

2. **GRANIWG Client (Go/Rust)**
   ```go
   // graniwg-client/main.go
   type GRANIWGClient struct {
       serverEndpoint string
       obfuscationKey []byte
       wgInterface string
   }
   
   func (c *GRANIWGClient) Connect() {
       // 1. Отправка signature packets (I1-I5)
       c.sendSignaturePackets()
       
       // 2. Отправка junk-train
       c.sendJunkTrain()
       
       // 3. Обфускация WireGuard пакетов
       c.startObfuscation()
   }
   
   func (c *GRANIWGClient) obfuscate(packet []byte) []byte {
       // Рандомизация заголовков
       // Добавление случайных префиксов
       // Изменение структуры
   }
   ```

3. **Интеграция с WireGuard**

   **Вариант A: Прокси перед WireGuard**
   ```
   Client → GRANIWG Client → GRANIWG Server → WireGuard Server
   ```

   **Вариант B: Модификация WireGuard**
   ```
   Client → Modified WireGuard (с обфускацией) → Server
   ```

---

### Этап 3: Детальная реализация техник

#### 3.1 Рандомизация заголовков

```python
# backend/services/graniwg_obfuscator.py
class PacketObfuscator:
    def __init__(self, user_key):
        self.user_key = user_key
        self.random_constants = self._generate_random_constants()
    
    def obfuscate_header(self, packet_type, packet_data):
        """
        Рандомизация заголовка пакета
        
        packet_type: 'init', 'response', 'data', 'under_load'
        """
        # Генерация случайных констант для пользователя
        constants = self.random_constants[packet_type]
        
        # Смещение offset'ов
        offset = constants['offset']
        
        # Изменение идентифицируемых полей
        obfuscated = self._modify_fields(packet_data, constants)
        
        return obfuscated
    
    def _generate_random_constants(self):
        """Генерация случайных констант для каждого типа пакета"""
        return {
            'init': {
                'offset': random.randint(0, 16),
                'magic': random.randint(0, 0xFFFFFFFF),
                # ...
            },
            'response': { ... },
            'data': { ... },
            'under_load': { ... }
        }
```

#### 3.2 Переменная длина handshake

```python
def obfuscate_handshake(self, handshake_packet, handshake_type):
    """
    Добавление случайных префиксов к handshake
    
    handshake_type: 'init' (148 байт) или 'response' (92 байта)
    """
    # Генерация случайных префиксов S1, S2 (до 64 байт)
    s1_size = random.randint(0, 32)
    s2_size = random.randint(0, 32)
    
    s1_prefix = os.urandom(s1_size)
    s2_prefix = os.urandom(s2_size)
    
    # Добавление префиксов
    obfuscated = s1_prefix + s2_prefix + handshake_packet
    
    # Корректировка offset'ов в пакете
    obfuscated = self._adjust_offsets(obfuscated, s1_size + s2_size)
    
    return obfuscated
```

#### 3.3 Signature Packets (I1-I5)

```python
def generate_signature_packets(self):
    """
    Генерация цепочки signature packets перед handshake
    """
    signature_packets = []
    
    # I1-I5 пакеты с Custom Protocol Signatures
    protocols = ['quic', 'dns', 'http', 'tls', 'custom']
    
    for i, protocol in enumerate(protocols):
        packet = self._create_signature_packet(
            packet_id=f'I{i+1}',
            protocol_signature=protocol,
            size=random.randint(32, 128)
        )
        signature_packets.append(packet)
    
    return signature_packets

def _create_signature_packet(self, packet_id, protocol_signature, size):
    """Создание signature packet с имитацией протокола"""
    packet = bytearray(size)
    
    # Заголовок с имитацией протокола
    if protocol_signature == 'quic':
        packet[0:4] = b'\x00\x00\x00\x00'  # QUIC magic
    elif protocol_signature == 'dns':
        packet[0:2] = struct.pack('>H', random.randint(0, 65535))  # DNS ID
    # ...
    
    # Заполнение случайными данными
    packet[4:] = os.urandom(size - 4)
    
    return bytes(packet)
```

#### 3.4 Junk-Train

```python
def generate_junk_train(self):
    """
    Генерация цепочки junk пакетов
    """
    # Количество пакетов (Jc)
    packet_count = random.randint(3, 10)
    
    # Размеры пакетов (Jmin-Jmax)
    min_size = 16
    max_size = 256
    
    junk_packets = []
    
    for _ in range(packet_count):
        size = random.randint(min_size, max_size)
        packet = os.urandom(size)
        junk_packets.append(packet)
    
    return junk_packets
```

#### 3.5 Under-Load Packet Obfuscation

```python
def obfuscate_under_load_packet(self, keepalive_packet):
    """
    Обфускация keep-alive пакетов
    """
    # Рандомизация заголовка
    obfuscated = self.obfuscate_header('under_load', keepalive_packet)
    
    # Добавление случайных данных
    random_suffix = os.urandom(random.randint(0, 16))
    obfuscated = obfuscated + random_suffix
    
    # Изменение timing (для клиента)
    # В реальной реализации это делается на уровне отправки
    
    return obfuscated
```

---

## Интеграция с существующим кодом

### 1. Обновление модели Server

```python
# backend/domain/models/server.py
class Server(Base):
    # Существующие поля GRANIWG
    graniwg_enabled = Column(Boolean, default=False)
    graniwg_obfuscation_key = Column(String, nullable=True)
    graniwg_obfuscation_type = Column(String, nullable=True)
    
    # Новые поля для продвинутой обфускации
    graniwg_signature_enabled = Column(Boolean, default=True)
    graniwg_junk_train_enabled = Column(Boolean, default=True)
    graniwg_random_header_enabled = Column(Boolean, default=True)
    graniwg_handshake_randomization = Column(Boolean, default=True)
```

### 2. Обновление WireGuardManager

```python
# backend/services/wireguard_manager.py
def create_graniwg_client_config(self, device, server, client_ip):
    """Создает обфусцированную конфигурацию GRANIWG"""
    if not server.graniwg_enabled:
        return self.create_client_config(device, server, client_ip, "wireguard")
    
    # Выбор типа обфускации
    obfuscation_type = server.graniwg_obfuscation_type or 'udp2raw'
    
    if obfuscation_type == 'udp2raw':
        return self._create_udp2raw_config(device, server, client_ip)
    elif obfuscation_type == 'custom':
        return self._create_custom_obfuscation_config(device, server, client_ip)
    else:
        raise Exception(f"Неподдерживаемый тип обфускации: {obfuscation_type}")

def _create_custom_obfuscation_config(self, device, server, client_ip):
    """Создает конфигурацию с кастомной обфускацией"""
    from services.graniwg_obfuscator import GRANIWGObfuscator
    
    obfuscator = GRANIWGObfuscator(server.graniwg_obfuscation_key)
    
    # Базовый WireGuard конфиг
    base_config = self.create_client_config(device, server, client_ip, "wireguard")
    
    # Добавляем параметры обфускации
    obfuscation_params = {
        'signature_enabled': server.graniwg_signature_enabled,
        'junk_train_enabled': server.graniwg_junk_train_enabled,
        'random_header_enabled': server.graniwg_random_header_enabled,
        'handshake_randomization': server.graniwg_handshake_randomization,
    }
    
    # Генерация конфигурации для клиента
    config = f"""
# GRANIWG Configuration (Custom Obfuscation)
{base_config}

# Obfuscation Parameters
# Signature Packets: {obfuscation_params['signature_enabled']}
# Junk Train: {obfuscation_params['junk_train_enabled']}
# Random Headers: {obfuscation_params['random_header_enabled']}
# Handshake Randomization: {obfuscation_params['handshake_randomization']}
# Obfuscation Key: {server.graniwg_obfuscation_key[:16]}...
"""
    
    return config
```

### 3. Создание GRANIWG сервиса

```python
# backend/services/graniwg_service.py
class GRANIWGService:
    """Сервис для управления GRANIWG обфускацией"""
    
    def __init__(self):
        self.obfuscator = GRANIWGObfuscator()
    
    def setup_server(self, server):
        """Настройка GRANIWG на сервере"""
        # Установка GRANIWG сервера
        # Настройка обфускации
        # Запуск сервиса
        pass
    
    def generate_client_config(self, device, server):
        """Генерация конфигурации клиента"""
        # Генерация ключей обфускации
        # Создание конфигурации
        pass
```

---

## Тестирование

### 1. Unit тесты

```python
# backend/tests/test_graniwg_obfuscator.py
def test_packet_obfuscation():
    obfuscator = GRANIWGObfuscator("test_key")
    original_packet = b"test_packet_data"
    
    obfuscated = obfuscator.obfuscate_header('data', original_packet)
    deobfuscated = obfuscator.deobfuscate_header('data', obfuscated)
    
    assert deobfuscated == original_packet
```

### 2. Интеграционные тесты

```python
def test_graniwg_connection():
    # Настройка тестового сервера
    # Подключение клиента
    # Проверка обфускации трафика
    # Проверка работоспособности VPN
    pass
```

### 3. Тестирование в условиях блокировок

- Тестирование на серверах в странах с блокировками
- Проверка обхода DPI
- Измерение производительности

---

## Временные рамки

### Этап 1: udp2raw (2-3 недели)
- Исследование и настройка udp2raw
- Интеграция с существующим кодом
- Тестирование

### Этап 2: Кастомная обфускация (2-3 месяца)
- Разработка GRANIWG сервера/клиента
- Реализация техник обфускации
- Интеграция
- Тестирование

### Этап 3: Оптимизация (1 месяц)
- Оптимизация производительности
- Улучшение обфускации
- Документация

---

## Ресурсы

### Инструменты
- udp2raw: https://github.com/wangyu-/udp2raw
- WireGuard: https://www.wireguard.com/
- AmneziaWG документация: https://amneziavpn.org/documentation/amnezia-wg

### Исследования
- DPI обход техники
- Протокол impersonation
- Timing атаки и защита

---

**Документ создан:** 2025-01-14  
**Версия:** 1.0

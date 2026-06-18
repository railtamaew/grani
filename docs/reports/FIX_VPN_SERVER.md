# Инструкция по исправлению VPN сервера

## Проблема
VPN туннель подключается, но интернет не работает. Клиент отправляет данные (2.60 КБ), но не получает ответа (0 Б).

## Причина
На сервере не настроены:
1. Пир (peer) не добавлен в конфигурацию WireGuard
2. IP forwarding не включен
3. iptables правила для маршрутизации отсутствуют

## Решение

### Шаг 1: Подключитесь к серверу по SSH
```bash
ssh root@45.12.132.94
# или
ssh user@45.12.132.94
```

### Шаг 2: Добавьте пир в конфигурацию WireGuard

Откройте конфигурацию:
```bash
sudo nano /etc/wireguard/wg0.conf
```

Добавьте в конец файла секцию пира:
```ini
[Peer]
PublicKey = TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=
AllowedIPs = 10.0.0.2/32
```

**Важно:** 
- `PublicKey` - это публичный ключ клиента (TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=)
- `AllowedIPs` - IP адрес клиента в VPN сети (10.0.0.2/32, должен совпадать с `Address` в `wg0.conf` клиента)

### Шаг 3: Включите IP forwarding

```bash
# Временно включить
sudo sysctl -w net.ipv4.ip_forward=1

# Постоянно включить (добавить в /etc/sysctl.conf)
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf

# Применить изменения
sudo sysctl -p
```

### Шаг 4: Настройте iptables правила

Сначала определите основной сетевой интерфейс:
```bash
ip route | grep default | awk '{print $5}' | head -n1
```

Обычно это `eth0`, `ens3`, `enp0s3` или подобное.

Затем добавьте правила (замените `eth0` на ваш интерфейс, если отличается):
```bash
# Разрешить форвардинг трафика через wg0
sudo iptables -A FORWARD -i wg0 -j ACCEPT

# Настроить NAT (маскарадинг) для исходящего трафика
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

**Для постоянного сохранения правил:**
```bash
# Ubuntu/Debian
sudo apt-get install iptables-persistent
sudo netfilter-persistent save

# Или вручную сохранить
sudo iptables-save > /etc/iptables/rules.v4
```

### Шаг 5: Перезапустите WireGuard

```bash
sudo wg-quick down wg0
sudo wg-quick up wg0
```

Или через systemd:
```bash
sudo systemctl restart wg-quick@wg0
```

### Шаг 6: Проверьте статус

```bash
# Проверить статус WireGuard
sudo wg show

# Проверить IP forwarding
sysctl net.ipv4.ip_forward

# Проверить iptables правила
sudo iptables -L FORWARD -n -v
sudo iptables -t nat -L POSTROUTING -n -v
```

## Автоматическая настройка (если есть SSH доступ)

Если на сервере установлен `paramiko` и настроен SSH доступ, можно использовать скрипт:
```bash
cd /opt/grani/backend
python3 scripts/check_and_fix_server.py
```

## Проверка после настройки

После выполнения всех шагов:
1. Переподключитесь к VPN на клиенте
2. Проверьте передачу данных - должны появиться полученные байты
3. Проверьте интернет - должен работать

## Дополнительная диагностика

Если проблема сохраняется:

1. **Проверьте логи WireGuard на сервере:**
   ```bash
   sudo journalctl -u wg-quick@wg0 -f
   ```

2. **Проверьте, что пир виден на сервере:**
   ```bash
   sudo wg show wg0
   ```
   Должен отображаться ваш пир с публичным ключом

3. **Проверьте файрвол:**
   ```bash
   sudo ufw status
   sudo iptables -L -n -v
   ```

4. **Проверьте сетевые интерфейсы:**
   ```bash
   ip addr show wg0
   ip route show
   ```

## Важные замечания

- IP адрес клиента (`10.0.0.2`) должен совпадать в конфигурации клиента и сервера
- Публичный ключ клиента должен точно совпадать (без пробелов, переносов строк)
- После изменений в `/etc/wireguard/wg0.conf` обязательно перезапустите WireGuard
- iptables правила могут сбрасываться после перезагрузки, используйте `iptables-persistent`

## Контакты

Если проблема не решена, проверьте:
- Логи на сервере: `sudo journalctl -u wg-quick@wg0`
- Логи на клиенте (в WireGuard приложении)
- Сетевые настройки сервера


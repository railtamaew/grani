# Настройка SSH ключа для доступа к серверу

## Текущий статус

- ✅ **SSH ключ id_rsa.pub существует** на локальной машине
- ⚠️ **Нужно проверить** добавлен ли ключ на сервер

## Проверка SSH ключа

### 1. Просмотр публичного ключа

**Windows PowerShell:**
```powershell
Get-Content $env:USERPROFILE\.ssh\id_rsa.pub
```

**Mac/Linux:**
```bash
cat ~/.ssh/id_rsa.pub
```

### 2. Проверка ключа на сервере

```bash
ssh root@159.223.199.122 "cat ~/.ssh/authorized_keys"
```

Если ваш ключ есть в списке - всё в порядке. Если нет - нужно добавить.

## Добавление SSH ключа на сервер

### Вариант 1: Автоматическое добавление (если есть доступ по паролю)

```bash
# Скопировать ключ на сервер
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh root@159.223.199.122 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
```

### Вариант 2: Ручное добавление

1. **Скопировать публичный ключ:**
   ```powershell
   Get-Content $env:USERPROFILE\.ssh\id_rsa.pub | Set-Clipboard
   ```

2. **Подключиться к серверу (по паролю или другому ключу):**
   ```bash
   ssh root@159.223.199.122
   ```

3. **На сервере добавить ключ:**
   ```bash
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   echo "ВАШ_ПУБЛИЧНЫЙ_КЛЮЧ_ЗДЕСЬ" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

### Вариант 3: Создание нового ключа (если текущий не работает)

**Windows PowerShell:**
```powershell
# Создать новый ключ ed25519 (рекомендуется)
ssh-keygen -t ed25519 -C "your_email@example.com" -f $env:USERPROFILE\.ssh\id_ed25519

# Или RSA ключ
ssh-keygen -t rsa -b 4096 -C "your_email@example.com" -f $env:USERPROFILE\.ssh\id_rsa_new
```

**Добавить новый ключ на сервер:**
```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@159.223.199.122 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

## Проверка подключения

После добавления ключа проверить:

```bash
ssh -o ConnectTimeout=5 root@159.223.199.122 "echo 'Connection successful'"
```

Если подключение работает без запроса пароля - ключ настроен правильно.

## Устранение проблем

### Проблема: Connection timed out

**Возможные причины:**
- Сервер недоступен
- Файрвол блокирует порт 22
- Неправильный IP адрес

**Решение:**
1. Проверить доступность сервера: `ping 159.223.199.122`
2. Проверить другой IP если есть
3. Проверить настройки файрвола на сервере

### Проблема: Permission denied

**Возможные причины:**
- Ключ не добавлен на сервер
- Неправильные права доступа на сервере

**Решение:**
1. Проверить что ключ добавлен: `ssh root@SERVER "cat ~/.ssh/authorized_keys"`
2. Проверить права: `ssh root@SERVER "ls -la ~/.ssh"`
3. Исправить права: `ssh root@SERVER "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"`

## Текущий публичный ключ

Ваш текущий публичный ключ (id_rsa.pub):
```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDlOnOzGb/jv1RqF42No8ALv4WAHXWPCMcT8S1GHeSB4nlRRCR4W/6bLGKCndHpGEj42fquOJt5YvxQg3LpVLTW8v2D/gWeWGP3JHfKarz/ujnlFjV4xQ9LGElzue9sDI+42qGbS6sXAJfMc0RSn0VvOhrxWonc9NctBHL6juPLsBr9S8VS4MC/n3e9HG/FdmhkQ41w9FgD+6c9+oZ1cM9BQ8dZKW7ILJjLzwN9Sb6SP0lYGa8aga08/HOaNb/MZw4d0foiuiRBINL8VbmI8WfxQFlZj8sWk4Qk9O5iiRDpbCrxGaLlYMdF3FJ/dsC0ZbB+McR0TToVVC+sedvxaIlHfeY15nBNz3/UydrW31XxrjHs3bKosFXo7Vy6i6vqWtmaDE8UtnpmVmFjRxq73BkjlQw6wkO/LK7Ji/+eJTQRtczAG9noy8R/0oEfEk9EKa9FX0OrGwzIkgWjyhwm7LaW4Qosp9gkijEMpop+2E9nmpfp/MzDADHVgfby00I33fx10mLNQbB4IQh3OrPZQW/fa4801c2ilcEFo3YFi8qOg4JHme5K89Rwfs6Agm737cg/sWOJgdtbjhGZhDVMGQFwwmJO48vGLaDkR13OSCRK9FWu1ycjPLLN5g8Vup8v2+zUiuK505+58PhuzFUXyxZYu0fD/D3zypMVhEZKguSjoQ== railt@эмтех-маркетинг
```

## Рекомендации

1. **Использовать ed25519 ключи** для новых серверов (более безопасно)
2. **Не использовать один ключ для всех серверов** (лучше отдельные ключи)
3. **Регулярно ротировать ключи** (менять раз в год)
4. **Использовать SSH агент** для управления ключами




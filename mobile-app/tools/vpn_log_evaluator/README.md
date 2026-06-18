# VPN Log Evaluator

Инструмент оценки VPN-сервиса GraniVPN по логам adb logcat.

## Использование

```bash
# Из файла
python3 vpn_log_evaluator.py --input logs.txt

# Из stdin
adb logcat -d | python3 vpn_log_evaluator.py

# С фильтром
adb logcat -d -s VpnService:* Tun2SocksProc:* ConnectionLogger:* | python3 vpn_log_evaluator.py
```

## Документация

См. [docs/VPN_LOG_EVALUATION_SYSTEM.md](../../docs/VPN_LOG_EVALUATION_SYSTEM.md).

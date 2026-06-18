#!/usr/bin/env python3
"""
PoC сценария 3 (Adaptive Strategy): выбор стратегии по результатам зондов.
Вход: результаты проверок (DoH, основной домен, SNI-блок, задержки).
Выход: имя стратегии (boring_https, doh_bootstrap_only, mimicry, multipath, fallback_ip).
Используется в лаборатории и может быть перенесён в приложение.
"""
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class ProbeResult:
    doh_ok: bool = False
    main_domain_ok: bool = False
    sni_blocked: bool = False
    cover_domain_ok: bool = False
    rtt_ms: Optional[float] = None


# Стратегии (соответствуют сценариям)
STRATEGY_BORING_HTTPS = "boring_https"
STRATEGY_DOH_BOOTSTRAP = "doh_bootstrap_only"
STRATEGY_MIMICRY = "mimicry"
STRATEGY_MULTIPATH = "multipath"
STRATEGY_FALLBACK_IP = "fallback_ip"


def select_strategy(probe: ProbeResult) -> str:
    """
    Выбор стратегии по результатам зондов.
    Порядок приоритета: если основной домен и SNI не блокируют — boring_https;
    иначе DoH + прикрывающий домен; при блокировке по отпечатку — mimicry/multipath;
    последний резерв — fallback по IP.
    """
    if probe.main_domain_ok and not probe.sni_blocked:
        return STRATEGY_BORING_HTTPS
    if probe.doh_ok and probe.cover_domain_ok:
        return STRATEGY_BORING_HTTPS
    if probe.doh_ok:
        return STRATEGY_DOH_BOOTSTRAP
    if probe.sni_blocked and probe.cover_domain_ok:
        return STRATEGY_MIMICRY
    return STRATEGY_FALLBACK_IP


def run_tests() -> List[str]:
    """Unit-тесты логики выбора; возвращает список ошибок (пусто — всё ок)."""
    errors = []
    # Все ок — boring_https
    r = select_strategy(ProbeResult(doh_ok=True, main_domain_ok=True, sni_blocked=False))
    if r != STRATEGY_BORING_HTTPS:
        errors.append(f"main_ok: expected boring_https got {r}")
    # DoH + прикрывающий — boring_https
    r = select_strategy(ProbeResult(doh_ok=True, cover_domain_ok=True))
    if r != STRATEGY_BORING_HTTPS:
        errors.append(f"doh+cover: expected boring_https got {r}")
    # Только DoH — doh_bootstrap_only
    r = select_strategy(ProbeResult(doh_ok=True, main_domain_ok=False, cover_domain_ok=False))
    if r != STRATEGY_DOH_BOOTSTRAP:
        errors.append(f"doh_only: expected doh_bootstrap_only got {r}")
    # SNI блок, прикрывающий ок — mimicry
    r = select_strategy(ProbeResult(doh_ok=False, sni_blocked=True, cover_domain_ok=True))
    if r != STRATEGY_MIMICRY:
        errors.append(f"sni_block+cover: expected mimicry got {r}")
    # Всё плохо — fallback_ip
    r = select_strategy(ProbeResult(doh_ok=False, main_domain_ok=False, cover_domain_ok=False))
    if r != STRATEGY_FALLBACK_IP:
        errors.append(f"all_bad: expected fallback_ip got {r}")
    return errors


if __name__ == "__main__":
    import sys
    errs = run_tests()
    if errs:
        for e in errs:
            print(e, file=sys.stderr)
        sys.exit(1)
    print("All adaptive selector tests passed.")

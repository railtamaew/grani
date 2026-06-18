# Observability V2 (Вариант B)

Эта папка содержит пакет спецификаций реализации для принятой observability-архитектуры.

## Документы

- `ADR-0001-observability-v2-variant-b.md` - ADR по архитектурному решению.
- `EVENT_SCHEMA_AND_TAXONOMY.md` - каноническая модель событий и подход к словарю.
- `INCIDENT_RULES_SPEC.md` - логика детекции дублей сессий, stale-туннелей, конфликтов конфигурации и др.
- `ADMIN_OBSERVABILITY_API_CONTRACT.md` - API-контракты админки для observability-страниц.
- `ADMIN_OBSERVABILITY_OPERATOR_RUNBOOK.md` - полный операторский гайд по странице Observability и значениям событий.
- `MIGRATION_AND_BACKFILL_PLAN.md` - поэтапный rollout и стратегия миграции исторических данных.
- `DEPLOY_ADMIN_OBSERVABILITY.md` - как выкатить админку на `admin.granilink.com`, чтобы открывался `/observability`.

## Назначение

- Базовая спецификация для инженерной реализации.
- Выравнивание между командами (backend, админка, ops, support).
- Единый источник истины по этапам rollout.

#!/usr/bin/env python3
"""
Migration bootstrap for Observability V2 (PostgreSQL).

Creates:
- observability_events
- observability_incidents
- event_dictionary

Adds nullable vpn_session_id columns:
- client_logs
- connection_logs
- telemetry_events
"""

from sqlalchemy import text

from core.database import engine


DDL = [
    """
    CREATE TABLE IF NOT EXISTS observability_events (
      id SERIAL PRIMARY KEY,
      event_time TIMESTAMP NOT NULL DEFAULT NOW(),
      event_name VARCHAR NOT NULL,
      severity VARCHAR NOT NULL DEFAULT 'info',
      source VARCHAR NOT NULL DEFAULT 'backend',
      request_id VARCHAR NULL,
      trace_id VARCHAR NULL,
      span_id VARCHAR NULL,
      vpn_session_id VARCHAR NULL,
      user_id INTEGER NULL REFERENCES users(id),
      device_id INTEGER NULL REFERENCES devices(id),
      server_id INTEGER NULL REFERENCES servers(id),
      device_fingerprint VARCHAR NULL,
      protocol VARCHAR NULL,
      stage VARCHAR NULL,
      outcome VARCHAR NULL,
      reason_code VARCHAR NULL,
      message TEXT NULL,
      config_revision VARCHAR NULL,
      config_hash_expected VARCHAR NULL,
      config_hash_actual VARCHAR NULL,
      attrs_json JSONB NOT NULL DEFAULT '{}'::jsonb,
      schema_version INTEGER NOT NULL DEFAULT 1,
      created_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS observability_incidents (
      id SERIAL PRIMARY KEY,
      incident_key VARCHAR NOT NULL,
      incident_type VARCHAR NOT NULL,
      severity VARCHAR NOT NULL DEFAULT 'P3',
      status VARCHAR NOT NULL DEFAULT 'open',
      title VARCHAR NOT NULL,
      summary TEXT NULL,
      evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
      first_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
      last_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
      assignee_user_id INTEGER NULL REFERENCES users(id),
      resolved_at TIMESTAMP NULL,
      created_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS event_dictionary (
      id SERIAL PRIMARY KEY,
      event_name VARCHAR NOT NULL UNIQUE,
      display_name_ru VARCHAR NOT NULL,
      display_name_en VARCHAR NOT NULL,
      default_comment_template TEXT NULL,
      operator_hint TEXT NULL,
      severity_default VARCHAR NOT NULL DEFAULT 'info',
      is_active BOOLEAN NOT NULL DEFAULT TRUE,
      created_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS observability_incident_comments (
      id SERIAL PRIMARY KEY,
      incident_id INTEGER NOT NULL REFERENCES observability_incidents(id),
      author_user_id INTEGER NULL REFERENCES users(id),
      comment TEXT NOT NULL,
      created_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """,
    "ALTER TABLE client_logs ADD COLUMN IF NOT EXISTS vpn_session_id VARCHAR NULL",
    "ALTER TABLE connection_logs ADD COLUMN IF NOT EXISTS vpn_session_id VARCHAR NULL",
    "ALTER TABLE telemetry_events ADD COLUMN IF NOT EXISTS vpn_session_id VARCHAR NULL",
    "CREATE INDEX IF NOT EXISTS idx_observability_events_event_time ON observability_events(event_time)",
    "CREATE INDEX IF NOT EXISTS idx_observability_events_name ON observability_events(event_name)",
    "CREATE INDEX IF NOT EXISTS idx_observability_events_user ON observability_events(user_id)",
    "CREATE INDEX IF NOT EXISTS idx_observability_events_server ON observability_events(server_id)",
    "CREATE INDEX IF NOT EXISTS idx_observability_events_session ON observability_events(vpn_session_id)",
    "CREATE INDEX IF NOT EXISTS idx_observability_incidents_key ON observability_incidents(incident_key)",
    "CREATE INDEX IF NOT EXISTS idx_observability_incidents_status ON observability_incidents(status)",
    "CREATE INDEX IF NOT EXISTS idx_observability_incident_comments_incident ON observability_incident_comments(incident_id)",
    "CREATE INDEX IF NOT EXISTS idx_client_logs_vpn_session_id ON client_logs(vpn_session_id)",
    "CREATE INDEX IF NOT EXISTS idx_connection_logs_vpn_session_id ON connection_logs(vpn_session_id)",
    "CREATE INDEX IF NOT EXISTS idx_telemetry_events_vpn_session_id ON telemetry_events(vpn_session_id)",
]


def main() -> None:
    with engine.begin() as conn:
        for stmt in DDL:
            conn.execute(text(stmt))
    print("Observability V2 migration applied successfully.")


if __name__ == "__main__":
    main()

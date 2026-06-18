from pathlib import Path
from sqlalchemy import create_engine, text
from contextlib import closing


def load_env_file(path: Path) -> dict:
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def main() -> None:
    secrets_path = None
    for candidate in ("/etc/grani/secrets.env", "/run/secrets/grani.env"):
        candidate_path = Path(candidate)
        if candidate_path.exists():
            secrets_path = candidate_path
            break

    if not secrets_path:
        print("No secrets file found")
        return

    env = load_env_file(secrets_path)
    database_url = env.get("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL not found in secrets file")
        return

    engine = create_engine(database_url)
    with closing(engine.connect()) as conn:
        server = conn.execute(
            text(
                """
                SELECT id, name, ip_address
                FROM servers
                WHERE name = :name
                ORDER BY id ASC
                LIMIT 1
                """
            ),
            {"name": "HU-BUD-01"},
        ).mappings().first()
        print("server:", dict(server) if server else None)

        if not server:
            return

        server_id = server["id"]
        cols = conn.execute(
            text(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_name = :t
                ORDER BY ordinal_position
                """
            ),
            {"t": "connection_logs"},
        ).fetchall()
        col_names = [col[0] for col in cols]
        print("connection_logs columns:", col_names)

        wanted = [
            "id",
            "device_id",
            "server_id",
            "event_type",
            "created_at",
            "connected_at",
            "disconnected_at",
            "duration_seconds",
        ]
        select_cols = [col for col in wanted if col in col_names]
        if not select_cols:
            print("connection_logs: no expected columns found")
        else:
            query = (
                "SELECT {} FROM connection_logs WHERE server_id = :sid "
                "ORDER BY created_at DESC LIMIT 20"
            ).format(", ".join(select_cols))
            rows = conn.execute(text(query), {"sid": server_id}).mappings().all()
            print("connection_logs latest:")
            for row in rows:
                print(dict(row))

        total = conn.execute(
            text("SELECT COUNT(*) FROM connection_logs WHERE server_id = :sid"),
            {"sid": server_id},
        ).scalar()
        print("connection_logs total for server:", total)

        devices_total = conn.execute(
            text("SELECT COUNT(*) FROM devices WHERE current_server_id = :sid"),
            {"sid": server_id},
        ).scalar()
        print("devices on server:", devices_total)


if __name__ == "__main__":
    main()

"""EXPERIMENT (guarded): apply the v2 feed migrations (001-010) from the backend at startup.

- Cheap startup check first: one query on feed_epoch. When every feed is present nothing
  else runs, so a normal restart adds no noticeable startup delay.
- The apply itself runs in a background task, so a slow or failing migration never blocks
  the server from starting and never turns into HTTP 500 for users: a feed without its
  epoch row keeps answering the "disabled" response and clients stay on the old sync.
- A PostgreSQL advisory lock serializes multiple workers/restarts. A worker that cannot
  take the lock waits briefly for the holder, then leaves the feeds as they are until a
  later restart.
- Each file is idempotent: Part 1 (columns/trigger/epoch row) runs in its own transaction
  with lock_timeout from the file, then each CREATE INDEX CONCURRENTLY runs alone outside
  any transaction. A leftover INVALID index from a crashed attempt is dropped and rebuilt.
- A failed file is logged and skipped; the remaining files still apply.
"""
import asyncio
import os
import re
import time
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlparse

import psycopg2

EXPECTED_FEEDS = 14
ADVISORY_LOCK_KEY = 727403
MIN_SERVER_VERSION_NUM = 140000  # the SQL files state PostgreSQL 14+ (xid8, OR REPLACE TRIGGER)

MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "feed_migrations"
PART2_MARKER = "-- ===== Part 2"

# (sql file, feeds it creates, indexes it builds), in apply order.
FILES = [
    ("001_tx_feed_up.sql", ["transactions"], ["transactions_company_tx_id"]),
    ("002_coding_feed_up.sql", ["coding"], ["coding_company_tx_id"]),
    ("003_employees_feed_up.sql", ["employees"], ["employees_company_tx_id"]),
    ("004_supplier_feed_up.sql", ["supplier"], ["supplier_company_tx_id"]),
    ("005_settlement_feed_up.sql", ["settlement"], ["settlement_company_tx_id"]),
    ("006_inventory_feed_up.sql", ["inventory"], ["inventory_company_tx_id"]),
    ("007_commercial_feed_up.sql", ["sale", "sale_return", "customer_payment"],
     ["sales_company_tx_id", "sale_returns_company_tx_id", "customer_payments_company_tx_id"]),
    ("008_transfers_feed_up.sql", ["stock_transfer"], ["stock_transfers_company_tx_id"]),
    ("009_hr_attendance_feed_up.sql", ["hr_attendance"], ["hr_attendance_company_tx_id"]),
    ("010_hr_remaining_feeds_up.sql", ["hr_vacations", "hr_adjustments", "hr_employee_settings"],
     ["hr_vacations_company_tx_id", "hr_adjustments_company_tx_id",
      "hr_employee_settings_company_tx_id"]),
]


class MigratorConnectError(RuntimeError):
    """Connection failure whose message never carries credentials or the raw URL."""


# libpq parameters psycopg2 accepts; driver-specific ones (asyncpg's `ssl`,
# SQLAlchemy / pgbouncer options, ...) are dropped so a copied URL cannot crash us.
_LIBPQ_PARAMS = {
    "sslmode", "sslcert", "sslkey", "sslrootcert", "sslcrl", "channel_binding",
    "connect_timeout", "application_name", "options", "hostaddr", "keepalives",
    "keepalives_idle", "keepalives_interval", "keepalives_count",
}
_SSL_ALIASES = {"require": "require", "verify-ca": "verify-ca", "verify-full": "verify-full",
                "true": "require", "1": "require", "prefer": "prefer", "allow": "allow",
                "disable": "disable", "false": "disable", "0": "disable"}


def _direct_host(host: str) -> str:
    # Neon's pooled endpoint is the direct endpoint id with "-pooler" appended.
    # Session advisory locks and CREATE INDEX CONCURRENTLY are unreliable through
    # the pgbouncer pooler, so the migrator connects to the direct endpoint.
    if host and "-pooler." in host:
        return host.replace("-pooler.", ".", 1)
    return host


def connect_params() -> dict:
    """Parse the database URL into psycopg2 kwargs (host/dbname/user may be logged;
    password and the raw URL never are)."""
    raw = (os.getenv("FEED_MIGRATOR_DATABASE_URL") or os.getenv("DATABASE_URL") or "").strip()
    if not raw:
        raise RuntimeError("DATABASE_URL is not set")
    # accept postgres://, postgresql:// and SQLAlchemy driver forms (postgresql+asyncpg://, ...)
    m = re.match(r"^postgres(?:ql)?(?:\+[a-z0-9_]+)?://", raw, re.IGNORECASE)
    if not m:
        raise RuntimeError("DATABASE_URL is not a postgres connection URL")
    parsed = urlparse("postgresql://" + raw[m.end():])
    if not parsed.hostname or not parsed.username:
        raise RuntimeError("DATABASE_URL is missing host or user")
    query = dict(parse_qsl(parsed.query))
    ssl = query.pop("ssl", None)  # asyncpg-style parameter
    if ssl is not None and "sslmode" not in query:
        query["sslmode"] = _SSL_ALIASES.get(ssl.lower(), "require")
    if "sslmode" not in query:
        query["sslmode"] = "disable" if os.getenv("LOCAL_PG_NOSSL") else "require"
    params = {
        "host": _direct_host(parsed.hostname),
        "port": parsed.port or 5432,
        "dbname": unquote(parsed.path.lstrip("/")) or "postgres",
        "user": unquote(parsed.username),
        "password": unquote(parsed.password) if parsed.password else None,
    }
    params.update({k: v for k, v in query.items() if k in _LIBPQ_PARAMS})
    return {k: v for k, v in params.items() if v is not None}


def _connect():
    params = connect_params()
    try:
        conn = psycopg2.connect(**params)
    except Exception as exc:
        # the driver error can echo the DSN (with the password) — never surface it
        raise MigratorConnectError(
            f"could not connect (host={params['host']} dbname={params['dbname']} "
            f"user={params['user']}): {type(exc).__name__}") from None
    conn.autocommit = True
    return conn


def _safe_repr(exc) -> str:
    """repr() of an exception with the password and raw URLs blanked out."""
    msg = repr(exc)
    secrets = [os.getenv("DATABASE_URL"), os.getenv("FEED_MIGRATOR_DATABASE_URL")]
    try:
        secrets.append(connect_params().get("password"))
    except Exception:
        pass
    for secret in secrets:
        if secret and secret in msg:
            msg = msg.replace(secret, "***")
    return msg


def _existing_feeds(cur) -> set:
    try:
        cur.execute("select feed from feed_epoch")
        return {r[0] for r in cur.fetchall()}
    except psycopg2.Error:
        return set()


def _invalid_indexes(cur, names):
    bad = []
    for name in names:
        cur.execute(
            "select 1 from pg_index i join pg_class c on c.oid = i.indexrelid "
            "where c.relname = %s and not i.indisvalid", (name,))
        if cur.fetchone():
            bad.append(name)
    return bad


def _split_parts(sql: str):
    # every file is: one BEGIN..COMMIT block (columns/trigger/epoch), then the
    # CREATE INDEX CONCURRENTLY statements that must run outside any transaction.
    part1, sep, part2 = sql.partition("COMMIT;")
    assert sep, "migration file has no COMMIT;"
    part1 = part1 + sep
    # comment lines first (a comment may itself contain a semicolon), then split on ";"
    lines = [l for l in part2.splitlines()
             if l.strip() and not l.strip().startswith("--")]
    statements = [s.strip() for s in "\n".join(lines).split(";") if s.strip()]
    return part1, statements


def _apply_file(cur, fname, feeds, index_names, done_feeds, log):
    if all(f in done_feeds for f in feeds) and not _invalid_indexes(cur, index_names):
        return "skipped"
    t0 = time.monotonic()
    for name in _invalid_indexes(cur, index_names):
        log(f"⚠️ {fname}: dropping invalid leftover index {name} before rebuild")
        cur.execute(f'DROP INDEX CONCURRENTLY IF EXISTS "{name}"')
    part1, part2_statements = _split_parts(
        (MIGRATIONS_DIR / fname).read_text(encoding="utf-8"))
    cur.execute(part1)  # the file's own BEGIN..COMMIT with SET LOCAL lock_timeout
    for stmt in part2_statements:  # CREATE INDEX CONCURRENTLY, autocommit, no transaction
        cur.execute(stmt)
    log(f"✅ {fname} applied in {time.monotonic() - t0:.1f}s")
    return "applied"


def _apply_all_sync(log=print):
    applied, failed, skipped = [], [], []
    conn = _connect()
    try:
        with conn.cursor() as cur:
            cur.execute("select pg_try_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
            if not cur.fetchone()[0]:
                deadline = time.monotonic() + float(
                    os.getenv("FEED_MIGRATOR_WAIT_SECS", "120"))
                while time.monotonic() < deadline:
                    time.sleep(2)
                    if len(_existing_feeds(cur)) >= EXPECTED_FEEDS:
                        log("✅ v2 feed migrations: applied by another worker")
                        return ("waited", applied, failed, skipped)
                log("⚠️ v2 feed migrations: another worker holds the migration lock; "
                    "leaving v2 feeds disabled until a later restart")
                return ("locked", applied, failed, skipped)
            try:
                cur.execute("show server_version_num")
                if int(cur.fetchone()[0]) < MIN_SERVER_VERSION_NUM:
                    log("⚠️ v2 feed migrations need PostgreSQL 14+; leaving v2 feeds disabled")
                    return ("pg-version", applied, failed, skipped)
                done = _existing_feeds(cur)
                for fname, feeds, indexes in FILES:
                    try:
                        outcome = _apply_file(cur, fname, feeds, indexes, done, log)
                    except Exception as exc:
                        log(f"⚠️ {fname} failed: {_safe_repr(exc)}")
                        # a failed BEGIN..COMMIT block leaves an aborted transaction
                        # that would poison every later statement on this session
                        try:
                            cur.execute("ROLLBACK")
                        except psycopg2.Error:
                            pass
                        outcome = "failed"
                    {"applied": applied, "failed": failed,
                     "skipped": skipped}[outcome].append(fname)
                    if outcome in ("applied", "skipped"):
                        done |= set(feeds)
                log(f"v2 feed migrations: {len(done)}/{EXPECTED_FEEDS} feeds active")
            finally:
                try:
                    cur.execute("select pg_advisory_unlock(%s)", (ADVISORY_LOCK_KEY,))
                except psycopg2.Error:
                    pass  # the lock also dies with the session on close()
    finally:
        conn.close()
    log(f"v2 feed migrations done: {len(applied)} applied, "
        f"{len(skipped)} skipped, {len(failed)} failed")
    return ("ok", applied, failed, skipped)


async def applied_feed_count() -> int:
    """Cheap startup check: one pooled query, no lock. -1 when unknown."""
    try:
        from sqlalchemy import text
        from app.core.database import engine
        async with engine.connect() as conn:
            row = (await conn.execute(text("select count(*) from feed_epoch"))).scalar()
            return int(row)
    except Exception:
        return -1


async def run_background():
    try:
        _, _, failed, _ = await asyncio.to_thread(_apply_all_sync)
        if failed:
            print(f"⚠️ v2 feed migrations finished with {len(failed)} failed file(s): "
                  f"{', '.join(failed)}. Those feeds keep serving the old sync.")
    except Exception as exc:
        print(f"⚠️ v2 feed migrator crashed: {_safe_repr(exc)}. Feeds keep serving the old sync.")


if __name__ == "__main__":
    asyncio.run(run_background())

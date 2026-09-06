"""Read-only structural preflight for rollback images without db.schema_contract."""

from __future__ import annotations

import asyncio
import os
import re
import sys

import asyncpg

REQUIRED_COLUMNS = {
    "fortune_profiles": {
        "user_id", "gender", "birth_date", "revision", "created_at", "updated_at",
    },
    "daily_fortunes": {
        "user_id", "fortune_date", "timezone_snapshot", "profile_revision",
        "result_schema_version", "semantic_result", "copy_by_locale", "unlock_state",
        "unlock_source", "unlocked_at", "revealed_at", "ephemeris_version",
        "rule_version", "copy_version", "created_at", "updated_at",
    },
    "fortune_ad_sessions": {
        "session_id", "user_id", "fortune_date", "client_request_id", "verified",
        "ssv_transaction_id", "created_at", "expires_at", "verified_at",
    },
}

EXPECTED_KIND_CONSTRAINT = (
    "CHECK((kind=ANY(ARRAY['normal'::text,'greeting'::text,"
    "'fortune_context_root'::text,'fortune_derived'::text])))"
)


def _compact(value: str) -> str:
    return re.sub(r"\s+", "", value)


async def _check() -> list[str]:
    raw_dsn = os.environ.get("SUPABASE_DB_CONNECTION_STRING", "")
    if not raw_dsn:
        return ["SUPABASE_DB_CONNECTION_STRING is missing"]
    dsn = re.sub(r"^postgresql\+asyncpg://", "postgresql://", raw_dsn)
    errors: list[str] = []
    conn = await asyncpg.connect(dsn, command_timeout=15, statement_cache_size=0)
    try:
        async with conn.transaction(readonly=True):
            table_rows = await conn.fetch(
                """
                SELECT c.relname, c.relrowsecurity
                FROM pg_class c
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND c.relkind='r'
                  AND c.relname=ANY($1::text[])
                """,
                list(REQUIRED_COLUMNS),
            )
            tables = {row["relname"]: row["relrowsecurity"] for row in table_rows}
            for table in REQUIRED_COLUMNS:
                if table not in tables:
                    errors.append(f"missing table: public.{table}")
                elif not tables[table]:
                    errors.append(f"RLS disabled: public.{table}")

            column_rows = await conn.fetch(
                """
                SELECT table_name,column_name FROM information_schema.columns
                WHERE table_schema='public' AND table_name=ANY($1::text[])
                """,
                list(REQUIRED_COLUMNS),
            )
            columns: dict[str, set[str]] = {name: set() for name in REQUIRED_COLUMNS}
            for row in column_rows:
                columns[row["table_name"]].add(row["column_name"])
            for table, required in REQUIRED_COLUMNS.items():
                missing = sorted(required - columns[table])
                if missing:
                    errors.append(f"missing columns: public.{table} ({', '.join(missing)})")

            grants = await conn.fetch(
                """
                SELECT table_name,grantee FROM information_schema.role_table_grants
                WHERE table_schema='public' AND table_name=ANY($1::text[])
                  AND grantee IN ('anon','authenticated')
                """,
                list(REQUIRED_COLUMNS),
            )
            for row in grants:
                errors.append(f"client grant exposed: {row['table_name']} -> {row['grantee']}")

            reward_expiry_column = await conn.fetchrow(
                """
                SELECT is_nullable,column_default FROM information_schema.columns
                WHERE table_schema='public' AND table_name='reward_ad_sessions'
                  AND column_name='expires_at'
                """
            )
            if reward_expiry_column is None:
                errors.append("missing column: reward_ad_sessions.expires_at")
            elif reward_expiry_column["is_nullable"] != "NO":
                errors.append("reward_ad_sessions.expires_at must be NOT NULL")

            reward_expiry = await conn.fetchrow(
                """
                SELECT pg_get_constraintdef(oid) AS definition,convalidated
                FROM pg_constraint
                WHERE conrelid=to_regclass('public.reward_ad_sessions')
                  AND conname='reward_ad_sessions_expiry_ck'
                """
            )
            if reward_expiry is None:
                errors.append("missing constraint: reward_ad_sessions_expiry_ck")
            elif (
                not reward_expiry["convalidated"]
                or _compact(reward_expiry["definition"]) != "CHECK((expires_at>created_at))"
            ):
                errors.append("reward_ad_sessions_expiry_ck is not the validated expiry contract")

            reward_index = await conn.fetchrow(
                """
                SELECT i.indisvalid,i.indisready,pg_get_indexdef(i.indexrelid) AS definition,
                       pg_get_expr(i.indpred,i.indrelid) AS predicate
                FROM pg_index i
                JOIN pg_class c ON c.oid=i.indexrelid
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND c.relname='reward_ad_sessions_expiry_idx'
                """
            )
            if reward_index is None:
                errors.append("missing index: reward_ad_sessions_expiry_idx")
            else:
                definition = _compact(reward_index["definition"]).lower()
                predicate = _compact(reward_index["predicate"] or "").lower()
                if not reward_index["indisvalid"] or not reward_index["indisready"]:
                    errors.append("reward_ad_sessions_expiry_idx is invalid or not ready")
                if "onpublic.reward_ad_sessionsusingbtree(expires_at,session_id)" not in definition:
                    errors.append("reward_ad_sessions_expiry_idx has unexpected columns")
                if predicate:
                    errors.append("reward_ad_sessions_expiry_idx must cover all sessions")

            kind = await conn.fetchrow(
                """
                SELECT pg_get_constraintdef(oid) AS definition, convalidated
                FROM pg_constraint
                WHERE conrelid=to_regclass('public.messages')
                  AND conname='messages_kind_check'
                """
            )
            if kind is None:
                errors.append("missing constraint: messages_kind_check")
            elif not kind["convalidated"] or _compact(kind["definition"]) != EXPECTED_KIND_CONSTRAINT:
                errors.append("messages_kind_check is not the validated fortune contract")

            index = await conn.fetchrow(
                """
                SELECT i.indisvalid,i.indisready,pg_get_indexdef(i.indexrelid) AS definition,
                       pg_get_expr(i.indpred,i.indrelid) AS predicate
                FROM pg_index i
                JOIN pg_class c ON c.oid=i.indexrelid
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND c.relname='messages_fortune_context_root_idx'
                """
            )
            if index is None:
                errors.append("missing index: messages_fortune_context_root_idx")
            else:
                definition = _compact(index["definition"]).lower()
                predicate = _compact(index["predicate"] or "").lower()
                if not index["indisvalid"] or not index["indisready"]:
                    errors.append("messages_fortune_context_root_idx is invalid or not ready")
                if "onpublic.messagesusingbtree(user_id,iddesc)" not in definition:
                    errors.append("messages_fortune_context_root_idx has unexpected columns")
                if "sender='user'::text" not in predicate or "kind='fortune_context_root'::text" not in predicate:
                    errors.append("messages_fortune_context_root_idx has unexpected predicate")

    finally:
        await conn.close()
    return errors


def main() -> int:
    try:
        errors = asyncio.run(_check())
    except Exception as exc:  # noqa: BLE001  # any preflight failure must stop deployment
        print(f"ERROR: fortune DB preflight query failed: {type(exc).__name__}", file=sys.stderr)
        return 1
    if errors:
        print("ERROR: fortune DB preflight failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("  - fortune DB preflight OK (schema, RLS, grants, constraint, index)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

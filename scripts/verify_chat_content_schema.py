"""Trusted readonly compatibility for the exact pre-encryption main catalog.

Only the reviewed four columns, two nullable changes, three storage checks and
paired deletion change are permitted. Runs from infra stdin, never rollback code.
No generation, migration, user-content query, key or decoded data output.
"""

from __future__ import annotations

import asyncio
from copy import deepcopy
import hashlib
import json
import os
import re
import sys

BASELINE_DIGEST = "5843b2aefad6de4729dbb3982931e5ad04a80a9081891f1c315d066a35b4e5ae"
EXPANDED_DIGEST = "dc82ed2ede6967ab335377c94df287bdb5df811a7b75a1406b8c12d119eaabe6"
REVIEWED_DELTA = {
    "columns": {
        "public.greetings.content": {
            "collation": '"default"',
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "text",
        },
        "public.greetings.content_ciphertext": {
            "collation": None,
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "bytea",
        },
        "public.idempotency_keys.response_ciphertext": {
            "collation": None,
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "bytea",
        },
        "public.messages.content": {
            "collation": '"default"',
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "text",
        },
        "public.messages.content_chars": {
            "collation": None,
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "integer",
        },
        "public.messages.content_ciphertext": {
            "collation": None,
            "default": None,
            "generated": "",
            "identity": "",
            "not_null": False,
            "type": "bytea",
        },
    },
    "constraints": {
        "public.greetings.greetings_content_storage_ck": {
            "deferrable": False,
            "deferred": False,
            "definition": "CHECK "
            "((((content_ciphertext "
            "IS NULL) AND (content "
            "IS NOT NULL)) OR "
            "((content_ciphertext "
            "IS NOT NULL) AND "
            "(content IS NULL) "
            "AND\n"
            "CASE\n"
            "    WHEN "
            "((octet_length(content_ciphertext) "
            ">= 32) AND "
            "(octet_length(content_ciphertext) "
            "<= 1048608)) THEN "
            "((SUBSTRING(content_ciphertext "
            "FROM 1 FOR 2) = "
            "decode('0100'::text, "
            "'hex'::text)) AND "
            "((get_byte(content_ciphertext, "
            "2) > 0) OR "
            "(get_byte(content_ciphertext, "
            "3) > 0)))\n"
            "    ELSE false\n"
            "END))) NOT VALID",
            "enforcement_triggers": [],
            "validated": False,
        },
        "public.idempotency_keys.idempotency_response_storage_ck": {
            "deferrable": False,
            "deferred": False,
            "definition": "CHECK "
            "((((response_schema_version "
            "<> 3) AND "
            "(response_ciphertext "
            "IS NULL)) "
            "OR "
            "((response_schema_version "
            "= 3) AND "
            "(((response "
            "IS NULL) "
            "AND "
            "(response_ciphertext "
            "IS NULL) "
            "AND "
            "((redacted_at "
            "IS NOT "
            "NULL) OR "
            "(terminal_status "
            "= ANY "
            "(ARRAY['expired'::text, "
            "'redacted'::text])))) "
            "OR "
            "((response "
            "IS NOT "
            "NULL) AND "
            "(response = "
            "'{}'::jsonb) "
            "AND "
            "(response_ciphertext "
            "IS NOT "
            "NULL) AND "
            "(redacted_at "
            "IS NULL) "
            "AND "
            "(terminal_status "
            "= "
            "'succeeded'::text) "
            "AND "
            "(request_hash "
            "IS NOT "
            "NULL) AND "
            "(request_hash "
            "<> "
            "''::text) "
            "AND (key "
            "!~~ "
            "'shop-purchase:%'::text) "
            "AND (key "
            "!~~ "
            "'topic-prepare:%'::text) "
            "AND\n"
            "CASE\n"
            "    WHEN "
            "((octet_length(response_ciphertext) "
            ">= 32) AND "
            "(octet_length(response_ciphertext) "
            "<= "
            "4194336)) "
            "THEN "
            "((SUBSTRING(response_ciphertext "
            "FROM 1 FOR "
            "2) = "
            "decode('0100'::text, "
            "'hex'::text)) "
            "AND "
            "((get_byte(response_ciphertext, "
            "2) > 0) OR "
            "(get_byte(response_ciphertext, "
            "3) > 0)))\n"
            "    ELSE "
            "false\n"
            "END))))) "
            "NOT VALID",
            "enforcement_triggers": [],
            "validated": False,
        },
        "public.messages.messages_content_storage_ck": {
            "deferrable": False,
            "deferred": False,
            "definition": "CHECK "
            "((((content_ciphertext "
            "IS NULL) AND (content "
            "IS NOT NULL) AND "
            "(content_chars IS "
            "NULL)) OR "
            "((content_ciphertext IS "
            "NOT NULL) AND (content "
            "IS NULL) AND "
            "(content_chars IS NOT "
            "NULL) AND "
            "(content_chars >= 0) "
            "AND (content_chars <= "
            "1048576) AND\n"
            "CASE\n"
            "    WHEN "
            "((octet_length(content_ciphertext) "
            ">= 32) AND "
            "(octet_length(content_ciphertext) "
            "<= 1048608)) THEN "
            "((SUBSTRING(content_ciphertext "
            "FROM 1 FOR 2) = "
            "decode('0100'::text, "
            "'hex'::text)) AND "
            "((get_byte(content_ciphertext, "
            "2) > 0) OR "
            "(get_byte(content_ciphertext, "
            "3) > 0)) AND "
            "(content_chars <= "
            "(octet_length(content_ciphertext) "
            "- 32)) AND "
            "((octet_length(content_ciphertext) "
            "- 32) <= (content_chars "
            "* 4)))\n"
            "    ELSE false\n"
            "END))) NOT VALID",
            "enforcement_triggers": [],
            "validated": False,
        },
    },
    "functions": {
        "public.begin_subject_deletion(uuid,uuid)": {
            "definition": "CREATE OR REPLACE FUNCTION "
            "public.begin_subject_deletion(p_user_id "
            "uuid, p_operation_id uuid)\n"
            " RETURNS bigint\n"
            " LANGUAGE plpgsql\n"
            " SECURITY DEFINER\n"
            " SET search_path TO ''\n"
            "AS $function$\n"
            "DECLARE\n"
            "  v_watermark bigint;\n"
            "BEGIN\n"
            "  IF p_user_id IS NULL OR "
            "p_operation_id IS NULL THEN\n"
            "    RAISE EXCEPTION 'user "
            "and operation are "
            "required';\n"
            "  END IF;\n"
            "  PERFORM "
            "pg_advisory_xact_lock(hashtextextended(p_user_id::text, "
            "0));\n"
            "  -- Every deletion attempt "
            "is a new epoch; work queued "
            "in an earlier epoch is "
            "rejected.\n"
            "  INSERT INTO "
            "public.privacy_subject_barriers "
            "AS b (user_id, state, "
            "operation_id, "
            "high_watermark)\n"
            "  SELECT p_user_id, "
            "'deleting', p_operation_id, "
            "c.memory_source_watermark\n"
            "  FROM public.chat_contexts "
            "c WHERE c.user_id = "
            "p_user_id\n"
            "  ON CONFLICT (user_id) DO "
            "UPDATE SET\n"
            "    state = 'deleting', "
            "operation_id = "
            "EXCLUDED.operation_id, epoch "
            "= b.epoch + 1,\n"
            "    high_watermark = "
            "GREATEST(b.high_watermark, "
            "EXCLUDED.high_watermark), "
            "updated_at = now()\n"
            "  RETURNING b.high_watermark "
            "INTO v_watermark;\n"
            "  IF NOT FOUND THEN\n"
            "    -- An account that never "
            "chatted has no chat "
            "context.\n"
            "    INSERT INTO "
            "public.privacy_subject_barriers "
            "AS b (user_id, state, "
            "operation_id, "
            "high_watermark)\n"
            "    VALUES (p_user_id, "
            "'deleting', p_operation_id, "
            "0)\n"
            "    ON CONFLICT (user_id) DO "
            "UPDATE SET\n"
            "      state = 'deleting', "
            "operation_id = "
            "EXCLUDED.operation_id, epoch "
            "= b.epoch + 1,\n"
            "      updated_at = now();\n"
            "    v_watermark := 0;\n"
            "  END IF;\n"
            "\n"
            "  DELETE FROM "
            "public.chat_topic_entries "
            "WHERE user_id = p_user_id;\n"
            "  DELETE FROM "
            "public.user_topic_states "
            "WHERE user_id = p_user_id;\n"
            "  UPDATE "
            "public.idempotency_keys\n"
            "  SET response = NULL, "
            "response_ciphertext = NULL, "
            "terminal_status = "
            "'redacted', redacted_at = "
            "now()\n"
            "  WHERE user_id = "
            "p_user_id;\n"
            "  UPDATE "
            "public.chat_response_references\n"
            "  SET state = 'unavailable', "
            "diary_id = NULL, "
            "rendered_metadata = "
            "'{}'::jsonb,\n"
            "      redacted_at = now(), "
            "redaction_reason = "
            "'subject_deleting'\n"
            "  WHERE user_id = "
            "p_user_id;\n"
            "  UPDATE public.async_jobs\n"
            "  SET state = CASE WHEN "
            "state = 'ready' THEN "
            "'cancelled' ELSE state END,\n"
            "      payload = '{}'::jsonb, "
            "result_detail = NULL, "
            "payload_redacted_at = "
            "now(),\n"
            "      finished_at = CASE "
            "WHEN state = 'ready' THEN "
            "now() ELSE finished_at END,\n"
            "      result_code = CASE "
            "WHEN state = 'ready' THEN "
            "'subject_deleting' ELSE "
            "result_code END\n"
            "  WHERE user_id = p_user_id "
            "AND state IN ('ready', "
            "'running', 'succeeded', "
            "'dead', 'cancelled');\n"
            "\n"
            "  INSERT INTO "
            "public.privacy_ledger_events(operation_id, "
            "user_id, event, "
            "high_watermark)\n"
            "  VALUES (p_operation_id, "
            "p_user_id, "
            "'serving_blocked_and_redacted', "
            "v_watermark);\n"
            "  RETURN v_watermark;\n"
            "END;\n"
            "$function$\n",
            "owner": "postgres",
        }
    },
}


def catalog_digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def reviewed_upgrade(expected):
    if catalog_digest(expected) != BASELINE_DIGEST:
        raise ValueError("unsupported_legacy_catalog")
    result = deepcopy(expected)
    for section, entries in REVIEWED_DELTA.items():
        result[section].update(deepcopy(entries))
    if catalog_digest(result) != EXPANDED_DIGEST:
        raise ValueError("invalid_reviewed_delta")
    return result


async def check():
    import asyncpg
    from db.catalog import read_catalog, compare_catalog
    from db.schema_contract import load_contract

    expected = reviewed_upgrade(load_contract())
    dsn = re.sub(
        r"^postgresql\+asyncpg://",
        "postgresql://",
        os.environ.get("SUPABASE_DB_CONNECTION_STRING", ""),
    )
    connection = await asyncpg.connect(
        dsn,
        statement_cache_size=0,
        timeout=3,
        command_timeout=15,
        server_settings={"default_transaction_read_only": "on"},
    )
    try:
        async with connection.transaction(readonly=True):
            state = await connection.fetchval(
                "SELECT value FROM public.app_config WHERE key='chat_content_encryption_state'"
            )
        if isinstance(state, str):
            state = json.loads(state)
        if not isinstance(state, dict) or state.get("started") is not False:
            raise ValueError("legacy_reader_forbidden")
        actual = await read_catalog(connection)
        if compare_catalog(expected, actual):
            raise ValueError("schema_drift")
    finally:
        try:
            await asyncio.wait_for(connection.close(), timeout=0.2)
        except BaseException:
            connection.terminate()


def main():
    try:
        asyncio.run(check())
        print("Reviewed inactive encryption schema compatibility OK")
        return 0
    except BaseException:
        print("ERROR: reviewed legacy schema compatibility rejected")
        return 1


if __name__ == "__main__":
    sys.exit(main())

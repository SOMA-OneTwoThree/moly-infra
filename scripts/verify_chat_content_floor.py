"""Trusted infra-supplied readonly downgrade guard, run inside a candidate image.

This source is streamed by deploy.sh, not taken from the rollback target. Only
one app_config row is read; it does not scan/decrypt user content or print keys.
"""
from __future__ import annotations

import asyncio
import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys

KEY = 'chat_content_encryption_state'


def normalize_keyring(raw, *, environment):
    # Do not erase duplicate keys before the runtime's strict parser sees them.
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('invalid_keyring')
            result[key] = value
        return result
    if len(raw) > 65_536:
        raise ValueError('invalid_keyring')
    value = json.loads(raw, object_pairs_hook=pairs)
    if (not isinstance(value, dict) or set(value) != {'environment', 'keys'}
            or value['environment'] != environment
            or not isinstance(value['keys'], dict) or not value['keys']):
        raise ValueError('invalid_keyring')
    decoded = set()
    for number, encoded in value['keys'].items():
        if (not re.fullmatch(r'[1-9][0-9]{0,4}', number) or int(number) > 65535
                or not isinstance(encoded, str)):
            raise ValueError('invalid_keyring')
        key = base64.b64decode(encoded, validate=True)
        if len(key) != 32 or base64.b64encode(key).decode('ascii') != encoded or key in decoded:
            raise ValueError('invalid_keyring')
        decoded.add(key)
    return json.dumps(value, ensure_ascii=True, separators=(',', ':'))


def floor(value, *, supported):
    if value is None:
        return {'supported': supported, 'started': False, 'state_present': False}
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict) or type(value.get('started')) is not bool:
        raise ValueError('invalid_state')
    required, active = value.get('required_key_ids'), value.get('active_key_id')
    if (type(value.get('format_version')) is not int or value['format_version'] != 1
            or type(active) is not int or not 1 <= active <= 65535
            or not isinstance(required, list) or not required
            or any(type(k) is not int or not 1 <= k <= 65535 for k in required)
            or len(required) != len(set(required)) or active not in required):
        raise ValueError('invalid_state')
    if value['started'] and not supported:
        raise ValueError('compatible_reader_required')
    return {'supported': supported, 'started': value['started'], 'state_present': True}


def validate_proof(value, *, environment, version):
    if (not isinstance(value,dict) or value.get('capability')!='chat-content-aead-v1'
            or value.get('environment')!=environment or value.get('version')!=version
            or not re.fullmatch(r'[0-9a-f]{40}',version)
            or type(value.get('started')) is not bool
            or type(value.get('format_version')) is not int or value['format_version']!=1
            or type(value.get('active_key_id')) is not int or not 1<=value['active_key_id']<=65535
            or value.get('schema')!='ok' or value.get('self_test')!='ok'
            or not isinstance(value.get('key_fingerprints'),dict)
            or str(value['active_key_id']) not in value['key_fingerprints']
            or not all(re.fullmatch(r'[1-9][0-9]{0,4}',key) and int(key)<=65535
                       and isinstance(digest,str) and re.fullmatch(r'[0-9a-f]{64}',digest)
                       for key,digest in value['key_fingerprints'].items())):
        raise ValueError('invalid_proof')


async def check():
    import asyncpg
    dsn = re.sub(r'^postgresql\+asyncpg://', 'postgresql://',
                 os.environ.get('SUPABASE_DB_CONNECTION_STRING', ''))
    connection = await asyncpg.connect(dsn, statement_cache_size=0, timeout=3,
        command_timeout=1, server_settings={'default_transaction_read_only':'on'})
    try:
        async with connection.transaction(readonly=True):
            value = await connection.fetchval('SELECT value FROM public.app_config WHERE key=$1', KEY)
        return floor(value, supported=Path('/app/scripts/check_chat_content_crypto.py').is_file())
    finally:
        try:
            await asyncio.wait_for(connection.close(), timeout=0.2)
        except BaseException:
            connection.terminate()


def main():
    try:
        parser=argparse.ArgumentParser()
        parser.add_argument('--normalize-keyring', action='store_true')
        parser.add_argument('--proof')
        parser.add_argument('--reference')
        parser.add_argument('--environment')
        parser.add_argument('--expected-sha')
        args=parser.parse_args()
        if args.normalize_keyring:
            print(normalize_keyring(sys.stdin.read(65_537), environment=args.environment))
            return 0
        if args.proof:
            path=Path(args.proof)
            if path.stat().st_size>65_536:
                raise ValueError('proof_too_large')
            value=json.loads(path.read_text())
            validate_proof(value,environment=args.environment,version=args.expected_sha)
            if args.reference:
                reference=json.loads(Path(args.reference).read_text())
                validate_proof(reference,environment=args.environment,version=args.expected_sha)
                if value!=reference:
                    raise ValueError('runtime_key_or_policy_mismatch')
            return 0
        print(json.dumps(asyncio.run(check()), sort_keys=True))
        return 0
    except BaseException:
        print(json.dumps({'status':'blocked','reason':'chat_content_crypto_floor_failed'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())

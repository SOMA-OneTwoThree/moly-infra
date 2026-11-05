"""Offline helpers and portable shell fragments; no Docker/AWS/DB execution."""
import importlib.util
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('floor',ROOT/'scripts/verify_chat_content_floor.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FloorTests(unittest.TestCase):
    def mode(self,**updates):
        return dict(started=False,format_version=1,active_key_id=1,required_key_ids=[1],**updates)

    def test_missing_before_first_expansion_does_not_invent_a_started_state(self):
        self.assertEqual(module.floor(None,supported=False),{'started':False,'supported':False,'state_present':False})

    def test_started_rejects_old_image_before_legacy_fallback(self):
        value=self.mode()
        value['started']=True
        with self.assertRaises(ValueError):
            module.floor(value,supported=False)
        self.assertTrue(module.floor(value,supported=True)['started'])

    def test_invalid_mode_is_not_false(self):
        for key,value in [('started',0),('format_version',True),('active_key_id',True),
                          ('required_key_ids',[]),('required_key_ids',[1,1])]:
            mode=self.mode()
            mode[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                module.floor(mode,supported=True)

    def test_capability_proof_requires_exact_environment_key_and_version(self):
        value={'capability':'chat-content-aead-v1','environment':'development','version':'a'*40,
               'started':False,'format_version':1,'active_key_id':1,'key_fingerprints':{'1':'b'*64},
               'schema':'ok','self_test':'ok'}
        module.validate_proof(value,environment='development',version='a'*40)
        for key,wrong in [('capability','legacy'),('environment','production'),('version','c'*40),
                          ('format_version',True),('key_fingerprints',{'1':'secret'})]:
            corrupted={**value,key:wrong}
            with self.subTest(key=key),self.assertRaises(ValueError):
                module.validate_proof(corrupted,environment='development',version='a'*40)

    def test_pretty_keyring_normalizes_without_changing_key_material(self):
        value={'environment':'development','keys':{'1':base64.b64encode(b'x'*32).decode()}}
        raw=json.dumps(value,indent=2)+'\r\n'
        compact=module.normalize_keyring(raw,environment='development')
        self.assertNotIn('\n',compact)
        self.assertEqual(json.loads(compact),value)

    def test_raw_standard_key_wraps_only_key_one_and_exact_environment(self):
        encoded=base64.b64encode(b'x'*32).decode()
        for environment in ('development','production'):
            for raw in (encoded, ' \r\n'+encoded+'\n'):
                with self.subTest(environment=environment,raw_length=len(raw)):
                    self.assertEqual(json.loads(module.normalize_keyring(raw,environment=environment)),
                        {'environment':environment,'keys':{'1':encoded}})

    def test_raw_key_extension_does_not_admit_scalar_malformed_or_noncanonical_values(self):
        encoded=base64.b64encode(b'x'*32).decode()
        cases=[json.dumps(encoded), encoded.rstrip('='), encoded+'=',
               encoded[:10]+'\n'+encoded[10:],
               base64.b64encode(b'x'*31).decode(),
               base64.b64encode(b'x'*33).decode(),
               encoded[:-2]+'h=',
               base64.urlsafe_b64encode(b'\xff'*32).decode(),
               '{"environment":"development","keys":{',
               json.dumps({'environment':'production','keys':{'1':encoded}})]
        for raw in cases:
            with self.subTest(raw_length=len(raw)),self.assertRaises(ValueError):
                module.normalize_keyring(raw,environment='development')

    def test_invalid_keyring_never_exposes_input_or_parser_error(self):
        good=base64.b64encode(b'x'*32).decode()
        cases=['{secret-canary',
               '{"environment":"development","keys":{"1":"'+good+'","1":"'+good+'"}}',
               json.dumps({'environment':'development','keys':{'1':good+'\n'}})]
        for raw in cases:
            result=subprocess.run(['python3',str(ROOT/'scripts/verify_chat_content_floor.py'),
                '--normalize-keyring','--environment','development'],input=raw,text=True,
                capture_output=True,timeout=3)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(result.stderr,'')
            self.assertNotIn('secret-canary',result.stdout)
            self.assertEqual(json.loads(result.stdout)['status'],'blocked')

    def test_static_no_plaintext_or_secret_output_and_parallel_order(self):
        source=(ROOT/'deploy.sh').read_text()
        self.assertIn('CHAT_CONTENT_ENCRYPTION_KEYS=${CHAT_CONTENT_ENCRYPTION_KEYS}',source)
        self.assertLess(source.index('CRYPTO_TIMER_PAUSED=0'),source.index('mv "$NEXT_BACKEND_ENV_FILE"'))
        self.assertGreater(source.index('old worker drain complete'),source.index('up -d'))
        self.assertIn('label=com.docker.compose.service=worker',source)
        self.assertNotIn('systemctl stop moly-worker.service',source)
        self.assertNotIn('docker kill',source)
        self.assertIn('trap crypto_restore_timer EXIT',source)
        self.assertIn('CRYPTO_TIMER_PAUSED=1\n  trap crypto_restore_timer EXIT\n  case',source)


class DrainShellTests(unittest.TestCase):
    def run_fragment(self,case):
        source=(ROOT/'deploy.sh').read_text()
        setup=source[source.index('CRYPTO_TIMER_PAUSED=0'):source.index('# 여기서부터 live 파일을 바꾼다.')]
        # This fixture isolates graceful drain/timer behavior. The complete
        # image/env/key launch check is exercised by DeployTests; provide its
        # successful dependency here instead of running it with missing host
        # paths. Record the call so its ordering remains observable.
        launch_check='\ncrypto_verify_worker_launch() { printf "worker_launch_check\\n" >> "$EVENTS"; }\n'
        start=source.index('if [ "$CRYPTO_SUPPORTED" = 1 ]; then\n  while true; do')
        stop=source.index('# ---------------------------------------------------------------------------\n# 7.',start)
        drain=source[start:stop]
        # Keep the production branch verbatim; force the elapsed clock past its
        # bound in this fixture only rather than waiting900s in an offline test.
        if case=='timeout':
            drain=drain.replace('-ge 900','-ge 0')
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)
            log=path/'events'
            for command in ('docker','systemctl','sleep'):
                script=path/command
                script.write_text('''#!/bin/sh
printf '%s %s\\n' "${0##*/}" "$*" >> "$EVENTS"
case "${0##*/}:$*" in
  systemctl:is-active\\ moly-worker.timer) echo active ;;
  systemctl:is-active\\ moly-worker.service) echo inactive ;;
  systemctl:stop\\ moly-worker.timer) [ "$CASE" != stopfail ] ;;
  docker:ps*)
    [ "$CASE" != inventoryfail ] || exit 1
    [ "$CASE" != timeout ] || echo synthetic-old-worker ;;
esac
exit 0
''')
                # In stopfail preserve the command's actual failure code.
                script.write_text(script.read_text().replace('[ "$CASE" != stopfail ] ;;','[ "$CASE" != stopfail ] || exit 1 ;;'))
                script.chmod(0o755)
            env={'PATH':str(path)+':/usr/bin:/bin','EVENTS':str(log),'CASE':case}
            result=subprocess.run([os.environ.get('MOLY_TEST_BASH','/bin/bash'),'-c',
                                   'set -euo pipefail\nCRYPTO_SUPPORTED=1\n'+setup+launch_check+drain],
                                  env=env,capture_output=True,text=True,timeout=3)
            return result,log.read_text()

    def test_completed_tick_is_observed_without_kill_and_timer_restored(self):
        result,log=self.run_fragment('complete')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('old worker drain complete',result.stdout)
        self.assertIn('systemctl stop moly-worker.timer',log)
        self.assertIn('systemctl start moly-worker.timer',log)
        self.assertLess(log.index('worker_launch_check'),log.index('systemctl start moly-worker.timer'))

    def test_orphan_tick_times_out_and_restores_timer(self):
        result,log=self.run_fragment('timeout')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('graceful drain timed out',result.stderr)
        self.assertIn('systemctl start moly-worker.timer',log)
        self.assertNotIn('kill',log)

    def test_failed_inventory_never_claims_drained(self):
        result,log=self.run_fragment('inventoryfail')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('inventory unavailable',result.stderr)
        self.assertIn('systemctl start moly-worker.timer',log)

    def test_pause_error_still_restores_owned_timer(self):
        result,log=self.run_fragment('stopfail')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('systemctl start moly-worker.timer',log)


if __name__=='__main__':
    unittest.main()


class BootstrapProofTests(unittest.TestCase):
    def proof(self):
        return {'format':'chat-content-schema-v1','environment':'production',
                'project_ref':'qkgjlgzsharnilxnkytd','version':'a'*40,
                'key_fingerprints':{'1':'b'*64},'self_test':'ok',
                'sql_sha256':module.BOOTSTRAP_SQL_SHA256,'schema_status':'needs_expansion',
                'schema_fingerprint':'c'*64,'applied':False,
                'config_snapshot':{key:{'exists':False,'value':None} for key in module.CONFIG_KEYS}}

    def validate(self,proof,apply=False):
        return module.validate_bootstrap(proof,environment='production',version='a'*40,
            project_ref='qkgjlgzsharnilxnkytd',apply=apply)

    def test_before_expansion_key_proof_is_valid_but_apply_requires_expanded_schema(self):
        value=self.proof()
        self.validate(value)
        with self.assertRaises(ValueError):
            self.validate(value,apply=True)
        self.validate({**value,'schema_status':'expanded','applied':True},apply=True)
        with self.assertRaises(ValueError):
            self.validate({**value,'applied':True})

    def test_receipt_rejects_wrong_target_version_sql_keys_or_partial_snapshot(self):
        for key,wrong in [('project_ref','wrong'),('version','b'*40),('sql_sha256','d'*64),
                          ('self_test','failed'),('key_fingerprints',{}),('config_snapshot',{})]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.validate({**self.proof(),key:wrong})

    def test_existing_marker_requires_proof_for_all_required_keys(self):
        value=self.proof()
        value['config_snapshot'][module.KEY]={'exists':True,'value':{
            'started':False,'format_version':1,'active_key_id':2,'required_key_ids':[1,2]}}
        with self.assertRaises(ValueError):
            self.validate(value)
        value['key_fingerprints']['2']='e'*64
        self.validate(value)

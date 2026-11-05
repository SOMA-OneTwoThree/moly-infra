"""Execute deploy.sh with local fake services; no Docker daemon, AWS or live DB calls.

Run on Linux/Bash >=4: python3 -m unittest discover -s tests -v
Only absolute host paths are redirected into a TemporaryDirectory. Service commands
are stubs, while the actual shell branching, env writing and file promotion execute.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
root=Path(os.environ['DEPLOY_TEST_ROOT'])
case=json.loads(os.environ['DEPLOY_TEST_CASE'])
def event(kind):
    with (root/'calls.jsonl').open('a') as f:
        f.write(json.dumps({'kind':kind,'args':args,
          'live':(root/'backend.env').read_text()})+'\n')
def fail(key):
    code=case.get(key,0)
    if code: sys.exit(code)
if name=='aws':
    if args[:2]==['ecr','get-login-password']: event('ecr_login');print('test-ecr-password')
    elif args[:2]==['ssm','get-parameters-by-path']:
        event('ssm')
        prefix=args[args.index('--path')+1]
        expected='/moly/'+case.get('environment','prod')+'/'
        assert prefix==expected,(prefix,expected)
        keys=['anthropic-api-key','openai-api-key','supabase-db-connection-string',
          'supabase-url','supabase-publishable-key','supabase-secret-key',
          'revenuecat-webhook-auth','fortune-ad-unit-ids','slack-feedback-webhook-url']
        values={k:'test-'+k for k in keys}
        values.update(case.get('parameters', {}))
        values['fcm-service-account']='{\n  "project_id": "test-project"\n}'
        if case.get('missing'): values.pop(case['missing'])
        if case.get('empty'): values[case['empty']]=''
        print(json.dumps({'Parameters':[{'Name':prefix+k,'Value':v} for k,v in values.items()]}))
    else: raise AssertionError(args)
elif name=='jq':
    data=json.load(sys.stdin)
    if '--arg' in args:
        key=args[args.index('--arg')+2]
        print(next(x['Value'] for x in data['Parameters'] if x['Name']==key))
    else: print('\n'.join(x['Name'] for x in data['Parameters']))
elif name=='df': print('Use%\n40%')
elif name=='sleep': pass
elif name=='systemctl':
    event('systemctl')
    if args[0]=='is-active':
        print('inactive' if case.get('crypto_supported') and args[-1]=='moly-worker.service' else 'active')
elif name=='curl':
    event('ready' if ':8000/' in args[-1] else 'nginx')
    fail('ready_fail' if ':8000/' in args[-1] else 'nginx_fail')
elif name=='docker':
    if args[0]=='login': sys.stdin.read();fail('login_fail')
    elif args[0]=='compose':
        if 'pull' in args: event('pull');fail('pull_fail')
        elif 'up' in args: event('up')
        elif 'config' in args:
            event('worker_launch_config')
            env=dict(line.split('=',1) for line in (root/'.env').read_text().splitlines())
            print(json.dumps({'services':{'worker':{'image':'676972757138.dkr.ecr.ap-northeast-2.amazonaws.com/'+env['IMAGE_REPO']+':'+case.get('worker_image_tag',env['IMAGE_TAG']),
              'command':['python','-m','worker']}}}))
        elif 'run' in args and 'scripts/check_chat_content_crypto.py' in args:
            event('crypto_worker_launch');fail('crypto_worker_fail')
            print(json.dumps({'capability':'chat-content-aead-v1','environment':('development' if case.get('environment')=='dev' else 'production'),
              'version':args[-1],'started':case.get('crypto_started',False),'format_version':1,'active_key_id':1,
              'key_fingerprints':{'1':('b'*64 if case.get('worker_key_mismatch') else 'a'*64)},'schema':'ok','self_test':'ok'}))
        elif 'version' not in args and 'ps' not in args: raise AssertionError(args)
    elif args[0]=='run':
        if '-c' in args:
            expr=args[args.index('-c')+1]
            if 'preflight_chat_content_encryption.py' in expr: event('bootstrap_probe');fail('bootstrap_probe')
            elif 'db.schema_contract' in expr: event('schema_probe');fail('schema_probe')
            elif 'worker.consumer' in expr: event('consumer_probe');fail('consumer_probe')
            else: raise AssertionError(args)
        elif args[-1]=='db.schema_contract':
            event('full_schema')
            assert args[args.index('--env-file')+1].endswith('backend.env.next')
            fail('schema_fail')
        elif args[-1]=='-':
            incoming=sys.stdin.read()
            if 'unsupported_legacy_catalog' in incoming:
                event('reviewed_compat_schema')
                sys.exit(0 if case.get('compat_schema_ok') else 1)
            if 'chat_content_encryption_state' in incoming:
                event('crypto_floor');fail('crypto_floor_fail')
                if case.get('crypto_started') and not case.get('crypto_supported'): sys.exit(1)
                print(json.dumps({'supported':case.get('crypto_supported',False),'started':case.get('crypto_started',False),'state_present':True}))
                sys.exit(0)
            event('fallback_schema')
            assert args[args.index('--env-file')+1].endswith('backend.env.next')
            fail('schema_fail')
        elif 'scripts/preflight_chat_content_encryption.py' in args:
            event('bootstrap_controller');fail('bootstrap_fail')
            applied='--apply' in args
            proof={'format':'chat-content-schema-v1','environment':args[args.index('--environment')+1],
              'project_ref':args[args.index('--expected-project-ref')+1],'version':args[args.index('--expected-sha')+1],
              'key_fingerprints':{'1':'a'*64},'self_test':'ok',
              'sql_sha256':args[args.index('--expected-sql-sha256')+1],
              'schema_status':'expanded' if applied else 'needs_expansion','schema_fingerprint':'b'*64,
              'applied':applied,'config_snapshot':{key:{'exists':False,'value':None} for key in
                ('crisis_guard_enabled','crisis_guard_policy_version','crisis_guard_timeout_s',
                 'crisis_guard_history_messages','chat_content_encryption_state')}}
            if case.get('bootstrap_bad'): proof['version']='wrong'
            print(json.dumps(proof))
        elif 'scripts/check_chat_content_crypto.py' in args:
            event('crypto_proof');fail('crypto_proof_fail')
            print(json.dumps({'capability':'chat-content-aead-v1','environment':('development' if case.get('environment')=='dev' else 'production'),
              'version':args[-1],'started':case.get('crypto_started',False),'format_version':1,'active_key_id':1,
              'key_fingerprints':{'1':'a'*64},'schema':'ok','self_test':'ok'}))
        elif args[-1]=='worker.consumer': event('consumer_startup');fail('startup_fail')
        else: raise AssertionError(args)
    elif args[0]=='exec' and 'scripts/check_chat_content_crypto.py' in args:
        event('crypto_runtime');fail('crypto_runtime_fail')
        print(json.dumps({'capability':'chat-content-aead-v1','environment':('development' if case.get('environment')=='dev' else 'production'),
          'version':args[-1],'started':case.get('crypto_started',False),'format_version':1,'active_key_id':1,
          'key_fingerprints':{'1':'a'*64},'schema':'ok','self_test':'ok'}))
    elif args[0]=='inspect':
        event('inspect')
        if '.State.Status' in args[2]: print(case.get('consumer_state','running'))
        else:
            env=dict(line.split('=',1) for line in (root/'.env').read_text().splitlines())
            print('676972757138.dkr.ecr.ap-northeast-2.amazonaws.com/'+env['IMAGE_REPO']+':'+case.get('consumer_image_tag' if args[-1]=='moly-consumer' else 'running_tag',env['IMAGE_TAG']))
    elif args[0]=='rm': event('remove_consumer')
    elif args[0]=='images': pass
    elif args[0]=='ps':
        event('ps')
        if 'label=com.docker.compose.service=consumer' in args:
            fail('consumer_inventory_fail')
            print('moly-consumer')
            if case.get('orphan_consumer'): print('unverified-old-consumer')
    elif args[0] in {'image','logs','rmi'}: event(args[0])
    else: raise AssertionError(args)
else: raise AssertionError(name)
'''


class DeployTests(unittest.TestCase):
    def run_deploy(self, case=None, *, source=None, twice=False, extra_env=None):
        case = case or {}
        with tempfile.TemporaryDirectory(prefix='moly-deploy-test-') as directory:
            root = Path(directory)
            for name in ['scripts', 'systemd']:
                shutil.copytree(ROOT / name, root / name)
            shutil.copy(ROOT / 'docker-compose.yml', root)
            content = (source or ROOT / 'deploy.sh').read_text()
            for path in ['/etc/moly-env', '/etc/moly-worker-host', '/etc/systemd/system']:
                content = content.replace(path, str(root / 'host' / path.removeprefix('/etc/')))
            (root / 'deploy.sh').write_text(content)
            (root / 'host/systemd/system').mkdir(parents=True)
            if case.get('environment') == 'dev':
                (root / 'host/moly-env').write_text('dev\n')
            if 'marker' in case:
                (root / 'host/moly-env').write_text(case['marker'])
            if case.get('worker'):
                (root / 'host/moly-worker-host').touch()
            (root / '.env').write_text('IMAGE_TAG=old-image\nIMAGE_REPO=moly-backend\n')
            (root / 'backend.env').write_text('OLD_ENV=keep\n')
            (root / 'secrets').mkdir()
            (root / 'secrets/fcm-service-account.json').write_text('{"project_id":"old-project"}')
            original_fcm_inode = (root / 'secrets/fcm-service-account.json').stat().st_ino
            (root / 'bin').mkdir()
            for command in ['aws', 'docker', 'curl', 'jq', 'df', 'sleep', 'systemctl']:
                target = root / 'bin' / command
                target.write_text(STUB)
                target.chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'],
                       DEPLOY_TEST_ROOT=str(root), DEPLOY_TEST_CASE=json.dumps(case))
            env.update(extra_env or {})
            args = [os.environ.get('MOLY_TEST_BASH', 'bash'), str(root / 'deploy.sh'), case.get('image_tag','candidate-image')]
            runs = []
            for _ in range(2 if twice else 1):
                runs.append(subprocess.run(args, env=env, text=True, capture_output=True, timeout=30))
            trace = root / 'calls.jsonl'
            events = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            files = {name: (root / name).read_text() for name in ['.env', 'backend.env']}
            fcm = root / 'secrets/fcm-service-account.json'
            files['fcm'] = fcm.read_text() if fcm.exists() else None
            files['fcm_preserved_inode'] = fcm.exists() and fcm.stat().st_ino == original_fcm_inode
            state = root / '.deploy-state'
            files['next_left'] = sorted(p.name for p in state.glob('*.next')) if state.exists() else []
            files['hash_written'] = (state / 'backend.hash').exists()
            files['units'] = sorted(p.name for p in (root / 'host/systemd/system').iterdir())
            return runs[-1], events, files

    def crypto_case(self, **updates):
        value={'environment':'production' if updates.get('environment')=='prod' else 'development','keys':{'1':base64.b64encode(b'x'*32).decode()}}
        return {'environment':'dev','image_tag':'dev-'+'a'*40,'crypto_supported':True,
                'parameters':{'chat-content-keyring':json.dumps(value,indent=2)+'\n'},**updates}

    def test_crypto_candidate_and_both_runtime_roles_are_checked(self):
        run,events,files=self.run_deploy(self.crypto_case(worker=True))
        self.assertEqual(run.returncode,0,run.stderr)
        kinds=[e['kind'] for e in events]
        self.assertEqual(kinds.count('crypto_floor'),1)
        self.assertEqual(kinds.count('crypto_proof'),1)
        self.assertEqual(kinds.count('crypto_runtime'),2)
        self.assertLess(kinds.index('crypto_proof'),kinds.index('up'))
        line=next(x for x in files['backend.env'].splitlines() if x.startswith('CHAT_CONTENT_ENCRYPTION_KEYS='))
        parsed=json.loads(line.split('=',1)[1])
        self.assertEqual(parsed['environment'],'development')
        self.assertNotIn(parsed['keys']['1'],run.stdout+run.stderr)

    def test_supported_production_verifies_three_actual_roles_and_exact_worker_launch(self):
        run,events,_=self.run_deploy(self.crypto_case(environment='prod',image_tag='a'*40,worker=True,crypto_started=True))
        self.assertEqual(run.returncode,0,run.stderr)
        kinds=[e['kind'] for e in events]
        self.assertEqual(kinds.count('crypto_runtime'),2)
        self.assertEqual(kinds.count('crypto_worker_launch'),1)
        self.assertLess(kinds.index('crypto_floor'),kinds.index('full_schema'))
        launch=next(e for e in events if e['kind']=='crypto_worker_launch')
        self.assertIn('--no-deps',launch['args'])
        self.assertIn('scripts/check_chat_content_crypto.py',launch['args'])
        self.assertNotIn('-m',launch['args'])

    def test_started_old_reader_is_rejected_before_any_schema_fallback_or_live_change(self):
        for fallback in ({}, {'schema_probe':3}):
            with self.subTest(fallback=fallback):
                run,events,files=self.run_deploy(dict(fallback,crypto_started=True))
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertNotIn('schema_probe',[e['kind'] for e in events])
                self.assertNotIn('up',[e['kind'] for e in events])

    def test_known_inactive_legacy_schema_delta_is_the_only_compatibility_retry(self):
        run,events,_=self.run_deploy({'schema_fail':1,'compat_schema_ok':True})
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('reviewed_compat_schema',[e['kind'] for e in events])
        run,events,files=self.run_deploy(self.crypto_case(schema_fail=1,compat_schema_ok=True))
        self.assertNotEqual(run.returncode,0)
        self.assertNotIn('reviewed_compat_schema',[e['kind'] for e in events])
        self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')

    def test_capable_consumer_absence_or_latest_tag_fails_before_live_change(self):
        for update in ({'consumer_probe':3},{'image_tag':'latest'}):
            with self.subTest(update=update):
                run,events,files=self.run_deploy(self.crypto_case(**update))
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertNotIn('up',[e['kind'] for e in events])
                self.assertNotIn('remove_consumer',[e['kind'] for e in events])

    def test_worker_launch_failure_preserves_paused_timer_until_compatible_recovery(self):
        for update in ({'worker_image_tag':'wrong'},{'worker_key_mismatch':True},{'crypto_worker_fail':1}):
            with self.subTest(update=update):
                run,events,_=self.run_deploy(self.crypto_case(**update))
                self.assertNotEqual(run.returncode,0)
                calls=[e['args'] for e in events if e['kind']=='systemctl']
                self.assertIn(['stop','moly-worker.timer'],calls)
                self.assertNotIn(['start','moly-worker.timer'],calls)
                self.assertIn('timer remains paused',run.stderr)
                self.assertNotIn('배포 완료',run.stdout)

    def test_wrong_actual_consumer_image_is_not_accepted_from_its_tag_or_proof(self):
        run,events,_=self.run_deploy(self.crypto_case(consumer_image_tag='wrong'))
        self.assertNotEqual(run.returncode,0)
        self.assertIn('runtime image mismatch',run.stderr)
        self.assertIn(['start','moly-worker.timer'],[e['args'] for e in events if e['kind']=='systemctl'])

    def test_bootstrap_checks_keys_before_expansion_without_normal_deploy_or_timer(self):
        for environment in ('dev','prod'):
            with self.subTest(environment=environment):
                case=self.crypto_case(environment=environment,image_tag=('dev-' if environment=='dev' else '')+'a'*40)
                run,events,files=self.run_deploy(case,extra_env={'DEPLOY_PREFLIGHT_ONLY':'1','DEPLOY_CRYPTO_BOOTSTRAP':'1'})
                self.assertEqual(run.returncode,0,run.stderr)
                kinds=[e['kind'] for e in events]
                self.assertIn('bootstrap_controller',kinds)
                for forbidden in ('crypto_floor','schema_probe','full_schema','up','systemctl','ready','crypto_proof'):
                    self.assertNotIn(forbidden,kinds)
                event=next(e for e in events if e['kind']=='bootstrap_controller')
                self.assertIn('--check',event['args'])
                self.assertNotIn('--apply',event['args'])
                self.assertIn('qkgjlgzsharnilxnkytd' if environment=='prod' else 'wywzjslvxwttxkecbyis',event['args'])
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertEqual(files['next_left'],[])

    def test_expand_requires_both_readonly_bootstrap_flags_and_exits_before_live_change(self):
        run,events,files=self.run_deploy(self.crypto_case(),extra_env={'DEPLOY_PREFLIGHT_ONLY':'1',
            'DEPLOY_CRYPTO_BOOTSTRAP':'1','DEPLOY_CRYPTO_EXPAND':'1'})
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('--apply',next(e['args'] for e in events if e['kind']=='bootstrap_controller'))
        self.assertNotIn('up',[e['kind'] for e in events])
        self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
        for values in ({'DEPLOY_CRYPTO_EXPAND':'1'}, {'DEPLOY_CRYPTO_BOOTSTRAP':'1'},
                       {'DEPLOY_PREFLIGHT_ONLY':'1','DEPLOY_CRYPTO_EXPAND':'1'},
                       {'DEPLOY_PREFLIGHT_ONLY':'1','DEPLOY_CRYPTO_BOOTSTRAP':'true'}):
            with self.subTest(values=values):
                run,events,_=self.run_deploy(self.crypto_case(),extra_env=values)
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(events,[])

    def test_bootstrap_missing_controller_failure_or_bad_receipt_preserves_every_live_file(self):
        for update in ({'bootstrap_probe':3},{'bootstrap_fail':1},{'bootstrap_bad':True}):
            with self.subTest(update=update):
                run,events,files=self.run_deploy(self.crypto_case(**update),extra_env={
                    'DEPLOY_PREFLIGHT_ONLY':'1','DEPLOY_CRYPTO_BOOTSTRAP':'1'})
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertEqual(files['next_left'],[])
                self.assertNotIn('up',[e['kind'] for e in events])
                self.assertNotIn('systemctl',[e['kind'] for e in events])

    def test_extra_old_consumer_or_unavailable_inventory_blocks_before_live_change(self):
        for update in ({'orphan_consumer':True},{'consumer_inventory_fail':1}):
            with self.subTest(update=update):
                run,events,files=self.run_deploy(self.crypto_case(**update))
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertNotIn('up',[e['kind'] for e in events])
                self.assertNotIn('remove_consumer',[e['kind'] for e in events])

    def test_raw_ssm_key_is_wrapped_before_candidate_and_runtime_checks(self):
        encoded=base64.b64encode(b'x'*32).decode()
        case=self.crypto_case(parameters={'chat-content-keyring':' \n'+encoded+'\n'})
        run,events,files=self.run_deploy(case)
        self.assertEqual(run.returncode,0,run.stderr)
        line=next(x for x in files['backend.env'].splitlines() if x.startswith('CHAT_CONTENT_ENCRYPTION_KEYS='))
        self.assertEqual(json.loads(line.split('=',1)[1]),{'environment':'development','keys':{'1':encoded}})
        self.assertEqual([e['kind'] for e in events].count('crypto_runtime'),2)
        self.assertNotIn(encoded,run.stdout+run.stderr)

    def test_crypto_preflight_failures_preserve_live_files_and_timer(self):
        for failure in ('crypto_floor_fail','crypto_proof_fail'):
            with self.subTest(failure=failure):
                run,events,files=self.run_deploy(self.crypto_case(**{failure:1}))
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(files['backend.env'],'OLD_ENV=keep\n')
                self.assertNotIn('up',[e['kind'] for e in events])
                self.assertNotIn('systemctl',[e['kind'] for e in events])

    def test_crypto_runtime_failure_restores_timer_and_fails(self):
        run,events,_=self.run_deploy(self.crypto_case(crypto_runtime_fail=1))
        self.assertNotEqual(run.returncode,0)
        calls=[e['args'] for e in events if e['kind']=='systemctl']
        self.assertIn(['stop','moly-worker.timer'],calls)
        self.assertIn(['start','moly-worker.timer'],calls)
        self.assertNotIn('배포 완료',run.stdout)

    def test_preflight_only_validates_without_touching_live_state(self):
        # ALB에서 빼기 전에 실행하는 모드. 통과하든 실패하든 live 파일은 그대로여야 한다.
        side_effects = ['up', 'inspect', 'consumer_probe', 'consumer_startup', 'remove_consumer',
                        'ready', 'nginx', 'systemctl', 'image', 'rmi', 'ps', 'logs']
        for case in [{}, {'schema_probe': 3}, {'schema_fail': 1}, {'schema_probe': 125},
                     {'schema_probe': 3, 'schema_fail': 1}, {'pull_fail': 1}, {'login_fail': 1},
                     {'missing': 'supabase-secret-key'}]:
            with self.subTest(case=case):
                passes = case in ({}, {'schema_probe': 3})
                run, events, files = self.run_deploy(dict(case, worker=True),
                                                     extra_env={'DEPLOY_PREFLIGHT_ONLY': '1'})
                kinds = [e['kind'] for e in events]
                self.assertEqual(run.returncode == 0, passes, run.stderr)
                for kind in side_effects:
                    self.assertNotIn(kind, kinds)
                self.assertEqual(files['backend.env'], 'OLD_ENV=keep\n')
                self.assertIn('IMAGE_TAG=old-image', files['.env'])
                self.assertEqual(json.loads(files['fcm']), {'project_id': 'old-project'})
                self.assertTrue(files['fcm_preserved_inode'])
                self.assertFalse(files['hash_written'])
                self.assertNotIn('test-supabase-secret-key', run.stdout + run.stderr)
                self.assertNotIn('배포 완료', run.stdout)
                if passes:
                    self.assertIn('fallback_schema' if case else 'full_schema', kinds)
                    self.assertEqual(files['next_left'], [])
                    self.assertIn('preflight-only 통과', run.stdout)

    def test_preflight_only_accepts_only_zero_or_one(self):
        for value in ['true', 'yes', '2', ' 1']:
            with self.subTest(value=value):
                run, events, files = self.run_deploy(extra_env={'DEPLOY_PREFLIGHT_ONLY': value})
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(events, [])
                self.assertEqual(files['backend.env'], 'OLD_ENV=keep\n')
                self.assertIn('DEPLOY_PREFLIGHT_ONLY', run.stderr)
        for value in ['0', '']:
            with self.subTest(value=value):
                run, events, files = self.run_deploy(extra_env={'DEPLOY_PREFLIGHT_ONLY': value})
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn('up', [e['kind'] for e in events])
                self.assertIn('IMAGE_TAG=candidate-image', files['.env'])

    def test_new_images_check_candidate_before_promoting_dev_and_prod(self):
        for environment in ['dev', 'prod']:
            with self.subTest(environment=environment):
                run, events, files = self.run_deploy({'environment': environment, 'worker': True})
                self.assertEqual(run.returncode, 0, run.stderr)
                kinds = [e['kind'] for e in events]
                self.assertLess(kinds.index('full_schema'), kinds.index('up'))
                self.assertNotIn('fallback_schema', kinds)
                self.assertEqual(next(e for e in events if e['kind'] == 'full_schema')['live'], 'OLD_ENV=keep\n')
                self.assertIn('IMAGE_TAG=candidate-image', files['.env'])
                self.assertIn('ENVIRONMENT=' + ('development' if environment == 'dev' else 'production'), files['backend.env'])
                self.assertEqual('ENABLE_DEV_ROUTES=true' in files['backend.env'], environment == 'dev')
                self.assertIn('FORTUNE_CHAT_ENABLED=true', files['backend.env'])
                self.assertEqual(json.loads(files['fcm']), {'project_id': 'test-project'})
                self.assertTrue(files['fcm_preserved_inode'])
                self.assertNotIn('test-supabase-secret-key', run.stdout + run.stderr)
                self.assertTrue(any(e['kind'] == 'systemctl' and e['args'][:2] == ['enable', '--now'] for e in events))

    def test_revenuecat_read_configuration_is_optional_and_not_logged(self):
        for environment in ['dev', 'prod']:
            for configured in [False, True]:
                with self.subTest(environment=environment, configured=configured):
                    parameters = ({'revenuecat-api-v2-key': 'test-rc-read-secret',
                                   'revenuecat-project-id': 'test-rc-project'} if configured else {})
                    run, _, files = self.run_deploy({'environment': environment, 'parameters': parameters})
                    self.assertEqual(run.returncode, 0, run.stderr)
                    env = dict(line.split('=', 1) for line in files['backend.env'].splitlines())
                    self.assertEqual(env['REVENUECAT_API_V2_KEY'], parameters.get('revenuecat-api-v2-key', ''))
                    self.assertEqual(env['REVENUECAT_PROJECT_ID'], parameters.get('revenuecat-project-id', ''))
                    self.assertNotIn('test-rc-read-secret', run.stdout + run.stderr)

    def test_fcm_dead_token_switch_defaults_to_dry_run_and_rejects_other_values(self):
        # 미설정이면 false다. true, false 외의 값은 live env를 바꾸기 전에 중단해야 한다.
        for parameters, expected in [({}, 'false'), ({'fcm-invalidate-dead-tokens': 'true'}, 'true'),
                                     ({'fcm-invalidate-dead-tokens': 'false'}, 'false')]:
            with self.subTest(parameters=parameters):
                run, _, files = self.run_deploy({'parameters': parameters})
                self.assertEqual(run.returncode, 0, run.stderr)
                env = dict(line.split('=', 1) for line in files['backend.env'].splitlines())
                self.assertEqual(env['FCM_INVALIDATE_DEAD_TOKENS'], expected)
        for value in ['TRUE', 'yes', '1']:
            with self.subTest(value=value):
                run, events, files = self.run_deploy({'parameters': {'fcm-invalidate-dead-tokens': value}})
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(files['backend.env'], 'OLD_ENV=keep\n')
                self.assertNotIn('up', [e['kind'] for e in events])
                self.assertIn('fcm-invalidate-dead-tokens', run.stderr)

    def test_preflight_and_pull_failures_preserve_live_env(self):
        for failure in [{'schema_fail': 1}, {'schema_probe': 125}, {'schema_probe': 3, 'schema_fail': 1},
                        {'pull_fail': 1}, {'login_fail': 1}, {'missing': 'supabase-secret-key'}]:
            with self.subTest(failure=failure):
                run, events, files = self.run_deploy(failure)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(files['backend.env'], 'OLD_ENV=keep\n')
                self.assertIn('IMAGE_TAG=old-image', files['.env'])
                kinds = [e['kind'] for e in events]
                self.assertNotIn('up', kinds)
                reached = ('full_schema' if 'schema_fail' in failure and 'schema_probe' not in failure
                           else 'fallback_schema' if failure.get('schema_probe') == 3
                           else 'schema_probe' if 'schema_probe' in failure
                           else 'pull' if 'pull_fail' in failure
                           else 'ssm' if 'missing' in failure else 'ecr_login')
                self.assertIn(reached, kinds, run.stderr)

    def test_old_image_uses_structural_fallback_and_removes_absent_consumer(self):
        run, events, _ = self.run_deploy({'schema_probe': 3, 'consumer_probe': 3})
        self.assertEqual(run.returncode, 0, run.stderr)
        kinds = [e['kind'] for e in events]
        self.assertIn('fallback_schema', kinds)
        self.assertNotIn('full_schema', kinds)
        self.assertIn('remove_consumer', kinds)
        self.assertNotIn('consumer_startup', kinds)
        self.assertTrue(any(e['kind'] == 'systemctl' and e['args'][:2] == ['disable', '--now'] for e in events))

    def test_failed_preflight_preserves_existing_fcm_credentials(self):
        for failure in [{'schema_fail': 1}, {'schema_probe': 125},
                        {'schema_probe': 3, 'schema_fail': 1}, {'pull_fail': 1}]:
            for fcm in [{}, {'empty': 'fcm-service-account'}, {'missing': 'fcm-service-account'}]:
                with self.subTest(failure=failure, fcm=fcm):
                    run, events, files = self.run_deploy(dict(failure, **fcm))
                    self.assertNotEqual(run.returncode, 0)
                    self.assertNotIn('up', [e['kind'] for e in events])
                    self.assertEqual(json.loads(files['fcm']), {'project_id': 'old-project'})
                    self.assertTrue(files['fcm_preserved_inode'])

    def test_invalid_marker_and_missing_prod_configuration_fail(self):
        for case in [{'marker': ''}, {'marker': 'deev'}, {'empty': 'fortune-ad-unit-ids'},
                     {'empty': 'slack-feedback-webhook-url'}]:
            with self.subTest(case=case):
                run, events, files = self.run_deploy(case)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(files['backend.env'], 'OLD_ENV=keep\n')
                self.assertNotIn('up', [e['kind'] for e in events])
                self.assertIn('prod|dev' if 'marker' in case else 'SSM 파라미터 누락', run.stderr)

    def test_consumer_readiness_image_and_proxy_failures_are_not_success(self):
        for case in [{'consumer_probe': 125}, {'startup_fail': 1}, {'ready_fail': 1},
                     {'running_tag': 'wrong'}, {'consumer_state': 'exited'}, {'nginx_fail': 1}]:
            with self.subTest(case=case):
                run, events, _ = self.run_deploy(case)
                kinds = [e['kind'] for e in events]
                reached = ('consumer_probe' if 'consumer_probe' in case
                           else 'consumer_startup' if 'startup_fail' in case
                           else 'ready' if 'ready_fail' in case
                           else 'nginx' if 'nginx_fail' in case else 'inspect')
                self.assertIn(reached, kinds, run.stderr)
                self.assertNotEqual(run.returncode, 0)
                self.assertNotIn('배포 완료', run.stdout)

    def test_worker_host_installs_failure_notice_unit(self):
        # 실패 알림 유닛은 워커 호스트에만 워커 유닛과 함께 설치돼야 한다.
        for worker in [True, False]:
            with self.subTest(worker=worker):
                run, _, files = self.run_deploy({'worker': worker})
                self.assertEqual(run.returncode, 0, run.stderr)
                expected = ['moly-worker-failed.service', 'moly-worker.service', 'moly-worker.timer']
                self.assertEqual(files['units'], expected if worker else [])
        self.assertIn('OnFailure=moly-worker-failed.service',
                      (ROOT / 'systemd/moly-worker.service').read_text().splitlines())
        notice = (ROOT / 'systemd/moly-worker-failed.service').read_text()
        self.assertIn('ExecStart=/usr/bin/bash /root/moly-infra/scripts/notify-worker-failure.sh',
                      notice.splitlines())
        self.assertTrue((ROOT / 'scripts/notify-worker-failure.sh').is_file())

    def test_same_config_does_not_force_recreate_again(self):
        run, events, _ = self.run_deploy(twice=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        forced = [e for e in events if '--force-recreate' in e['args']]
        self.assertEqual(len(forced), 1)

    @unittest.skipUnless(os.environ.get('MOLY_DEPLOY_BASELINE'), 'optional pre-refactor comparison')
    def test_configuration_matches_original_script(self):
        for environment in ['dev', 'prod']:
            with self.subTest(environment=environment):
                case = {'environment': environment}
                before, _, old_files = self.run_deploy(case, source=Path(os.environ['MOLY_DEPLOY_BASELINE']))
                after, _, new_files = self.run_deploy(case)
                self.assertEqual(before.returncode, 0, before.stderr)
                self.assertEqual(after.returncode, 0, after.stderr)
                self.assertEqual(old_files, new_files)


if __name__ == '__main__':
    unittest.main()

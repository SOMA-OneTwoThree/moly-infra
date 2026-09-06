"""Execute deploy.sh with local fake services; no Docker daemon, AWS or live DB calls.

Run on Linux/Bash >=4: python3 -m unittest discover -s tests -v
Only absolute host paths are redirected into a TemporaryDirectory. Service commands
are stubs, while the actual shell branching, env writing and file promotion execute.
"""
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
    sys.exit(case.get(key,0))
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
    if args[0]=='is-active': print('active')
elif name=='curl':
    event('ready' if ':8000/' in args[-1] else 'nginx')
    fail('ready_fail' if ':8000/' in args[-1] else 'nginx_fail')
elif name=='docker':
    if args[0]=='login': sys.stdin.read();fail('login_fail')
    elif args[0]=='compose':
        if 'pull' in args: event('pull');fail('pull_fail')
        elif 'up' in args: event('up')
        elif 'version' not in args and 'ps' not in args: raise AssertionError(args)
    elif args[0]=='run':
        if '-c' in args:
            expr=args[args.index('-c')+1]
            if 'db.schema_contract' in expr: event('schema_probe');fail('schema_probe')
            elif 'worker.consumer' in expr: event('consumer_probe');fail('consumer_probe')
            else: raise AssertionError(args)
        elif args[-1]=='db.schema_contract':
            event('full_schema')
            assert args[args.index('--env-file')+1].endswith('backend.env.next')
            fail('schema_fail')
        elif args[-1]=='-':
            event('fallback_schema');sys.stdin.read()
            assert args[args.index('--env-file')+1].endswith('backend.env.next')
            fail('schema_fail')
        elif args[-1]=='worker.consumer': event('consumer_startup');fail('startup_fail')
        else: raise AssertionError(args)
    elif args[0]=='inspect':
        event('inspect')
        if '.State.Status' in args[2]: print(case.get('consumer_state','running'))
        else:
            env=dict(line.split('=',1) for line in (root/'.env').read_text().splitlines())
            print('registry/'+env['IMAGE_REPO']+':'+case.get('running_tag',env['IMAGE_TAG']))
    elif args[0]=='rm': event('remove_consumer')
    elif args[0]=='images': pass
    elif args[0] in {'image','ps','logs','rmi'}: event(args[0])
    else: raise AssertionError(args)
else: raise AssertionError(name)
'''


class DeployTests(unittest.TestCase):
    def run_deploy(self, case=None, *, source=None, twice=False):
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
            args = ['bash', str(root / 'deploy.sh'), 'candidate-image']
            runs = []
            for _ in range(2 if twice else 1):
                runs.append(subprocess.run(args, env=env, text=True, capture_output=True, timeout=30))
            trace = root / 'calls.jsonl'
            events = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            files = {name: (root / name).read_text() for name in ['.env', 'backend.env']}
            fcm = root / 'secrets/fcm-service-account.json'
            files['fcm'] = fcm.read_text() if fcm.exists() else None
            files['fcm_preserved_inode'] = fcm.exists() and fcm.stat().st_ino == original_fcm_inode
            return runs[-1], events, files

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

"""Run scripts/notify-worker-failure.sh with stubbed systemctl/curl; no network or systemd.

Run: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CURL = r'''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
config=sys.stdin.read() if args[args.index('-K')+1]=='-' else ''
with open(os.environ['NOTICE_TEST_LOG'],'a') as f:
    f.write(json.dumps({'args':args,'config':config})+'\n')
sys.exit(int(os.environ.get('NOTICE_CURL_EXIT','0')))
'''
SYSTEMCTL = r'''#!/usr/bin/env python3
import sys
args=sys.argv[1:]
assert args[:2]==['show','moly-worker.service'],args
print({'Result':'exit-code','ExecMainStatus':'1'}[args[args.index('-p')+1]])
'''
STATUS = 'https://hooks.example.test/services/STATUS/channel'
SHARED = 'https://hooks.example.test/services/SHARED/channel'
ALERT = 'https://hooks.example.test/services/ALERT/channel'


class FailureNoticeTests(unittest.TestCase):
    def run_notice(self, env_lines, *, monitor=None, curl_exit=0):
        with tempfile.TemporaryDirectory(prefix='moly-notice-test-') as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copy(ROOT / 'scripts/notify-worker-failure.sh', root / 'scripts')
            (root / 'backend.env').write_text(''.join(line + '\n' for line in env_lines))
            (root / 'bin').mkdir()
            for name, body in [('curl', CURL), ('systemctl', SYSTEMCTL)]:
                (root / 'bin' / name).write_text(body)
                (root / 'bin' / name).chmod(0o755)
            log = root / 'curl.jsonl'
            env = {k: v for k, v in os.environ.items() if not k.startswith('MONITOR_')}
            env.update(PATH=str(root / 'bin') + ':' + os.environ['PATH'],
                       NOTICE_TEST_LOG=str(log), NOTICE_CURL_EXIT=str(curl_exit), **(monitor or {}))
            run = subprocess.run(['bash', str(root / 'scripts/notify-worker-failure.sh')],
                                 env=env, text=True, capture_output=True, timeout=30)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return run, calls

    def assert_sent_to(self, calls, url):
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['config'], f'url = "{url}"\n')
        self.assertFalse(any('hooks.example.test' in arg for arg in calls[0]['args']))  # argv에 웹훅 없음
        return json.loads(calls[0]['args'][calls[0]['args'].index('--data-binary') + 1])['text']

    def test_status_channel_is_preferred_and_webhook_is_not_exposed(self):
        run, calls = self.run_notice(
            [f'SLACK_ALERT_WEBHOOK_URL={ALERT}', f'SLACK_WEBHOOK_URL={SHARED}', f'SLACK_STATUS_WEBHOOK_URL={STATUS}'],
            monitor={'MONITOR_SERVICE_RESULT': 'timeout', 'MONITOR_EXIT_STATUS': '130'})
        self.assertEqual(run.returncode, 0, run.stderr)
        text = self.assert_sent_to(calls, STATUS)
        self.assertIn('result=timeout status=130', text)
        self.assertIn('KST', text)
        self.assertNotIn('hooks.example.test', run.stdout + run.stderr)

    def test_falls_back_to_shared_webhook_and_reads_unit_state(self):
        # 운영처럼 상태 채널 전용 웹훅이 없으면 공용 웹훅(backend status 라우팅과 같다). MONITOR_* 없으면 systemctl.
        run, calls = self.run_notice([f'SLACK_ALERT_WEBHOOK_URL={ALERT}', f'SLACK_WEBHOOK_URL={SHARED}',
                                      'SLACK_STATUS_WEBHOOK_URL='])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('result=exit-code status=1', self.assert_sent_to(calls, SHARED))

    def test_alert_webhook_is_never_used(self):
        run, calls = self.run_notice([f'SLACK_ALERT_WEBHOOK_URL={ALERT}', 'SLACK_WEBHOOK_URL='])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls, [])
        self.assertIn('미설정', run.stderr)

    def test_send_failure_and_odd_values_never_fail_the_handler(self):
        run, calls = self.run_notice([f'SLACK_WEBHOOK_URL={SHARED}'], curl_exit=22,
                                     monitor={'MONITOR_SERVICE_RESULT': 'time"out\\', 'MONITOR_EXIT_STATUS': ''})
        self.assertEqual(run.returncode, 0)
        self.assertIn('전송 실패', run.stderr)
        self.assertIn('result=timeout status=1', self.assert_sent_to(calls, SHARED))  # JSON 깨지는 문자 제거

    def test_unexpected_webhook_format_is_skipped(self):
        for url in ['http://hooks.example.test/x', 'https://hooks.example.test/x" -o /tmp/y', 'hooks.example.test']:
            with self.subTest(url=url):
                run, calls = self.run_notice([f'SLACK_WEBHOOK_URL={url}'])
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(calls, [])
                self.assertNotIn('hooks.example.test', run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()

"""Check that container logs go to host journald and survive container recreation.

Run: python3 -m unittest discover -s tests -v
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def service_blocks(text):
    """Split the top-level `services:` mapping into {name: block text} without a YAML parser."""
    blocks, name = {}, None
    for line in text.splitlines():
        match = re.match(r'^  ([a-z][a-z0-9_-]*):\s*$', line)
        if match:
            name = match.group(1)
            blocks[name] = []
        elif name is not None:
            blocks[name].append(line)
    return {key: '\n'.join(lines) for key, lines in blocks.items()}


class ComposeLoggingTests(unittest.TestCase):
    def test_every_service_logs_to_journald_with_a_fixed_tag(self):
        compose = (ROOT / 'docker-compose.yml').read_text()
        services = service_blocks(compose)
        self.assertEqual(sorted(services), ['backend', 'consumer', 'worker'])
        for service, tag in [('backend', 'moly-backend'), ('consumer', 'moly-consumer'),
                             ('worker', 'moly-worker')]:
            with self.subTest(service=service):
                block = services[service]
                self.assertIn('      driver: journald', block.splitlines())
                self.assertIn(f'        tag: {tag}', block.splitlines())
        # json-file 로그는 컨테이너와 함께 지워진다 — 다시 섞이면 재생성 전 로그를 잃는다.
        self.assertNotIn('driver: json-file', compose)

    def test_operator_hints_name_the_same_tag(self):
        # 실패 알림·유닛 주석이 가리키는 조회 명령이 compose 태그와 어긋나지 않게 한다.
        hint = 'journalctl -t moly-worker'
        self.assertIn(hint, (ROOT / 'scripts/notify-worker-failure.sh').read_text())
        self.assertIn(hint, (ROOT / 'systemd/moly-worker.service').read_text())


if __name__ == '__main__':
    unittest.main()

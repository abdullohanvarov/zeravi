"""Hosting lifecycle tests use temporary directories and fake OS commands."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
from hosting_test_support import FakeServer, hosting, manager


class HostingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zeravi hosting ')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.runner = FakeServer()
        self.manager = manager(self.home, self.runner)

    def upload(self, extra=None):
        path = self.home / '.zeravi-upload-test.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in {'project/requirements.txt': '', 'project/main.py': 'print("Hello")', 'project/data/seed.txt': 'seed', **(extra or {})}.items():
                archive.writestr(name, value)
        return path

    def deploy(self, bot=None, **options):
        request = dict(action='deploy', zipPath=str(self.upload()), projectRoot='project', name='Test bot', environment={'BOT_TOKEN': 'secret-12345'}, **options)
        if bot:
            request['id'] = bot['id']
        return self.manager.handle(request)

    def test_lifecycle_update_rollback_and_archive_preserve_data(self):
        first = self.deploy()
        self.assertEqual(first['state'], 'active')
        self.assertNotIn('secret-12345', json.dumps(first))
        root = self.manager.bot_root(first['id'])
        self.assertEqual(stat.S_IMODE((root / 'environment').stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((root / 'config.json').stat().st_mode), 0o600)
        (root / 'current/app/data/seed.txt').write_text('runtime data')
        second = self.deploy(first)
        self.assertNotEqual(first['current'], second['current'])
        self.assertEqual(second['previous'], first['current'])
        self.assertEqual((root / 'current/app/data/seed.txt').read_text(), 'runtime data')
        restored = self.manager.handle(dict(action='rollback', id=first['id']))
        self.assertEqual(restored['current'], first['current'])
        self.assertEqual((root / 'current/app/data/seed.txt').read_text(), 'runtime data')
        for verb, expected in [('stop', 'inactive'), ('start', 'active'), ('restart', 'active')]:
            self.assertEqual(self.manager.handle(dict(action='control', id=first['id'], verb=verb))['state'], expected)
        result = self.manager.handle(dict(action='remove', id=first['id']))
        self.assertTrue((Path(result['archive']) / 'shared/data/seed.txt').is_file())
        self.assertFalse(root.exists())
        self.assertEqual(self.manager.listing()['bots'], [])

    def test_failed_dependencies_do_not_stop_running_release(self):
        bot = self.deploy()
        self.runner.calls.clear()
        self.runner.fail_pip = True
        with self.assertRaisesRegex(hosting.HostingError, 'Dependency failure'):
            self.deploy(bot)
        self.assertFalse(any(args[:3] == ['systemctl', '--user', 'stop'] for args, _ in self.runner.calls))
        self.assertEqual(self.manager.status(bot['id'])['current'], bot['current'])
        self.assertEqual(self.manager.status(bot['id'])['state'], 'active')
        self.assertEqual(len(list((self.manager.bot_root(bot['id']) / 'releases').iterdir())), 1)

    def test_update_start_failure_restores_previous_service(self):
        bot = self.deploy()
        self.runner.fail_start = 1
        with self.assertRaisesRegex(hosting.HostingError, 'Restoring'):
            self.deploy(bot, entrypoint='main.py')
        restored = self.manager.status(bot['id'])
        self.assertEqual(restored['current'], bot['current'])
        self.assertEqual(restored['state'], 'active')

    def test_config_failure_restores_environment_and_running_state(self):
        bot = self.deploy()
        self.runner.fail_start = 1
        with self.assertRaises(hosting.HostingError):
            self.manager.handle(dict(action='configure', id=bot['id'], environment={'BOT_TOKEN': 'replacement'}))
        root = self.manager.bot_root(bot['id'])
        self.assertEqual(self.manager.load(root / 'config.json')['environment']['BOT_TOKEN'], 'secret-12345')
        self.assertEqual(self.manager.status(bot['id'])['state'], 'active')

    def test_config_keeps_keys_removes_requested_keys_and_masks_logs(self):
        bot = self.deploy()
        updated = self.manager.handle(dict(action='configure', id=bot['id'], environment={'SECOND': 'second-secret'}, removeEnv=['BOT_TOKEN'], start=False))
        self.assertEqual(updated['envKeys'], ['SECOND'])
        self.assertEqual(updated['state'], 'inactive')
        self.runner.journal = 'token second-secret https://name:password@example.com/repo'
        logs = self.manager.handle(dict(action='logs', id=bot['id']))['text']
        self.assertNotIn('second-secret', logs)
        self.assertNotIn('password', logs)

    def test_zip_traversal_and_links_cannot_write_outside_project(self):
        path = self.upload({'../outside.txt': 'bad'})
        with self.assertRaises(hosting.HostingError):
            hosting.inspect_zip(path)
        path = self.upload()
        with zipfile.ZipFile(path, 'a') as archive:
            link = zipfile.ZipInfo('project/link')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, '/etc/passwd')
        with self.assertRaises(hosting.HostingError):
            hosting.inspect_zip(path)
        self.assertFalse((self.home / 'outside.txt').exists())

    def test_missing_requirements_and_entrypoint_are_rejected(self):
        path = self.home / 'empty.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('main.py', '')
        with self.assertRaises(hosting.HostingError):
            hosting.inspect_zip(path)
        with self.assertRaises(hosting.HostingError):
            hosting.extract_project(self.upload(), self.home / 'output', 'project', 'missing.py')

    def test_duplicate_and_file_folder_conflicts_are_rejected(self):
        path = self.upload({'project/collision': '', 'project/collision/child.py': ''})
        with self.assertRaises(hosting.HostingError):
            hosting.inspect_zip(path)

    def test_foreign_or_symlinked_unit_is_never_stopped(self):
        bot = self.deploy()
        unit = self.manager.units / ('zeravi-bot-' + bot['id'] + '.service')
        unit.write_text('[Service]\nExecStart=/bin/true\n')
        self.runner.calls.clear()
        with self.assertRaises(hosting.HostingError):
            self.manager.handle(dict(action='remove', id=bot['id']))
        self.assertFalse(self.runner.calls)
        unit.unlink()
        unit.symlink_to(self.home / 'unrelated')
        with self.assertRaises(hosting.HostingError):
            self.manager.handle(dict(action='control', id=bot['id'], verb='stop'))
        self.assertFalse(self.runner.calls)

    def test_persistent_paths_cannot_overwrite_code_or_traverse(self):
        for path in ['../outside', 'main.py', 'requirements.txt', 'data/nested']:
            with self.subTest(path=path), self.assertRaises(hosting.HostingError):
                self.manager.config(dict(persistent=[path]))

    def test_new_failed_install_cleans_up_and_never_creates_service(self):
        self.runner.fail_pip = True
        with self.assertRaises(hosting.HostingError):
            self.deploy()
        self.assertEqual(self.manager.listing()['bots'], [])
        self.assertFalse(list(self.manager.base.glob('bot-*')))
        self.assertFalse(list(self.manager.units.glob('*.service')))

    def test_dependency_install_runs_inside_project_without_shell(self):
        bot = self.deploy()
        pip = next((args, opts) for args, opts in self.runner.calls if 'pip' in args)
        self.assertTrue(pip[1]['cwd'].endswith('/app'))
        self.assertEqual(pip[0][1:4], ['-m', 'pip', 'install'])
        root = self.manager.bot_root(bot['id'])
        text = (self.manager.units / ('zeravi-bot-' + bot['id'] + '.service')).read_text()
        self.assertNotIn('secret-12345', text)
        self.assertIn('Restart=on-failure', text)
        self.assertIn('NoNewPrivileges=true', text)
        self.assertIn(str(root / 'current/venv/bin/python'), text)

    def test_streaming_runner_redacts_secrets_and_reports_failure(self):
        events = []
        instance = hosting.HostingManager(home=self.home, event=lambda kind, **data: events.append(data['message']))
        instance.secrets = ['private-token']
        instance.command([sys.executable, '-c', 'print("private-token")'], stream=True)
        self.assertEqual(events, ['[redacted]'])
        with self.assertRaises(hosting.HostingError):
            instance.command([sys.executable, '-c', 'raise SystemExit(2)'], stream=True)

    def test_unit_arguments_escape_specifiers_and_environment_expansion(self):
        self.assertEqual(hosting.unit_quote('100% $TOKEN', exec_arg=True), '"100%% $$TOKEN"')
        with self.assertRaises(hosting.HostingError):
            hosting.unit_quote('bad\nExecStart=/bin/false')


if __name__ == '__main__':
    unittest.main()

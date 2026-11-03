"""Disposable hosting test double: never invokes pip, systemd, or loginctl."""
import importlib.util
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('zeravi_hosting', Path(__file__).resolve().parents[1] / 'assets/hosting/manager.py')
hosting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosting)


class FakeServer:
    def __init__(self):
        self.states = {}
        self.calls = []
        self.fail_pip = False
        self.fail_start = 0
        self.journal = 'Bot started\n'

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        code, out = 0, ''
        if args[1:3] == ['-m', 'venv']:
            python = Path(args[3]) / 'bin/python'
            python.parent.mkdir(parents=True)
            python.write_text('#!/bin/sh\nexit 0\n')
            python.chmod(0o700)
        elif 'pip' in args:
            code = 1 if self.fail_pip else 0
            out = 'Dependency failure' if code else 'Dependencies installed'
        elif args[0] == 'systemctl':
            verb = args[2]
            unit = args[3] if len(args) > 3 else ''
            if verb == 'show':
                out = f'ActiveState={self.states.get(unit, "inactive")}\nSubState=running\nMainPID=123\nNRestarts=0\nMemoryCurrent=1048576\nExecMainStatus=0\nResult=success\n'
            elif verb in ('start', 'restart'):
                if self.fail_start:
                    self.fail_start -= 1
                    code = 1
                else:
                    self.states[unit] = 'active'
            elif verb == 'stop':
                self.states[unit] = 'inactive'
        elif args[0] == 'loginctl':
            out = 'yes\n'
        elif args[0] == 'journalctl':
            out = self.journal
        return subprocess.CompletedProcess(args, code, out, '')


def manager(home, runner, event=None):
    instance = hosting.HostingManager(home=home, runner=runner, event=event)
    instance.doctor = lambda: dict(python='3.12', venv=True, userManager=True, linger=True, username='tester', ready=True, root=str(instance.base))
    return instance

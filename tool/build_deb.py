#!/usr/bin/env python3
"""Build a local Debian installer for the tested host and Flutter release bundle.

The dependency floor uses the installed runtime versions on the build host. This
is intentionally conservative: build on each target Ubuntu release rather than
claiming that a bundle compiled on a newer distribution runs on older releases.
"""
import argparse
import hashlib
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True).stdout.strip()


def runtime_dependencies(bundle):
    """Map direct ELF dependencies to their installed Debian runtime packages."""
    required = set()
    resolved = {}
    binaries = [bundle / 'zeravi', *sorted((bundle / 'lib').glob('*.so'))]
    for binary in binaries:
        needed = re.findall(r'\(NEEDED\).*\[(.*?)\]', output('readelf', '-d', str(binary)))
        required.update(needed)
        linked = run('ldd', str(binary), capture_output=True, env={**os.environ, 'LD_LIBRARY_PATH': str(bundle / 'lib')}).stdout
        if 'not found' in linked:
            raise RuntimeError(f'Unresolved runtime library in {binary.name}:\n{linked}')
        for name, path in re.findall(r'^\s*(\S+) => (/[^(]+?)\s+\(', linked, re.MULTILINE):
            resolved[name] = Path(path)
    packages = {'openssh-client', 'xdg-utils'}
    for name in required:
        path = resolved.get(name)
        if path is None:
            # The dynamic loader may be reported without an => in ldd output.
            if name.startswith('ld-linux'):
                packages.add('libc6')
                continue
            raise RuntimeError(f'Cannot resolve required library {name}')
        if path.resolve().is_relative_to(bundle.resolve()):
            continue
        candidates = [str(path), str(path.resolve())]
        owner = None
        for candidate in candidates:
            found = subprocess.run(['dpkg-query', '-S', candidate], text=True, capture_output=True)
            if found.returncode == 0:
                owner = found.stdout.splitlines()[0].split(': ', 1)[0].split(':')[0]
                break
        if not owner:
            raise RuntimeError(f'No Debian package owns runtime library {path}')
        packages.add(owner)
    depends = []
    for package in sorted(packages):
        status = output('dpkg-query', '-W', '-f=${db:Status-Status}', package)
        if status != 'installed':
            raise RuntimeError(f'Required runtime package is not installed: {package}')
        version = output('dpkg-query', '-W', '-f=${Version}', package)
        depends.append(f'{package} (>= {version})')
    return ', '.join(depends)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Package an already verified release bundle')
    parser.add_argument('--output', type=Path, default=ROOT / 'build' / 'packages')
    parser.add_argument('--maintainer', help='Debian maintainer identity; defaults to the local Git identity')
    args = parser.parse_args()
    for command in ['dpkg-deb', 'dpkg-query', 'readelf', 'ldd', 'cmake']:
        if shutil.which(command) is None:
            raise SystemExit(f'Missing packaging tool: {command}')
    if not args.skip_build:
        run('flutter', 'build', 'linux', '--release', cwd=ROOT)
    architecture = output('dpkg', '--print-architecture')
    target = {'amd64': 'x64', 'arm64': 'arm64'}.get(architecture)
    if target is None:
        raise SystemExit(f'Unsupported build architecture: {architecture}')
    bundle = ROOT / 'build' / 'linux' / target / 'release' / 'bundle'
    if not (bundle / 'zeravi').is_file():
        raise SystemExit('No release bundle found. Run flutter build linux --release first.')
    elf_header = output('readelf', '-h', str(bundle / 'zeravi'))
    if (architecture == 'amd64' and 'X86-64' not in elf_header) or (architecture == 'arm64' and 'AArch64' not in elf_header):
        raise SystemExit('The bundle architecture does not match the packaging host.')
    raw_version = re.search(r'^version:\s*(\S+)', (ROOT / 'pubspec.yaml').read_text(), re.MULTILINE).group(1)
    upstream, _, revision = raw_version.partition('+')
    version = f'{upstream}-{revision or "1"}'
    run('dpkg', '--validate-version', version)
    maintainer = args.maintainer or f"{output('git', 'config', 'user.name')} <{output('git', 'config', 'user.email')}>"
    if '\n' in maintainer or not re.fullmatch(r'[^<>\r\n]+ <[^<>\s]+@[^<>\s]+>', maintainer):
        raise SystemExit('Provide a valid --maintainer "Name <email>" identity.')
    dependencies = runtime_dependencies(bundle)
    args.output.mkdir(parents=True, exist_ok=True)
    deb = args.output.resolve() / f'zeravi_{version}_{architecture}.deb'
    with tempfile.TemporaryDirectory(prefix='zeravi-deb-') as temp:
        stage = Path(temp) / 'package'
        app = stage / 'opt' / 'zeravi'
        shutil.copytree(bundle, app)
        # Some Flutter plugins retain a CMake build RUNPATH. Replace only
        # development paths with the installed sibling-library location.
        for library in sorted((app / 'lib').glob('*.so')):
            dynamic = output('readelf', '-d', str(library))
            paths = re.findall(r'\((?:RPATH|RUNPATH)\).*\[(.*?)\]', dynamic)
            for old in paths:
                parts = old.split(':')
                if not any(part.startswith(('/home/', '/tmp/')) or str(ROOT) in part for part in parts):
                    continue
                kept = [part for part in parts if part and not part.startswith(('/home/', '/tmp/')) and str(ROOT) not in part]
                new_path = ':'.join(dict.fromkeys(['$ORIGIN', *kept]))
                cmake_script = Path(temp) / 'fix-rpath.cmake'
                def quoted(value):
                    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
                cmake_script.write_text('file(RPATH_CHANGE FILE ' + quoted(library) +
                    ' OLD_RPATH ' + quoted(old) + ' NEW_RPATH ' + quoted(new_path) + ')\n')
                run('cmake', '-P', str(cmake_script))
        for binary in [app / 'zeravi', *sorted((app / 'lib').glob('*.so'))]:
            linked = output('ldd', str(binary))
            if 'not found' in linked or str(ROOT) in linked:
                raise RuntimeError(f'Bundle is not relocatable: {binary.name}\n{linked}')

        # Flutter loads NativeAssetsManifest.json from flutter_assets. The
        # supplemental lib manifest can be left over from local test builds;
        # keep both consistent so no development-machine paths are shipped.
        native_manifest = app / 'data' / 'flutter_assets' / 'NativeAssetsManifest.json'
        if native_manifest.exists():
            if str(ROOT) in native_manifest.read_text():
                raise RuntimeError('The runtime native-asset manifest still references the build machine.')
            shutil.copy2(native_manifest, app / 'lib' / 'native_assets.json')
        binaries = stage / 'usr' / 'bin'
        binaries.mkdir(parents=True)
        launcher = binaries / 'zeravi'
        launcher.write_text('#!/bin/sh\nexec /opt/zeravi/zeravi "$@"\n')
        launcher.chmod(0o755)
        applications = stage / 'usr' / 'share' / 'applications'
        applications.mkdir(parents=True)
        desktop = applications / 'com.example.zeravi.desktop'
        shutil.copy2(ROOT / 'packaging/linux/com.example.zeravi.desktop', desktop)
        icons = stage / 'usr' / 'share' / 'icons' / 'hicolor' / 'scalable' / 'apps'
        icons.mkdir(parents=True)
        shutil.copy2(ROOT / 'packaging/linux/zeravi.svg', icons / 'zeravi.svg')
        docs = stage / 'usr' / 'share' / 'doc' / 'zeravi'
        docs.mkdir(parents=True)
        shutil.copy2(ROOT / 'README.md', docs / 'README.md')
        shutil.copytree(ROOT / 'docs', docs / 'docs')
        # Normalize payload modes before creating the package and checksums.
        for path in stage.rglob('*'):
            if path.is_symlink():
                continue
            path.chmod(0o755 if path.is_dir() or path == launcher or path == app / 'zeravi' else 0o644)
        metadata = stage / 'DEBIAN'
        metadata.mkdir()
        installed_kib = math.ceil(sum(p.stat().st_size for p in stage.rglob('*') if p.is_file()) / 1024)
        (metadata / 'control').write_text(
            f'Package: zeravi\nVersion: {version}\nArchitecture: {architecture}\n'
            f'Maintainer: {maintainer}\nSection: net\nPriority: optional\n'
            f'Installed-Size: {installed_kib}\nDepends: {dependencies}\n'
            'Homepage: https://github.com/abdullohanvarov/zeravi\n'
            'Description: Local desktop workspace for remote Linux servers\n'
            ' SSH terminals, SFTP file management, native file-manager transfers,\n'
            ' remote editing, Python bot hosting, and Linux server monitoring.\n')
        refresh = '''#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
'''
        for name in ['postinst', 'postrm']:
            script = metadata / name
            script.write_text(refresh)
            script.chmod(0o755)
        sums = []
        for path in sorted(stage.rglob('*')):
            if path.is_file() and not path.is_symlink() and not path.is_relative_to(metadata):
                sums.append(f'{hashlib.md5(path.read_bytes()).hexdigest()}  {path.relative_to(stage)}')
        (metadata / 'md5sums').write_text('\n'.join(sums) + '\n')
        if shutil.which('desktop-file-validate'):
            run('desktop-file-validate', str(desktop))
        run('dpkg-deb', '--root-owner-group', '--build', str(stage), str(deb))
    digest = hashlib.sha256(deb.read_bytes()).hexdigest()
    deb.with_suffix('.deb.sha256').write_text(f'{digest}  {deb.name}\n')
    print(f'Installer: {deb}\nSHA256: {digest}')


if __name__ == '__main__':
    main()

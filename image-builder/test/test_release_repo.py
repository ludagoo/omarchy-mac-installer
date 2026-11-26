#!/usr/bin/env python3
"""SmartRoom releases (fork only, see CARRY.md): builder/release_repo.py."""
import base64
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'builder/release_repo.py'


def run(*args, check=True):
    result = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f'release_repo {args} failed: {result.stderr}')
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def database(path, entries):
    """A pacman sync database of ENTRIES: (name, version, filename, sha256[, pgpsig])."""
    with tarfile.open(path, 'w:gz') as tar:
        for name, version, filename, digest, *pgpsig in entries:
            text = f'%FILENAME%\n{filename}\n\n%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%SHA256SUM%\n{digest}\n\n'
            if pgpsig:
                text += f'%PGPSIG%\n{pgpsig[0]}\n\n'
            data = text.encode()
            info = tarfile.TarInfo(f'{name}-{version}/desc')
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))


TEMPLATE = '''# Omarchy aarch64-apple stable
[options]
HoldPkg = pacman glibc
Architecture = aarch64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch

[core]
Include = /etc/pacman.d/mirrorlist
'''


class ReleaseRepo(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.dir = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def test_config_names_only_the_release_and_requires_signatures(self):
        (self.dir / 'pacman-stable.conf').write_text(TEMPLATE)
        text = run('config', self.dir / 'pacman-stable.conf').stdout
        sections = [line[1:-1] for line in text.splitlines() if line.startswith('[')]
        self.assertEqual(sections, ['options', 'smartroom-release'])
        self.assertIn('Include = /etc/pacman.d/smartroom-release', text)
        self.assertIn('SigLevel = Required DatabaseRequired', text)
        self.assertIn('LocalFileSigLevel = Required', text)
        for line in ('HoldPkg = pacman glibc', 'Architecture = aarch64', 'ParallelDownloads = 5'):
            self.assertIn(line, text)
        for gone in ('Optional', 'TrustAll', 'Never', 'Server', 'mirrorlist', 'omarchy]', '[core]'):
            self.assertNotIn(gone, text)

    def test_dev_config_requires_local_file_signatures(self):
        conf = self.dir / 'pacman.conf'
        conf.write_text(TEMPLATE.replace('[omarchy]\nSigLevel = Optional TrustAll\n', '[omarchy]\n'))
        text = run('require-signatures', conf).stdout
        self.assertIn('SigLevel = Required DatabaseOptional\nLocalFileSigLevel = Required\n', text)
        self.assertNotIn('LocalFileSigLevel = Optional', text)
        self.assertEqual(text.replace('LocalFileSigLevel = Required', 'LocalFileSigLevel = Optional'), conf.read_text())
        conf.write_text('[options]\nArchitecture = aarch64\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n')
        self.assertEqual(run('require-signatures', conf).stdout,
                         '[options]\nArchitecture = aarch64\n\nLocalFileSigLevel = Required\n[core]\nInclude = /etc/pacman.d/mirrorlist\n')

    def test_dev_config_refuses_untrusted_levels(self):
        conf = self.dir / 'pacman.conf'
        for section, level in (('omarchy', 'Optional TrustAll'), ('core', 'Never'), ('options', 'Optional'),
                               ('options', 'Required PackageOptional'), ('extra', 'PackageTrustAll')):
            text = TEMPLATE.replace('[omarchy]\nSigLevel = Optional TrustAll\n', '[omarchy]\n')
            text = text.replace(f'[{section}]\n', f'[{section}]\nSigLevel = {level}\n', 1) if section != 'options' else \
                text.replace('SigLevel = Required DatabaseOptional', f'SigLevel = {level}')
            if section == 'extra':
                text += '\n[extra]\nSigLevel = PackageTrustAll\nInclude = /etc/pacman.d/mirrorlist\n'
            conf.write_text(text)
            result = run('require-signatures', conf, check=False)
            self.assertNotEqual(result.returncode, 0, (section, level))
            self.assertIn('without a trusted signature', result.stderr)

    def test_mirror_is_the_firmware_format(self):
        # ludagoo/smartroomcontrollerfirmware release-lib.sh smartroom_release_mirror
        # writes, and smartroom-release-repo reads, exactly these lines.
        self.assertEqual(run('mirror', '2026.11.20-studio-edge',
                             'https://rooms.example/releases/2026.11.20-studio-edge').stdout,
                         '# SmartRoom release 2026.11.20-studio-edge. This room takes packages only from this signed\n'
                         '# repository; it moves to another release only through\n'
                         '# smartroom-release-repo switch <version>.\n'
                         '# release=2026.11.20-studio-edge\n'
                         'Server = https://rooms.example/releases/2026.11.20-studio-edge\n')

    def test_release_file_is_checked(self):
        good = self.dir / 'good'
        good.write_text('version=v1\nurl=https://rooms.example/releases/v1\n')
        self.assertEqual(run('check-release', good).stdout, 'version=v1\nurl=https://rooms.example/releases/v1\n')
        for text in ('version=v1\nurl=https://x.test/releases/v2\n', 'version=../v1\nurl=https://x.test/../v1\n',
                     'version=v1\nurl=http://x.test/releases/v1\n', 'version=v1\n', 'url=https://x.test/v1\n',
                     'version=v1\nurl=https://x.test/releases//v1\n'):
            bad = self.dir / 'bad'
            bad.write_text(text)
            self.assertNotEqual(run('check-release', bad, check=False).returncode, 0, text)

    def fixture(self):
        repos, cache, out = self.dir / 'repos', self.dir / 'cache', self.dir / 'out'
        for d in (repos / 'core', repos / 'smartroom', cache):
            d.mkdir(parents=True)
        a, b, c = b'core archive', b'smartroom archive', b'cached with database signature'
        (cache / 'a-1-1-aarch64.pkg.tar.xz').write_bytes(a)
        (cache / 'a-1-1-aarch64.pkg.tar.xz.sig').write_bytes(b'a sig')
        (repos / 'smartroom/b-2-1-any.pkg.tar.zst').write_bytes(b)
        (repos / 'smartroom/b-2-1-any.pkg.tar.zst.sig').write_bytes(b'b sig')
        (cache / 'c-3-1-aarch64.pkg.tar.xz').write_bytes(c)
        database(repos / 'core/core.db', [('c', '3-1', 'c-3-1-aarch64.pkg.tar.xz', sha(c),
                                            base64.b64encode(b'c sig from the database').decode())])
        records = self.dir / 'packages'
        records.write_text(f'a|1-1|core|a-1-1-aarch64.pkg.tar.xz|{sha(a)}\n'
                           f'b|2-1|smartroom|b-2-1-any.pkg.tar.zst|{sha(b)}\n'
                           f'c|3-1|core|c-3-1-aarch64.pkg.tar.xz|{sha(c)}\n')
        return repos, cache, out, records

    def test_stage_copies_each_archive_with_its_publishers_signature(self):
        repos, cache, out, records = self.fixture()
        run('stage', '--records', records, '--repositories', repos, '--cache', cache, '--local', 'smartroom', '--output', out)
        self.assertEqual((out / 'PACKAGES').read_text(), records.read_text())
        self.assertEqual((out / 'a-1-1-aarch64.pkg.tar.xz.sig').read_bytes(), b'a sig')
        self.assertEqual((out / 'b-2-1-any.pkg.tar.zst').read_bytes(), b'smartroom archive')
        self.assertEqual((out / 'b-2-1-any.pkg.tar.zst.sig').read_bytes(), b'b sig')
        self.assertEqual((out / 'c-3-1-aarch64.pkg.tar.xz.sig').read_bytes(), b'c sig from the database')

    def test_stage_refuses_other_bytes(self):
        repos, cache, out, records = self.fixture()
        (cache / 'a-1-1-aarch64.pkg.tar.xz').write_bytes(b'tampered')
        result = run('stage', '--records', records, '--repositories', repos, '--cache', cache, '--local', 'smartroom',
                     '--output', out, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('is not the recorded archive', result.stderr)

    def test_stage_refuses_an_unsigned_archive(self):
        repos, cache, out, records = self.fixture()
        (cache / 'a-1-1-aarch64.pkg.tar.xz.sig').unlink()
        result = run('stage', '--records', records, '--repositories', repos, '--cache', cache, '--local', 'smartroom',
                     '--output', out, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no signature from its publisher', result.stderr)

    def test_records_are_checked(self):
        for text in ('a|1-1|core|a.pkg|nothex\n', 'a|1-1|core|a.pkg\n', '', f'a|1|core|x/a.pkg|{"0" * 64}\n',
                     f'a|1|core|a.pkg|{"0" * 64}\na|2|core|b.pkg|{"0" * 64}\n'):
            records = self.dir / 'records'
            records.write_text(text)
            result = run('check-db', '--records', records, self.dir / 'none.db', check=False)
            self.assertNotEqual(result.returncode, 0, text)

    def test_check_db_is_exact(self):
        records = self.dir / 'records'
        records.write_text(f'a|1-1|core|a.pkg|{"1" * 64}\nb|2-1|extra|b.pkg|{"2" * 64}\n')
        database(self.dir / 'good.db', [('a', '1-1', 'a.pkg', '1' * 64), ('b', '2-1', 'b.pkg', '2' * 64)])
        run('check-db', '--records', records, self.dir / 'good.db')
        for name, entries in {
            'missing': [('a', '1-1', 'a.pkg', '1' * 64)],
            'extra': [('a', '1-1', 'a.pkg', '1' * 64), ('b', '2-1', 'b.pkg', '2' * 64), ('c', '1', 'c.pkg', '3' * 64)],
            'version': [('a', '1-2', 'a.pkg', '1' * 64), ('b', '2-1', 'b.pkg', '2' * 64)],
            'digest': [('a', '1-1', 'a.pkg', '9' * 64), ('b', '2-1', 'b.pkg', '2' * 64)],
        }.items():
            database(self.dir / f'{name}.db', entries)
            self.assertNotEqual(run('check-db', '--records', records, self.dir / f'{name}.db', check=False).returncode, 0, name)


if __name__ == '__main__':
    unittest.main()

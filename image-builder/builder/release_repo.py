#!/usr/bin/env python3
"""SmartRoom releases (fork only, see CARRY.md).

A release is one exact package set served as one signed pacman repository,
[smartroom-release], at <base>/<version>. The installed /etc/pacman.conf names
only that repository through /etc/pacman.d/smartroom-release, the mirror file
ludagoo/smartroomcontrollerfirmware's release-lib.sh and smartroom-release-repo
read and switch.

  check-release FILE     FILE (version=, url=) names a release
  config TEMPLATE        the installed pacman.conf: TEMPLATE's [options] with
                         every signature required, and [smartroom-release] only
  require-signatures CONF
                         a SmartRoom dev image's pacman.conf: CONF with local
                         files' signatures required; refuses any level that
                         accepts an unsigned or untrusted package
  mirror VERSION URL     /etc/pacman.d/smartroom-release
  stage --records FILE --repositories DIR --cache DIR --local NAMES --output DIR
                         copies every recorded archive (its sha256 checked) and
                         its publisher's signature (the archive's .sig, else the
                         PGPSIG its pinned database records) into DIR, and
                         writes DIR/PACKAGES, the records
  check-db --records FILE DB
                         the repository database lists exactly the records
"""
import argparse
import base64
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = 'smartroom-release'
VERSION = re.compile(r'^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$')
BASE = re.compile(r'^(https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\s]*)?|file:///[^\s]*)$')
SHA256 = re.compile(r'^[0-9a-f]{64}$')
SIGNATURE_OPTIONS = re.compile(r'^\s*(SigLevel|LocalFileSigLevel|RemoteFileSigLevel)\s*=')


def fail(message):
    print(f'release_repo: {message}', file=sys.stderr)
    raise SystemExit(1)


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_release(version, url):
    if not VERSION.match(version or ''):
        fail(f'bad release version: {version!r}')
    base = (url or '').removesuffix('/' + version)
    if base == url or base.endswith('/') or not BASE.match(base):
        fail(f'the release URL must be <https or file base>/{version}: {url!r}')


def read_release(path):
    fields = {}
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith('#'):
            key, _, value = line.partition('=')
            fields[key] = value
    check_release(fields.get('version'), fields.get('url'))
    return fields['version'], fields['url']


def config(template):
    options, section = [], None
    for line in Path(template).read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            section = stripped[1:-1]
            continue
        if section == 'options' and not SIGNATURE_OPTIONS.match(line):
            options.append(line)
    if section is None:
        fail(f'{template} has no [options]')
    while options and not options[-1].strip():
        options.pop()
    return '\n'.join([
        '# SmartRoom Firmware release: every package comes from one fixed, signed',
        '# repository (/etc/pacman.d/smartroom-release names the release).',
        '[options]', *options, '',
        'SigLevel = Required DatabaseRequired',
        'LocalFileSigLevel = Required', '',
        f'[{REPOSITORY}]',
        f'Include = /etc/pacman.d/{REPOSITORY}', ''])


def require_signatures(text):
    """A dev image's pacman.conf: every package archive, local files included,
    needs a trusted signature. Only databases may be unsigned (Arch and Omarchy
    publish none); no level may trust every key or skip checks."""
    out, section, local_level = [], None, False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            if section == 'options' and not local_level:
                out.append('LocalFileSigLevel = Required')
                local_level = True
            section = stripped[1:-1]
        match = re.match(r'^\s*(SigLevel|LocalFileSigLevel|RemoteFileSigLevel)\s*=\s*(.*?)\s*$', line)
        if match:
            levels = match.group(2).split()
            if section == 'options' and match.group(1) == 'LocalFileSigLevel':
                line, local_level = 'LocalFileSigLevel = Required', True
            elif any(level in ('Never', 'TrustAll', 'Optional', 'PackageNever', 'PackageOptional', 'PackageTrustAll')
                     for level in levels):
                fail(f'[{section}] {match.group(1)} = {match.group(2)} accepts packages without a trusted signature')
        out.append(line)
    if section is None:
        fail('the configuration has no [options]')
    if section == 'options' and not local_level:
        out.append('LocalFileSigLevel = Required')
    return '\n'.join(out) + '\n'


def mirror(version, url):
    check_release(version, url)
    return (f'# SmartRoom release {version}. This room takes packages only from this signed\n'
            '# repository; it moves to another release only through\n'
            '# smartroom-release-repo switch <version>.\n'
            f'# release={version}\n'
            f'Server = {url}\n')


def read_records(path):
    records, names, files = [], set(), set()
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        fields = line.split('|')
        if len(fields) != 5 or not all(fields) or not SHA256.match(fields[4]) or '/' in fields[3]:
            fail(f'{path}:{number} is not name|version|repository|file|sha256')
        if fields[0] in names or fields[3] in files:
            fail(f'{path}:{number} lists {fields[0]} or {fields[3]} twice')
        names.add(fields[0])
        files.add(fields[3])
        records.append(fields)
    if not records:
        fail(f'{path} records no package')
    return records


def desc_fields(text):
    fields, key = {}, None
    for line in text.splitlines():
        if line.startswith('%') and line.endswith('%'):
            key = line.strip('%')
            fields[key] = []
        elif line and key:
            fields[key].append(line)
    return fields


def database_entries(database):
    """(name, version) -> desc fields for every package DATABASE lists."""
    entries = {}
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['bsdtar', '-xf', str(database), '-C', scratch], check=True)
        for desc in Path(scratch).glob('*/desc'):
            fields = desc_fields(desc.read_text())
            if fields.get('NAME') and fields.get('VERSION'):
                entries[(fields['NAME'][0], fields['VERSION'][0])] = fields
    return entries


def stage(args):
    records = read_records(args.records)
    local = set(filter(None, args.local.split(',')))
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    databases = {}
    for name, version, repository, filename, digest in records:
        source = (args.repositories / repository if repository in local else args.cache) / filename
        if not source.is_file() or sha256(source) != digest:
            fail(f'{name} {version}: {source} is not the recorded archive')
        shutil.copyfile(source, output / filename)
        signature = source.with_name(filename + '.sig')
        if signature.is_file():
            shutil.copyfile(signature, output / (filename + '.sig'))
            continue
        if repository not in databases:
            database = args.repositories / repository / f'{repository}.db'
            databases[repository] = database_entries(database) if database.is_file() else {}
        pgpsig = databases[repository].get((name, version), {}).get('PGPSIG')
        if not pgpsig:
            fail(f'{name} {version}: no signature from its publisher ({repository})')
        (output / (filename + '.sig')).write_bytes(base64.b64decode(''.join(pgpsig)))
    shutil.copyfile(args.records, output / 'PACKAGES')


def check_db(args):
    want = {(r[0], r[1], r[3], r[4]) for r in read_records(args.records)}
    got = set()
    for (name, version), fields in database_entries(args.database).items():
        got.add((name, version, (fields.get('FILENAME') or [''])[0], (fields.get('SHA256SUM') or [''])[0]))
    if got != want:
        for entry in sorted(want - got):
            print(f'release_repo: not in the database: {" ".join(entry)}', file=sys.stderr)
        for entry in sorted(got - want):
            print(f'release_repo: not recorded: {" ".join(entry)}', file=sys.stderr)
        fail(f'{args.database} is not the recorded package set')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check-release').add_argument('file', type=Path)
    commands.add_parser('config').add_argument('template', type=Path)
    commands.add_parser('require-signatures').add_argument('conf', type=Path)
    command = commands.add_parser('mirror')
    command.add_argument('version')
    command.add_argument('url')
    command = commands.add_parser('stage')
    command.add_argument('--records', type=Path, required=True)
    command.add_argument('--repositories', type=Path, required=True)
    command.add_argument('--cache', type=Path, required=True)
    command.add_argument('--local', default='')
    command.add_argument('--output', type=Path, required=True)
    command = commands.add_parser('check-db')
    command.add_argument('--records', type=Path, required=True)
    command.add_argument('database', type=Path)
    args = parser.parse_args()
    if args.command == 'check-release':
        print('version={}\nurl={}'.format(*read_release(args.file)))
    elif args.command == 'config':
        sys.stdout.write(config(args.template))
    elif args.command == 'require-signatures':
        sys.stdout.write(require_signatures(args.conf.read_text()))
    elif args.command == 'mirror':
        sys.stdout.write(mirror(args.version, args.url))
    elif args.command == 'stage':
        stage(args)
    else:
        check_db(args)


if __name__ == '__main__':
    main()

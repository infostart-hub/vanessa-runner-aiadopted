#!/usr/bin/env python3
"""Explicit, reversible trust setup for named local test infobases on Windows and macOS."""
import argparse
import json
import os
from pathlib import Path
import stat
import tempfile

KEY = 'DisableUnsafeActionProtection'


def default_config_path(os_name=None, env=None):
    target_os = os_name or os.name
    environ = os.environ if env is None else env
    if target_os == 'nt':
        local_app_data = environ.get('LOCALAPPDATA')
        root = Path(local_app_data) if local_app_data else (Path.home() / 'AppData/Local')
        return root / '1C/1cv8/conf/conf.cfg'
    return Path.home() / '.1cv8/1C/1cv8/conf/conf.cfg'


def base_pattern(value, require_existing=True):
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ValueError('Infobase path must be absolute')
    if any(c in str(path) for c in ';"\r\n\x00'):
        raise ValueError('Infobase path cannot be safely represented in conf.cfg')
    path = path.resolve(strict=require_existing)
    if require_existing and not (path / '1Cv8.1CD').is_file():
        raise ValueError('An existing file infobase with 1Cv8.1CD is required')
    text = str(path)
    if any(c in text for c in ';"\r\n\x00'):
        raise ValueError('Infobase path cannot be safely represented in conf.cfg')
    # POSIX BRE, not Python re.escape: escaped parentheses would introduce groups.
    escaped = ''.join('\\' + c if c in '\\.[*^$' else c for c in text)
    # Closing quote prevents a prefix from granting access to a neighbouring base.
    return '^File="' + escaped + '".*$'


def transform(content, patterns, revoke=False):
    lines = content.splitlines(keepends=True)
    indexes = [i for i, line in enumerate(lines) if line.split('=', 1)[0].strip() == KEY]
    if len(indexes) > 1:
        raise ValueError('Multiple protection settings: resolve ambiguity before editing')
    current = []
    if indexes:
        current = [p.strip() for p in lines[indexes[0]].strip().split('=', 1)[1].split(';') if p.strip()]
    updated = [p for p in current if p not in patterns] if revoke else list(dict.fromkeys(current + patterns))
    if updated == current:
        return content
    replacement = KEY + '=' + ';'.join(updated) + '\n' if updated else ''
    if indexes:
        lines[indexes[0]] = replacement
    else:
        if lines and not lines[-1].endswith(('\n', '\r')):
            lines[-1] += '\n'
        lines.append(replacement)
    return ''.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--infobase', action='append', required=True)
    parser.add_argument('--config', help='Explicit path to conf.cfg (defaults to user 1C conf.cfg)')
    parser.add_argument('--revoke', action='store_true')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--acknowledge-trust-change', action='store_true',
                        help='Caller has explicit owner approval for the listed test bases')
    args = parser.parse_args()
    patterns = [base_pattern(p, require_existing=not args.revoke) for p in args.infobase]
    config = Path(args.config).expanduser() if args.config else default_config_path()
    before = config.read_text(encoding='utf-8-sig') if config.exists() else ''
    after = transform(before, patterns, args.revoke)
    if args.apply:
        if not args.acknowledge_trust_change:
            raise ValueError('Explicit approval of this trust change is required')
        if before != after:
            config.parent.mkdir(parents=True, exist_ok=True)
            mode = stat.S_IMODE(config.stat().st_mode) if config.exists() else 0o600
            fd, temporary = tempfile.mkstemp(prefix='conf-', suffix='.tmp', dir=config.parent)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    stream.write(after)
                os.chmod(temporary, mode)
                os.replace(temporary, config)
            finally:
                Path(temporary).unlink(missing_ok=True)
    print(json.dumps(dict(action='revoke' if args.revoke else 'grant', applied=args.apply,
                          changed=before != after, config=str(config), patterns=patterns), ensure_ascii=False))


if __name__ == '__main__':
    main()

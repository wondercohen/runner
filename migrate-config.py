#!/usr/bin/env python3
"""Convert a supported legacy Bash-style runner.cfg to data-only sections.

IMPORTANT: The legacy input is NEVER executed. This parser fails closed on
unrecognized statements, shell substitutions, duplicate fields or syntax.
Python 3 is needed only for this one-time conversion, not for runner.sh.
"""
import argparse
import os
from pathlib import Path
import re
import sys

GLOBAL_KEYS = {"SSH_USER": "ssh_user", "SSH_KEY_PATH": "ssh_key_path",
               "LOG_DIR": "log_dir", "BECOME_DEFAULT": "become"}
ARRAY_KEYS = {"NODE_INVENTORY", "NODE_MAP", "NODE_HOSTNAME", "NODE_ROLE",
              "HOST_SSH_USER", "HOST_SSH_KEY_PATH", "HOST_BECOME"}
ASSIGNMENT = re.compile(r'^([A-Z][A-Z0-9_]*)\s*=\s*(.*)$')
ARRAY_HEADER = re.compile(r'^declare\s+-(?:gA|A)\s+([A-Z_]+)\s*=\s*\((.*)$')
ENTRY = re.compile(r'\s*\[([0-9]+)\]\s*=\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', re.S)


def abort(message):
    raise ValueError(message)


def decode(value, context):
    value = value.strip()
    if not value:
        return ""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        quote = value[0]
        value = value[1:-1]
        if quote == '"':
            # Only Bash's standard escaped double-quote and escaped backslash
            # are allowed; everything else is treated as an unsupported form.
            if re.search(r'\\(?!["\\])', value):
                abort(f"{context}: unsupported backslash escape")
            value = value.replace('\\"', '"').replace('\\\\', '\\')
        elif "\\" in value:
            abort(f"{context}: escaped single-quoted strings are unsupported")
    elif '\"' in value or "'" in value or any(c.isspace() for c in value):
        abort(f"{context}: unsupported quoting")
    # Never expand arbitrary Bash expressions from the input.
    if '$(' in value or '`' in value or re.search(r'\$(?!\{HOME\}/|HOME/)', value):
        abort(f"{context}: shell expansion is unsupported; edit manually")
    if '${' in value and '${HOME}/' not in value:
        abort(f"{context}: unsupported variable expansion")
    value = value.replace('${HOME}/', '~/').replace('$HOME/', '~/')
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        abort(f"{context}: control character in value")
    return value


def parse_entries(text, label, records):
    pos = 0
    while text[pos:].strip():
        match = ENTRY.match(text, pos)
        if not match:
            abort(f"{label}: unrecognized array entry near {text[pos:pos+35]!r}")
        node, raw = match.groups()
        if node in records:
            abort(f"{label}: duplicate node {node}")
        records[node] = decode(raw, f"{label}[{node}]")
        pos = match.end()


def parse_legacy(data):
    globals_ = {}
    arrays = {}
    current = None
    chunks = []
    for n, raw in enumerate(data.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if current:
            if ')' in line and line.rstrip().endswith(')'):
                content = line[:line.rfind(')')]
                chunks.append(content)
                parse_entries(' '.join(chunks), current, arrays[current])
                current = None
                chunks = []
            else:
                chunks.append(line)
            continue
        ah = ARRAY_HEADER.fullmatch(line)
        if ah:
            name, initial = ah.groups()
            if name not in ARRAY_KEYS or name in arrays:
                abort(f"line {n}: unknown or duplicate array: {name}")
            arrays[name] = {}
            if initial.endswith(')'):
                parse_entries(initial[:-1], name, arrays[name])
            else:
                current = name
                chunks = [initial]
            continue
        assignment = ASSIGNMENT.fullmatch(line)
        if assignment:
            key, raw_val = assignment.groups()
            if key not in GLOBAL_KEYS or key in globals_:
                abort(f"line {n}: unsupported or duplicate variable {key}")
            globals_[key] = decode(raw_val, f"line {n} ({key})")
            continue
        abort(f"line {n}: unsupported Bash syntax: {line[:60]}")
    if current:
        abort(f"unterminated array: {current}")
    if not {'SSH_USER', 'SSH_KEY_PATH'} <= globals_.keys():
        abort('missing global SSH_USER or SSH_KEY_PATH')
    if 'NODE_INVENTORY' not in arrays and not {'NODE_MAP', 'NODE_HOSTNAME'} <= arrays.keys():
        abort('missing NODE_INVENTORY or NODE_MAP/NODE_HOSTNAME')

    nodes = {}
    if 'NODE_INVENTORY' in arrays:
        for node, val in arrays['NODE_INVENTORY'].items():
            fields = val.split('|')
            if len(fields) not in (4, 5):
                abort(f'node {node}: expected four or five inventory fields')
            ip, name, sshkey, user = fields[:4]
            become = fields[4] if len(fields) == 5 else ''
            nodes[node] = dict(ip=ip, hostname=name, ssh_key_path=sshkey,
                               ssh_user=user, become=become)
    else:
        for node, ip in arrays['NODE_MAP'].items():
            name = arrays['NODE_HOSTNAME'].get(node, '')
            nodes[node] = dict(ip=ip, hostname=name)
        for extra_name, key in [('HOST_SSH_KEY_PATH', 'ssh_key_path'), ('HOST_SSH_USER', 'ssh_user'), ('HOST_BECOME', 'become')]:
            for node, val in arrays.get(extra_name, {}).items():
                if node not in nodes:
                    abort(f'{extra_name}: unknown node {node}')
                nodes[node][key] = val
    for node, role in arrays.get('NODE_ROLE', {}).items():
        if node not in nodes:
            abort(f'NODE_ROLE: unknown node {node}')
        nodes[node]['role'] = role
    if not nodes:
        abort('no nodes found')
    for node, details in nodes.items():
        if not details.get('ip') or not details.get('hostname'):
            abort(f'node {node}: missing ip or hostname')
        if details.get('become') and details['become'] not in ('true', 'false'):
            abort(f'node {node}: invalid become')
    if globals_.get('BECOME_DEFAULT', 'false') not in ('true', 'false'):
        abort('invalid BECOME_DEFAULT')
    return globals_, nodes


def format_new(globals_, nodes):
    lines = [
        '# SSH Runner configuration (migrated; data-only, never sourced).',
        '# chmod 600 runner.cfg  |  paths: absolute or ~/...',
        '', '[global]',
    ]
    for old, new in GLOBAL_KEYS.items():
        if old in globals_:
            lines.append(f'{new} = {globals_[old]}')
    if 'BECOME_DEFAULT' not in globals_:
        lines.append('become = false')
    for node in sorted(nodes, key=int):
        lines.extend(['', f'[node:{node}]'])
        for key in ('ip', 'hostname', 'ssh_user', 'ssh_key_path', 'become', 'role'):
            if nodes[node].get(key):
                lines.append(f'{key} = {nodes[node][key]}')
    return '\n'.join(lines) + '\n'


def main():
    ap = argparse.ArgumentParser(description='Convert legacy Bash runner.cfg to data-only runner.cfg (never executes input)')
    ap.add_argument('source', type=Path, help='old Bash-style runner.cfg')
    ap.add_argument('--output', type=Path, required=True, help='new destination file; must not exist')
    args = ap.parse_args()
    if args.source.resolve() == args.output.resolve():
        ap.error('input and output must be different; keep the old file as backup')
    try:
        globals_, nodes = parse_legacy(args.source.read_text(encoding='utf-8'))
        converted = format_new(globals_, nodes)
        # Fail if destination exists; no accidental overwrite of live config.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(converted)
        print(f'Migrated {len(nodes)} node(s) to {args.output} (chmod 600).')
        print('Review the output before replacing the existing runner.cfg.')
    except (OSError, UnicodeError, ValueError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

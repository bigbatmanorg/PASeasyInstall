#!/usr/bin/env python3
"""Read-only, secret-minimizing assessor for PASeasyInstall exported run journals.

It deliberately does not assert functional readiness or publish a PASS for a lab scenario.
The output contains only target IDs, known status enums and event counts, not messages,
network addresses, credentials, or vendor files.
"""
import argparse
import collections
import json
import re
import sys
from pathlib import Path

TERMINAL_SUCCESS = 'Succeeded'
MAX_JSON_BYTES = 15_000_000
SAFE_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$')
KNOWN_EVENTS = {'TaskStarted', 'TaskCompleted', 'TaskFailed', 'DetachedProgress',
                'IntegrationComplete', 'IntegrationFailed', 'IntegrationBlocked',
                'IntegrationWaiting', 'VerificationRecovered', 'LaneFailed'}


def load(path: Path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError(f'missing, unsafe or oversized file: {path.name}')
    with path.open(encoding='utf-8-sig') as source:
        return json.load(source)


def expected_targets(config):
    components = config.get('components', [])
    types = {c.get('type') for c in components if isinstance(c, dict)}
    expected = []
    if 'Vault' in types:
        expected.append('primary')
        if 'DRVault' in types:
            expected.append('primary_final')
    if 'DRVault' in types:
        expected.extend(('dr', 'dr_final'))
    for component in components:
        if not isinstance(component, dict):
            raise ValueError('invalid component record')
        id_ = component.get('id')
        if not isinstance(id_, str) or not SAFE_ID.fullmatch(id_):
            raise ValueError('invalid component identifier')
        if component.get('type') not in ('Vault', 'DRVault'):
            expected.append(id_)
        if component.get('type') == 'HTML5GW':
            expected.append('register-' + id_)
        if component.get('type') == 'PTA' and config.get('security', {}).get('profile') == 'Lab':
            expected.append('trust-' + id_)
    ad = config.get('activeDirectory', {})
    if isinstance(ad, dict) and ad.get('mode') not in (None, 'None'):
        for host in ad.get('join', []):
            if not isinstance(host, str) or not SAFE_ID.fullmatch(host):
                raise ValueError('invalid join host')
            expected.append('join-' + host)
    if len(expected) != len(set(expected)):
        raise ValueError('duplicate expected target')
    return expected


def summarize_events(path: Path):
    counter = collections.Counter()
    if not path.is_file():
        return {}, 0
    if path.is_symlink() or path.stat().st_size > 50_000_000:
        raise ValueError('unsafe/oversized event journal')
    invalid = 0
    with path.open(encoding='utf-8-sig') as source:
        for line in source:
            if not line.strip():
                continue
            try:
                e = json.loads(line)
                event = e.get('Event', e.get('event', ''))
                if event in KNOWN_EVENTS:
                    counter[event] += 1
            except (json.JSONDecodeError, ValueError, AttributeError):
                invalid += 1
    return dict(sorted(counter.items())), invalid


def assess(run_dir: Path):
    run_dir = run_dir.resolve(strict=True)
    record = load(run_dir / 'run.json')
    config = load(run_dir / 'config.json')
    expected = expected_targets(config)
    targets = {}
    issues = []
    for name in expected:
        path = run_dir / name / 'state.json'
        if not path.is_file():
            targets[name] = 'MISSING'
            issues.append('Missing journal: ' + name)
            continue
        try:
            state = load(path)
            status = state.get('status')
            if not isinstance(status, str) or status not in (
                'Succeeded', 'Failed', 'Unknown', 'Running', 'Blocked', 'Pending',
                'Interrupted', 'Abandoned', 'Stopped', 'NotStarted'):
                status = 'UNRECOGNIZED'
            targets[name] = status
            if status != TERMINAL_SUCCESS:
                issues.append('Not succeeded: ' + name + ' [' + status + ']')
        except (OSError, ValueError, json.JSONDecodeError):
            targets[name] = 'UNREADABLE'
            issues.append('Unreadable journal: ' + name)
    run_status = record.get('status', 'MISSING')
    if run_status != TERMINAL_SUCCESS:
        issues.insert(0, 'Controller is not Succeeded')
    event_counts, invalid_event_lines = summarize_events(run_dir / 'events.jsonl')
    if invalid_event_lines:
        issues.append('Controller event journal contains malformed lines')
    # A successful controller can still have unfinished target-specific work:
    # never trust just its status or intermediate component success counters.
    workflow_complete = not issues
    return {
        'schemaVersion': 1,
        'scope': 'LAB_ONLY',
        'runId': str(record.get('id', '')) if SAFE_ID.fullmatch(str(record.get('id', ''))) else 'UNAVAILABLE',
        'controllerStatus': str(run_status) if run_status in ('Succeeded','Running','Failed','Unknown','Blocked','Abandoned','Interrupted','LaunchFailed') else 'UNRECOGNIZED',
        'requiredWorkflowTargets': targets,
        'controllerEventCounts': event_counts,
        'invalidEventLines': invalid_event_lines,
        'workflowComplete': workflow_complete,
        'functionalAcceptance': 'NOT_ASSESSED',
        'scenarioResult': 'NOT_ASSESSED',
        'issues': issues,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', type=Path, help='exported run folder with run.json and config.json')
    parser.add_argument('--output', type=Path, help='write sanitized assessment outside source/media directory')
    args = parser.parse_args()
    try:
        result = assess(args.run_dir)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, f'Run assessment failed: {type(exc).__name__}\n')
    rendered = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding='utf-8')
    else:
        print(rendered, end='')
    return 0 if result['workflowComplete'] else 1


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Exercise the actual runner jq filters using synthetic secrets only."""
import json
import pathlib
import re
import subprocess
import tempfile

runner = pathlib.Path(__file__).resolve().parents[1] / 'Modules/PASeasyInstall.Core/Private/Engine/Assets/LinuxDetachedRunner.sh'
source = runner.read_text()
filters = re.findall(r"jq(?: --unbuffered)? -Rr(s)? --slurpfile args \"\$input\" '(.*?)'", source, re.S)
assert len(filters) == 2, 'Expected actual cleanup and pre-write runner filters'
marker = 'SYNTHETIC_PFX_CONTAINER_MARKER_20261117'
password = 'SYNTHETIC_PFX_PASSWORD_20261117'
with tempfile.TemporaryDirectory(prefix='paeasy-pfx-redaction-') as folder:
    args = pathlib.Path(folder) / 'inputs.json'
    args.write_text(json.dumps({'CertificatePfxData': marker, 'CertificatePassword': password}))
    args.chmod(0o600)
    for slurp, program in filters:
        output = subprocess.check_output(['jq', '-Rrs' if slurp else '-Rr', '--slurpfile', 'args', str(args), program], input=f'prefix {marker} {password} suffix\n'.encode()).decode()
        assert marker not in output and password not in output, 'Actual runner filter leaked synthetic PFX input'
        assert '[REDACTED]' in output and 'prefix' in output, 'Filter output missing expected nonsecret context'
print('PASS actual pre-write and cleanup jq filters redact synthetic PFX payload/password; no native vendor execution.')

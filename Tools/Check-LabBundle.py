#!/usr/bin/env python3
"""Standard-library structural self-check (NOT PowerShell, Pester, or deployment validation)."""
import json
import re
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
necessary = (
    'PASeasyInstall/PASeasyInstall.psd1',
    'PASeasyInstall/Private/Engine/DurableCheck.ps1',
    'PASeasyInstall/Private/Run/Lanes.ps1',
    'PASeasyInstall/Recipes/Vault/Tasks/VaultDR/Wait-Replication.ps1',
    'PASeasyInstall/Recipes/LinuxComponent/Task.sh',
    'PASeasyInstall/Desktop/Views.ps1',
    'LabValidation/scenarios.json',
    'LabValidation/AGENT-PROMPT.md',
    'Docs/LAB-STABILIZATION.md',
    'Tests/StabilityRefactor.Tests.ps1',
)
for relative in necessary:
    assert (root / relative).is_file(), f'Missing: {relative}'
scenarios = json.loads((root / 'LabValidation/scenarios.json').read_text(encoding='utf-8'))
assert scenarios['scope'] == 'LAB_ONLY'
assert len(scenarios['scenarios']) == 8
assert len({x['id'] for x in scenarios['scenarios']}) == 8
for scenario in scenarios['scenarios']:
    assert scenario['topology'].get('Vault') == 1
    assert scenario['acceptance'] and scenario['records_required']
model = (root / 'PASeasyInstall/Desktop/Model.ps1').read_text(encoding='utf-8-sig')
views = (root / 'PASeasyInstall/Desktop/Views.ps1').read_text(encoding='utf-8-sig')
# Duplicate keys in a PowerShell hashtable initializer cause a startup failure.
map_body = model.split('$script:PASUIStageNames = @{', 1)[1].split('\n}', 1)[0]
stage_keys = re.findall(r"^\s*'([^']+)'\s*=", map_body, re.MULTILINE)
assert len(stage_keys) == len(set(stage_keys)), 'Duplicate UI stage-map key'
assert "Preset = 'custom'" in model
assert 'New-PASUICustomLabCard' in views
assert "New-PASUIPresetCard" not in views.split('function Add-PASUILabPage {')[1].split('function New-PASUICustomLabCard')[0]
psmp = (root / 'PASeasyInstall/Recipes/LinuxComponent/Task.sh').read_text(encoding='utf-8')
assert '  Preflight)' in psmp and '  PrepareTools)' in psmp
preflight = psmp.split('  Preflight)', 1)[1].split('  PrepareTools)', 1)[0]
assert 'apt-get' not in preflight and 'paeasy_needrestart_guard' not in preflight
stages = (root / 'PASeasyInstall/Public/Get-PASStageCatalog.ps1').read_text()
assert "'prepare-tools'" in stages
for relative in ('PASeasyInstall/Recipes/LinuxComponent/Task.sh', 'PASeasyInstall/Recipes/LinuxComponent/Verify.sh'):
    command = subprocess.run(['bash', '-n', str(root / relative)], capture_output=True, text=True)
    assert command.returncode == 0, f'Invalid Bash syntax: {relative}: {command.stderr}'
print('PASS: lab bundle structure, 8 scenarios, UI single path, PSMP stage split, Bash syntax')
print('NOT TESTED: PowerShell AST/Pester, Windows WPF, vendor installers, Proxmox and runtime workflows')

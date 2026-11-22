# Renders the command reference pages of the site from the comment-based help of the public commands.
# Usage: gen_commands.py <repository root>
import re, sys, os
root = sys.argv[1]

def read_help(name):
    s = open(os.path.join(root, 'PASeasyInstall', 'Public', name + '.ps1'), encoding='utf-8-sig').read()
    h = re.search(r'<#(.*?)#>', s, re.S).group(1)
    lines = [l.rstrip() for l in h.split('\n')]
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    lines = [l[indent:] if len(l) >= indent else '' for l in lines]
    sections, cur = [], None
    for l in lines:
        m = re.match(r'^\.(SYNOPSIS|DESCRIPTION|PARAMETER|EXAMPLE|OUTPUTS|NOTES|LINK|INPUTS)\s*(\S*)\s*$', l)
        if m:
            cur = [m.group(1), m.group(2), []]
            sections.append(cur)
        elif cur is not None:
            cur[2].append(l)
    return sections

def esc(t):
    return t.replace('<', '&lt;').replace('>', '&gt;')

def prose(lines):
    # Paragraphs; "- " lines become bullets; aligned text becomes a code block.
    out, para = [], []
    def flush():
        if not para:
            return
        if any(re.search(r'\S {3,}\S', p) for p in para) and not any(p.startswith('- ') for p in para):
            out.append('```text\n' + '\n'.join(para) + '\n```')
        else:
            text, plain = [], []
            for p in para:
                if p.startswith('- '):
                    if plain:
                        text.append(' '.join(plain))
                        text.append('')
                        plain = []
                    text.append('- ' + esc(p[2:]))
                elif text and text[-1].startswith('- '):
                    text[-1] += ' ' + esc(p.strip())
                else:
                    plain.append(esc(p.strip()))
            if plain:
                text.append(' '.join(plain))
            out.append('\n'.join(text))
        para.clear()
    for l in lines:
        if l.strip() == '':
            flush()
        else:
            para.append(l if l.startswith('- ') else l.rstrip())
    flush()
    return '\n\n'.join(out)

def synopsis(sec):
    return ' '.join(' '.join(' '.join(x[2]).split()) for x in sec if x[0] == 'SYNOPSIS')

def render(name, replace=None, after=None):
    sec = read_help(name)
    desc = [x[2] for x in sec if x[0] == 'DESCRIPTION']
    out = ['## ' + name, '', esc(synopsis(sec)), '']
    if desc:
        d = prose(desc[0])
        for old, new in (replace or []):
            assert old in d, (name, old)
            d = d.replace(old, new)
        out += [d, '']
    if after:
        out += [after, '']
    params = [x for x in sec if x[0] == 'PARAMETER']
    if params:
        out += ['| Parameter | Meaning |', '|---|---|']
        for p in params:
            text = esc(' '.join(' '.join(p[2]).split())).replace('|', '\\|')
            out.append('| `-%s` | %s |' % (p[1], text))
        out.append('')
    for e in [x for x in sec if x[0] == 'EXAMPLE']:
        body = e[2]
        while body and not body[0].strip():
            body = body[1:]
        code, rest, incode = [], [], True
        for l in body:
            if incode and l.strip() == '':
                incode = False
                continue
            (code if incode else rest).append(l)
        out += ['```powershell', '\n'.join(c.rstrip() for c in code).rstrip(), '```', '']
        note = ' '.join(' '.join(rest).split())
        if note:
            out += [esc(note), '']
    return '\n'.join(out)

def table(names):
    rows = ['| Command | What it does |', '|---|---|']
    for n in names:
        rows.append('| [`%s`](#%s) | %s |' % (n, n.lower(), esc(synopsis(read_help(n)))))
    return '\n'.join(rows)

def page(path, title, intro, names, extras=None):
    extras = extras or {}
    parts = ['# ' + title, '', intro.strip(), '', table(names), '']
    for n in names:
        parts.append(render(n, **extras.get(n, {})))
    text = '\n'.join(parts).rstrip() + '\n'
    open(os.path.join(root, 'site-src', 'commands', path), 'w', encoding='utf-8').write(text)

GENERATED = 'The text of every command below is its own help (`Get-Help <command> -Full`).'

page('install.md', 'Install commands', '''
Each command installs one thing and returns a run id at once; the installation runs in its own process. Add
`-Wait` to follow it, `-WhatIf` to see what would happen without asking or contacting anything.

`Install-PASLab` installs a whole lab from a configuration, with all its servers at the same time. The other
commands install one component for a Vault that exists already. The HTML5 Gateway and PTA have no command of
their own: they are installed as part of a lab configuration (`New-PASLabConfiguration -Instances`).

''' + GENERATED,
     ['Install-PASLab', 'Install-PASVault', 'Install-PASPVWA', 'Install-PASCPM', 'Install-PASPSM', 'Install-PASPSMP', 'Install-PASDomainController'],
     {'Install-PASLab': {
         'after': 'A lab configuration can also hold an HTML5 Gateway, PTA and a domain; see [`New-PASLabConfiguration`](configuration.md#new-paslabconfiguration).'}})

page('configuration.md', 'Lab configuration commands', '''
A lab configuration says what to install where: the Vault, the components, their servers and installers. These
commands compose it, check it, show its plan and save it. None of them contacts a server, and a configuration
never contains a password.

```powershell
$media = Get-PASMediaInventory -Path D:\\CyberArk | Get-PASMediaSelection
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' })
Test-PASLabConfiguration -Configuration $cfg -CheckMedia | Format-List Valid, Issues, Warnings
Export-PASLabConfiguration -Configuration $cfg -Path .\\MyLab.json
```

''' + GENERATED,
     ['New-PASLabConfiguration', 'Test-PASLabConfiguration', 'Get-PASLabPlan', 'Export-PASLabConfiguration', 'Import-PASLabConfiguration', 'Get-PASCredentialRequirement', 'Get-PASStageCatalog'])

page('media.md', 'Media commands', '''
Find the CyberArk installers, the license and the recovery key in files, folders and ZIP files. Both commands
only read. Give `Get-PASMediaInventory` every folder and file where a part lies; they do not have to be in one
place.

''' + GENERATED,
     ['Get-PASMediaInventory', 'Get-PASMediaSelection'],
     {      'Get-PASMediaSelection': {'after': 'To use another file than the one that was chosen, replace the entry before you pass the selection on: `$media.HTML5GW = <inventory item>`.'}})

page('runs.md', 'Run commands', '''
An installation is a **run**. It executes in its own process on the controller and has a run id of 32
characters. These commands list, follow, continue and give up runs. They read the files of the run; only
`Resume-PASRun` and `Stop-PASRun -CredentialMap` contact servers.

See also [Runs and resume](../concepts/durable-runs.md) and [Locks](../concepts/coordination.md).

''' + GENERATED,
     ['Get-PASRun', 'Get-PASRunEvent', 'Wait-PASRun', 'Resume-PASRun', 'Stop-PASRun'])

page('checks.md', 'Checks and diagnostics', '''
`Test-PASPreflight` looks at the servers before an installation, `Test-PASHealth` at the lab after it.
`Export-PASDiagnostics` and `Get-PASRunLog` collect what a bug report needs. None of them changes anything on a
server.

''' + GENERATED,
     ['Test-PASPreflight', 'Test-PASHealth', 'Export-PASDiagnostics', 'Get-PASRunLog'],
     {})

page('start-paseasyinstall.md', 'Start-PASeasyInstall', '''
Opens [the window](../gui/index.md).

''' + GENERATED,
     ['Start-PASeasyInstall'],
     {'Start-PASeasyInstall': {'after': 'From the portable folder use `Start-PASeasyInstall.cmd`; from a source checkout `.\\Start-PASeasyInstall.ps1`. Both take the same two parameters.'}})
print('ok')

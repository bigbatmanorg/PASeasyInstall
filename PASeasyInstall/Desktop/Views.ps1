# The screens of the desktop window as HTML text. Every function takes the state and returns a string:
# no window, no installer call. Every value that is not written in this file goes through ConvertTo-PASUIText.

function ConvertTo-PASUIText {
    param([AllowNull()][string]$Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-PASUIFlowSteps {
    return @(
        @{ Id = 'media'; Title = 'Media' }
        @{ Id = 'lab'; Title = 'Lab' }
        @{ Id = 'servers'; Title = 'Servers' }
        @{ Id = 'review'; Title = 'Install' }
    )
}

function Get-PASUIStepsHtml {
    # The step line in the top bar. Empty outside the four steps of a new lab.
    param([hashtable]$State)
    $steps = @(Get-PASUIFlowSteps)
    $ids = @($steps | ForEach-Object { $_.Id })
    $position = [array]::IndexOf($ids, [string]$State.Screen)
    if ($position -lt 0) {
        return ''
    }
    $html = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $class = 'step'
        $disabled = ''
        if ($i -eq $position) {
            $class = 'step current'
        } elseif ($i -lt $position) {
            $class = 'step done'
        } else {
            $disabled = ' disabled'
        }
        [void]$html.Append("<button id=`"step-$($steps[$i].Id)`" class=`"$class`"$disabled><span class=`"num`">$($i + 1)</span>$($steps[$i].Title)</button>")
    }
    return $html.ToString()
}

function Get-PASUINoticeHtml {
    param([hashtable]$State)
    if (-not $State.Notice) {
        return ''
    }
    $ring = ''
    if ([string]$State.Notice.Kind -eq 'busy') {
        $ring = '<span class="spin"></span>'
    }
    return "<div class=`"notice $($State.Notice.Kind)`">" + $ring + (ConvertTo-PASUIText $State.Notice.Text) + '</div>'
}

function Get-PASUIIssueBoxHtml {
    # A red box with what is missing. Empty when nothing is.
    param([string[]]$Issues, [string]$Title = 'Before you continue')
    $list = @($Issues | Where-Object { $_ })
    if (-not $list.Count) {
        return ''
    }
    $items = ($list | ForEach-Object { '<li>' + (ConvertTo-PASUIText $_) + '</li>' }) -join ''
    return "<div class=`"box bad`"><strong>" + (ConvertTo-PASUIText $Title) + "</strong><ul>$items</ul></div>"
}

function Get-PASUIBarHtml {
    # Back and Next at the bottom of the four steps.
    param([hashtable]$State)
    switch ([string]$State.Screen) {
        'media' { return '<button id="act-back" class="btn">Back</button><span class="grow"></span><button id="act-next" class="btn primary">Next: choose the lab</button>' }
        'lab' { return '<button id="act-back" class="btn">Back</button><span class="grow"></span><button id="act-next" class="btn primary">Next: servers</button>' }
        'servers' {
            if ($State.Checking) {
                return '<button id="act-back" class="btn">Back</button><span class="grow">Checking the servers. Nothing is installed yet.</span><button class="btn primary" disabled><span class="spin"></span>Checking...</button>'
            }
            return '<button id="act-back" class="btn">Back</button><span class="grow">Next checks that every server answers and that the accounts work. Nothing is installed yet.</span><button id="act-next" class="btn primary">Next: check the servers</button>'
        }
        'review' { return '<button id="act-back" class="btn">Back</button><span class="grow"></span>' }
    }
    return ''
}

# ------------------------------------------------------------------ start page

function Get-PASUIHomeHtml {
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page">')
    [void]$html.Append('<div class="card hero"><h1>Build a CyberArk PAM lab</h1>')
    [void]$html.Append('<p class="lead">Media, lab, servers, install. Nothing is changed on any server before you press Install.</p>')
    [void]$html.Append('<div class="actions"><button id="act-new" class="btn primary big">Start a new lab</button><button id="act-open" class="btn big">Open a saved lab file</button></div></div>')

    [void]$html.Append('<div class="card"><h2>Your installations</h2>')
    $runs = @($State.Runs)
    if (-not $runs.Count) {
        [void]$html.Append('<p class="hint">No installation has been started from this computer yet.</p>')
    } else {
        [void]$html.Append('<ul class="list">')
        foreach ($run in ($runs | Select-Object -First 12)) {
            $kind = Get-PASUIStatusKind ([string]$run.Status)
            [void]$html.Append('<li><span class="grow"><span class="name">' + (ConvertTo-PASUIText $run.Name) + '</span> ')
            [void]$html.Append('<span class="when">started ' + (ConvertTo-PASUIText (Format-PASUIWhen ([string]$run.StartedUtc))) + '</span></span>')
            [void]$html.Append("<span class=`"pill $kind`">" + (ConvertTo-PASUIText (Get-PASUIStatusText ([string]$run.Status))) + '</span>')
            [void]$html.Append("<button id=`"run-$([string]$run.RunId)`" class=`"btn small`">Open</button></li>")
        }
        [void]$html.Append('</ul>')
    }
    [void]$html.Append('</div>')

    [void]$html.Append('<p class="hint">PASeasyInstall builds labs. An installation runs in its own process and continues when this window is closed.</p>')
    [void]$html.Append('</div>')
    return $html.ToString()
}

# ------------------------------------------------------------------ step 1: media

function Get-PASUIMediaHtml {
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page"><h1>Where is the installer media?</h1>')
    [void]$html.Append('<p class="lead">The folder with what you downloaded from CyberArk (the one big ZIP or the separate ZIPs), your license file and the recovery public key.</p>')
    [void]$html.Append('<div class="card"><div id="media-drop" class="drop" data-nativehtmlkit-drop="files"><strong>Drop the media folder or the ZIP files here</strong><span>or type the folder below</span></div>')
    [void]$html.Append('<div class="row"><div class="grow"><label for="f-mediapath">Media folder</label>')
    [void]$html.Append('<input type="text" id="f-mediapath" placeholder="D:\CyberArkMedia" value="' + (ConvertTo-PASUIText $State.MediaPath) + '"></div>')
    [void]$html.Append('<button id="act-browse" class="btn">Browse</button><button id="act-scan" class="btn primary">Look for installers</button></div>')
    [void]$html.Append('<div id="media-sources">' + (Get-PASUIMediaSourcesHtml $State) + '</div></div>')
    [void]$html.Append('<div id="media-result">' + (Get-PASUIMediaResultHtml $State) + '</div></div>')
    return $html.ToString()
}

function Get-PASUIMediaSourcesHtml {
    # The files and folders that were dropped, with a button to forget them.
    param([hashtable]$State)
    $sources = @($State.MediaSources)
    if (-not $sources.Count) {
        return ''
    }
    $items = ($sources | ForEach-Object { '<li>' + (ConvertTo-PASUIText $_) + '</li>' }) -join ''
    return '<p class="hint" style="margin-top:12px">Also used:</p><ul class="sources">' + $items + '</ul><button id="act-media-clear" class="btn small">Remove these</button>'
}

function Get-PASUIMediaResultHtml {
    param([hashtable]$State)
    if (-not $State.MediaScanned) {
        return ''
    }
    $rows = @(Get-PASUIMediaRows $State)
    $found = @($rows | Where-Object { $_.Found })
    $html = New-Object System.Text.StringBuilder
    if (-not $found.Count) {
        [void]$html.Append('<div class="box bad"><strong>No CyberArk installer was recognised in that folder.</strong> Check that it is the folder with the ZIP files as downloaded, not an unpacked copy.</div>')
        return $html.ToString()
    }
    [void]$html.Append('<div class="card"><h2>Found in this folder</h2><table><tbody>')
    foreach ($row in $rows) {
        $pill = '<span class="pill">not found</span>'
        if ($row.Found) {
            $pill = '<span class="pill ok">found</span>'
        }
        [void]$html.Append('<tr><td class="state">' + $pill + '</td><td>' + (ConvertTo-PASUIText $row.Label) + '<span class="sub">' + (ConvertTo-PASUIText $row.Detail) + '</span></td></tr>')
    }
    [void]$html.Append('</tbody></table><p class="hint">Parts that are not found can simply be left out of the lab on the next step.</p></div>')
    return $html.ToString()
}

# ------------------------------------------------------------------ step 2: lab

function Get-PASUILabHtml {
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page"><h1>What do you want to build?</h1>')
    [void]$html.Append('<p class="lead">Pick a ready-made lab. You can change every part with Custom.</p>')

    [void]$html.Append('<div class="choices">')
    foreach ($preset in Get-PASUIPresets) {
        $class = 'choice'
        if ($State.Preset -eq $preset.Id) {
            $class = 'choice selected'
        }
        $servers = ''
        if ($preset.Counts) {
            $copy = @{ VaultMode = $preset.VaultMode; Counts = $preset.Counts; Colocate = $true }
            $servers = '<span class="servers">' + @(Get-PASUIServerSlots $copy).Count + ' servers</span>'
        }
        $badge = ''
        if ($preset.ContainsKey('Recommended')) {
            $badge = ' <span class="badge rec">recommended</span>'
        }
        [void]$html.Append("<button id=`"preset-$($preset.Id)`" class=`"$class`"><span class=`"title`">$($preset.Title)$badge</span><span class=`"what`">$($preset.What)</span>$servers</button>")
    }
    [void]$html.Append('</div>')

    if ($State.Preset -eq 'custom') {
        [void]$html.Append((Get-PASUICustomLabHtml $State))
    }

    [void]$html.Append('<div class="card"><h2>Active Directory</h2><div class="choices">')
    $domains = @(
        @{ Id = 'None'; Title = 'No domain'; What = 'The servers stay as they are.' }
        @{ Id = 'New'; Title = 'New domain'; What = 'One more server becomes the domain controller. PVWA, CPM and PSM servers join it and get the CyberArk hardening GPOs.' }
        @{ Id = 'Existing'; Title = 'A domain I already have'; What = 'PVWA, CPM and PSM servers join it. Its GPOs are not touched.' }
    )
    foreach ($domain in $domains) {
        $class = 'choice'
        if ($State.Domain -eq $domain.Id) {
            $class = 'choice selected'
        }
        [void]$html.Append("<button id=`"domain-$($domain.Id)`" class=`"$class`"><span class=`"title`">$($domain.Title)</span><span class=`"what`">$($domain.What)</span></button>")
    }
    [void]$html.Append('</div>')
    if ($State.Domain -ne 'None') {
        [void]$html.Append('<div class="field"><label for="f-domainname">DNS name of the domain</label>')
        [void]$html.Append('<input type="text" id="f-domainname" value="' + (ConvertTo-PASUIText $State.DomainName) + '">')
        [void]$html.Append('<p class="hint">For example pam.lab. The servers restart once when they join. Vault servers are never joined.</p></div>')
    }
    [void]$html.Append('</div>')

    [void]$html.Append('<div class="card"><div class="field"><label for="f-labname">Name of the lab</label>')
    [void]$html.Append('<input type="text" id="f-labname" value="' + (ConvertTo-PASUIText $State.LabName) + '">')
    [void]$html.Append('<p class="hint">Installations are listed under this name. Letters, digits, dot, dash, underscore.</p></div></div>')


    [void]$html.Append('<div id="lab-issues">' + (Get-PASUIIssueBoxHtml (Get-PASUIInputIssues $State 'lab')) + '</div></div>')
    return $html.ToString()
}

function Get-PASUICustomLabHtml {
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="card"><h2>Vault</h2><div class="choices">')
    $modes = @(
        @{ Id = 'Primary'; Title = 'New Vault'; What = 'One Vault server.' }
        @{ Id = 'PrimaryDR'; Title = 'New Vault with DR'; What = 'A Vault and a DR Vault that replicates it.' }
        @{ Id = 'Existing'; Title = 'A Vault I already have'; What = 'Only add components to it.' }
    )
    foreach ($mode in $modes) {
        $class = 'choice'
        if ($State.VaultMode -eq $mode.Id) {
            $class = 'choice selected'
        }
        [void]$html.Append("<button id=`"vault-$($mode.Id)`" class=`"$class`"><span class=`"title`">$($mode.Title)</span><span class=`"what`">$($mode.What)</span></button>")
    }
    [void]$html.Append('</div>')

    [void]$html.Append('<h2>Components</h2><table><tbody>')
    $max = Get-PASUIMaxCount $State
    foreach ($type in $script:PASUIComponentTypes) {
        $count = [int]$State.Counts[$type]
        $note = ''
        if (-not $State.MediaSelection.ContainsKey($type) -and $State.MediaScanned) {
            $note = '<span class="sub">no installer in the media folder</span>'
        }
        [void]$html.Append('<tr><td>' + (ConvertTo-PASUIText $script:PASUITypeNames[$type]) + $note + '</td><td style="width:150px"><div class="counter">')
        [void]$html.Append("<button id=`"cnt-$type-dec`" class=`"btn small`" aria-label=`"Fewer $type`">-</button><span class=`"value`">$count</span>")
        [void]$html.Append("<button id=`"cnt-$type-inc`" class=`"btn small`" aria-label=`"More $type`">+</button></div></td></tr>")
    }
    [void]$html.Append('</tbody></table>')
    [void]$html.Append("<p class=`"hint`">Up to $max of each. Two of each were tested; the Vault license decides how many can register.</p>")
    $checked = ''
    if ($State.Colocate) {
        $checked = ' checked'
    }
    [void]$html.Append('<label class="check"><input type="checkbox" id="f-colocate"' + $checked + '> Install CPM on the PVWA server (one server less)</label></div>')
    return $html.ToString()
}

# ------------------------------------------------------------------ step 3: servers

function Get-PASUIServersHtml {
    # A plain form: one line per server with its address and the account to sign in with, then the Vault passwords.
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page"><h1>Which servers?</h1>')
    [void]$html.Append('<p class="lead">Freshly installed machines this computer can reach: Windows with WinRM over HTTPS, Linux with SSH. For each one, the account that may administer it.</p>')

    [void]$html.Append('<div class="card"><table class="servers"><thead><tr><th>Server for</th><th>Computer name</th><th>Address</th><th>Account</th><th>Password</th></tr></thead><tbody>')
    foreach ($slot in Get-PASUIServerSlots $State) {
        $os = 'Windows'
        if ($slot.Os -eq 'Linux') {
            $os = 'Linux'
        }
        $key = $slot.Key
        $role = ConvertTo-PASUIText $slot.Roles
        $nameCell = '<span class="hint">not needed</span>'
        if ($slot.Named) {
            $nameCell = "<input type=`"text`" id=`"srv-$key-name`" aria-label=`"Computer name of the $role server`" value=`"" + (ConvertTo-PASUIText (Get-PASUISlotValue $State $slot 'Name')) + '">'
        }
        [void]$html.Append("<tr><td><strong>$role</strong><span class=`"sub`">$os</span></td><td>$nameCell</td>")
        [void]$html.Append("<td><input type=`"text`" id=`"srv-$key-addr`" aria-label=`"Address of the $role server`" placeholder=`"IP or DNS name`" value=`"" + (ConvertTo-PASUIText (Get-PASUISlotValue $State $slot 'Address')) + '"></td>')
        [void]$html.Append("<td><input type=`"text`" id=`"srv-$key-user`" aria-label=`"Account on the $role server`" value=`"" + (ConvertTo-PASUIText (Get-PASUISlotValue $State $slot 'User')) + '"></td>')
        [void]$html.Append("<td><input type=`"password`" id=`"srv-$key-pass`" autocomplete=`"off`" aria-label=`"Password on the $role server`" value=`"" + (ConvertTo-PASUIText (Get-PASUISlotValue $State $slot 'Password')) + '"></td></tr>')
    }
    [void]$html.Append('</tbody></table><p class="hint">Computer name: the name the server already has. PVWA is reached under this name. Account: a local administrator on Windows, root on Linux.</p>')
    if ($State.Domain -eq 'New') {
        [void]$html.Append('<p class="hint">Domain controller: its administrator becomes the administrator of the new domain, with the same password. That password is also set as the restore mode password of the domain.</p>')
    }
    if ($State.Domain -eq 'Existing') {
        [void]$html.Append('<p class="hint">Existing domain: the address of one of its DNS servers (usually a domain controller), and a domain account that may join computers.</p>')
    }
    [void]$html.Append('</div>')

    [void]$html.Append('<div class="card"><h2>Vault</h2>')
    if ($State.VaultMode -eq 'Existing') {
        [void]$html.Append('<div class="field"><label for="f-existing">Address of the Vault you already have</label>')
        [void]$html.Append('<input type="text" id="f-existing" value="' + (ConvertTo-PASUIText $State.ExistingVault) + '"></div>')
    }
    [void]$html.Append('<div class="row top">')
    foreach ($field in Get-PASUIVaultSecrets $State) {
        $value = ''
        if ($State.Secrets.ContainsKey($field.Key)) {
            $value = [string]$State.Secrets[$field.Key]
        }
        [void]$html.Append("<div class=`"grow field`"><label for=`"sec-$($field.Key)`">" + (ConvertTo-PASUIText $field.Label) + '</label>')
        [void]$html.Append("<input type=`"password`" id=`"sec-$($field.Key)`" autocomplete=`"off`" value=`"" + (ConvertTo-PASUIText $value) + '"><p class="hint">' + (ConvertTo-PASUIText $field.Hint) + '</p></div>')
    }
    [void]$html.Append('</div>')
    if ([int]$State.Counts.PSMP -gt 0 -or [int]$State.Counts['HTML5GW'] -gt 0 -or [int]$State.Counts['PTA'] -gt 0) {
        $checked = ''
        if ($State.AcceptEula) {
            $checked = ' checked'
        }
        [void]$html.Append('<label class="check"><input type="checkbox" id="f-eula"' + $checked + '> I have read and accept the CyberArk end user license agreement of the Linux installers (PSMP, HTML5 Gateway, PTA)</label>')
    }
    [void]$html.Append('<p class="hint" style="margin-top:6px">Passwords are kept in memory only, never in a file.</p></div>')

    if ($State.Advanced) {
        [void]$html.Append('<div class="card advanced"><h2>Network</h2>')
        [void]$html.Append('<div class="field"><label for="f-controller">Address of this computer</label><input type="text" id="f-controller" value="' + (ConvertTo-PASUIText $State.Controller) + '">')
        [void]$html.Append('<p class="hint">As the Vault sees it. The hardened Vault firewall is opened for it.</p></div></div>')
        [void]$html.Append('<div class="card advanced"><h2>Who installs</h2><div class="row">')
        [void]$html.Append('<div class="grow field"><label for="f-installer-name">User name</label><input type="text" id="f-installer-name" value="' + (ConvertTo-PASUIText $State.InstallerName) + '"></div>')
        [void]$html.Append('<div class="grow field"><label for="f-installer-company">Company</label><input type="text" id="f-installer-company" value="' + (ConvertTo-PASUIText $State.InstallerCompany) + '"></div>')
        [void]$html.Append('</div><p class="hint">What the CyberArk installers record as registered user and company. Empty: the CyberArk defaults.</p></div>')
        if ([int]$State.Counts['PTA'] -gt 0) {
            [void]$html.Append('<div class="card advanced"><h2>PTA</h2><div class="field"><label for="f-vault-timezone">Time zone of the Vault server</label>')
            [void]$html.Append('<input type="text" id="f-vault-timezone" placeholder="UTC" value="' + (ConvertTo-PASUIText $State.VaultTimezone) + '">')
            [void]$html.Append('<p class="hint">A tz database name such as Europe/Berlin. PTA reads the times in the Vault audit with it. Empty: UTC.</p></div></div>')
        }
    }

    [void]$html.Append('<div id="servers-issues"></div>')
    [void]$html.Append('<div id="preflight-result">' + (Get-PASUIPreflightHtml $State) + '</div></div>')
    return $html.ToString()
}

function Get-PASUIPreflightHtml {
    # The result of the server check. Problems first and in full; what passed only as a count,
    # or line by line in the advanced view.
    param([hashtable]$State)
    if ($State.Checking) {
        # The servers of a configuration are a table keyed by their id.
        $count = 0
        if ($State.Configuration -and $State.Configuration.hosts -is [System.Collections.IDictionary]) {
            $count = $State.Configuration.hosts.Count
        }
        $servers = 'the servers'
        if ($count -eq 1) {
            $servers = 'the server'
        } elseif ($count -gt 1) {
            $servers = "the $count servers"
        }
        if ([string]$State.CheckPhase -eq 'plan') {
            return '<div class="box busy"><span class="spin"></span><strong>Checking the servers.</strong> Getting ready...</div>'
        }
        if ([string]$State.CheckPhase -eq 'reach') {
            return '<div class="box busy"><span class="spin"></span><strong>Checking the servers, part 1 of 2.</strong> Looking whether ' + $servers + ' answer. This takes a few seconds.</div>'
        }
        return '<div class="box busy"><span class="spin"></span><strong>Checking the servers, part 2 of 2.</strong> All of them answer. Now signing in to ' + $servers + ' and checking that each is ready. This takes up to a minute per server; nothing is installed.</div>'
    }
    if (-not $State.Preflight) {
        return ''
    }
    $rows = @($State.Preflight)
    $failed = @($rows | Where-Object { $_.Passed -is [bool] -and -not $_.Passed })
    $passed = @($rows | Where-Object { $_.Passed -is [bool] -and $_.Passed })
    $html = New-Object System.Text.StringBuilder
    if ($failed.Count) {
        [void]$html.Append('<div class="box bad"><strong>The servers are not ready.</strong> Correct this, then press Next again.<ul>')
        foreach ($row in $failed) {
            [void]$html.Append('<li><strong>' + (ConvertTo-PASUIText (([string]$row.Address + ' ' + [string]$row.Server).Trim())) + '</strong>: ' + (ConvertTo-PASUIText $row.Detail) + '</li>')
        }
        [void]$html.Append('</ul></div>')
    } else {
        [void]$html.Append('<div class="box ok"><strong>All servers answered and look ready</strong> (' + $passed.Count + ' checks passed).</div>')
    }
    if ($State.Advanced) {
        [void]$html.Append('<div class="card flat"><table><thead><tr><th></th><th>Server</th><th>Check</th><th>Result</th></tr></thead><tbody>')
        foreach ($row in $rows) {
            $pill = '<span class="pill">skipped</span>'
            if ($row.Passed -is [bool] -and $row.Passed) {
                $pill = '<span class="pill ok">ok</span>'
            } elseif ($row.Passed -is [bool]) {
                $pill = '<span class="pill bad">problem</span>'
            }
            [void]$html.Append('<tr><td class="state">' + $pill + '</td><td>' + (ConvertTo-PASUIText $row.Server) + '<span class="sub">' + (ConvertTo-PASUIText $row.Address) + '</span></td>')
            [void]$html.Append('<td>' + (ConvertTo-PASUIText $row.Check) + '</td><td>' + (ConvertTo-PASUIText $row.Detail) + '</td></tr>')
        }
        [void]$html.Append('</tbody></table></div>')
    }
    return $html.ToString()
}

# ------------------------------------------------------------------ step 4: review and install

function Get-PASUIReviewHtml {
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page"><h1>Review and install</h1>')
    $check = $State.Check
    if (-not $check) {
        [void]$html.Append('<div class="box bad">The plan could not be prepared. Go back and check the entries.</div></div>')
        return $html.ToString()
    }
    $issues = @($check.Issues)
    if ($issues.Count) {
        [void]$html.Append('<p class="lead">The plan has problems. Nothing can be installed until they are solved.</p>')
        [void]$html.Append((Get-PASUIIssueBoxHtml $issues 'To solve'))
        [void]$html.Append('</div>')
        return $html.ToString()
    }
    $items = @($State.Plan.Items)
    $minutes = Get-PASUIEstimateMinutes $State
    [void]$html.Append('<p class="lead">This is what will be installed, in this order. It takes about ' + $minutes + ' minutes and needs no attention while it runs.</p>')

    [void]$html.Append('<div class="card"><table><thead><tr><th>#</th><th>What</th><th>On server</th><th>Installer</th></tr></thead><tbody>')
    $number = 0
    foreach ($item in $items) {
        $number++
        $media = ''
        if ([string]$item.Media) {
            $media = [IO.Path]::GetFileName([string]$item.Media)
        }
        [void]$html.Append("<tr><td>$number</td><td><strong>" + (ConvertTo-PASUIText $script:PASUITypeNames[[string]$item.Type]) + '</strong></td>')
        [void]$html.Append('<td>' + (ConvertTo-PASUIText $item.Address) + '<span class="sub">' + (ConvertTo-PASUIText $item.Name) + '</span></td><td class="hint">' + (ConvertTo-PASUIText $media) + '</td></tr>')
    }
    [void]$html.Append('</tbody></table></div>')

    $warnings = @($check.Warnings | Where-Object { $_ })
    if ($warnings.Count) {
        $list = ($warnings | ForEach-Object { '<li>' + (ConvertTo-PASUIText $_) + '</li>' }) -join ''
        [void]$html.Append('<details><summary>Lab shortcuts in use (' + $warnings.Count + '). Fine for a lab, not for production.</summary><div class="box warn"><ul>' + $list + '</ul></div></details>')
    }

    if ($State.Advanced) {
        [void]$html.Append('<div class="card advanced"><h2>The same from PowerShell</h2><p class="hint">Everything this window does can be done from the prompt. The lab file holds the choices, never a password.</p>')
        [void]$html.Append('<pre>' + (ConvertTo-PASUIText (Get-PASUICommandText $State)) + '</pre>')
        [void]$html.Append('<div class="actions"><button id="act-save" class="btn">Save the lab file</button></div></div>')
    }

    [void]$html.Append('<div class="card hero"><button id="act-install" class="btn primary big">Install the lab</button>')
    [void]$html.Append('<p class="hint" style="margin-top:10px">The installation runs in its own process. You can close this window and open it again later.</p></div>')
    [void]$html.Append('<div id="review-issues"></div></div>')
    return $html.ToString()
}

# ------------------------------------------------------------------ run page

function Get-PASUIRunHtml {
    # The page of one installation. It is built from four parts with their own ids, so a refresh can
    # replace each part and leave the scroll position and the opened activity log as they are.
    # Catalog: @{ <type> = <number of steps> }.
    param([hashtable]$State, [hashtable]$Catalog = @{})
    if (-not $State.Run) {
        return '<div class="page"><div class="box bad">This installation could not be read.</div></div>'
    }
    $open = ''
    if ($State.Advanced) {
        $open = ' open'
    }
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="page"><div id="run-status">' + (Get-PASUIRunStatusHtml $State $Catalog) + '</div>')
    [void]$html.Append('<div class="card" id="run-comps">' + (Get-PASUIRunComponentsHtml $State $Catalog) + '</div>')
    [void]$html.Append("<details class=`"logbox`"$open><summary>Activity log<span class=`"last`" id=`"run-last`">" + (Get-PASUIRunLastLineHtml $State) + "</span></summary><div class=`"log`" id=`"run-log`">" + (Get-PASUIRunLogHtml $State) + '</div></details>')
    [void]$html.Append('<div id="run-adv">' + (Get-PASUIRunAdvancedHtml $State) + '</div></div>')
    return $html.ToString()
}

function Get-PASUIRunStatusHtml {
    # Name, status, progress bar and what to do next.
    param([hashtable]$State, [hashtable]$Catalog = @{})
    $run = $State.Run
    $status = [string]$run.Status
    $kind = Get-PASUIStatusKind $status
    $progress = Get-PASUIRunProgress -Snapshot $run -Catalog $Catalog -PlanItems $State.RunPlan
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="runhead"><h1>' + (ConvertTo-PASUIText $run.Name) + '</h1>')
    [void]$html.Append("<span class=`"pill $kind`">" + (ConvertTo-PASUIText (Get-PASUIStatusText $status)) + '</span>')

    $elapsed = ''
    if ($run.PSObject.Properties['StartedUtc']) {
        $finished = ''
        if ($run.PSObject.Properties['FinishedUtc']) {
            $finished = [string]$run.FinishedUtc
        }
        $elapsed = Format-PASUIDuration ([string]$run.StartedUtc) $finished
    }
    $meterClass = 'meter'
    if ($kind -eq 'ok') {
        $meterClass = 'meter ok'
    } elseif ($kind -eq 'bad') {
        $meterClass = 'meter bad'
    }
    $line = "$($progress.Done) of $($progress.Total) steps"
    if ($elapsed) {
        $line += ", $elapsed"
    }
    [void]$html.Append('<span class="grow">' + (ConvertTo-PASUIText $line) + '</span></div>')
    [void]$html.Append("<div class=`"$meterClass`"><div class=`"fill`" style=`"width:$($progress.Percent)%`"></div></div>")

    if (Test-PASUIRunActive $status) {
        [void]$html.Append('<p class="hint">Running on its own: you can close this window and open it again later.</p>')
    } elseif ($status -eq 'Succeeded') {
        [void]$html.Append('<div class="box ok"><strong>The lab is installed.</strong> Check that every component is connected to the Vault before you use it.')
        [void]$html.Append('<div class="actions"><button id="act-health" class="btn primary">Check the lab</button></div></div>')
    } elseif ($status -eq 'Abandoned') {
        [void]$html.Append('<div class="box warn"><strong>This installation was stopped.</strong> The servers keep what was installed until then.</div>')
    } else {
        $failure = Get-PASUIFailure $run
        [void]$html.Append('<div class="box bad"><strong>The installation stopped.</strong> ')
        if ($failure) {
            [void]$html.Append('It stopped at "' + (ConvertTo-PASUIText (Get-PASUIStageText $failure.Stage)) + '" of ' + (ConvertTo-PASUIText $failure.Component) + '.<pre>' + (ConvertTo-PASUIText $failure.Message) + '</pre>')
        } else {
            [void]$html.Append((ConvertTo-PASUIText $run.Message))
        }
        [void]$html.Append('<p style="margin-top:10px">Correct the cause on the server, then continue. Steps that are finished are not repeated.</p><div class="actions">')
        if ($failure) {
            [void]$html.Append('<button id="act-retry" class="btn primary">Try this step again</button>')
        }
        [void]$html.Append('<button id="act-resume" class="btn">Continue without repeating it</button><button id="act-diag" class="btn">Save the logs as a ZIP</button></div></div>')
    }
    if ($State.Health) {
        [void]$html.Append((Get-PASUIHealthHtml $State))
    }
    return $html.ToString()
}

function Get-PASUIRunComponentsHtml {
    # One line per component: state, where, progress bar, current step.
    param([hashtable]$State, [hashtable]$Catalog = @{})
    $progress = Get-PASUIRunProgress -Snapshot $State.Run -Catalog $Catalog -PlanItems $State.RunPlan
    $html = New-Object System.Text.StringBuilder
    foreach ($row in @($progress.Components)) {
        $now = Get-PASUIStatusText $row.Status
        if ($row.Kind -eq 'run' -and $row.Current) {
            $now = Get-PASUIStageText $row.Current
        } elseif ($row.Kind -eq 'bad' -and $row.Current) {
            $now = 'Stopped at: ' + (Get-PASUIStageText $row.Current)
        }
        [void]$html.Append("<div class=`"comp $($row.Kind)`"><span class=`"dot`"></span><span class=`"who`"><span class=`"name`">" + (ConvertTo-PASUIText $script:PASUITypeNames[$row.Type]) + '</span>')
        [void]$html.Append('<span class="addr">' + (ConvertTo-PASUIText (($row.Address + ' ' + $row.Id).Trim())) + '</span></span>')
        [void]$html.Append("<span class=`"prog`"><div class=`"mini`"><div class=`"fill`" style=`"width:$($row.Percent)%`"></div></div><span class=`"now`">" + (ConvertTo-PASUIText $now) + '</span></span>')
        [void]$html.Append("<span class=`"count`">$($row.Done) / $($row.Total)</span></div>")
    }
    return $html.ToString()
}

function Get-PASUIRunLogHtml {
    # The newest 200 events, newest first. One line each: time, component, step, message.
    # A coloured bar on the left tells what kind of line it is (finished, started, warning, failed).
    param([hashtable]$State)
    $html = New-Object System.Text.StringBuilder
    $events = @($State.Run.Events | Select-Object -Last 200)
    [array]::Reverse($events)
    foreach ($entry in $events) {
        $kind = Get-PASUIEventKind $entry
        $step = Get-PASUIStageText ([string]$entry.Stage)
        [void]$html.Append("<div class=`"ev $kind`"><span class=`"t`">" + (ConvertTo-PASUIText (Format-PASUITime ([string]$entry.TimestampUtc))) + '</span>')
        [void]$html.Append('<span class="c">' + (ConvertTo-PASUIText $entry.Component) + '</span><span class="s">' + (ConvertTo-PASUIText $step) + '</span>')
        [void]$html.Append('<span class="m">' + (ConvertTo-PASUIText $entry.Message) + '</span></div>')
    }
    return $html.ToString()
}

function Get-PASUIRunLastLineHtml {
    # The number of events and the newest one, shown next to "Activity log" while the log is folded.
    param([hashtable]$State)
    $events = @($State.Run.Events)
    if (-not $events.Count) {
        return ''
    }
    $last = $events[-1]
    $text = [string]$last.Message
    if ($text.Length -gt 90) {
        $text = $text.Substring(0, 90) + '...'
    }
    return (ConvertTo-PASUIText ("$($events.Count) events, latest " + (Format-PASUITime ([string]$last.TimestampUtc)) + ': ' + $text))
}

function Get-PASUIRunAdvancedHtml {
    # The PowerShell commands for this run, and Stop. Only in the advanced view.
    param([hashtable]$State)
    if (-not $State.Advanced) {
        return ''
    }
    $id = [string]$State.Run.RunId
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="card advanced"><h2>This installation from PowerShell</h2>')
    [void]$html.Append('<pre>' + (ConvertTo-PASUIText ("Get-PASRun -RunId $id`nGet-PASRunEvent -RunId $id -Failed`nResume-PASRun -RunId $id`nExport-PASDiagnostics -RunId $id")) + '</pre>')
    if (Test-PASUIRunActive ([string]$State.Run.Status)) {
        [void]$html.Append('<div class="actions"><button id="act-stop" class="btn danger">Stop the installation</button></div>')
    }
    [void]$html.Append('</div>')
    return $html.ToString()
}

function Get-PASUIHealthHtml {
    param([hashtable]$State)
    $health = $State.Health
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<div class="card"><h2>Lab check</h2>')
    if ($health.Healthy) {
        [void]$html.Append('<div class="box ok"><strong>Healthy.</strong> ' + (ConvertTo-PASUIText $health.Message) + '</div>')
    } else {
        [void]$html.Append((Get-PASUIIssueBoxHtml @($health.Issues) 'Not healthy yet'))
    }
    $rows = @($health.Components)
    if ($rows.Count) {
        [void]$html.Append('<table><thead><tr><th></th><th>Component</th><th>Server</th><th>Version</th></tr></thead><tbody>')
        foreach ($row in $rows) {
            $pill = '<span class="pill bad">not connected</span>'
            if ($row.LoggedOn) {
                $pill = '<span class="pill ok">connected</span>'
            }
            [void]$html.Append('<tr><td class="state" style="width:120px">' + $pill + '</td><td>' + (ConvertTo-PASUIText $row.User) + '</td><td>' + (ConvertTo-PASUIText $row.Address) + '</td><td>' + (ConvertTo-PASUIText $row.Version) + '</td></tr>')
        }
        [void]$html.Append('</tbody></table>')
    }
    [void]$html.Append('</div>')
    return $html.ToString()
}

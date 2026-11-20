# Read-only normalized event stream. Engine stores structured JSONL; UI never scrapes a console.
function ConvertTo-PASComponentId {
    <# The Vault engine journals its two roles as primary/primary_final and dr/dr_final. #>
    param([string]$Component)
    switch -Regex ($Component){'^primary(_final)?$'{return 'vault'} '^dr(_final)?$'{return 'dr'} default{return $Component}}
}
function Get-PASDeploymentEvents {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string]$RunId,
        [string]$DataRoot=(Get-PASDataRoot),[ValidateRange(1,1000)][int]$Tail=150)
    $dir=Get-PASRunDirectory -RunId $RunId -DataRoot $DataRoot
    if(-not(Test-Path -LiteralPath $dir -PathType Container)){return @()}
    $sources=@()
    $controllerEvents=Join-Path $dir 'events-v2.jsonl'
    if(Test-Path -LiteralPath $controllerEvents -PathType Leaf){$sources+=@($controllerEvents)}
    foreach($subdir in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop)){
        if($subdir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $candidate=Join-Path $subdir.FullName 'events.jsonl'
        if(Test-Path -LiteralPath $candidate -PathType Leaf){$sources+=@($candidate)}
    }
    $events=New-Object System.Collections.ArrayList
    foreach($source in $sources){
        $sourceType=if([IO.Path]::GetFileName($source) -eq 'events-v2.jsonl'){'Controller'}else{'Engine'}
        $lineNumber=0
        foreach($line in @(Get-Content -LiteralPath $source -Tail $Tail -Encoding UTF8 -ErrorAction Stop)){
            $lineNumber++
            if(-not $line){continue}
            try{$data=$line|ConvertFrom-Json -ErrorAction Stop}catch{
                # A partially written final line may be observed; never guess a step state.
                continue
            }
            $stamp=[string](Get-PASValue $data 'timestampUtc' '')
            $eventType=[string](Get-PASValue $data 'type' (Get-PASValue $data 'event' 'Event'))
            $stage=[string](Get-PASValue $data 'taskId' '')
            $target=[string](Get-PASValue $data 'target' (Get-PASValue $data 'component' ''))
            $level=[string](Get-PASValue $data 'level' 'Information')
            if($level -notin @('Information','Warning','Error')){$level='Information'}
            $state='Info'
            if($level -eq 'Error' -or $eventType -match '(?i)(Failed|Unknown|Stopped)'){$state='Failed'}
            elseif($level -eq 'Warning' -or $eventType -match '(?i)(Warning|Retry|Reconcile)'){$state='Warning'}
            elseif($eventType -match '(?i)(Completed|Verified|Skipped|Revalidated|Published)'){$state='Complete'}
            elseif($eventType -match '(?i)(Started|Launched|Executing)'){$state='Running'}
            [void]$events.Add([pscustomobject]@{
                TimestampUtc=$stamp;RunId=$RunId;Component=$target;Stage=$stage;Event=$eventType;
                Level=$level;Status=$state;Source=$sourceType;
                Message=[string](Get-PASValue $data 'message' '');Sequence=[int](Get-PASValue $data 'sequence' $lineNumber)
            })
        }
    }
    return @($events.ToArray()|Sort-Object -Property TimestampUtc,Source,Component,Sequence|Select-Object -Last $Tail)
}
function Get-PASDeploymentSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[string]$DataRoot=(Get-PASDataRoot),[int]$Tail=150)
    $run=Get-PASRunRecord -RunId $RunId -DataRoot $DataRoot
    if(-not $run){throw "Deployment run not found: $RunId"}
    $events=@(Get-PASDeploymentEvents -RunId $RunId -DataRoot $DataRoot -Tail $Tail)
    $progress=@($events|Where-Object {$_.Event -eq 'TaskCompleted'})
    $errors=@($events|Where-Object {$_.Status -eq 'Failed'})
    $latest=@($events|Where-Object {$_.Stage}|Select-Object -Last 1)
    return [pscustomobject]@{
        RunId=$RunId;Name=[string]$run.name;Status=[string]$run.status;
        CurrentComponent=[string]$run.currentComponent;Message=[string]$run.message;
        LastStep=$(if($latest.Count){[string]$latest[-1].Stage}else{''});
        CompletedEvents=$progress.Count;ErrorEvents=$errors.Count;Events=$events;
        OperationallyVerified=$false # Installer workflow success does not prove PAM end-to-end function.
    }
}

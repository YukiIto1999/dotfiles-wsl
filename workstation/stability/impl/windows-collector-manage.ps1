[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install', 'status', 'uninstall')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [Parameter(Mandatory = $true)]
    [string]$TaskName,

    [string]$CollectorSource,

    [string]$ExpectedSha256,

    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 10,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$SnapshotName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$collectorName = 'collector.ps1'
$stagedCollectorName = 'collector.ps1.new'
$launcherName = 'collector-launcher.exe'
$stagedLauncherName = 'collector-launcher.new.exe'
$installLockName = 'install.lock'
$collectorLockName = 'collector.lock'
$taskMarker = 'dotfiles-windows-resource-collector'
$stopWaitSeconds = 15
$ownedNames = @($collectorName, $stagedCollectorName, $launcherName, $stagedLauncherName, $installLockName, $collectorLockName, $SnapshotName, ($SnapshotName + '.tmp'))

$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
$administratorsSid = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
$permittedSids = @($userSid.Value, $systemSid.Value, $administratorsSid.Value)

$script:applied = New-Object System.Collections.Generic.List[string]

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body, [switch]$Applies)

    try {
        $result = & $Body
    } catch {
        $message = $_.Exception.Message
        if ($_.Exception -is [UnauthorizedAccessException] -or $message -match 'denied') {
            $message += ' (this script runs as the current user and does not elevate; the current user is not permitted to do this on this machine)'
        }
        throw ('could not {0}: {1}' -f $Name, $message)
    }
    if ($Applies) { $script:applied.Add($Name) }
    return $result
}

function Resolve-SnapshotDirectory {
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($full)
    $programData = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if (-not $parent -or -not [string]::Equals($parent, $programData, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('the snapshot directory must be a direct child of ' + $programData + ': ' + $full)
    }
    return $full
}

function Test-DirectoryTrusted {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $userSid.Value -and $owner -ne $administratorsSid.Value) { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $permittedSids -notcontains $rule.IdentityReference.Value) {
            return $false
        }
    }
    return $true
}

function Assert-DirectoryOwned {
    param([string]$Path)

    if (-not (Test-DirectoryTrusted -Path $Path)) {
        throw ('{0} exists but is not restricted to this user, SYSTEM and Administrators, so it is not treated as this collector directory; nothing was changed' -f $Path)
    }
    $unowned = New-Object System.Collections.Generic.List[string]
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($Path)) {
        $name = [IO.Path]::GetFileName($entry)
        $item = Get-Item -LiteralPath $entry -Force
        if ($ownedNames -notcontains $name -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $unowned.Add($name)
        }
    }
    if ($unowned.Count -gt 0) {
        throw ('{0} holds entries that are not files of this collector ({1}); nothing was changed' -f $Path, ($unowned -join ', '))
    }
}

function Test-DirectoryOwned {
    param([string]$Path)

    try {
        Assert-DirectoryOwned -Path $Path
        return $true
    } catch {
        return $false
    }
}

function Set-RestrictedAcl {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('the directory is a reparse point: ' + $Path) }
    $security = Get-Acl -LiteralPath $Path
    $owner = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $userSid.Value -and $owner -ne $administratorsSid.Value) {
        throw ('the directory is owned by another principal: ' + $Path)
    }
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($security.Access)) { [void]$security.RemoveAccessRule($rule) }
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @($userSid, $systemSid, $administratorsSid)) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)))
    }
    $item.SetAccessControl($security)
    if (-not (Test-DirectoryTrusted -Path $Path)) { throw ('the directory permissions could not be restricted: ' + $Path) }
}

function Get-Digest {
    param([string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Find-TaskByName {
    return Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
}

function ConvertTo-SidValue {
    param([string]$Identity)

    if ($Identity -match '^S-1-') {
        try { return (New-Object Security.Principal.SecurityIdentifier($Identity)).Value } catch { return $null }
    }
    $candidates = @($Identity)
    if (-not $Identity.Contains('\') -and -not $Identity.Contains('@')) { $candidates += ($env:COMPUTERNAME + '\' + $Identity) }
    foreach ($candidate in $candidates) {
        try { return (New-Object Security.Principal.NTAccount($candidate)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    }
    return $null
}

function Get-TaskOwnershipProblem {
    param($Task, [string]$CollectorPath, [string]$SnapshotDirectory)

    if ((ConvertTo-SidValue -Identity ([string]$Task.Principal.UserId)) -ne $userSid.Value) { return 'it runs as another principal' }
    if (-not ([string]$Task.Description).StartsWith($taskMarker + ':')) { return 'its description does not carry the collector marker' }
    $actions = @($Task.Actions)
    $legacyExecutable = Join-Path $PSHOME 'powershell.exe'
    $launcherPath = Join-Path $SnapshotDirectory $launcherName
    if ($actions.Count -ne 1 -or @($legacyExecutable, $launcherPath) -notcontains [string]$actions[0].Execute) {
        return 'its action is not this collector launcher or PowerShell'
    }
    $arguments = [string]$actions[0].Arguments
    if (-not $arguments.Contains('-File "' + $CollectorPath + '"') -or -not $arguments.Contains('-Directory "' + $SnapshotDirectory + '"')) {
        return 'its action does not run the collector script of this directory'
    }
    return $null
}

function Assert-TaskOwnedOrAbsent {
    param([string]$CollectorPath, [string]$SnapshotDirectory)

    $task = Find-TaskByName
    if ($null -eq $task) { return }
    $problem = Get-TaskOwnershipProblem -Task $task -CollectorPath $CollectorPath -SnapshotDirectory $SnapshotDirectory
    if ($null -ne $problem) {
        throw ('a scheduled task named {0} already exists and is not this collector ({1}); nothing was changed' -f $TaskName, $problem)
    }
}

function Stop-OwnTask {
    param([string]$SnapshotDirectory)

    Stop-ScheduledTask -TaskName $TaskName -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds($stopWaitSeconds)
    $collectorLockPath = Join-Path $SnapshotDirectory $collectorLockName
    do {
        $task = Find-TaskByName
        if ($null -eq $task -or $task.State -ne 'Running') {
            try {
                $writer = [IO.File]::Open($collectorLockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $writer.Dispose()
                return
            } catch [IO.FileNotFoundException] {
                return
            } catch [IO.DirectoryNotFoundException] {
                return
            } catch [IO.IOException] {
                if (($_.Exception.HResult -band 0xFFFF) -notin @(32, 33)) { throw }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'the collector task or its snapshot writer did not stop in time'
}

function Enter-InstallLock {
    param([string]$Path)

    try {
        return [IO.File]::Open((Join-Path $Path $installLockName), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        $code = $_.Exception.HResult -band 0xFFFF
        if ($code -eq 32 -or $code -eq 33) { throw 'another installation or removal of this collector holds the lock; nothing was changed' }
        throw
    }
}

function New-CollectorLauncher {
    param([string]$Path)

    Add-Type -OutputAssembly $Path -OutputType WindowsApplication -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

internal static class CollectorLauncher
{
    private const int ExtendedLimitInformation = 9;
    private const uint KillOnJobClose = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicJobLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedJobLimits
    {
        public BasicJobLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedJobLimits limits, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    private static void BindCollectorToLauncherLifetime()
    {
        var limits = new ExtendedJobLimits();
        limits.Basic.LimitFlags = KillOnJobClose;
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero ||
            !SetInformationJobObject(job, ExtendedLimitInformation, ref limits, Marshal.SizeOf(limits)) ||
            !AssignProcessToJobObject(job, GetCurrentProcess()))
            throw new Win32Exception();
        // Closing the job before process exit would terminate the launcher before it returns the collector's exit code
    }

    private static int Main()
    {
        try
        {
            // Forward the original argument tail without decoding and re-quoting Windows paths
            var commandLine = Environment.CommandLine;
            int end = 0;
            if (commandLine[0] == '"')
                end = commandLine.IndexOf('"', 1) + 1;
            while (end < commandLine.Length && !char.IsWhiteSpace(commandLine[end]))
                end++;
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = commandLine.Substring(end),
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            BindCollectorToLauncherLifetime();
            using (var collector = Process.Start(start))
            {
                collector.WaitForExit();
                return collector.ExitCode;
            }
        }
        catch (Exception error)
        {
            return error.HResult;
        }
    }
}
'@
}

function New-TaskDefinition {
    param([string]$CollectorPath, [string]$SnapshotDirectory)

    $escape = { param([string]$Text) [Security.SecurityElement]::Escape($Text) }
    $executable = & $escape (Join-Path $SnapshotDirectory $launcherName)
    $arguments = & $escape ('-NoLogo -NoProfile -NonInteractive -File "{0}" -Directory "{1}" -SnapshotName "{3}" -IntervalSeconds {2}' -f $CollectorPath, $SnapshotDirectory, $IntervalSeconds, $SnapshotName)
    $sid = $userSid.Value
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>${taskMarker}: publishes Windows memory counters for workload admission on this host.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$executable</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Get-CollectorStatus {
    $full = Resolve-SnapshotDirectory
    $collectorPath = Join-Path $full $collectorName
    $exists = [IO.Directory]::Exists($full)
    $owned = $exists -and (Test-DirectoryOwned -Path $full)
    $installed = $owned -and [IO.File]::Exists($collectorPath)
    $current = $false
    if ($installed -and $ExpectedSha256) { $current = (Get-Digest -Path $collectorPath) -eq $ExpectedSha256.ToLowerInvariant() }
    $task = Find-TaskByName
    $taskOwned = $false
    $taskCurrent = $false
    if ($null -ne $task) {
        $taskOwned = $null -eq (Get-TaskOwnershipProblem -Task $task -CollectorPath $collectorPath -SnapshotDirectory $full)
        $launcherPath = Join-Path $full $launcherName
        $taskCurrent = $taskOwned -and [IO.File]::Exists($launcherPath) -and $task.Actions[0].Execute -eq $launcherPath
    }
    return [ordered]@{
        directoryTrusted   = $owned
        collectorInstalled = $installed
        collectorCurrent   = $current
        taskRegistered     = ($null -ne $task)
        taskOwned          = $taskOwned
        taskCurrent        = $taskCurrent
        taskState          = $(if ($null -ne $task) { [string]$task.State } else { $null })
    }
}

function New-RestrictedDirectory {
    param([string]$Final)

    $staging = '{0}.{1}.staging' -f $Final, [Guid]::NewGuid().ToString('N')
    $stagedCollector = Join-Path $staging $collectorName
    [void][IO.Directory]::CreateDirectory($staging)
    try {
        Set-RestrictedAcl -Path $staging
        [IO.File]::Copy($CollectorSource, $stagedCollector)
        if ((Get-Digest -Path $stagedCollector) -ne $ExpectedSha256.ToLowerInvariant()) { throw 'the copy does not match the expected digest' }
        [IO.Directory]::Move($staging, $Final)
    } catch {
        $reason = $_.Exception.Message
        if ([IO.File]::Exists($stagedCollector)) { [IO.File]::Delete($stagedCollector) }
        if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging) }
        if ([IO.Directory]::Exists($Final)) {
            throw 'another installation created the snapshot directory first; nothing of this run remains, run install again to update it'
        }
        throw $reason
    }
}

function Install-Collector {
    if (-not $CollectorSource -or -not $ExpectedSha256) { throw 'CollectorSource and ExpectedSha256 are required to install' }
    $full = Resolve-SnapshotDirectory
    $collectorPath = Join-Path $full $collectorName
    $stagedCollector = Join-Path $full $stagedCollectorName
    $launcherPath = Join-Path $full $launcherName
    $stagedLauncher = Join-Path $full $stagedLauncherName
    $definition = Invoke-Step 'build the scheduled task definition' {
        $text = New-TaskDefinition -CollectorPath $collectorPath -SnapshotDirectory $full
        [void][xml]$text
        $text
    }
    Assert-TaskOwnedOrAbsent -CollectorPath $collectorPath -SnapshotDirectory $full
    $lock = $null
    $resumeTask = $false
    try {
        if ([IO.Directory]::Exists($full)) {
            Assert-DirectoryOwned -Path $full
            $lock = Invoke-Step 'take the installation lock' { Enter-InstallLock -Path $full }
            Assert-DirectoryOwned -Path $full
            Assert-TaskOwnedOrAbsent -CollectorPath $collectorPath -SnapshotDirectory $full
            Invoke-Step 'stage and verify the new collector script' {
                if ([IO.File]::Exists($stagedCollector)) { [IO.File]::Delete($stagedCollector) }
                [IO.File]::Copy($CollectorSource, $stagedCollector)
                if ((Get-Digest -Path $stagedCollector) -ne $ExpectedSha256.ToLowerInvariant()) { throw 'the copy does not match the expected digest' }
            }
        } else {
            Invoke-Step 'create the restricted snapshot directory with the verified collector' -Applies {
                New-RestrictedDirectory -Final $full
            }
            $lock = Invoke-Step 'take the installation lock' { Enter-InstallLock -Path $full }
        }
        Assert-TaskOwnedOrAbsent -CollectorPath $collectorPath -SnapshotDirectory $full
        Invoke-Step 'build the windowless collector launcher' {
            if ([IO.File]::Exists($stagedLauncher)) { [IO.File]::Delete($stagedLauncher) }
            New-CollectorLauncher -Path $stagedLauncher
        }
        $existing = Find-TaskByName
        if ($null -ne $existing) {
            if ($existing.Settings.Enabled) {
                Invoke-Step 'suspend the collector schedule' -Applies {
                    Disable-ScheduledTask -InputObject $existing | Out-Null
                }
                $resumeTask = $true
            }
            Invoke-Step 'stop the running collector and drain its writer' -Applies { Stop-OwnTask -SnapshotDirectory $full }
        }
        $snapshot = Join-Path $full $SnapshotName
        $previousWrite = if ([IO.File]::Exists($snapshot)) {
            ([DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($snapshot))).ToUnixTimeSeconds()
        } else { 0 }
        if ([IO.File]::Exists($stagedCollector)) {
            Invoke-Step 'install collector.ps1' -Applies {
                if ([IO.File]::Exists($collectorPath)) {
                    [IO.File]::Replace($stagedCollector, $collectorPath, [NullString]::Value)
                } else {
                    [IO.File]::Move($stagedCollector, $collectorPath)
                }
            }
        }
        Invoke-Step 'install the windowless collector launcher' -Applies {
            if ([IO.File]::Exists($launcherPath)) {
                [IO.File]::Replace($stagedLauncher, $launcherPath, [NullString]::Value)
            } else {
                [IO.File]::Move($stagedLauncher, $launcherPath)
            }
        }
        Invoke-Step 'register the scheduled task' -Applies {
            [void](Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $definition -Force)
        }
        $resumeTask = $false
        Invoke-Step 'start the scheduled task' -Applies { Start-ScheduledTask -TaskName $TaskName -TaskPath '\' }
        return $previousWrite
    } finally {
        if ($null -ne $lock) {
            if ($resumeTask) {
                try {
                    Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' | Out-Null
                    Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
                } catch {
                    [Console]::Error.WriteLine('could not resume the previous collector task: ' + $_.Exception.Message)
                }
            }
            if ([IO.File]::Exists($stagedCollector)) { [IO.File]::Delete($stagedCollector) }
            if ([IO.File]::Exists($stagedLauncher)) { [IO.File]::Delete($stagedLauncher) }
            $lock.Dispose()
        }
    }
}

function Uninstall-Collector {
    $full = Resolve-SnapshotDirectory
    $collectorPath = Join-Path $full $collectorName
    $exists = [IO.Directory]::Exists($full)
    Assert-TaskOwnedOrAbsent -CollectorPath $collectorPath -SnapshotDirectory $full
    if ($exists) { Assert-DirectoryOwned -Path $full }
    $lock = $null
    try {
        if ($exists) {
            $lock = Invoke-Step 'take the installation lock' { Enter-InstallLock -Path $full }
            Assert-DirectoryOwned -Path $full
            Assert-TaskOwnedOrAbsent -CollectorPath $collectorPath -SnapshotDirectory $full
        }
        if ($null -ne (Find-TaskByName)) {
            Invoke-Step 'suspend the collector schedule' -Applies {
                Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' | Out-Null
            }
            Invoke-Step 'stop and unregister the collector task' -Applies {
                Stop-OwnTask -SnapshotDirectory $full
                Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
            }
        }
        if ($exists) {
            Invoke-Step 'remove the collector files' -Applies {
                foreach ($name in @($collectorName, $stagedCollectorName, $launcherName, $stagedLauncherName, $collectorLockName, $SnapshotName, ($SnapshotName + '.tmp'))) {
                    $file = Join-Path $full $name
                    if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
                }
            }
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
    if ($exists) {
        Invoke-Step 'remove the lock file and the empty snapshot directory' -Applies {
            $lockFile = Join-Path $full $installLockName
            if ([IO.File]::Exists($lockFile)) { [IO.File]::Delete($lockFile) }
            if ([IO.Directory]::GetFileSystemEntries($full).Length -eq 0) { [IO.Directory]::Delete($full) }
        }
    }
}

try {
    switch ($Action) {
        'install' { [Console]::Out.WriteLine((Install-Collector)) }
        'uninstall' { Uninstall-Collector }
    }
    if ($Action -eq 'status') {
        [Console]::Out.WriteLine((Get-CollectorStatus | ConvertTo-Json -Compress))
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($script:applied.Count -gt 0) {
        [Console]::Error.WriteLine('already applied before the failure: ' + ($script:applied -join '; '))
    }
    exit 1
}

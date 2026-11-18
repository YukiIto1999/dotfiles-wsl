[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$SnapshotName,

    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 10,

    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$schemaVersion = 1
$maximumConsecutiveFailures = 6
$replaceAttempts = 3
$replaceRetryMilliseconds = 100

if (-not [Environment]::Is64BitProcess) {
    [Console]::Error.WriteLine('the collector requires a 64-bit PowerShell')
    exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DotfilesPerformanceInfo
{
    [StructLayout(LayoutKind.Sequential)]
    private struct PERFORMANCE_INFORMATION
    {
        public uint cb;
        public UIntPtr CommitTotal;
        public UIntPtr CommitLimit;
        public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal;
        public UIntPtr PhysicalAvailable;
        public UIntPtr SystemCache;
        public UIntPtr KernelTotal;
        public UIntPtr KernelPaged;
        public UIntPtr KernelNonpaged;
        public UIntPtr PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPerformanceInfo(ref PERFORMANCE_INFORMATION information, uint size);

    public static ulong[] Read()
    {
        PERFORMANCE_INFORMATION information = new PERFORMANCE_INFORMATION();
        information.cb = (uint)Marshal.SizeOf(typeof(PERFORMANCE_INFORMATION));
        if (!GetPerformanceInfo(ref information, information.cb))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ulong page = information.PageSize.ToUInt64();
        return new ulong[]
        {
            information.PhysicalTotal.ToUInt64() * page,
            information.PhysicalAvailable.ToUInt64() * page,
            information.CommitTotal.ToUInt64() * page,
            information.CommitLimit.ToUInt64() * page
        };
    }
}
'@

function Write-Snapshot {
    param([string]$Path, [string]$Content)

    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
    for ($attempt = 1; ; $attempt++) {
        try {
            if ([IO.File]::Exists($Path)) {
                [IO.File]::Replace($temporary, $Path, [NullString]::Value)
            } else {
                [IO.File]::Move($temporary, $Path)
            }
            break
        } catch [IO.IOException] {
            if ($attempt -ge $replaceAttempts) { throw }
            Start-Sleep -Milliseconds $replaceRetryMilliseconds
        }
    }
}

$sizeFactors = @{ B = 1; K = 1KB; KB = 1KB; M = 1MB; MB = 1MB; G = 1GB; GB = 1GB; T = 1TB; TB = 1TB }

function Read-WslConfig {
    $unreadable = [ordered]@{ state = 'unreadable'; memoryBytes = $null; processors = $null }
    try {
        $profileDirectory = $env:USERPROFILE
        if (-not $profileDirectory) { return $unreadable }
        $path = Join-Path $profileDirectory '.wslconfig'
        if (-not [IO.File]::Exists($path)) {
            return [ordered]@{ state = 'missing'; memoryBytes = $null; processors = $null }
        }
        $values = @{}
        $section = ''
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            $text = $line.TrimStart()
            if ($text -match '^\[([A-Za-z][A-Za-z0-9]*)\]\s*(#.*)?$') {
                $section = $Matches[1].ToLowerInvariant()
            } elseif ($text.StartsWith('[')) {
                $section = ''
            } elseif ($section -and $text -match '^([A-Za-z][A-Za-z0-9]*)\s*=\s*([^#]*)') {
                $name = $section + '.' + $Matches[1].ToLowerInvariant()
                if (-not $values.ContainsKey($name)) { $values[$name] = $Matches[2].Replace('"', '').TrimEnd() }
            }
        }
        $memoryBytes = $null
        if ($values.ContainsKey('wsl2.memory') -and $values['wsl2.memory'] -cmatch '^([0-9]{1,15})(B|K|KB|M|MB|G|GB|T|TB)?$') {
            $number = [decimal]$Matches[1]
            $unit = $Matches[2]
            $bytes = $number * $(if ($unit) { $sizeFactors[$unit] } else { 1 })
            if ($bytes -gt 0 -and $bytes -le 9007199254740991) { $memoryBytes = [long]$bytes }
        }
        $processors = $null
        if ($values.ContainsKey('wsl2.processors') -and $values['wsl2.processors'] -match '^[0-9]{1,6}$' -and [int]$values['wsl2.processors'] -gt 0) {
            $processors = [int]$values['wsl2.processors']
        }
        return [ordered]@{ state = 'read'; memoryBytes = $memoryBytes; processors = $processors }
    } catch {
        return $unreadable
    }
}

# 一部の process だけを合計すると VM の commit が小さく見えて増やせる余地が過大になるため、読取りに失敗した場合は合計せず $null を返す。
# vmmem 系の process が無い場合も $null で、入場は需要の全量を数える。vmmemWSL と vmmem の両方を合計するのは、
# 他の Hyper-V VM の分だけ余地が小さく見える保守側の誤差にするため
function Read-WslVmCommitBytes {
    try {
        $total = [long]0
        $count = 0
        foreach ($process in @(Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue)) {
            $total += [long]$process.PrivateMemorySize64
            $count++
        }
        if ($count -eq 0) { return $null }
        return $total
    } catch {
        return $null
    }
}

if (-not [IO.Directory]::Exists($Directory)) {
    [Console]::Error.WriteLine('the snapshot directory does not exist: ' + $Directory)
    exit 1
}
$target = Join-Path $Directory $snapshotName
$collectorLock = $null
try {
    $collectorLock = [IO.File]::Open((Join-Path $Directory 'collector.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    $code = $_.Exception.HResult -band 0xFFFF
    if ($code -ne 32 -and $code -ne 33) { throw }
    [Console]::Error.WriteLine('another collector already serves this directory; exiting')
    exit 0
}

$exitCode = 0
try {
    if ([IO.File]::Exists($target + '.tmp')) { [IO.File]::Delete($target + '.tmp') }
    $sequence = [long]0
    $failures = 0
    while ($true) {
        try {
            $sample = [DotfilesPerformanceInfo]::Read()
            $sequence++
            $record = [ordered]@{
                schemaVersion          = $schemaVersion
                sampledAt              = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                sequence               = $sequence
                intervalSeconds        = $IntervalSeconds
                physicalTotalBytes     = [long]$sample[0]
                physicalAvailableBytes = [long]$sample[1]
                commitUsedBytes        = [long]$sample[2]
                commitLimitBytes       = [long]$sample[3]
                wslConfig              = Read-WslConfig
                wslVmCommitBytes       = Read-WslVmCommitBytes
            }
            Write-Snapshot -Path $target -Content ($record | ConvertTo-Json -Compress -Depth 4)
            $failures = 0
        } catch {
            if ($Once) { throw }
            $failures++
            if ($failures -ge $maximumConsecutiveFailures) {
                [Console]::Error.WriteLine('the collector gave up after repeated failures: ' + $_.Exception.Message)
                $exitCode = 1
                break
            }
        }
        if ($Once) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $collectorLock.Dispose()
}
exit $exitCode

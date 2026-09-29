<#
.SYNOPSIS
    Query the API and report whether the answer came from Redis or MySQL, and how long it took.

.DESCRIPTION
    Every response carries where it was served from and the time spent in each
    tier, so a single request already tells you whether the cache is doing its
    job. -Compare runs the three interesting cases back to back.

.PARAMETER Id
    Product id to read. Seeded data covers 1..50000.

.PARAMETER BaseUrl
    ALB URL. Read from 'terraform output -raw base_url' when omitted.

.PARAMETER NoCache
    Append &nocache=1 so the read always goes to MySQL.

.PARAMETER Flush
    Empty the cache before the request.

.PARAMETER Compare
    Flush, then read the same id three ways (miss, hit, bypass) and tabulate.

.PARAMETER Repeat
    Issue the request this many times.

.EXAMPLE
    .\scripts\Test-Cache.ps1 -Id 42

.EXAMPLE
    .\scripts\Test-Cache.ps1 -Id 42 -Compare

.EXAMPLE
    .\scripts\Test-Cache.ps1 -Id 7 -Repeat 5
#>
[CmdletBinding()]
param(
    [int]    $Id = 42,
    [string] $BaseUrl,
    [switch] $NoCache,
    [switch] $Flush,
    [switch] $Compare,
    [int]    $Repeat = 1
)

$ErrorActionPreference = 'Stop'

function Resolve-BaseUrl {
    param([string] $Provided)

    if ($Provided) { return $Provided.TrimEnd('/') }

    $tfDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'
    if (-not (Test-Path $tfDir)) {
        throw "No -BaseUrl given and no terraform directory at $tfDir."
    }

    Push-Location $tfDir
    try {
        $url = (& terraform output -raw base_url 2>$null)
    } finally {
        Pop-Location
    }

    if (-not $url) {
        throw "Could not read base_url from terraform output. Has apply finished? Otherwise pass -BaseUrl http://<alb-dns>."
    }

    # terraform.exe terminates its output with CR, which corrupts the URL.
    return $url.Trim().TrimEnd('/')
}

function Invoke-Product {
    param([string] $Base, [int] $ProductId, [bool] $Bypass)

    $url = "$Base/product?id=$ProductId"
    if ($Bypass) { $url += '&nocache=1' }

    # The API times its own work; this also measures the round trip, so the gap
    # between the two is network plus ALB and Lambda overhead.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -TimeoutSec 60
    $sw.Stop()

    if ($res.StatusCode -ne 200) {
        return [pscustomobject]@{
            Id       = $ProductId
            Source   = "HTTP $($res.StatusCode)"
            Cache    = '-'
            DbMs     = $null
            CacheMs  = $null
            ServerMs = $null
            ClientMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            Name     = $null
        }
    }

    $body = $res.Content | ConvertFrom-Json

    [pscustomobject]@{
        Id       = $ProductId
        Source   = $body.source
        Cache    = $body.cache
        DbMs     = $body.db_ms
        CacheMs  = $body.cache_ms
        ServerMs = $body.total_ms
        ClientMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        Name     = $body.product.name
    }
}

function Format-Result {
    param([pscustomobject] $R)

    $color = switch ($R.Cache) {
        'HIT'    { 'Green' }
        'MISS'   { 'Yellow' }
        'BYPASS' { 'Red' }
        default  { 'Gray' }
    }

    Write-Host ('  {0,-7}' -f $R.Cache) -ForegroundColor $color -NoNewline
    Write-Host ('served from {0,-9}  db {1,8} ms   total {2,8} ms   round trip {3,8} ms' -f `
        $R.Source, $R.DbMs, $R.ServerMs, $R.ClientMs)
}

# ---------------------------------------------------------------------------

$base = Resolve-BaseUrl -Provided $BaseUrl
Write-Host "Target: $base" -ForegroundColor Cyan
Write-Host ''

if ($Compare) {
    Write-Host "Reading product $Id three ways" -ForegroundColor Cyan
    Write-Host ''

    Invoke-WebRequest -Uri "$base/flush" -TimeoutSec 30 | Out-Null

    $miss   = Invoke-Product -Base $base -ProductId $Id -Bypass $false
    $hit    = Invoke-Product -Base $base -ProductId $Id -Bypass $false
    $bypass = Invoke-Product -Base $base -ProductId $Id -Bypass $true

    Format-Result $miss
    Format-Result $hit
    Format-Result $bypass

    Write-Host ''
    if ($hit.ServerMs -gt 0) {
        $speedup = [math]::Round($miss.ServerMs / $hit.ServerMs, 1)
        Write-Host "  The cached read is ${speedup}x faster." -ForegroundColor Green
        Write-Host "  On the hit, db time is $($hit.DbMs) ms - MySQL was never touched." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  MISS   first read after a flush: Redis is empty, so it costs a full MySQL query,' -ForegroundColor DarkGray
    Write-Host '         and the result is written back to the cache.' -ForegroundColor DarkGray
    Write-Host '  HIT    same id again: answered from Redis alone.' -ForegroundColor DarkGray
    Write-Host '  BYPASS nocache=1: identical query, cache deliberately skipped. The control.' -ForegroundColor DarkGray
    return
}

if ($Flush) {
    Invoke-WebRequest -Uri "$base/flush" -TimeoutSec 30 | Out-Null
    Write-Host '  cache flushed' -ForegroundColor DarkGray
}

$results = 1..$Repeat | ForEach-Object {
    $r = Invoke-Product -Base $base -ProductId $Id -Bypass $NoCache.IsPresent
    Format-Result $r
    $r
}

if ($Repeat -gt 1) {
    $avg = ($results | Measure-Object -Property ServerMs -Average).Average
    Write-Host ''
    Write-Host ('  average server time {0:N2} ms over {1} requests' -f $avg, $Repeat) -ForegroundColor Cyan
}

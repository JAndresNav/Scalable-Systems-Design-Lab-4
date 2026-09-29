<#
.SYNOPSIS
    Verify a freshly applied stack: connectivity, seed data, cache-aside behaviour, error handling.

.DESCRIPTION
    Eight requests, one per assertion. This is a pre-flight check, not a
    benchmark: it confirms every code path does what it should before you start
    measuring anything. Exits non-zero if any assertion fails.

.PARAMETER BaseUrl
    ALB URL. Read from 'terraform output -raw base_url' when omitted.

.EXAMPLE
    .\scripts\Test-Deployment.ps1
#>
[CmdletBinding()]
param([string] $BaseUrl)

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-Equals {
    param([string] $Label, $Expected, $Actual)

    if ("$Actual" -like "*$Expected*") {
        Write-Host '  PASS  ' -ForegroundColor Green -NoNewline
        Write-Host ('{0,-34} {1}' -f $Label, $Actual)
        $script:Passed++
    } else {
        Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline
        Write-Host ('{0,-34} expected {1}, got {2}' -f $Label, $Expected, $Actual)
        $script:Failed++
    }
}

function Resolve-BaseUrl {
    param([string] $Provided)

    if ($Provided) { return $Provided.TrimEnd('/') }

    $tfDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'
    Push-Location $tfDir
    try { $url = (& terraform output -raw base_url 2>$null) } finally { Pop-Location }

    if (-not $url) {
        throw 'Could not read base_url from terraform output. Pass -BaseUrl http://<alb-dns> instead.'
    }
    # terraform.exe terminates its output with CR, which corrupts the URL.
    return $url.Trim().TrimEnd('/')
}

function Get-Api {
    param([string] $Url)
    Invoke-WebRequest -Uri $Url -SkipHttpErrorCheck -TimeoutSec 60
}

# ---------------------------------------------------------------------------

$base = Resolve-BaseUrl -Provided $BaseUrl
Write-Host "Target: $base" -ForegroundColor Cyan
Write-Host ''

Write-Host '1. Reachability'
$health = Get-Api "$base/health"
Assert-Equals 'ALB answers /health' 200 $health.StatusCode

if ($health.StatusCode -ne 200) {
    Write-Host ''
    Write-Host 'The load balancer is not answering. Usual causes:' -ForegroundColor Yellow
    Write-Host '  - apply has not finished, or the target group attachment failed'
    Write-Host '  - your address is outside allowed_cidr'
    exit 1
}

Write-Host ''
Write-Host '2. Data was seeded by terraform apply'
$stats = (Get-Api "$base/stats").Content | ConvertFrom-Json
Assert-Equals 'products table populated' 50000  $stats.database.products
Assert-Equals 'reviews table populated'  150000 $stats.database.reviews
Assert-Equals 'database reachable'       'True' $stats.database.reachable
Assert-Equals 'cache reachable'          'True' $stats.cache.reachable

Write-Host ''
Write-Host '3. Cache-aside behaviour'
Get-Api "$base/flush" | Out-Null

$miss = Get-Api "$base/product?id=42"
Assert-Equals 'first read is a MISS' 'MISS' $miss.Headers['X-Cache']

$hit = Get-Api "$base/product?id=42"
Assert-Equals 'second read is a HIT' 'HIT' $hit.Headers['X-Cache']

$bypass = Get-Api "$base/product?id=42&nocache=1"
Assert-Equals 'nocache=1 bypasses cache' 'BYPASS' $bypass.Headers['X-Cache']

# A cache that returns different data from the database is worse than no cache.
$missBody = ($miss.Content | ConvertFrom-Json).product | ConvertTo-Json -Compress
$hitBody  = ($hit.Content  | ConvertFrom-Json).product | ConvertTo-Json -Compress
Assert-Equals 'cache and DB agree' $missBody $hitBody

Write-Host ''
Write-Host '4. The cache is actually faster'
$missMs   = ($miss.Content   | ConvertFrom-Json).total_ms
$hitMs    = ($hit.Content    | ConvertFrom-Json).total_ms
$bypassMs = ($bypass.Content | ConvertFrom-Json).total_ms

Write-Host ('  cache miss   {0,8} ms' -f $missMs)
Write-Host ('  cache hit    {0,8} ms' -f $hitMs)
Write-Host ('  bypass       {0,8} ms' -f $bypassMs)

if ($hitMs -gt 0) {
    $speedup = [math]::Round($missMs / $hitMs, 1)
    Write-Host ('  speedup      {0,8}x' -f $speedup)
    Assert-Equals 'hit is >5x faster than miss' 'True' ($speedup -gt 5)
}

Write-Host ''
Write-Host '5. Error handling'
Assert-Equals 'unknown route returns 404'   404 (Get-Api "$base/does-not-exist").StatusCode
Assert-Equals 'missing product returns 404' 404 (Get-Api "$base/product?id=99999999").StatusCode

Write-Host ''
Write-Host '=============================================='
$summaryColor = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ('  {0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor $summaryColor
Write-Host '=============================================='

if ($script:Failed -ne 0) { exit 1 }

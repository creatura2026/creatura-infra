<#
.SYNOPSIS
  Builds the Creatura web apps and publishes them to the S3 bucket behind CloudFront.

.DESCRIPTION
  Layout published to the bucket:
    /            player PWA      (apps/player, base path /)
    /admin/      admin dashboard (apps/admin, built with base path /admin/)
    /sprites/    managed by Terraform, never touched by this script
    /guides/     static HTML user guides from guides/ in this repository (optional: skipped
                 if the folder does not exist). images/ subfolders are uploaded with a
                 one-year immutable cache; HTML files with no-cache.
    /telechargements/  Windows app (apps/desktop): both exe files and latest.json, read by
                 the home page to offer the download. The exe calls the API of site_url
                 (simulated API with -Api mock).
                 Android app (apps/mobile): the APK and android.json, read the same way on
                 phones. The APK opens site_url. Built when Java and the Android SDK are found.

  Hashed files under assets/ and admin/assets/ are uploaded first with a one-year
  immutable cache. Everything else (index.html, service worker, manifest, icons)
  is uploaded last with "no-cache" so that a new release is picked up immediately.
  Old hashed assets are not deleted, so a failed release never breaks the live site.

.PARAMETER AppPath
  Path to the creatura-app repository. Defaults to a sibling folder of this repository.

.PARAMETER AwsProfile
  AWS CLI profile to use. Defaults to the current environment / default profile.

.PARAMETER Bucket
  Target bucket. Defaults to the "bucket_name" output of the infra/ Terraform stack.

.PARAMETER DistributionId
  CloudFront distribution to invalidate. Defaults to the "cloudfront_distribution_id" output.

.PARAMETER Api
  "mock" (default): the apps use their simulated API, stored in the browser. Use it as long
  as the backend is not deployed: without a server, every /api call fails (POST answers 403).
  "server": the apps call the real backend on /api/v1, on the same domain.

.PARAMETER SkipBuild
  Reuse the content already staged in .deploy/site instead of building again (and the exe and
  APK already built in creatura-app/apps/*/release).

.PARAMETER SkipDesktop
  Neither build nor publish the Windows app.

.PARAMETER DesktopDir
  Exe files and latest.json already built elsewhere (e.g. the app CI artifact): published as is.

.PARAMETER SkipMobile
  Neither build nor publish the Android app.

.PARAMETER MobileDir
  APK and android.json already built elsewhere (e.g. the app CI artifact): published as is.

.PARAMETER StageOnly
  Build and stage the site locally, print what would be uploaded, and stop. Nothing is sent to AWS.

.EXAMPLE
  .\scripts\deploy-frontend.ps1 -StageOnly

.EXAMPLE
  .\scripts\deploy-frontend.ps1
#>
[CmdletBinding()]
param(
  [string]$AppPath = (Join-Path $PSScriptRoot '..\..\creatura-app'),
  [string]$AwsProfile,
  [string]$Bucket,
  [string]$DistributionId,
  [ValidateSet('mock', 'server')][string]$Api = 'mock',
  [switch]$SkipBuild,
  [switch]$SkipDesktop,
  [string]$DesktopDir,
  [switch]$SkipMobile,
  [string]$MobileDir,
  [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InfraDir = Join-Path $RepoRoot 'infra'
$StageDir = Join-Path $RepoRoot '.deploy\site'

$ImmutableCache = 'public, max-age=31536000, immutable'
$RevalidateCache = 'no-cache'

# Explicit content types: the AWS CLI guesses them from the Windows registry, which is
# unreliable (a module script served as text/plain is rejected by browsers).
$ContentTypes = @{
  '.html'        = 'text/html; charset=utf-8'
  '.js'          = 'text/javascript; charset=utf-8'
  '.mjs'         = 'text/javascript; charset=utf-8'
  '.css'         = 'text/css; charset=utf-8'
  '.json'        = 'application/json'
  '.map'         = 'application/json'
  '.webmanifest' = 'application/manifest+json'
  '.txt'         = 'text/plain; charset=utf-8'
  '.xml'         = 'application/xml'
  '.svg'         = 'image/svg+xml'
  '.png'         = 'image/png'
  '.jpg'         = 'image/jpeg'
  '.jpeg'        = 'image/jpeg'
  '.gif'         = 'image/gif'
  '.webp'        = 'image/webp'
  '.avif'        = 'image/avif'
  '.ico'         = 'image/x-icon'
  '.woff'        = 'font/woff'
  '.woff2'       = 'font/woff2'
  '.ttf'         = 'font/ttf'
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  # Windows PowerShell 5.1 turns stderr lines of native tools into errors when output is
  # redirected. Only the exit code decides whether the command failed.
  $ErrorActionPreference = 'Continue'
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) {
    $ErrorActionPreference = 'Stop'
    throw "'$Exe $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
  }
}

function Get-TerraformOutput {
  param([Parameter(Mandatory)][string]$Name)
  $ErrorActionPreference = 'Continue'
  $value = & terraform "-chdir=$InfraDir" output -raw $Name
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
    $ErrorActionPreference = 'Stop'
    throw "Cannot read Terraform output '$Name'. Apply the infra/ stack first, or pass -Bucket and -DistributionId."
  }
  return $value.Trim()
}

if ($AwsProfile) {
  $env:AWS_PROFILE = $AwsProfile
}

# --- 1. Build and stage ---------------------------------------------------------------

if (-not $SkipBuild) {
  if (-not (Test-Path (Join-Path $AppPath 'pnpm-workspace.yaml'))) {
    throw "creatura-app not found at '$AppPath'. Pass -AppPath."
  }
  $AppPath = (Resolve-Path $AppPath).Path

  if (Test-Path $StageDir) {
    Remove-Item -Recurse -Force $StageDir
  }
  New-Item -ItemType Directory -Force $StageDir | Out-Null
  $AdminStageDir = Join-Path $StageDir 'admin'

  # Vite reads VITE_* variables from the environment; the apps switch API on this one.
  $previousApiMock = $env:VITE_API_MOCK
  $env:VITE_API_MOCK = if ($Api -eq 'mock') { 'true' } else { 'false' }
  Write-Host "==> API mode: $Api" -ForegroundColor Cyan

  Push-Location $AppPath
  try {
    Write-Host '==> Installing dependencies' -ForegroundColor Cyan
    Invoke-Native pnpm @('install', '--frozen-lockfile')

    Write-Host '==> Building the player PWA (base /)' -ForegroundColor Cyan
    Invoke-Native pnpm @('--filter', 'player', 'run', 'build')
    Copy-Item -Path (Join-Path $AppPath 'apps\player\dist\*') -Destination $StageDir -Recurse -Force

    Write-Host '==> Building the admin dashboard (base /admin/)' -ForegroundColor Cyan
    Invoke-Native pnpm @('--filter', 'admin', 'run', 'type-check')
    Invoke-Native pnpm @('--filter', 'admin', 'exec', 'vite', 'build', '--base=/admin/', '--outDir', $AdminStageDir, '--emptyOutDir')
  }
  finally {
    Pop-Location
    $env:VITE_API_MOCK = $previousApiMock
  }
}

foreach ($required in @('index.html', 'admin\index.html')) {
  if (-not (Test-Path (Join-Path $StageDir $required))) {
    throw "Staged site is incomplete: '$required' is missing from $StageDir."
  }
}

# --- 2. Plan the upload ---------------------------------------------------------------

$stagePrefix = $StageDir.TrimEnd('\') + '\'
$files = Get-ChildItem -Path $StageDir -Recurse -File | ForEach-Object {
  $key = $_.FullName.Substring($stagePrefix.Length).Replace('\', '/')
  $extension = $_.Extension.ToLowerInvariant()
  if (-not $ContentTypes.ContainsKey($extension)) {
    throw "No content type known for '$key'. Add '$extension' to `$ContentTypes in this script."
  }
  if ($key -like 'sprites/*' -or $key -like '.creatura/*') {
    throw "'$key' would overwrite a path that is not owned by the frontend."
  }
  [pscustomobject]@{
    Key       = $key
    Extension = $extension
    Immutable = ($key -like 'assets/*' -or $key -like 'admin/assets/*')
    Bytes     = $_.Length
  }
}

# Hashed assets first, entry points (html) last.
$groups = $files | Group-Object Immutable, Extension | Sort-Object `
  @{ Expression = { -not $_.Group[0].Immutable } }, `
  @{ Expression = { $_.Group[0].Extension -eq '.html' } }, `
  @{ Expression = { $_.Group[0].Extension } }

Write-Host ''
Write-Host ("Staged {0} files ({1:N0} KB) in {2}" -f $files.Count, (($files | Measure-Object Bytes -Sum).Sum / 1KB), $StageDir)
foreach ($group in $groups) {
  $first = $group.Group[0]
  $cache = if ($first.Immutable) { 'immutable' } else { 'no-cache ' }
  Write-Host ("  {0}  {1,-13} {2,3} file(s)  {3}" -f $cache, $first.Extension, $group.Count, $ContentTypes[$first.Extension])
}

if ($StageOnly) {
  Write-Host ''
  Write-Host 'StageOnly: nothing was sent to AWS.' -ForegroundColor Yellow
  return
}

# --- 3. Upload and invalidate ---------------------------------------------------------

if (-not $Bucket) { $Bucket = Get-TerraformOutput 'bucket_name' }
if (-not $DistributionId) { $DistributionId = Get-TerraformOutput 'cloudfront_distribution_id' }

Write-Host ''
Write-Host "==> Uploading to s3://$Bucket" -ForegroundColor Cyan
foreach ($group in $groups) {
  $first = $group.Group[0]
  $pattern = "*$($first.Extension)"
  $arguments = @('s3', 'cp', $StageDir, "s3://$Bucket", '--recursive', '--only-show-errors', '--exclude', '*')
  if ($first.Immutable) {
    $arguments += @('--include', "assets/$pattern", '--include', "admin/assets/$pattern", '--cache-control', $ImmutableCache)
  }
  else {
    $arguments += @('--include', $pattern, '--exclude', 'assets/*', '--exclude', 'admin/assets/*', '--cache-control', $RevalidateCache)
  }
  $arguments += @('--content-type', $ContentTypes[$first.Extension])
  Invoke-Native aws $arguments
  Write-Host ("  uploaded {0,3} {1}" -f $group.Count, $first.Extension)
}

# --- 4. Windows app -------------------------------------------------------------------

if (-not $SkipDesktop) {
  $ReleaseDir = if ($DesktopDir) { $DesktopDir } else { Join-Path $AppPath 'apps\desktop\release' }
  # Exe provided (-DesktopDir): already built, nothing to rebuild.
  if (-not $SkipBuild -and -not $DesktopDir) {
    Push-Location $AppPath
    try {
      if ($Api -eq 'mock') {
        Write-Host '==> Building the Windows app (simulated API)' -ForegroundColor Cyan
        Invoke-Native pnpm @('desktop:demo')
      }
      else {
        # Same address as the site: the custom domain when there is one, CloudFront otherwise.
        $apiUrl = (Get-TerraformOutput 'site_url').TrimEnd('/')
        Write-Host "==> Building the Windows app (API $apiUrl)" -ForegroundColor Cyan
        Invoke-Native pnpm @('desktop', '--api', $apiUrl)
      }
    }
    finally {
      Pop-Location
    }
  }
  $manifest = Join-Path $ReleaseDir 'latest.json'
  if (-not (Test-Path $manifest)) {
    # No exe built (e.g. CI with -SkipBuild: the artifact only holds the front, the exe comes from
    # another job). The site is still published; an exe already online, if any, is kept.
    Write-Warning "Windows app not published: latest.json is missing from $ReleaseDir. Build the exe (pnpm desktop in creatura-app) to offer it."
  }
  else {
    Write-Host "==> Uploading the Windows app to s3://$Bucket/telechargements/" -ForegroundColor Cyan
    # The exe files first: latest.json must never point to a file that is not uploaded yet.
    Invoke-Native aws @('s3', 'cp', $ReleaseDir, "s3://$Bucket/telechargements/", '--recursive', '--only-show-errors',
      '--exclude', '*', '--include', 'Creatura-*.exe',
      '--content-type', 'application/vnd.microsoft.portable-executable', '--cache-control', $RevalidateCache)
    Invoke-Native aws @('s3', 'cp', $manifest, "s3://$Bucket/telechargements/latest.json", '--only-show-errors',
      '--content-type', 'application/json', '--cache-control', $RevalidateCache)
    $version = (Get-Content $manifest -Raw | ConvertFrom-Json).version
    Write-Host "  uploaded Windows app $version"
  }
}


# --- 5. Android app -------------------------------------------------------------------

# Gradle needs Java and the Android SDK (installed by Android Studio, or ANDROID_HOME).
function Test-AndroidBuild {
  if (-not (Get-Command java -ErrorAction SilentlyContinue)) { return $false }
  $candidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
  if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
  foreach ($dir in $candidates) {
    if ($dir -and (Test-Path $dir)) { return $true }
  }
  return $false
}

if (-not $SkipMobile) {
  $MobileRelease = if ($MobileDir) { $MobileDir } else { Join-Path $AppPath 'apps\mobile\release' }
  # APK provided (-MobileDir): already built, nothing to rebuild.
  if (-not $SkipBuild -and -not $MobileDir) {
    if (Test-AndroidBuild) {
      Push-Location $AppPath
      try {
        if ($Api -eq 'mock') {
          Write-Host '==> Building the Android app (simulated API)' -ForegroundColor Cyan
          Invoke-Native pnpm @('mobile:demo')
        }
        else {
          # The APK opens the site itself: the custom domain when there is one, CloudFront otherwise.
          $siteUrl = (Get-TerraformOutput 'site_url').TrimEnd('/')
          Write-Host "==> Building the Android app (site $siteUrl)" -ForegroundColor Cyan
          Invoke-Native pnpm @('mobile', '--url', $siteUrl)
        }
      }
      finally {
        Pop-Location
      }
    }
    else {
      Write-Warning 'Android app not built: Java 21 and the Android SDK are required. The site is still published; on phones the home page shows the app as coming soon.'
      $MobileRelease = $null
    }
  }
  if ($MobileRelease) {
    $androidManifest = Join-Path $MobileRelease 'android.json'
    if (-not (Test-Path $androidManifest)) {
      # No APK (e.g. CI: the Android job of the app is optional). An APK already online is kept.
      Write-Warning "Android app not published: android.json is missing from $MobileRelease. Build the APK (pnpm mobile in creatura-app) to offer it."
    }
    else {
      Write-Host "==> Uploading the Android app to s3://$Bucket/telechargements/" -ForegroundColor Cyan
      # The APK first: android.json must never point to a file that is not uploaded yet.
      Invoke-Native aws @('s3', 'cp', $MobileRelease, "s3://$Bucket/telechargements/", '--recursive', '--only-show-errors',
        '--exclude', '*', '--include', 'Creatura-*.apk',
        '--content-type', 'application/vnd.android.package-archive', '--cache-control', $RevalidateCache)
      Invoke-Native aws @('s3', 'cp', $androidManifest, "s3://$Bucket/telechargements/android.json", '--only-show-errors',
        '--content-type', 'application/json', '--cache-control', $RevalidateCache)
      $version = (Get-Content $androidManifest -Raw | ConvertFrom-Json).version
      Write-Host "  uploaded Android app $version"
    }
  }
}

# Without a published exe, the player app still requests /telechargements/latest.json on every
# visit: a "no release" manifest avoids that 404 (the front then hides the download section).
& aws s3api head-object --bucket $Bucket --key 'telechargements/latest.json' *> $null
if ($LASTEXITCODE -ne 0) {
  $placeholder = Join-Path ([System.IO.Path]::GetTempPath()) 'creatura-latest.json'
  [System.IO.File]::WriteAllText($placeholder, "{`n  `"available`": false`n}`n")
  Invoke-Native aws @('s3', 'cp', $placeholder, "s3://$Bucket/telechargements/latest.json", '--only-show-errors',
    '--content-type', 'application/json', '--cache-control', 'no-cache')
  Remove-Item $placeholder
}
# Same for the APK: without a published version, phones show the app as coming soon.
& aws s3api head-object --bucket $Bucket --key 'telechargements/android.json' *> $null
if ($LASTEXITCODE -ne 0) {
  $placeholder = Join-Path ([System.IO.Path]::GetTempPath()) 'creatura-android.json'
  [System.IO.File]::WriteAllText($placeholder, "{`n  `"available`": false`n}`n")
  Invoke-Native aws @('s3', 'cp', $placeholder, "s3://$Bucket/telechargements/android.json", '--only-show-errors',
    '--content-type', 'application/json', '--cache-control', 'no-cache')
  Remove-Item $placeholder
}

# --- 6. User guides ------------------------------------------------------------------

$GuidesDir = Join-Path $RepoRoot 'guides'
if (Test-Path $GuidesDir) {
  Write-Host "==> Uploading guides to s3://$Bucket/guides/" -ForegroundColor Cyan
  # Images first (immutable cache), HTML last (no-cache so updates are immediate).
  Invoke-Native aws @('s3', 'cp', $GuidesDir, "s3://$Bucket/guides/", '--recursive', '--only-show-errors',
    '--exclude', '*',
    '--include', '*/images/*.png', '--include', '*/images/*.jpg', '--include', '*/images/*.jpeg',
    '--include', '*/images/*.webp', '--include', '*/images/*.gif',
    '--cache-control', $ImmutableCache)
  Invoke-Native aws @('s3', 'cp', $GuidesDir, "s3://$Bucket/guides/", '--recursive', '--only-show-errors',
    '--exclude', '*', '--include', '*.html',
    '--cache-control', $RevalidateCache, '--content-type', 'text/html; charset=utf-8')
  Write-Host "  uploaded guides"
} else {
  Write-Host "No guides/ folder found — skipping." -ForegroundColor Yellow
}

Write-Host "==> Invalidating CloudFront distribution $DistributionId" -ForegroundColor Cyan
Invoke-Native aws @('cloudfront', 'create-invalidation', '--distribution-id', $DistributionId, '--paths', '/*', '--query', 'Invalidation.Id', '--output', 'text')

$domain = & aws cloudfront get-distribution --id $DistributionId --query 'Distribution.DomainName' --output text
Write-Host ''
Write-Host "Done. Player: https://$domain/   Admin: https://$domain/admin/   Guides: https://$domain/guides/" -ForegroundColor Green

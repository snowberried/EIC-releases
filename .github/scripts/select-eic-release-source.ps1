[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceDirectory,

  [Parameter(Mandatory = $true)]
  [string]$LatestVersion,

  [string]$RequestedRef = '',

  [switch]$ForcePublish,

  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'

function ConvertTo-StableVersion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,

    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  if ($Value -notmatch '^\d+\.\d+\.\d+$') {
    throw "$Label must be a stable semantic version (major.minor.patch): $Value"
  }

  return [version]$Value
}

function Invoke-GitText {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $SourceDirectory @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  return ($output -join "`n")
}

function Get-SourceCandidate {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RefName
  )

  $packageContent = Invoke-GitText -Arguments @('show', "${RefName}:package.json")
  $configContent = Invoke-GitText -Arguments @('show', "${RefName}:src-tauri/tauri.conf.json")
  $cargoContent = Invoke-GitText -Arguments @('show', "${RefName}:src-tauri/Cargo.toml")

  if ($null -eq $packageContent -or $null -eq $configContent -or $null -eq $cargoContent) {
    return $null
  }

  try {
    $packageVersion = [string]($packageContent | ConvertFrom-Json).version
    $configVersion = [string]($configContent | ConvertFrom-Json).version
  }
  catch {
    throw "Failed to read version metadata from $RefName`: $($_.Exception.Message)"
  }

  $cargoVersionMatch = [regex]::Match(
    $cargoContent,
    '(?m)^version\s*=\s*"([^"]+)"'
  )
  if (-not $cargoVersionMatch.Success) {
    throw "$RefName does not contain a package version in src-tauri/Cargo.toml."
  }
  $cargoVersion = $cargoVersionMatch.Groups[1].Value

  $parsedVersions = @(
    ConvertTo-StableVersion -Value $packageVersion -Label "$RefName package.json version"
    ConvertTo-StableVersion -Value $configVersion -Label "$RefName tauri.conf.json version"
    ConvertTo-StableVersion -Value $cargoVersion -Label "$RefName Cargo.toml version"
  )

  if ($packageVersion -ne $configVersion -or $packageVersion -ne $cargoVersion) {
    $highestDeclaredVersion = $parsedVersions | Sort-Object -Descending | Select-Object -First 1
    if ($highestDeclaredVersion -gt $script:ParsedLatestVersion) {
      throw "Version mismatch in release candidate $RefName`: package.json=$packageVersion, tauri.conf.json=$configVersion, Cargo.toml=$cargoVersion"
    }

    Write-Warning "Skipping stale mismatched ref $RefName`: package.json=$packageVersion, tauri.conf.json=$configVersion, Cargo.toml=$cargoVersion"
    return $null
  }

  $sha = Invoke-GitText -Arguments @('rev-parse', $RefName)
  $commitDateText = Invoke-GitText -Arguments @('show', '-s', '--format=%cI', $RefName)
  if ($null -eq $sha -or $null -eq $commitDateText) {
    throw "Failed to resolve commit metadata for $RefName."
  }

  return [PSCustomObject]@{
    Ref = $RefName
    Sha = $sha.Trim()
    Version = $parsedVersions[0]
    VersionText = $packageVersion
    CommitDate = [DateTimeOffset]::Parse($commitDateText.Trim())
  }
}

function Write-WorkflowOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
    Write-Output "$Name=$Value"
    return
  }

  "$Name=$Value" | Add-Content -Encoding UTF8 -LiteralPath $GitHubOutputPath
}

$script:ParsedLatestVersion = ConvertTo-StableVersion `
  -Value $LatestVersion `
  -Label 'Latest public release version'

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
  throw "Source directory does not exist: $SourceDirectory"
}

if ([string]::IsNullOrWhiteSpace($RequestedRef)) {
  $refs = @(
    & git -C $SourceDirectory for-each-ref `
      '--format=%(refname:short)' `
      'refs/remotes/origin'
  ) | Where-Object {
    $_ -and $_ -ne 'origin/HEAD'
  }
}
else {
  $refs = @($RequestedRef)
}

if ($refs.Count -eq 0) {
  throw 'No source refs were found.'
}

$candidates = foreach ($ref in $refs) {
  $candidate = Get-SourceCandidate -RefName $ref
  if ($null -ne $candidate) {
    $candidate
  }
}

if ($ForcePublish) {
  $selected = $candidates | Select-Object -First 1
}
else {
  $selected = $candidates |
    Where-Object { $_.Version -gt $script:ParsedLatestVersion } |
    Sort-Object `
      @{ Expression = 'Version'; Descending = $true }, `
      @{ Expression = 'CommitDate'; Descending = $true }, `
      @{ Expression = 'Ref'; Descending = $false } |
    Select-Object -First 1
}

if ($null -eq $selected) {
  Write-WorkflowOutput -Name 'should_publish' -Value 'false'
  Write-WorkflowOutput -Name 'app_version' -Value $LatestVersion
  Write-WorkflowOutput -Name 'source_ref' -Value ''
  Write-WorkflowOutput -Name 'source_sha' -Value ''
  Write-Output "No version newer than $LatestVersion was found."
  exit 0
}

Write-WorkflowOutput -Name 'should_publish' -Value 'true'
Write-WorkflowOutput -Name 'app_version' -Value $selected.VersionText
Write-WorkflowOutput -Name 'source_ref' -Value $selected.Ref
Write-WorkflowOutput -Name 'source_sha' -Value $selected.Sha
Write-Output "Selected $($selected.Ref) at $($selected.Sha) with version $($selected.VersionText); latest public release is $LatestVersion."

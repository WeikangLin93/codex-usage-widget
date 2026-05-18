param(
  [Parameter(Mandatory = $true)]
  [string]$Token,

  [string]$Owner = "WeikangLin93",
  [string]$Repo = "codex-usage-widget",
  [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot "VERSION") -Raw).Trim()
$tagName = "v$version"
$zipPath = Join-Path $repoRoot "dist\CodexUsageWidget-$version.zip"

if (-not (Test-Path $zipPath)) {
  throw "Release zip not found: $zipPath"
}

$headers = @{
  Authorization = "Bearer $Token"
  Accept = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-GitHubJson {
  param(
    [string]$Method,
    [string]$Uri,
    $Body = $null
  )

  $args = @{
    Method = $Method
    Uri = $Uri
    Headers = $headers
  }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 100
    $args.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $args.ContentType = "application/json"
  }
  Invoke-RestMethod @args
}

function Get-RelativePath {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  $base = [System.IO.Path]::GetFullPath($BasePath)
  if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $base += [System.IO.Path]::DirectorySeparatorChar
  }
  $target = [System.IO.Path]::GetFullPath($TargetPath)
  $baseUri = New-Object System.Uri($base)
  $targetUri = New-Object System.Uri($target)
  [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
}

function New-Blob {
  param(
    [string]$Path,
    [string]$Content,
    [string]$Encoding = "utf-8"
  )

  $body = @{
    content = $Content
    encoding = $Encoding
  }
  Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/git/blobs" -Body $body
}

function Test-BinaryFile {
  param([string]$Path)

  $binaryExtensions = @(
    ".exe", ".dll", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip", ".7z",
    ".pdf", ".webp", ".bmp", ".ttf", ".otf"
  )
  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($binaryExtensions -contains $extension) {
    return $true
  }

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $buffer = New-Object byte[] ([Math]::Min(4096, [int]$stream.Length))
    $read = $stream.Read($buffer, 0, $buffer.Length)
    for ($i = 0; $i -lt $read; $i++) {
      if ($buffer[$i] -eq 0) { return $true }
    }
  } finally {
    $stream.Dispose()
  }
  return $false
}

function New-BlobFromFile {
  param(
    [string]$RelativePath,
    [string]$FullPath
  )

  if (Test-BinaryFile $FullPath) {
    $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($FullPath))
    return New-Blob -Path $RelativePath -Content $content -Encoding "base64"
  }

  $content = [System.IO.File]::ReadAllText($FullPath, [System.Text.Encoding]::UTF8)
  return New-Blob -Path $RelativePath -Content $content -Encoding "utf-8"
}

function Get-RepositoryFiles {
  $excludeDirs = @(".git", "dist", "__pycache__", ".test_runtime")
Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
    Where-Object {
      $relative = Get-RelativePath -BasePath $repoRoot -TargetPath $_.FullName
      $parts = $relative -split '[\\/]'
      foreach ($dir in $excludeDirs) {
        if ($parts -contains $dir) { return $false }
      }
      return $true
    }
}

Write-Host "Fetching $Owner/$Repo@$Branch ..."
$ref = Invoke-GitHubJson -Method Get -Uri "https://api.github.com/repos/$Owner/$Repo/git/ref/heads/$Branch"
$baseCommitSha = $ref.object.sha
$baseCommit = Invoke-GitHubJson -Method Get -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits/$baseCommitSha"
$baseTreeSha = $baseCommit.tree.sha

Write-Host "Creating tree ..."
$tree = @()
foreach ($file in Get-RepositoryFiles) {
  $relative = (Get-RelativePath -BasePath $repoRoot -TargetPath $file.FullName).Replace("\", "/")
  $blob = New-BlobFromFile -RelativePath $relative -FullPath $file.FullName
  $tree += @{
    path = $relative
    mode = "100644"
    type = "blob"
    sha = $blob.sha
  }
}

$newTree = Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/git/trees" -Body @{
  base_tree = $baseTreeSha
  tree = $tree
}

Write-Host "Creating commit ..."
$newCommit = Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits" -Body @{
  message = "Release $tagName"
  tree = $newTree.sha
  parents = @($baseCommitSha)
}

Write-Host "Updating $Branch ..."
Invoke-GitHubJson -Method Patch -Uri "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch" -Body @{
  sha = $newCommit.sha
  force = $false
} | Out-Null

Write-Host "Creating tag $tagName ..."
try {
  Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/git/refs" -Body @{
    ref = "refs/tags/$tagName"
    sha = $newCommit.sha
  } | Out-Null
} catch {
  $status = $_.Exception.Response.StatusCode.value__
  if ($status -ne 422) { throw }
  Write-Host "Tag already exists; continuing."
}

Write-Host "Creating release ..."
$release = $null
try {
  $release = Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/releases" -Body @{
    tag_name = $tagName
    target_commitish = $Branch
    name = "Codex Usage Widget $tagName"
    body = (Get-Content (Join-Path $repoRoot "CHANGELOG.md") -Raw)
    draft = $false
    prerelease = $false
  }
} catch {
  $status = $_.Exception.Response.StatusCode.value__
  if ($status -ne 422) { throw }
  $release = Invoke-GitHubJson -Method Get -Uri "https://api.github.com/repos/$Owner/$Repo/releases/tags/$tagName"
}

Write-Host "Uploading asset ..."
$assetName = [System.IO.Path]::GetFileName($zipPath)
$assets = Invoke-GitHubJson -Method Get -Uri $release.assets_url
foreach ($asset in $assets) {
  if ($asset.name -eq $assetName) {
    Invoke-GitHubJson -Method Delete -Uri "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($asset.id)" | Out-Null
  }
}

$uploadUri = $release.upload_url.Split("{")[0] + "?name=$([uri]::EscapeDataString($assetName))"
Invoke-RestMethod -Method Post -Uri $uploadUri -Headers @{
  Authorization = "Bearer $Token"
  Accept = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
} -ContentType "application/zip" -InFile $zipPath | Out-Null

Write-Host "Published commit: $($newCommit.sha)"
Write-Host "Release URL: $($release.html_url)"

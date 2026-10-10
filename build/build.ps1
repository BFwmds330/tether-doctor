<#
.SYNOPSIS
  把 tether-doctor 打包成可分发 zip（本地与 GitHub Actions 共用同一套逻辑）。

.DESCRIPTION
  产出 <OutDir>/tether-doctor-v<Version>.zip，内部是顶层目录 tether-doctor-v<Version>/，解压即用。
  末尾打印 ZIP_PATH / ZIP_SHA256，便于 CI 或人工取用。

.PARAMETER Version
  版本号（如 1.1.0）。省略时从 CHANGELOG.md 的第一个版本标题推断。

.PARAMETER OutDir
  输出目录，默认仓库根下的 dist。

.EXAMPLE
  ./build/build.ps1
  ./build/build.ps1 -Version 1.1.0 -OutDir dist
#>
[CmdletBinding()]
param(
  [string]$Version = '',
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

if (-not $Version) {
  $m = Select-String -Path (Join-Path $root 'CHANGELOG.md') -Pattern '^##\s*\[?v?(\d+\.\d+\.\d+)' | Select-Object -First 1
  if (-not $m) { throw 'CHANGELOG.md 里找不到版本号，请显式传 -Version' }
  $Version = $m.Matches[0].Groups[1].Value
}
$Version = $Version.TrimStart('v')

$include = @(
  'tether-doctor.ps1'
  '1-check.bat', '2-apply.bat', '3-revert.bat'
  'README.md', 'README.en.md', 'LICENSE', 'CHANGELOG.md'
  '.gitignore', '.gitattributes'
  'docs'
)

$name = "tether-doctor-v$Version"
$stage = Join-Path ([IO.Path]::GetTempPath()) ("td-build-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$inner = Join-Path $stage $name
New-Item -ItemType Directory -Path $inner -Force | Out-Null

foreach ($item in $include) {
  $src = Join-Path $root $item
  if (-not (Test-Path -LiteralPath $src)) { Write-Warning "跳过不存在的条目：$item"; continue }
  Copy-Item -LiteralPath $src -Destination $inner -Recurse -Force
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

$fileCount = @(Get-ChildItem $inner -Recurse -File).Count
Compress-Archive -Path $inner -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "已打包 $name ($fileCount 个文件)" -ForegroundColor Green
Write-Host ("  大小   : {0:N0} 字节" -f (Get-Item $zip).Length)
Write-Host "ZIP_PATH=$zip"
Write-Host "ZIP_SHA256=$hash"

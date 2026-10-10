<#
.SYNOPSIS
  从 CHANGELOG.md 抽取指定版本的条目，生成 Release 说明文件。

.PARAMETER Version
  版本号（如 1.1.0），对应 CHANGELOG 里的 ## [1.1.0] 小节。

.PARAMETER OutFile
  输出文件路径。

.PARAMETER Repo
  GitHub 仓库全名，用于在说明里生成链接，默认 BFwmds330/tether-doctor。

.EXAMPLE
  ./build/get-release-notes.ps1 -Version 1.1.0 -OutFile dist/release-notes.md
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$OutFile,
  [string]$Repo = 'BFwmds330/tether-doctor'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Version = $Version.TrimStart('v')
$lines = @(Get-Content (Join-Path $root 'CHANGELOG.md') -Encoding UTF8)

$start = -1
$end = $lines.Count
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($start -lt 0) {
    if ($lines[$i] -match "^##\s*\[$([regex]::Escape($Version))\]") { $start = $i }
  } elseif ($lines[$i] -match '^##\s') { $end = $i; break }
}
if ($start -lt 0) { throw "CHANGELOG.md 里找不到版本 [$Version] 的条目" }

$body = @()
if ($end - $start -gt 1) { $body = $lines[($start + 1)..($end - 1)] }

$header = @(
  '**手机 USB 共享网络为什么慢、为什么断 —— 一条命令查清楚。**'
  ''
  "本版完整说明见 [README](https://github.com/$Repo/blob/main/README.md)；多品牌手机菜单路径见 [docs/PHONE-SETTINGS.md](https://github.com/$Repo/blob/main/docs/PHONE-SETTINGS.md)。"
  ''
  '下载下方 `tether-doctor-v' + $Version + '.zip`（含主脚本、三个双击即用 .bat 与全部文档），解压即用。'
  ''
  '---'
  ''
)

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, (($header + $body) -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
Write-Host "发布说明已生成：$OutFile" -ForegroundColor Green

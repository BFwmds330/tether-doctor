<#
.SYNOPSIS
  校验脚本文件的编码与换行：.ps1 必须 UTF-8 with BOM 且 CRLF，.bat 必须无 BOM 且 CRLF。

.DESCRIPTION
  这不是洁癖。踩过的两个真实坑：
   1) tether-doctor.ps1 丢了 BOM 后，Windows PowerShell 5.1 会按 ANSI 解码中文，
      直接抛出一堆 Unexpected token（脚本完全无法运行）；
   2) .bat 若是 LF 换行，cmd 对括号块与标签的解析可能异常。
  本校验在 CI 里把这两个坑挡住。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = New-Object System.Collections.ArrayList

function Get-TextStats([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  $crlf = 0; $lf = 0
  for ($i = 0; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 10) { $lf++; if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } }
  }
  [pscustomobject]@{ Bom = $bom; Crlf = $crlf; BareLf = $lf - $crlf }
}

# .ps1：必须带 BOM（中文内容）+ CRLF
Get-ChildItem $root -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
  $rel = $_.FullName.Substring($root.Length + 1)
  $s = Get-TextStats $_.FullName
  if (-not $s.Bom) { [void]$fail.Add("$rel : 缺少 UTF-8 BOM（Windows PowerShell 5.1 会把中文读成乱码）") }
  if ($s.BareLf -gt 0) { [void]$fail.Add("$rel : 有 $($s.BareLf) 处裸 LF，.ps1 应为 CRLF") }
}

# .bat：不能有 BOM（BOM 会破坏 @echo off）+ CRLF
Get-ChildItem $root -Recurse -File -Filter '*.bat' | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
  $rel = $_.FullName.Substring($root.Length + 1)
  $s = Get-TextStats $_.FullName
  if ($s.Bom) { [void]$fail.Add("$rel : 不应带 BOM（会破坏批处理首行）") }
  if ($s.BareLf -gt 0) { [void]$fail.Add("$rel : 有 $($s.BareLf) 处裸 LF，.bat 应为 CRLF") }
}

if ($fail.Count) {
  Write-Host '文件编码校验未通过：' -ForegroundColor Red
  $fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host '文件编码校验通过：.ps1 均带 BOM + CRLF，.bat 均无 BOM + CRLF' -ForegroundColor Green
exit 0

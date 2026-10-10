<#
.SYNOPSIS
  用 PowerShell 解析器校验仓库内所有 .ps1 的语法（不执行）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem $root -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\\.git\\' })
$bad = New-Object System.Collections.ArrayList

foreach ($f in $files) {
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
  if ($errors -and $errors.Count) {
    foreach ($e in $errors) {
      [void]$bad.Add("$($f.FullName.Substring($root.Length + 1)):$($e.Extent.StartLineNumber) - $($e.Message)")
    }
  }
}

Write-Host ("已解析 {0} 个 .ps1 文件" -f $files.Count)
if ($bad.Count) {
  Write-Host '语法校验未通过：' -ForegroundColor Red
  $bad | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host '语法校验通过：无解析错误' -ForegroundColor Green
exit 0

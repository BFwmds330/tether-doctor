<#
.SYNOPSIS
  冒烟测试：用「当前宿主」（Windows PowerShell 5.1 或 PowerShell 7）的子进程真跑一次只读体检与 -Watch 监控，断言不报错、有正常输出。

.DESCRIPTION
  CI runner 上没有手机共享网卡。因此本测试会挑一块处于 Up 状态的网卡，
  用 -AdapterName 显式指定它（顺带覆盖「非 USB 网卡自动降级」这条路径），
  这样 -Watch 的报告生成代码在 CI 里也能被真正执行到，而不是被 early return 跳过。
  子进程输出经临时文件以 UTF-8 读取，避免中文被错误解码。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'tether-doctor.ps1'
$tmpDir = [IO.Path]::GetTempPath()
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)

# 编码三重坑的修复（中文 Windows 936 代码页实测）：
# 1) native stdout 按「外层」[Console]::OutputEncoding（GBK）解码 → 中文先坏一层，故捕获前强制 UTF-8；
# 2) PS5.1 的 *> 重定向按 UTF-16LE 落盘 → 显式 Out-File -Encoding utf8；
# 3) 子进程改用当前宿主（5.1 跑 5.1、7 跑 7），同一份冒烟在两种宿主下都真正执行主脚本。
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$psExe = (Get-Process -Id $PID).Path

$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1)
$adName = if ($up.Count) { $up[0].Name } else { '' }
if ($adName) { Write-Host "冒烟：使用网卡 '$adName' 进行测试" } else { Write-Host '冒烟：当前没有 Up 状态的网卡，将只验证无网卡时的优雅退出' -ForegroundColor Yellow }

# ---- 1. 只读体检必须退出码 0 且有正常输出 ----
$outFile = Join-Path $tmpDir "td-smoke-$id.txt"
$args1 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
if ($adName) { $args1 += @('-AdapterName', $adName) }
$ErrorActionPreference = 'Continue'   # 子进程的 stderr 行不能终止外层（PS5.1 2>&1 + Stop 的经典坑）
& $psExe @args1 2>&1 | Out-File $outFile -Encoding utf8 -Width 220
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$text = if (Test-Path $outFile) { Get-Content $outFile -Raw -Encoding UTF8 } else { '' }
Remove-Item $outFile -Force -ErrorAction SilentlyContinue

if ($code -ne 0) {
  Write-Host "冒烟测试失败：只读体检退出码 $code" -ForegroundColor Red
  Write-Host $text
  exit 1
}
$expect = if ($adName) { '共享网络适配器' } else { '没有找到 USB 共享网络适配器' }
if ($text -notmatch $expect) {
  Write-Host "冒烟测试失败：输出里没有预期的「$expect」" -ForegroundColor Red
  Write-Host $text
  exit 1
}
Write-Host '只读体检冒烟通过' -ForegroundColor Green

# ---- 2. -Watch 必须能启动、跑完并落盘报告 ----
if (-not $adName) {
  Write-Host '跳过 -Watch 冒烟（没有可用网卡）' -ForegroundColor Yellow
  exit 0
}

$logDir = Join-Path $tmpDir "td-smoke-logs-$id"
$watchOut = Join-Path $tmpDir "td-smoke-watch-$id.txt"
try {
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script,
    '-Watch', '1', '-Interval', '60', '-LogDir', $logDir, '-AdapterName', $adName)
  $ErrorActionPreference = 'Continue'
  & $psExe @args2 2>&1 | Out-File $watchOut -Encoding utf8 -Width 220
  $watchCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($watchCode -ne 0) {
    Write-Host "-Watch 冒烟失败：退出码 $watchCode" -ForegroundColor Red
    if (Test-Path $watchOut) { Write-Host (Get-Content $watchOut -Raw -Encoding UTF8) }
    exit 1
  }
  $md = @(Get-ChildItem $logDir -Filter 'watch-*.md' -ErrorAction SilentlyContinue)
  $csv = @(Get-ChildItem $logDir -Filter 'watch-*.csv' -ErrorAction SilentlyContinue)
  if (-not $md.Count -or -not $csv.Count) {
    Write-Host '-Watch 冒烟失败：没有生成报告（.md / .csv）' -ForegroundColor Red
    exit 1
  }
  $report = Get-Content $md[0].FullName -Raw -Encoding UTF8
  foreach ($need in '总览', '断流事件', '分时段趋势', '同期 Windows 系统事件', '自动结论') {
    if ($report -notmatch $need) {
      Write-Host "-Watch 冒烟失败：监控报告缺少「$need」小节" -ForegroundColor Red
      Write-Host $report
      exit 1
    }
  }
  Write-Host ("-Watch 冒烟通过：生成 {0} 与 {1}" -f $md[0].Name, $csv[0].Name) -ForegroundColor Green
} finally {
  Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $watchOut -Force -ErrorAction SilentlyContinue
}

Write-Host '冒烟测试全部通过' -ForegroundColor Green
exit 0

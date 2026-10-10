<#
.SYNOPSIS
  手机 USB 共享网络（RNDIS / Tethering）体检、优化、回滚与挂机监控。

.DESCRIPTION
  默认只读体检，零写入。所有改动必须显式 -Apply，且每一项都能 -Revert 回滚。
  -Test 做秒级延迟/丢包/抖动实测；-Watch 做长时间挂机监控，输出断流事件与证据链报告。
  适用：Windows 10 / 11 + 安卓手机 USB 共享网络。

.PARAMETER Apply
  落地安全项（需管理员）：关闭全局 USB 选择性暂停、设置公共 DNS、禁用本手机报错接口等。

.PARAMETER AdapterName
  显式指定要体检的网卡接口名（默认自动识别 USB 共享网卡）。
  指向 Wi-Fi / 以太网时，USB 专属判定会自动跳过，可用于监控任意链路的稳定性。

.PARAMETER InterfaceIndex
  显式指定要体检的网卡 ifIndex，作用同 -AdapterName。

.PARAMETER Revert
  回滚 -Apply 做过的可逆改动（需管理员）。

.PARAMETER Test
  体检后追加 TCP 往返 / 丢包 / 抖动实测（约几十 KB 流量）。

.PARAMETER Watch
  挂机监控的分钟数。例如 -Watch 120 表示连续监控 2 小时，输出 CSV 原始数据与 Markdown 报告。

.PARAMETER Interval
  监控采样间隔（秒），默认 3。间隔越短越容易抓到瞬时断流，日志也越大。

.PARAMETER LogDir
  监控报告输出目录，默认为当前目录下的 logs 子目录。

.PARAMETER FailThreshold
  连续失败多少次采样判定为一次「断流事件」，默认 2。

.PARAMETER SlowMs
  单次采样延迟超过该毫秒数记为「劣化样本」，默认 500。

.PARAMETER Dns
  -Apply 时写入共享网卡的 DNS，默认 223.5.5.5 / 119.29.29.29。

.PARAMETER TestCount
  -Test 时每个目标的探测次数，默认 20。

.PARAMETER Export
  导出「诊断包」到指定目录：体检全程的结构化记录会写成 JSON 与一份自包含 HTML 报告；
  -Watch 模式下同时把监控的 md/csv 一并复制进去。配合 -Sanitize 使用即可安全分享。

.PARAMETER Sanitize
  导出前脱敏：MAC 打码为 XX-XX、IPv4 保留前两段（192.168.x.x）、USB VID/PID 与序列号打码。
  只影响导出的文件，屏幕输出不变。

.EXAMPLE
  .\tether-doctor.ps1
  只读体检，不改任何设置。

.EXAMPLE
  .\tether-doctor.ps1 -Test
  体检 + 每个目标 20 次 TCP 往返实测。

.EXAMPLE
  .\tether-doctor.ps1 -Watch 120 -Interval 3
  挂机监控 2 小时，每 3 秒采样一次，结束（或 Ctrl+C）时输出断流证据链报告。

.EXAMPLE
  .\tether-doctor.ps1 -Export .\to-share -Sanitize
  体检并导出脱敏后的诊断包（JSON + HTML）到 to-share 目录，可直接发给别人。

.EXAMPLE
  .\tether-doctor.ps1 -Apply
  落地安全项（需管理员）。

.NOTES
  本文件必须以 UTF-8 with BOM 保存，否则 Windows PowerShell 5.1 会把中文读成乱码并报语法错误。
  集线器层省电开关没有可靠的注册表等价物，脚本只打印清单，需手动点击。
#>
[CmdletBinding()]
param(
  [string]$AdapterName = '',
  [int]$InterfaceIndex = -1,
  [switch]$Apply,
  [switch]$Revert,
  [switch]$Test,
  [ValidateRange(0, [int]::MaxValue)]
  [int]$Watch = 0,
  [ValidateRange(1, [int]::MaxValue)]
  [int]$Interval = 3,
  [string]$LogDir,
  [ValidateRange(1, [int]::MaxValue)]
  [int]$FailThreshold = 2,
  [ValidateRange(50, [int]::MaxValue)]
  [int]$SlowMs = 500,
  [string[]]$Dns = @('223.5.5.5', '119.29.29.29'),
  [ValidateRange(1, 100)]
  [int]$TestCount = 20,
  [string]$Export = '',
  [switch]$Sanitize
)

$script:Version = '1.2.1'

if ($Apply -and $Revert) { throw '参数冲突：-Apply 与 -Revert 不能同时使用（落地与回滚请分开各跑一次）。' }

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:changes = New-Object System.Collections.ArrayList
$script:report = New-Object System.Collections.ArrayList   # 全程输出记录（供 -Export 导出诊断包）
$script:curSection = ''
$script:testStats = @()

function Section($t) { Write-Host ''; Write-Host ("=" * 66) -ForegroundColor DarkGray; Write-Host " $t" -ForegroundColor Cyan; Write-Host ("=" * 66) -ForegroundColor DarkGray; $script:curSection = $t; [void]$script:report.Add([pscustomobject]@{ Section = $t; Level = 'HEAD'; Text = '' }) }
function Ok($t)     { Write-Host "  [OK]   $t" -ForegroundColor Green; [void]$script:report.Add([pscustomobject]@{ Section = $script:curSection; Level = 'OK'; Text = "$t" }) }
function Warn($t)   { Write-Host "  [注意] $t" -ForegroundColor Yellow; [void]$script:report.Add([pscustomobject]@{ Section = $script:curSection; Level = 'WARN'; Text = "$t" }) }
function Bad($t)    { Write-Host "  [问题] $t" -ForegroundColor Red; [void]$script:report.Add([pscustomobject]@{ Section = $script:curSection; Level = 'BAD'; Text = "$t" }) }
function Info($t)   { Write-Host "  · $t" -ForegroundColor Gray; [void]$script:report.Add([pscustomobject]@{ Section = $script:curSection; Level = 'INFO'; Text = "$t" }) }
function Todo($t)   { Write-Host "  [待办] $t" -ForegroundColor Magenta; [void]$script:report.Add([pscustomobject]@{ Section = $script:curSection; Level = 'TODO'; Text = "$t" }) }

# ---------------------------------------------------------------- 诊断包导出（-Export / -Sanitize）
function ConvertTo-SanitizedText([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  $s = $s -replace '\b([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}\b', 'XX-XX-XX-XX-XX-XX'
  $s = $s -replace '\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}\b', '$1.$2.x.x'
  $s = $s -replace 'VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}', 'VID_XXXX&PID_XXXX'
  $s = $s -replace '(MI_\d+\\)[0-9A-Fa-f&]+', '$1<已脱敏>'
  return $s
}
function ConvertTo-HtmlText([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}
function Invoke-Export {
  try {
    $expDir = $Export
    if (-not (Test-Path $expDir)) { New-Item -ItemType Directory -Path $expDir -Force | Out-Null }
    $expStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $expDir "tether-doctor-$expStamp.json"
    $htmlPath = Join-Path $expDir "tether-doctor-$expStamp.html"
    $fx = if ($Sanitize) { { param($s) ConvertTo-SanitizedText $s } } else { { param($s) $s } }

    $meta = [pscustomobject]@{
      Tool = 'tether-doctor'; Version = $script:Version
      Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Mode = $mode; Sanitized = [bool]$Sanitize
      PowerShell = $PSVersionTable.PSVersion.ToString()
      Adapter = if ($ad) { [pscustomobject]@{ Name = (& $fx $ad.Name); Description = (& $fx $ad.InterfaceDescription); IfIndex = $ad.ifIndex; Mac = (& $fx $ad.MacAddress); PnpId = (& $fx $ad.PnPDeviceID); LinkSpeed = "$($ad.LinkSpeed)" } } else { $null }
      TestStats = @($script:testStats)
    }
    $entries = @($script:report | ForEach-Object { [pscustomobject]@{ Section = (& $fx $_.Section); Level = $_.Level; Text = (& $fx $_.Text) } })
    [IO.File]::WriteAllText($jsonPath, ([pscustomobject]@{ Meta = $meta; Entries = $entries } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($true)))

    $h = New-Object System.Collections.ArrayList
    [void]$h.Add('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>tether-doctor 诊断报告</title>')
    [void]$h.Add('<style>body{font-family:"Microsoft YaHei",Segoe UI,sans-serif;max-width:960px;margin:24px auto;padding:0 12px;color:#222}h1{font-size:20px}h2{font-size:16px;border-bottom:1px solid #ddd;padding-bottom:4px;margin-top:28px}table{border-collapse:collapse;font-size:13px}td,th{border:1px solid #ccc;padding:4px 10px}ul{list-style:none;padding-left:8px}li{padding:2px 0;font-size:13px}.OK::before{content:"[OK]   ";color:#0a0}.WARN::before{content:"[注意] ";color:#c80}.BAD::before{content:"[问题] ";color:#c00}.TODO::before{content:"[待办] ";color:#808}.INFO::before{content:"·      ";color:#888}.OK{color:#060}.WARN{color:#a60}.BAD{color:#900}.TODO{color:#707}.INFO{color:#555}</style></head><body>')
    $sub = if ($Sanitize) { '（已脱敏，可分享）' } else { '' }
    [void]$h.Add("<h1>tether-doctor v$($script:Version) 诊断报告$sub</h1>")
    $adTxt = if ($ad) { ConvertTo-HtmlText (& $fx "$($ad.Name) — $($ad.InterfaceDescription)") } else { '（未识别到共享网卡）' }
    [void]$h.Add("<table><tr><th>时间</th><td>$(ConvertTo-HtmlText (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))</td><th>模式</th><td>$(ConvertTo-HtmlText $mode)</td></tr><tr><th>PowerShell</th><td>$($PSVersionTable.PSVersion)</td><th>网卡</th><td>$adTxt</td></tr></table>")
    $curSec = ''
    foreach ($e in $entries) {
      if ($e.Level -eq 'HEAD') { if ($curSec) { [void]$h.Add('</ul>') }; [void]$h.Add('<h2>' + (ConvertTo-HtmlText $e.Section) + '</h2><ul>'); $curSec = $e.Section }
      else { [void]$h.Add('<li class="' + $e.Level + '">' + (ConvertTo-HtmlText $e.Text) + '</li>') }
    }
    if ($curSec) { [void]$h.Add('</ul>') }
    [void]$h.Add('<p style="color:#888;font-size:12px;margin-top:32px">由 tether-doctor 生成（只读诊断，纯静态 HTML）。脱敏规则：MAC→XX-XX、IPv4 保留前两段、USB VID/PID 与序列号打码。</p></body></html>')
    [IO.File]::WriteAllText($htmlPath, ($h -join "`r`n"), (New-Object Text.UTF8Encoding($true)))

    if ($Watch -gt 0 -and $mdPath) {
      foreach ($src in @($mdPath, $csvPath)) {
        if (-not $src -or -not (Test-Path $src)) { continue }
        $dst = Join-Path $expDir (Split-Path $src -Leaf)
        if ($Sanitize) {
          $lines = @(Get-Content $src -Encoding UTF8 | ForEach-Object { ConvertTo-SanitizedText $_ })
          [IO.File]::WriteAllLines($dst, $lines, (New-Object Text.UTF8Encoding($true)))
        } else { Copy-Item $src $dst -Force }
      }
      Ok "监控报告与 CSV 已一并复制到：$expDir"
    }
    Ok "诊断包已导出：$htmlPath"
    Ok "结构化数据（可程序化处理）：$jsonPath"
    if (-not $Sanitize) { Warn '导出内容未脱敏（含 IP / MAC / 设备标识），分享前请确认，或改用 -Sanitize' }
  } catch { Bad "诊断包导出失败：$($_.Exception.Message)" }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mode = if ($Apply) { 'APPLY（落地改动）' } elseif ($Revert) { 'REVERT（回滚）' } elseif ($Watch -gt 0) { "WATCH（挂机监控 $Watch 分钟）" } elseif ($Test) { 'REPORT+TEST（体检 + 实测）' } else { 'REPORT（只读体检）' }

Section "环境"
Info ("tether-doctor v{0}" -f $script:Version)
Info ("PowerShell {0} / {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
if ($isAdmin) { Ok '当前以管理员身份运行' } else { Warn '当前不是管理员：体检查得全，但 -Apply / -Revert 会失败（用随附的 .bat 提权运行）' }
Info "运行模式：$mode"
if ($Apply) { Info '本次 -Apply 将执行：① 关全局 USB 选择性暂停 ② 设共享网卡 DNS ③ 禁网卡电源管理（仅驱动支持时） ④ 禁本手机报错的非 RNDIS 接口 ⑤ 多默认路由时把接口跃点设为 1 —— 条件项可能跳过，每项都可用 -Revert 回滚' }

# ---------------------------------------------------------------- 1. 找到目标适配器
Section "1. 共享网络适配器"
$cands = @()
$explicit = ($AdapterName -or $InterfaceIndex -ge 0)
try {
  if ($explicit) {
    $cands = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
        ($AdapterName -and $_.Name -eq $AdapterName) -or ($InterfaceIndex -ge 0 -and $_.ifIndex -eq $InterfaceIndex)
      })
    if (-not $cands) {
      Bad "指定的网卡不存在：$(if ($AdapterName) { "-AdapterName $AdapterName" } else { "-InterfaceIndex $InterfaceIndex" })"
      Info ('可用网卡：' + ((Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)[$($_.ifIndex)]" }) -join '、'))
      if ($Export) { Invoke-Export }
      return
    }
    Info '（使用 -AdapterName / -InterfaceIndex 显式指定的网卡；USB 相关判定会自动按网卡类型降级）'
  } else {
    $cands = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'NDIS|RNDIS|Remote|Tether|Gadget|Internet Sharing' -or $_.Name -match 'NDIS')
      })
  }
} catch { Bad "Get-NetAdapter 失败：$($_.Exception.Message)" }

if (-not $cands) {
  Bad '没有找到 USB 共享网络适配器。请确认手机已插好并已在手机上打开「USB 共享网络」。'
  $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
  if ($up) {
    Info ('当前处于已连接状态的网卡：' + (($up | ForEach-Object { "$($_.Name)($($_.InterfaceDescription))" }) -join '、'))
    Info '若想体检其中某一块（例如 Wi-Fi），用：-AdapterName "<接口名>" 或 -InterfaceIndex <编号>'
  }
  if ($Export) { Invoke-Export }
  return
}
if (@($cands).Count -gt 1) {
  Warn "找到 $((@($cands)).Count) 个候选适配器，取第一个：$(($cands | ForEach-Object { "$($_.Name)[$($_.ifIndex)]" }) -join '、')；如有误请用 -AdapterName / -InterfaceIndex 指定"
}
$ad = @($cands)[0]
$isUsb = ($ad.PnPDeviceID -like 'USB\*') -or ($ad.InterfaceDescription -match 'NDIS|RNDIS|Remote|Tether|Gadget|Internet Sharing')

Info "接口名        : $($ad.Name)"
Info "描述          : $($ad.InterfaceDescription)"
Info "ifIndex / MAC : $($ad.ifIndex) / $($ad.MacAddress)"
Info "PnP 实例      : $($ad.PnPDeviceID)"
Info "接口类型      : $(if ($isUsb) { 'USB 共享网络（RNDIS / Tethering）' } else { '非 USB 网卡（USB 专属判定会自动跳过）' })"

$ipcfg = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$gw    = Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
$iface = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$dnsNow = (Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

Info "IPv4 / 网关   : $(($ipcfg.IPAddress -join ', ')) / $($gw.NextHop)"
Info "MTU / 跃点    : $($iface.NlMtu) / $($iface.InterfaceMetric)"
Info "DNS           : $(if ($dnsNow) { $dnsNow -join ', ' } else { '(未显式设置，走 DHCP)' })"

# 链路速率判定
$link = 0
try { $link = [double]($ad.LinkSpeed -replace '[^\d\.]', '') } catch {}
if ($ad.LinkSpeed -match 'Gbps') { $link *= 1000 }
if ($isUsb) {
  if ($link -ge 100) {
    Ok "USB 链路协商速率 $($ad.LinkSpeed) —— 线材/USB 口没问题，瓶颈不在这里"
  } elseif ($link -gt 0) {
    Bad "USB 链路只有 $($ad.LinkSpeed)（典型 12Mbps = USB 全速）。换数据线、直插 USB 3.0 口、别用扩展坞/HUB。"
  } else { Warn "读不到链路速率：$($ad.LinkSpeed)" }
} else {
  Info "链路速率：$($ad.LinkSpeed)（非 USB 网卡，不做 USB 全速判定）"
}

# ---------------------------------------------------------------- 2. USB 父设备链
Section "2. USB 物理链路（手机插在哪一级）"
$hubName = $null; $portInfo = $null; $hubInst = $null
if (-not $isUsb) {
  Info '该网卡不是 USB 设备，跳过 USB 物理链路还原（其余检查照常进行）'
} elseif ($ad.PnPDeviceID) {
  $cur = $ad.PnPDeviceID; $depth = 0
  while ($cur -and $depth -lt 6) {
    $d = Get-PnpDevice -InstanceId $cur -ErrorAction SilentlyContinue
    $loc = (Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
    $line = ('  ' * $depth) + $(if ($d) { $d.FriendlyName } else { $cur })
    if ($loc) { $line += "   [$loc]" }
    Info $line
    if ($loc -match 'Port_#\d+\.Hub_#\d+') { $portInfo = $loc }
    if ($d -and $d.FriendlyName -match 'Hub|集线器') {
      if (-not $hubName) { $hubName = $d.FriendlyName; $hubInst = $d.InstanceId }
    }
    $cur = (Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    $depth++
  }
  if ($hubName) { Info "手机所在集线器：$hubName  端口：$(if ($portInfo) { $portInfo } else { '未上报' })" }
}

# ---------------------------------------------------------------- 3. 该网卡的电源管理能力
Section "3. 网卡自身的电源管理（能不能勾那两项）"
$pmOk = $false
try {
  $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
  $pmOk = $true
  Ok '该网卡支持电源管理，当前值：'
  $pm | Format-List * | Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | ForEach-Object { Info $_ }
  if ($Apply) {
    if (-not $isAdmin) { Bad '需要管理员权限，跳过' }
    else {
      try { Disable-NetAdapterPowerManagement -Name $ad.Name -Confirm:$false -ErrorAction Stop; [void]$script:changes.Add("已禁用网卡 $($ad.Name) 的电源管理"); Ok '已禁用该网卡的电源管理' }
      catch { Warn "禁用失败：$($_.Exception.Message)" }
    }
  } elseif ($Revert) {
    if ($isAdmin) {
      try { Enable-NetAdapterPowerManagement -Name $ad.Name -Confirm:$false -ErrorAction Stop; [void]$script:changes.Add("已启用网卡 $($ad.Name) 的电源管理"); Ok '已启用该网卡的电源管理' }
      catch { Warn "启用失败：$($_.Exception.Message)" }
    } else { Bad '需要管理员权限，跳过' }
  }
} catch {
  Ok '该驱动不支持电源管理 —— 设备管理器里没有「电源管理」标签页是正常的，不是你没找到'
  Info "  （实测报错：$($_.Exception.Message.Trim())）"
  Info '  微软通用 RNDIS 驱动（wceisvista.inf）就属于这种，Windows 无法对它做省电挂起，因此这一项无需处理。'
}

# ---------------------------------------------------------------- 4. 全局 USB 选择性暂停
Section "4. 全局 USB 选择性暂停（这才是 USB 侧真正会瞬断的开关）"
$sub = '2a737441-1930-4402-8d77-b2bebba308a3'; $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
function Get-UsbSuspend {
  $q = (powercfg /query SCHEME_CURRENT $sub 2>$null) -join "`n"
  $ac = [regex]::Match($q, '(?im)(当前交流电源设置索引|Current AC Power Setting Index):\s*(0x[0-9a-f]+)').Groups[2].Value
  $dc = [regex]::Match($q, '(?im)(当前直流电源设置索引|Current DC Power Setting Index):\s*(0x[0-9a-f]+)').Groups[2].Value
  [pscustomobject]@{ AC = $ac; DC = $dc }
}
$st = Get-UsbSuspend
function Show-Suspend($s) {
  if (-not $s.AC) { Warn '没解析到电源设置值'; return }
  foreach ($k in 'AC', 'DC') {
    if ($s.$k -match '0x0+$') { Ok "$k：已禁用（不会挂起 USB）" } else { Bad "$k：已启用（$($s.$k)）—— USB 空闲时会被挂起，是共享瞬断的嫌疑点" }
  }
}
Show-Suspend $st
Info '（powercfg 改的是当前活动电源计划；若你使用多个电源计划，切换后请分别确认/处理）'
if ($Apply -and ($st.AC -notmatch '0x0+$' -or $st.DC -notmatch '0x0+$')) {
  if (-not $isAdmin) { Bad '需要管理员权限，跳过（用 .bat 提权运行）' }
  else {
    powercfg /setacvalueindex SCHEME_CURRENT $sub $set 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    [void]$script:changes.Add('已禁用全局 USB 选择性暂停（AC+DC）')
    Ok '已禁用，复查：'; Show-Suspend (Get-UsbSuspend)
  }
} elseif ($Revert) {
  if ($isAdmin) {
    $cur = Get-UsbSuspend
    if ($cur.AC -match '0x0+$' -or $cur.DC -match '0x0+$') {
      powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
      powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
      powercfg /setactive SCHEME_CURRENT | Out-Null
      [void]$script:changes.Add('已恢复全局 USB 选择性暂停=启用（Windows 默认值）')
      Ok '已恢复为「启用」（Windows 默认值）。注：若你原本是手动禁用的（没跑过本脚本的 -Apply），请自行改回'
      Show-Suspend (Get-UsbSuspend)
    } else { Info '全局 USB 选择性暂停已是「启用」，无需恢复' }
  } else { Bad '需要管理员权限，跳过' }
}

# ---------------------------------------------------------------- 5. 集线器层电源管理（只能手点）
Section "5. 集线器层「允许计算机关闭此设备」（脚本不代改，给清单）"
$hubs = Get-PnpDevice -Class USB -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Hub|集线器' }
if (-not $hubs) { Info '没枚举到集线器设备' }
foreach ($h in $hubs) {
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $h.InstanceId + '\Device Parameters'
  $dp = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
  $state = if ($null -eq $dp.EnhancedPowerManagementEnabled -and $null -eq $dp.SelectiveSuspendEnabled) { '默认（勾选框=勾上，允许挂起）' } else { "Enhanced=$($dp.EnhancedPowerManagementEnabled) SelectiveSuspend=$($dp.SelectiveSuspendEnabled)" }
  $star = if ($h.InstanceId -eq $hubInst) { '  ← 手机挂在这个上，优先改它' } else { '' }
  Info ("{0,-34} {1}{2}" -f $h.FriendlyName, $state, $star)
}
Todo '设备管理器 → 通用串行总线控制器 → 逐个「USB 根集线器(USB 3.0)」/「通用 USB 集线器」/「通用 SuperSpeed USB 集线器」→ 属性 → 电源管理 → 取消「允许计算机关闭此设备以节约电源」'
Info '（这一项没有可靠的注册表等价物，手点最稳；副作用仅是待机功耗略增）'

# ---------------------------------------------------------------- 6. 路由 / 多网关
Section "6. 默认路由（多网关 = 抖动与断流的常见来源）"
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
$routes | ForEach-Object {
  $n = (Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).Name
  Info ("ifIndex={0} 接口={1} 网关={2} 路由跃点={3} 接口跃点={4}" -f $_.ifIndex, $n, $_.NextHop, $_.RouteMetric, $_.InterfaceMetric)
}
if (@($routes).Count -gt 1) {
  Bad "存在 $((@($routes)).Count) 条默认路由 —— 多网卡同时在线会互相抢路由，表现为忽快忽慢、偶发断流"
  Info '建议：共享上网时断开其他网络；确需并存则把共享网卡跃点调到最小'
  if ($Apply) {
    if ($isAdmin) {
      try {
        $origMetric = @($iface)[0].InterfaceMetric
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric 1 -ErrorAction Stop
        [void]$script:changes.Add("已把 $($ad.Name) 接口跃点设为 1（原值 $origMetric）")
        Ok "已把共享网卡接口跃点设为 1（原值 $origMetric；若原本是自动跃点，-Revert 会还原为自动）"
      }
      catch { Warn "设置跃点失败：$($_.Exception.Message)" }
    } else { Bad '需要管理员权限，跳过' }
  }
} else { Ok '只有一条默认路由，干净' }
if ($Revert) {
  if ($isAdmin) {
    try { Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric Automatic -ErrorAction Stop; [void]$script:changes.Add("已把 $($ad.Name) 接口跃点恢复为自动"); Ok '已把共享网卡接口跃点恢复为自动（Windows 按链路速率重算）' }
    catch { Warn "恢复跃点失败：$($_.Exception.Message)" }
  } else { Bad '需要管理员权限，跳过' }
}

# ---------------------------------------------------------------- 7. DNS
Section "7. DNS"
if (-not $dnsNow) { Warn '当前走 DHCP 下发的 DNS（运营商 DNS 常较慢/不稳）' } else { Info "当前：$($dnsNow -join ', ')" }
if ($Apply) {
  if ($isAdmin) {
    try {
      $prevDns = @($dnsNow)
      Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $Dns -ErrorAction Stop
      $prevTxt = if ($prevDns.Count) { $prevDns -join ', ' } else { '自动获取（DHCP）' }
      [void]$script:changes.Add("已把 $($ad.Name) 的 DNS 设为 $($Dns -join ', ')（原值：$prevTxt）")
      Ok "已设为 $($Dns -join ', ')（原值：$prevTxt）"
    }
    catch { Warn "设置 DNS 失败：$($_.Exception.Message)" }
  } else { Bad '需要管理员权限，跳过' }
} elseif ($Revert) {
  if ($isAdmin) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue; [void]$script:changes.Add("已把 $($ad.Name) 的 DNS 恢复为自动"); Ok '已恢复为自动获取（若原本是手动 DNS，请按 -Apply 运行时打印的「原值」改回）' }
  else { Bad '需要管理员权限，跳过' }
} else { Todo "如需加速解析：-Apply 会把本网卡 DNS 设为 $($Dns -join ', ')" }

# ---------------------------------------------------------------- 8. MTU 探测
Section "8. MTU 探测（解决「小网页正常、大文件/视频卡」）"
$probe = '223.5.5.5'
$ping = New-Object System.Net.NetworkInformation.Ping
$reach = $false
try { $reach = ($ping.Send($probe, 3000).Status -eq 'Success') } catch {}
if (-not $reach) { Warn 'ICMP 探测不通（被网络/安全软件拦截），跳过；如需自查可在 cmd 里手跑：ping -f -l 1472 223.5.5.5 并逐步减小' }
else {
  $best = $null
  for ($sz = 1472; $sz -ge 1200; $sz -= 8) {
    try {
      $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $true)
      $buf = New-Object 'byte[]' $sz
      if ($ping.Send($probe, 3000, $buf, $opt).Status -eq 'Success') { $best = $sz + 28; break }
    } catch {}
  }
  if ($best) {
    Info "可用的最大 MTU ≈ $best（当前网卡 MTU = $($iface.NlMtu)）"
    if ($best -lt $iface.NlMtu) { Todo "建议把该网卡 MTU 调成 $best：netsh interface ipv4 set subinterface `"$($ad.Name)`" mtu=$best store=persistent（还原用同样命令把值改回 1500）" }
    else { Ok 'MTU 正常，无需调整' }
  } else { Warn '未能探到（可能全程被拦），维持默认 1500 即可' }
}

# ---------------------------------------------------------------- 9. 异常设备（HDB 等）
Section "9. 异常设备（手机复合设备里有接口报错会周期性重枚举 → 共享瞬断）"
# 「属于本手机」的归因：复合设备场景用父设备精确比对（与网卡共享同一父 = 同一台物理手机），
# 同 VID/PID 的另一台手机、网卡自身都不会再被误判；父查询失败时降级为 VID/PID 前缀匹配（排除网卡自身）。
$script:phoneComposite = $null
if ($isUsb -and $ad.PnPDeviceID -and ($ad.PnPDeviceID -match '&MI_\d+')) {
  $script:phoneComposite = (Get-PnpDeviceProperty -InstanceId $ad.PnPDeviceID -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
}
function Test-BelongsToPhone([string]$instanceId) {
  if ($script:phoneComposite) {
    $p = (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    if ($p) { return ($p -eq $script:phoneComposite) }
  }
  $prefix = $ad.PnPDeviceID -replace '&MI_\d+.*$', '*'
  return ($instanceId -like $prefix -and $instanceId -ne $ad.PnPDeviceID)
}
$badDevs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' }
if (-not $badDevs) { Ok '没有异常设备' }
foreach ($b in $badDevs) {
  $isPhone = $isUsb -and (Test-BelongsToPhone $b.InstanceId)
  $tag = if ($isPhone) { '   ← 属于本手机，优先处理' } else { '' }
  if ($b.Status -eq 'Error') { Bad ("{0}  [{1}]  {2}{3}" -f $b.FriendlyName, $b.Status, $b.InstanceId, $tag) }
  elseif ($b.Status -eq 'Degraded') { Info ("{0}  [{1}]（通常无害）" -f $b.FriendlyName, $b.Status) }
  else { Warn ("{0}  [{1}]  {2}{3}" -f $b.FriendlyName, $b.Status, $b.InstanceId, $tag) }
}
$phoneBad = @()
if ($isUsb) {
  $phoneBad = @($badDevs | Where-Object { $_.Status -eq 'Error' -and (Test-BelongsToPhone $_.InstanceId) -and $_.InstanceId -notlike '*&MI_00*' })
}
if ($phoneBad) {
  Todo '处理方式（任选其一）：① 装荣耀/华为官方手机助手把驱动补齐；② 手机开发者选项里关掉「USB 调试 / HDB 调试」；③ 直接禁用该接口（本脚本 -Apply 会做）'
  if ($Apply) {
    if ($isAdmin) {
      foreach ($p in $phoneBad) {
        try { Disable-PnpDevice -InstanceId $p.InstanceId -Confirm:$false -ErrorAction Stop; [void]$script:changes.Add("已禁用异常接口 $($p.FriendlyName) [$($p.InstanceId)]"); Ok "已禁用 $($p.FriendlyName)" }
        catch { Warn "禁用失败：$($_.Exception.Message)" }
      }
    } else { Bad '需要管理员权限，跳过' }
  } elseif ($Revert) {
    if ($isAdmin) {
      foreach ($p in $phoneBad) { try { Enable-PnpDevice -InstanceId $p.InstanceId -Confirm:$false -ErrorAction Stop; [void]$script:changes.Add("已启用 $($p.FriendlyName)"); Ok "已启用 $($p.FriendlyName)" } catch { Warn "启用失败：$($_.Exception.Message)" } }
    } else { Bad '需要管理员权限，跳过' }
  }
}
Info '另：ROOT\USB\... 下报错的「USB Device(VID_xxx)」是软件虚拟设备（模拟器/手机助手残留），与共享无关，可在设备管理器里直接卸载。'

# ---------------------------------------------------------------- 10. 挂机监控（-Watch）
if ($Watch -gt 0) {
  Section "10. 挂机监控：$Watch 分钟 / 每 $Interval 秒采样"

  if (-not $LogDir) { $LogDir = Join-Path (Get-Location) 'logs' }
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $csvPath = Join-Path $LogDir "watch-$stamp.csv"
  $mdPath = Join-Path $LogDir "watch-$stamp.md"

  # 增量落盘：CSV 边采边写。挂机场景断电/崩溃/误杀进程时，已完成的样本仍留在磁盘上，结束时只补 MD 报告。
  $csvWriter = $null
  function ConvertTo-CsvLine([object[]]$vals) {
    ($vals | ForEach-Object { $v = if ($null -eq $_) { '' } else { "$_" }; '"' + ($v -replace '"', '""') + '"' }) -join ','
  }
  try {
    $csvWriter = New-Object IO.StreamWriter($csvPath, $false, [Text.Encoding]::UTF8)
    $csvWriter.WriteLine('"T","Time","Ok","MinMs","AlidnsMs","BaiduMs","AdapterState","LinkSpeed","IPv4","Gateway"')
  } catch { $csvWriter = $null; Warn "CSV 增量写入初始化失败（将改为结束时一次性写出）：$($_.Exception.Message)" }

  $targets = @(
    [pscustomobject]@{ Name = 'alidns'; Host = '223.5.5.5'; Port = 443 }
    [pscustomobject]@{ Name = 'baidu'; Host = 'www.baidu.com'; Port = 443 }
  )
  $totalSamples = [int][math]::Max(1, [math]::Floor($Watch * 60 / [math]::Max(1, $Interval)))
  Info ("探测目标 : " + (($targets | ForEach-Object { "$($_.Host):$($_.Port)" }) -join '、'))
  Info "采样     : 每 ${Interval}s 一次，共约 $totalSamples 次，预计 $((Get-Date).AddMinutes($Watch).ToString('HH:mm:ss')) 结束"
  Info "判定规则 : 连续失败 $FailThreshold 次采样 = 一次断流；单次延迟 > ${SlowMs}ms = 劣化样本"
  Info "报告     : $mdPath"
  Info "原始数据 : $csvPath"
  Todo '中途请记下你操作的时刻（开热点 / 接电话 / 换位置 / 改设置），报告按时间戳对齐即可定位因果'
  Info '随时按 Ctrl+C 结束，报告照常生成。'

  $samples = New-Object System.Collections.ArrayList
  $events = New-Object System.Collections.ArrayList
  $started = Get-Date
  $failRun = 0; $outageStart = $null; $outageState = ''; $prevSample = $null
  $okCount = 0; $outageCount = 0; $sleepEvents = 0

  try {
    for ($i = 1; $i -le $totalSamples; $i++) {
      $ts = Get-Date
      # 睡眠/唤醒检测：相邻采样间隔远超设定间隔 → 标记「疑似休眠」，并把未决断流起点重置（睡眠时长不计入断流统计）
      $gapSec = if ($prevSample) { ($ts - $prevSample.T).TotalSeconds } else { 0 }
      if ($gapSec -gt ([math]::Max(3 * $Interval, 30))) {
        $sleepEvents++
        $gTxt = [int][math]::Round($gapSec, 0)
        Warn "[$($ts.ToString('HH:mm:ss'))] 采样间隔异常（与前一样本相差 ${gTxt}s，应为 ${Interval}s）—— 系统可能睡眠/休眠过，该时段未采样"
        [void]$events.Add([pscustomobject]@{ Time = $ts.ToString('HH:mm:ss'); Type = '疑似休眠'; Seconds = $gTxt; State = ''; Detail = "与前一样本相差 ${gTxt}s（应为 ${Interval}s），该时段未采样" })
        if ($failRun -gt 0) { $failRun = 0; $outageStart = $null; $outageState = '' }
      }
      $lat = @{}; $okAny = $false
      foreach ($t in $targets) {
        $ms = $null
        $c = New-Object Net.Sockets.TcpClient
        try {
          $sw = [Diagnostics.Stopwatch]::StartNew()
          $iar = $c.BeginConnect($t.Host, $t.Port, $null, $null)
          if ($iar.AsyncWaitHandle.WaitOne(4000)) { $c.EndConnect($iar); $sw.Stop(); $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); $okAny = $true }
        } catch { } finally { $c.Close() }
        $lat[$t.Name] = $ms
      }

      $state = 'Missing'; $link = ''; $ip = ''; $gw = ''
      $na = Get-NetAdapter -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue
      if ($na) {
        $state = "$($na.Status)"; $link = "$($na.LinkSpeed)"
        $ip = ((@(Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress) -join ',')
        $g = Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { $gw = "$($g.NextHop)" }
      }
      $okMs = @($lat.Values | Where-Object { $_ -ne $null })
      $minMs = if ($okMs.Count) { ($okMs | Measure-Object -Minimum).Minimum } else { $null }
      if ($okAny) { $okCount++ }

      [void]$samples.Add([pscustomobject]@{
          T = $ts; Time = $ts.ToString('HH:mm:ss'); Ok = $okAny; MinMs = $minMs
          AlidnsMs = $lat['alidns']; BaiduMs = $lat['baidu']
          AdapterState = $state; LinkSpeed = $link; IPv4 = $ip; Gateway = $gw
        })
      $cur = $samples[$samples.Count - 1]
      if ($csvWriter) {
        try {
          $csvWriter.WriteLine((ConvertTo-CsvLine @($cur.T.ToString('yyyy-MM-dd HH:mm:ss'), $cur.Time, $cur.Ok, $cur.MinMs, $cur.AlidnsMs, $cur.BaiduMs, $cur.AdapterState, $cur.LinkSpeed, $cur.IPv4, $cur.Gateway)))
          if ($i % 10 -eq 0) { $csvWriter.Flush() }
        } catch { try { $csvWriter.Close() } catch {}; $csvWriter = $null; Warn "CSV 增量写入失败（将改为结束时一次性写出）：$($_.Exception.Message)" }
      }

      if ($prevSample -and ($prevSample.AdapterState -ne $state -or $prevSample.LinkSpeed -ne $link -or $prevSample.IPv4 -ne $ip -or $prevSample.Gateway -ne $gw)) {
        $desc = @()
        if ($prevSample.AdapterState -ne $state) { $desc += "适配器状态 $($prevSample.AdapterState) → $state" }
        if ($prevSample.LinkSpeed -ne $link) { $desc += "链路速率 $($prevSample.LinkSpeed) → $link" }
        if ($prevSample.IPv4 -ne $ip) { $desc += "IPv4 $($prevSample.IPv4) → $ip" }
        if ($prevSample.Gateway -ne $gw) { $desc += "网关 $($prevSample.Gateway) → $gw" }
        $d = ($desc -join '；')
        [void]$events.Add([pscustomobject]@{ Time = $ts.ToString('HH:mm:ss'); Type = '状态变化'; Seconds = 0; State = $state; Detail = $d })
        Warn "[$($ts.ToString('HH:mm:ss'))] 状态变化：$d"
      }
      $prevSample = $cur

      if (-not $okAny) {
        $failRun++
        if ($failRun -eq $FailThreshold) {
          $outageStart = $ts; $outageState = $state
          Warn "[$($ts.ToString('HH:mm:ss'))] 疑似断流开始（连续 $failRun 次采样全部失败，适配器 $state）"
        }
      } else {
        if ($failRun -ge $FailThreshold -and $outageStart) {
          $secs = [int][math]::Round(($ts - $outageStart).TotalSeconds, 0)
          [void]$events.Add([pscustomobject]@{ Time = $outageStart.ToString('HH:mm:ss'); Type = '断流'; Seconds = $secs; State = $outageState; Detail = "持续约 ${secs}s（$failRun 次失败采样），期间适配器 $outageState" })
          $outageCount++
          Bad "[$($ts.ToString('HH:mm:ss'))] 断流结束：持续约 ${secs}s"
        }
        $failRun = 0; $outageStart = $null; $outageState = ''
      }

      if ($i -eq 1 -or $i % 20 -eq 0) {
        $show = if ($null -eq $minMs) { '超时' } else { "$minMs ms" }
        Info ("[{0}] 采样 {1}/{2}  成功 {3}  当前 {4}  断流 {5} 次" -f $ts.ToString('HH:mm:ss'), $i, $totalSamples, $okCount, $show, $outageCount)
      }
      if ($i -lt $totalSamples) { Start-Sleep -Seconds $Interval }
    }
  } finally {
    $ended = Get-Date
    if ($failRun -ge $FailThreshold -and $outageStart) {
      $secs = [int][math]::Round(($ended - $outageStart).TotalSeconds, 0)
      [void]$events.Add([pscustomobject]@{ Time = $outageStart.ToString('HH:mm:ss'); Type = '断流(未恢复)'; Seconds = $secs; State = $outageState; Detail = "监控结束时仍未恢复，已持续约 ${secs}s" })
    }

    if ($csvWriter) {
      try { $csvWriter.Flush(); $csvWriter.Close() } catch { Warn "CSV 收尾失败：$($_.Exception.Message)" }
      Info "CSV 已边采边写完成：$csvPath"
    } elseif ($samples.Count) {
      # 增量写入不可用时的兜底：结束时一次性写出（统一带 BOM 的 UTF-8：5.1 的 'UTF8' 自带 BOM，7.x 需显式 'utf8BOM'）
      try { $csvEnc = if ($PSVersionTable.PSVersion.Major -ge 7) { 'utf8BOM' } else { 'UTF8' }; $samples | Export-Csv -Path $csvPath -NoTypeInformation -Encoding $csvEnc } catch { Warn "CSV 写入失败：$($_.Exception.Message)" }
    }

    # ---- 统计 ----
    $okS = @($samples | Where-Object { $_.Ok })
    $msArr = @($okS | Where-Object { $_.MinMs -ne $null } | ForEach-Object { [double]$_.MinMs } | Sort-Object)
    $rate = if ($samples.Count) { [math]::Round(100 * $okS.Count / $samples.Count, 2) } else { 0 }
    $statMin = ''; $statMed = ''; $statP95 = ''; $statMax = ''; $statAvg = ''; $statJit = ''
    if ($msArr.Count) {
      $statMin = $msArr[0]
      $statMed = $msArr[[int]($msArr.Count / 2)]
      $statP95 = $msArr[[math]::Min($msArr.Count - 1, [int][math]::Floor($msArr.Count * 0.95))]
      $statMax = $msArr[$msArr.Count - 1]
      $statAvg = [math]::Round(($msArr | Measure-Object -Average).Average, 1)
      $jit = 0
      for ($k = 1; $k -lt $msArr.Count; $k++) { $jit += [math]::Abs($msArr[$k] - $msArr[$k - 1]) }
      $statJit = [math]::Round($jit / [math]::Max(1, $msArr.Count - 1), 1)
    }
    $slowS = @($okS | Where-Object { $_.MinMs -ne $null -and $_.MinMs -gt $SlowMs })
    $outages = @($events | Where-Object { $_.Type -like '断流*' })
    $stateChanges = @($events | Where-Object { $_.Type -in '状态变化', '疑似休眠' })
    $outageSeconds = 0; foreach ($o in $outages) { $outageSeconds += [int]$o.Seconds }
    $spanSec = [math]::Max(1, ($ended - $started).TotalSeconds)

    # ---- 分时段（每 5 分钟）----
    $buckets = @()
    if ($samples.Count) {
      $buckets = @($samples | Group-Object { $_.T.AddMinutes(-1 * ($_.T.Minute % 5)).ToString('yyyy-MM-dd HH:mm') } | Sort-Object Name | ForEach-Object {
          $g = @($_.Group)
          $gOk = @($g | Where-Object { $_.Ok })
          $gMs = @($gOk | Where-Object { $_.MinMs -ne $null } | ForEach-Object { [double]$_.MinMs })
          [pscustomobject]@{
            时段 = $_.Name.Substring(11)
            采样 = $g.Count
            成功率 = if ($g.Count) { [math]::Round(100 * $gOk.Count / $g.Count, 0) } else { 0 }
            平均延迟 = if ($gMs.Count) { [math]::Round(($gMs | Measure-Object -Average).Average, 1) } else { $null }
            最大延迟 = if ($gMs.Count) { ($gMs | Measure-Object -Maximum).Maximum } else { $null }
          }
        })
    }

    # ---- 同期 Windows 系统事件 ----
    $sysEvents = @(); $sysNote = ''
    try {
      $raw = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $started; EndTime = $ended } -ErrorAction Stop)
      $sysEvents = @($raw | Where-Object { $_.ProviderName -match 'NDIS|RNDIS|Netwtw|USB|usbhub|Kernel-PnP|Dhcp|Tcpip|WLAN|BTHUSB|Power-Troubleshooter' -or $_.Message -match 'RNDIS|NDIS|USB' } | Select-Object -First 60)
    } catch {
      if ("$($_.Exception.Message)" -match 'No events|未找到|找不到') { $sysEvents = @() }
      else { $sysNote = "系统事件未能读取（$($_.Exception.Message)）。可能是权限不足或日志被清空；如需事件关联，请用管理员权限重跑。" }
    }
    if (-not $sysEvents.Count -and -not $sysNote) { $sysNote = '同期没有与 USB / 网络相关的系统事件。' }

    # ---- 自动结论 ----
    $concl = @()
    if ($outages.Count -eq 0) {
      $concl += "监控 $([math]::Round($spanSec / 60, 1)) 分钟内未发生断流，链路在该时段是稳定的 —— 可作为后续对比的基线。"
    } else {
      $downOut = @($outages | Where-Object { $_.State -and $_.State -ne 'Up' })
      $upOut = @($outages | Where-Object { $_.State -eq 'Up' })
      if ($downOut.Count) { $concl += "有 $($downOut.Count) 次断流时适配器**不在 Up 状态** → 指向 USB 侧：线材接触不良、USB 口供电或挂起、驱动重载。" }
      if ($upOut.Count) { $concl += "有 $($upOut.Count) 次断流时适配器**仍为 Up** → 物理链路正常但无连通：指向手机侧（信号 / 制式切换 / 达量限速 / 省电策略）或运营商。" }
      $concl += "断流共 $($outages.Count) 次，累计约 ${outageSeconds}s，占监控时长 $([math]::Round(100 * $outageSeconds / $spanSec, 2))%。"
    }
    if ($stateChanges.Count) { $concl += "期间发生 $($stateChanges.Count) 次接口状态 / 地址变化（见第 3 节）；IPv4 或网关变化通常意味着 DHCP 续约或手机侧重新分配。" }
    if ($sleepEvents) { $concl += "监控期间检测到 $sleepEvents 次采样间隔异常（疑似睡眠 / 休眠），相应时段无采样，睡眠时长已从断流统计中剔除。" }
    if ($msArr.Count -and $slowS.Count) { $concl += "有 $($slowS.Count) 次采样延迟超过 ${SlowMs}ms，占成功样本的 $([math]::Round(100 * $slowS.Count / $msArr.Count, 1))%，存在明显劣化 / 拥塞。" }
    if ($statJit -ne '' -and $statJit -gt 30) { $concl += "整体抖动 ${statJit}ms 偏高，链路不够平稳。" }
    $lk = @($samples | Where-Object { $_.LinkSpeed } | Select-Object -ExpandProperty LinkSpeed -Unique)
    if ($isUsb -and ($lk -match '12 Mbps|12Mbps')) { $concl += "监控期间 USB 链路出现过 12Mbps（USB 全速）→ 线材或接口问题的直接证据。" }
    $concl += "对照方法：手机端自己测速很快、而这里成功率/延迟差 → 瓶颈在电脑或 USB 侧；两边都差 → 瓶颈在无线侧。"

    # ---- 写报告 ----
    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# tether-doctor 挂机监控报告')
    [void]$md.Add('')
    [void]$md.Add('| 项 | 值 |')
    [void]$md.Add('|---|---|')
    [void]$md.Add("| 开始 | $($started.ToString('yyyy-MM-dd HH:mm:ss')) |")
    [void]$md.Add("| 结束 | $($ended.ToString('yyyy-MM-dd HH:mm:ss')) |")
    [void]$md.Add("| 时长 | $([math]::Round($spanSec / 60, 1)) 分钟（采样 $($samples.Count) 次，间隔 ${Interval}s） |")
    [void]$md.Add("| 共享网卡 | $($ad.Name) — $($ad.InterfaceDescription)（ifIndex $($ad.ifIndex)） |")
    [void]$md.Add("| 探测目标 | $(($targets | ForEach-Object { "$($_.Host):$($_.Port)" }) -join '、') |")
    [void]$md.Add("| 判定规则 | 连续失败 $FailThreshold 次 = 断流；延迟 > ${SlowMs}ms = 劣化 |")
    [void]$md.Add('')
    [void]$md.Add('## 1. 总览')
    [void]$md.Add('')
    [void]$md.Add('| 指标 | 值 |')
    [void]$md.Add('|---|---|')
    [void]$md.Add("| 成功率 | $rate%（成功 $($okS.Count) / 失败 $($samples.Count - $okS.Count)） |")
    [void]$md.Add("| 延迟 最小/中位/P95/最大 (ms) | $statMin / $statMed / $statP95 / $statMax |")
    [void]$md.Add("| 平均延迟 (ms) | $statAvg |")
    [void]$md.Add("| 相邻抖动均值 (ms) | $statJit |")
    [void]$md.Add("| 劣化样本 (>${SlowMs}ms) | $($slowS.Count) |")
    [void]$md.Add("| 断流事件 | $($outages.Count) 次，累计约 ${outageSeconds}s |")
    [void]$md.Add('')
    [void]$md.Add('## 2. 断流事件（证据链）')
    [void]$md.Add('')
    if ($outages.Count) {
      [void]$md.Add('| 开始 | 持续 | 适配器状态 | 说明 |')
      [void]$md.Add('|---|---|---|---|')
      foreach ($o in $outages) { [void]$md.Add("| $($o.Time) | $($o.Seconds)s | $($o.State) | $($o.Detail) |") }
    } else { [void]$md.Add('未发生断流。') }
    [void]$md.Add('')
    [void]$md.Add('## 3. 接口状态 / 地址变化（含疑似休眠）')
    [void]$md.Add('')
    if ($stateChanges.Count) {
      [void]$md.Add('| 时间 | 变化 |')
      [void]$md.Add('|---|---|')
      foreach ($e in $stateChanges) { [void]$md.Add("| $($e.Time) | $($e.Detail) |") }
    } else { [void]$md.Add('无变化。') }
    [void]$md.Add('')
    [void]$md.Add('## 4. 分时段趋势（每 5 分钟）')
    [void]$md.Add('')
    if ($buckets.Count) {
      [void]$md.Add('| 时段 | 采样 | 成功率 | 平均延迟(ms) | 最大延迟(ms) |')
      [void]$md.Add('|---|---|---|---|---|')
      foreach ($b in $buckets) { [void]$md.Add("| $($b.时段) | $($b.采样) | $($b.成功率)% | $($b.平均延迟) | $($b.最大延迟) |") }
    } else { [void]$md.Add('无数据。') }
    [void]$md.Add('')
    [void]$md.Add('## 5. 同期 Windows 系统事件')
    [void]$md.Add('')
    if ($sysEvents.Count) {
      [void]$md.Add('| 时间 | 来源 | 级别 | 事件ID | 摘要 |')
      [void]$md.Add('|---|---|---|---|---|')
      foreach ($e in $sysEvents) {
        $msg = (($e.Message -split "`r?`n")[0])
        if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) + '…' }
        [void]$md.Add("| $($e.TimeCreated.ToString('HH:mm:ss')) | $($e.ProviderName) | $($e.LevelDisplayName) | $($e.Id) | $($msg -replace '\|', '/') |")
      }
    } else { [void]$md.Add($sysNote) }
    [void]$md.Add('')
    [void]$md.Add('## 6. 自动结论')
    [void]$md.Add('')
    foreach ($c in $concl) { [void]$md.Add("- $c") }
    [void]$md.Add('')
    [void]$md.Add('## 7. 原始数据')
    [void]$md.Add('')
    [void]$md.Add("逐次采样记录（CSV，可直接用 Excel 画图）：``$csvPath``")
    [void]$md.Add('')
    [void]$md.Add('> CSV 为边采边写：即使监控被强杀 / 断电，已完成的样本也保留在文件中。')
    [void]$md.Add('> 想看清「开热点 / 接电话 / 换位置」是否与断流相关，把当时记下的时刻与第 2、4 节的时间戳对齐即可。')

    try {
      [IO.File]::WriteAllText($mdPath, ($md -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
      Ok "监控报告：$mdPath"
      Ok "原始数据：$csvPath"
    } catch { Bad "报告写入失败：$($_.Exception.Message)" }

    Write-Host ''
    Info "成功率 $rate%　平均延迟 $statAvg ms　抖动 $statJit ms　断流 $($outages.Count) 次"
    foreach ($c in $concl) { Info $c }
  }
}
elseif ($Test) {
  Section "10. 实测：TCP 往返 / 丢包 / 抖动（不发大文件，仅几十 KB）"
  function Test-Tcp([string]$Target, [int]$Port, [int]$Count) {
    $t = New-Object System.Collections.ArrayList; $fail = 0
    for ($i = 0; $i -lt $Count; $i++) {
      $sw = [Diagnostics.Stopwatch]::StartNew(); $c = New-Object Net.Sockets.TcpClient
      try {
        $iar = $c.BeginConnect($Target, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(5000)) { $c.EndConnect($iar); $sw.Stop(); [void]$t.Add($sw.Elapsed.TotalMilliseconds) } else { $fail++ }
      } catch { $fail++ } finally { $c.Close() }
    }
    if ($t.Count -eq 0) { Bad "$Target`:$Port —— $Count 次全部失败（也可能该目标本就不在 $Port 提供服务，以 www.baidu.com 那条为准）"; return $null }
    $s = $t | Sort-Object
    $jit = 0; for ($i = 1; $i -lt $t.Count; $i++) { $jit += [math]::Abs($t[$i] - $t[$i - 1]) }
    $avg = ($t | Measure-Object -Average).Average
    $line = "{0}:{1}  成功 {2}/{3}  最小 {4:N0}ms  中位 {5:N0}ms  平均 {6:N0}ms  最大 {7:N0}ms  抖动 {8:N0}ms" -f `
      $Target, $Port, $t.Count, $Count, $s[0], $s[[int]($s.Count / 2)], $avg, $s[$s.Count - 1], ($jit / [math]::Max(1, $t.Count - 1))
    if ($fail -gt 0) { Bad $line } elseif ($s[$s.Count - 1] -gt 300 -or ($jit / [math]::Max(1, $t.Count - 1)) -gt 30) { Warn $line } else { Ok $line }
    [pscustomobject]@{
      Target = "$Target`:$Port"; Ok = $t.Count; Total = $Count; Fail = $fail
      MinMs = [math]::Round($s[0], 1); MedMs = [math]::Round($s[[int]($s.Count / 2)], 1); AvgMs = [math]::Round($avg, 1)
      MaxMs = [math]::Round($s[$s.Count - 1], 1); JitterMs = [math]::Round($jit / [math]::Max(1, $t.Count - 1), 1)
    }
  }
  $r = Test-Tcp '223.5.5.5' 443 $TestCount; if ($r) { $script:testStats += $r }        # 阿里公共DNS，纯 IP、不依赖 DNS 解析
  $r = Test-Tcp 'www.baidu.com' 443 $TestCount; if ($r) { $script:testStats += $r }    # 真实站点，含 DNS 解析与首连
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { [void][System.Net.Dns]::GetHostAddresses('www.baidu.com'); $sw.Stop(); Info ("DNS 解析 www.baidu.com 用时 {0:N0} ms" -f $sw.Elapsed.TotalMilliseconds) } catch { Warn 'DNS 解析失败' }
  Info '（想看真实带宽请用浏览器 Speedtest，或手机端直接测速对比：若手机很快、电脑很慢才说明瓶颈在电脑/USB）'
}

# ---------------------------------------------------------------- 11. 手机端清单
Section "11. 手机端清单"
Info '各品牌完整菜单路径见 docs/PHONE-SETTINGS.md（华为/荣耀、小米/红米、OPPO/一加/realme、vivo/iQOO、三星、魅族、努比亚/红魔）'
@(
  '关「智能切换上网卡 / 自动切换数据卡」—— 掉线第一大来源',
  '关「WLAN+ / WLAN 助理 / 智能网络切换」—— 避免在 WLAN 与移动数据之间反复切换',
  '开「休眠时始终保持网络连接」（部分系统叫「始终连接」）',
  'USB 共享网络开关：通常在「个人热点 / 热点与网络共享」里的「更多共享设置」',
  '弱信号时锁 4G：拨号盘 *#*#4636#*#* → 手机信息 → 设置首选网络类型 → LTE only（部分版本已封禁该项）',
  '开发者选项 → 关闭「USB 调试」，可顺带消掉 HDB Interface 报错（USB 共享本身不需要它）',
  '省电模式关掉；共享时别同时开手机侧 VPN（会把共享流量一起拖进去）',
  '确认走的是没被达量限速的那张卡（限速后只有约 1Mbps，是「突然变慢」的头号原因）',
  '同时开 Wi-Fi 热点时，电脑侧带宽会被热点设备分走 —— 同一条蜂窝链路，手机内部没有 QoS 能给你优先'
) | ForEach-Object { Todo $_ }

# ---------------------------------------------------------------- 汇总
Section "汇总"
if ($Watch -gt 0 -and $mdPath) { Ok "监控报告：$mdPath"; Ok "原始数据：$csvPath" }
if ($script:changes.Count) { Write-Host "  本次改动：" -ForegroundColor Cyan; $script:changes | ForEach-Object { Ok $_ } }
elseif ($Apply -or $Revert) { Info '本次没有实际改动（可能都已是最优，或缺少管理员权限）' }
else { Info '只读体检完成，零写入。要落地安全项请用 .bat 提权后加 -Apply' }

# ---------------------------------------------------------------- 诊断包导出（-Export，可选）
if ($Export) { Invoke-Export }

Write-Host ''

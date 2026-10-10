<#
  tether-doctor.ps1 —— 手机 USB 共享网络 体检 / 优化 / 回滚
  适用：Windows 10/11 + 安卓手机 USB(tethering) 共享网络
  用法：
    .\tether-doctor.ps1              仅体检（零写入，默认）
    .\tether-doctor.ps1 -Test        体检 + 延迟/丢包实测（只用几十 KB 流量）
    .\tether-doctor.ps1 -Apply       落地安全项（需管理员）
    .\tether-doctor.ps1 -Revert      回滚本脚本做过的改动（需管理员）
  设计原则：默认绝不写入；-Apply 只做可逆、有把握的四件事，Hub 那类只能手点的会打印清单。
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Revert,
  [switch]$Test,
  [string[]]$Dns = @('223.5.5.5', '119.29.29.29'),
  [int]$TestCount = 20
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:changes = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host ("=" * 66) -ForegroundColor DarkGray; Write-Host " $t" -ForegroundColor Cyan; Write-Host ("=" * 66) -ForegroundColor DarkGray }
function Ok($t)     { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn($t)   { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Bad($t)    { Write-Host "  [问题] $t" -ForegroundColor Red }
function Info($t)   { Write-Host "  · $t" -ForegroundColor Gray }
function Todo($t)   { Write-Host "  [待办] $t" -ForegroundColor Magenta }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mode = if ($Apply) { 'APPLY（落地改动）' } elseif ($Revert) { 'REVERT（回滚）' } else { 'REPORT（只读体检）' }

Section "环境"
Info ("PowerShell {0} / {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
if ($isAdmin) { Ok '当前以管理员身份运行' } else { Warn '当前不是管理员：体检查得全，但 -Apply / -Revert 会失败（用随附的 .bat 提权运行）' }
Info "运行模式：$mode"

# ---------------------------------------------------------------- 1. 找到共享适配器
Section "1. 共享网络适配器"
$cands = @()
try {
  $cands = Get-NetAdapter -ErrorAction Stop | Where-Object {
    $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'NDIS|RNDIS|Remote|Tether|Gadget|Internet Sharing' -or $_.Name -match 'NDIS')
  }
} catch { Bad "Get-NetAdapter 失败：$($_.Exception.Message)" }

if (-not $cands) {
  Bad '没有找到 USB 共享网络适配器。请确认手机已插好并已在手机上打开「USB 共享网络」。'
  $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
  if ($up) { Info ('当前处于已连接状态的网卡：' + (($up | ForEach-Object { "$($_.Name)($($_.InterfaceDescription))" }) -join '、')) }
  return
}
if (@($cands).Count -gt 1) { Warn "找到多个候选适配器，取第一个；如有误请按接口名自行调整。" }
$ad = @($cands)[0]

Info "接口名        : $($ad.Name)"
Info "描述          : $($ad.InterfaceDescription)"
Info "ifIndex / MAC : $($ad.ifIndex) / $($ad.MacAddress)"
Info "PnP 实例      : $($ad.PnPDeviceID)"

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
if ($link -ge 100) {
  Ok "USB 链路协商速率 $($ad.LinkSpeed) —— 线材/USB 口没问题，瓶颈不在这里"
} elseif ($link -gt 0) {
  Bad "USB 链路只有 $($ad.LinkSpeed)（典型 12Mbps = USB 全速）。换数据线、直插 USB 3.0 口、别用扩展坞/HUB。"
} else { Warn "读不到链路速率：$($ad.LinkSpeed)" }

# ---------------------------------------------------------------- 2. USB 父设备链
Section "2. USB 物理链路（手机插在哪一级）"
$hubName = $null; $portInfo = $null; $hubInst = $null
if ($ad.PnPDeviceID) {
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
    try { Disable-NetAdapterPowerManagement -Name $ad.Name -Confirm:$false -ErrorAction Stop; [void]$script:changes.Add("已禁用网卡 $($ad.Name) 的电源管理"); Ok '已禁用该网卡的电源管理' }
    catch { Warn "禁用失败：$($_.Exception.Message)" }
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
    powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    [void]$script:changes.Add('已恢复全局 USB 选择性暂停=启用')
    Ok '已恢复为「启用」'
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
      try { Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric 1 -ErrorAction Stop; [void]$script:changes.Add("已把 $($ad.Name) 接口跃点设为 1"); Ok '已把共享网卡接口跃点设为 1' }
      catch { Warn "设置跃点失败：$($_.Exception.Message)" }
    } else { Bad '需要管理员权限，跳过' }
  }
} else { Ok '只有一条默认路由，干净' }

# ---------------------------------------------------------------- 7. DNS
Section "7. DNS"
if (-not $dnsNow) { Warn '当前走 DHCP 下发的 DNS（运营商 DNS 常较慢/不稳）' } else { Info "当前：$($dnsNow -join ', ')" }
if ($Apply) {
  if ($isAdmin) {
    try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $Dns -ErrorAction Stop; [void]$script:changes.Add("已把 $($ad.Name) 的 DNS 设为 $($Dns -join ', ')"); Ok "已设为 $($Dns -join ', ')" }
    catch { Warn "设置 DNS 失败：$($_.Exception.Message)" }
  } else { Bad '需要管理员权限，跳过' }
} elseif ($Revert) {
  if ($isAdmin) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue; [void]$script:changes.Add("已把 $($ad.Name) 的 DNS 恢复为自动"); Ok '已恢复为自动获取' }
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
    if ($best -lt $iface.NlMtu) { Todo "建议把该网卡 MTU 调成 $best：netsh interface ipv4 set subinterface `"$($ad.Name)`" mtu=$best store=persistent" }
    else { Ok 'MTU 正常，无需调整' }
  } else { Warn '未能探到（可能全程被拦），维持默认 1500 即可' }
}

# ---------------------------------------------------------------- 9. 异常设备（HDB 等）
Section "9. 异常设备（手机复合设备里有接口报错会周期性重枚举 → 共享瞬断）"
$badDevs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' }
if (-not $badDevs) { Ok '没有异常设备' }
foreach ($b in $badDevs) {
  $isPhone = $b.InstanceId -like ($ad.PnPDeviceID -replace '&MI_\d+.*$', '*')
  $tag = if ($isPhone) { '   ← 属于本手机，优先处理' } else { '' }
  if ($b.Status -eq 'Error') { Bad ("{0}  [{1}]  {2}{3}" -f $b.FriendlyName, $b.Status, $b.InstanceId, $tag) }
  elseif ($b.Status -eq 'Degraded') { Info ("{0}  [{1}]（通常无害）" -f $b.FriendlyName, $b.Status) }
  else { Warn ("{0}  [{1}]  {2}{3}" -f $b.FriendlyName, $b.Status, $b.InstanceId, $tag) }
}
$phoneBad = $badDevs | Where-Object { $_.Status -eq 'Error' -and $_.InstanceId -like ($ad.PnPDeviceID -replace '&MI_\d+.*$', '*') -and $_.InstanceId -notlike '*&MI_00*' }
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

# ---------------------------------------------------------------- 10. 实测（可选）
if ($Test) {
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
    if ($t.Count -eq 0) { Bad "$Target`:$Port —— $Count 次全部失败（也可能该目标本就不在 $Port 提供服务，以 www.baidu.com 那条为准）"; return }
    $s = $t | Sort-Object
    $jit = 0; for ($i = 1; $i -lt $t.Count; $i++) { $jit += [math]::Abs($t[$i] - $t[$i - 1]) }
    $avg = ($t | Measure-Object -Average).Average
    $line = "{0}:{1}  成功 {2}/{3}  最小 {4:N0}ms  中位 {5:N0}ms  平均 {6:N0}ms  最大 {7:N0}ms  抖动 {8:N0}ms" -f `
      $Target, $Port, $t.Count, $Count, $s[0], $s[[int]($s.Count / 2)], $avg, $s[$s.Count - 1], ($jit / [math]::Max(1, $t.Count - 1))
    if ($fail -gt 0) { Bad $line } elseif ($s[$s.Count - 1] -gt 300 -or ($jit / [math]::Max(1, $t.Count - 1)) -gt 30) { Warn $line } else { Ok $line }
  }
  Test-Tcp '223.5.5.5' 443 $TestCount        # 阿里公共DNS，纯 IP、不依赖 DNS 解析
  Test-Tcp 'www.baidu.com' 443 $TestCount    # 真实站点，含 DNS 解析与首连
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { [void][System.Net.Dns]::GetHostAddresses('www.baidu.com'); $sw.Stop(); Info ("DNS 解析 www.baidu.com 用时 {0:N0} ms" -f $sw.Elapsed.TotalMilliseconds) } catch { Warn 'DNS 解析失败' }
  Info '（想看真实带宽请用浏览器 Speedtest，或手机端直接测速对比：若手机很快、电脑很慢才说明瓶颈在电脑/USB）'
}

# ---------------------------------------------------------------- 11. 手机端清单
Section "11. 手机端清单（华为 / 荣耀 MagicOS 为例）"
@(
  '关「智能切换上网卡」：设置 → 移动网络 → SIM 卡管理 → 智能切换上网卡 → 关',
  '关「WLAN+」：设置 → WLAN → 更多设置 → WLAN+ → 关',
  '开「休眠时始终保持网络连接」：设置 → 电池 → 更多电池设置 → 开',
  'USB 共享网络开关：设置 → 移动网络 → 个人热点 → 更多共享设置 → USB 共享网络',
  '弱信号锁 4G：拨号盘输入 *#*#4636#*#* → 手机信息 → 设置首选网络类型 → LTE only（部分版本已封禁该项）',
  '开发者选项 → 关闭「USB 调试」（能顺带消掉 HDB Interface 报错）；USB 共享本身不需要调试开关',
  '省电模式关掉；共享时别同时开 VPN（手机侧 VPN 会把共享流量也拖进去）',
  '确认当前走的是没被达量限速的那张卡（限速后只有 1Mbps，这是「突然变慢」的头号原因）'
) | ForEach-Object { Todo $_ }

# ---------------------------------------------------------------- 汇总
Section "汇总"
if ($script:changes.Count) { Write-Host "  本次改动：" -ForegroundColor Cyan; $script:changes | ForEach-Object { Ok $_ } }
elseif ($Apply -or $Revert) { Info '本次没有实际改动（可能都已是最优，或缺少管理员权限）' }
else { Info '只读体检完成，零写入。要落地安全项请用 .bat 提权后加 -Apply' }
Write-Host ''

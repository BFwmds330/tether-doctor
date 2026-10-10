# 实现原理与判定依据

本文说明每一项检查**为什么这么判**、以及脚本因此做出的取舍。
如果你要改这个脚本，先读这里，避免把「有把握的判定」改成「看起来更聪明的猜测」。

## 设计原则

1. **默认零写入。** 不带参数运行时，脚本只读：`Get-NetAdapter`、`Get-PnpDevice`、`Get-NetRoute`、`powercfg /query`、`HKLM\SYSTEM\CurrentControlSet\Enum\...`（只读）。不动注册表，不改任何设置。
2. **先判定能力，再动手。** 例如电源管理：先用 `Get-NetAdapterPowerManagement` 探测驱动是否支持，支持才提示可改；不支持就给出「这是正常的」结论并跳过。绝不假设「网络适配器都有这个标签页」。
3. **没有可靠等价物的东西，宁可让你手点。** 集线器层的省电勾选框没有可验证的注册表映射，脚本只打印清单，不写猜测出来的值。
4. **不改用户的流量账。** 不做大文件测速。`-Test` 只做 TCP 建连，量级是几十 KB。
5. **每一项改动都可回滚。** `-Apply` 的每一项都有对应的 `-Revert` 路径，或明确指出用哪个官方 cmdlet 还原。

## 逐项依据

### 1. 共享网卡识别

匹配条件：`Status -eq 'Up'` 且 `InterfaceDescription` 命中 `NDIS|RNDIS|Remote|Tether|Gadget|Internet Sharing`。

安卓手机 USB 共享在 Windows 上的标准形态是 **RNDIS**，设备描述为 `Remote NDIS based Internet Sharing Device`（驱动 `wceisvista.inf`）。
注意同一个手机会有 `#2`、`#3` 这样的多实例（换过 USB 口就会新建一个），脚本取当前 `Up` 的那个。

### 2. USB 链路协商速率

`Get-NetAdapter ... LinkSpeed` 对 RNDIS 网卡返回的是 **USB 侧协商速率**：

| 显示值 | 含义 |
|---|---|
| 426 / 480 Mbps | USB 2.0 High Speed —— 正常，USB 不是瓶颈 |
| 5000 Mbps | USB 3.x SuperSpeed —— 更好 |
| **12 Mbps** | USB 1.1 Full Speed —— 线材只有充电线芯、或插在 USB 1.1 口/劣质 Hub 上，实际吞吐会被压到 ~8–10 Mbps |

阈值取 100 Mbps：低于它一定是链路问题，不是运营商问题。这一步的价值在于**把「网慢」和「USB 慢」当场分开**，避免在错误的方向上优化。

### 3. 物理链路还原

从网卡的 `PnPDeviceID` 出发，用 `DEVPKEY_Device_Parent` 逐级向上：

```
Remote NDIS based Internet Sharing Device #2   [位置: 0000.0014.0000.005...]
  └─ USB Composite Device                      [Port_#0005.Hub_#0001]
       └─ USB Root Hub (USB 3.0)
            └─ Intel(R) USB 3.x eXtensible Host Controller
                 └─ PCI Express Root Complex
```

`LocationInfo` 形如 `Port_#0005.Hub_#0001` 的层级用来定位物理端口（脚本会把它记下来，用于在第 5 节标出「手机挂在这个集线器上，优先改它」）。

### 4. 网卡电源管理能力

`Get-NetAdapterPowerManagement` 在 RNDIS 上抛：

```
A device attached to the system is not functioning.   (Windows System Error 31)
```

同时在注册表侧印证：网卡类键 `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\<nnnn>` 下，RNDIS 实例的 `PnPCapabilities`、`DeviceSleepOnDisconnect`、`SelectiveSuspendEnabled` **均为空**（即驱动未注册这些特性）。

结论：**「取消允许计算机关闭此设备」这类建议对 RNDIS 无效**，因为它连这个属性页都没有。
脚本因此把这条最常见的网络建议从「待办」降级为「说明」，避免用户白跑一趟设备管理器。

> 如果换成有厂商驱动的 USB 网卡（如某些 USB 转 RJ45），这一项会命中，脚本才会去执行 `Disable-NetAdapterPowerManagement`。

### 5. 全局 USB 选择性暂停

```powershell
powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3
#  电源设置 GUID: 48e6b7a6-50f5-4782-a5d4-53bb8f07e226  (USB 选择性暂停设置)
#    当前交流电源设置索引: 0x00000001   ← 已启用
```

索引 `0` = 已禁用，`1` = 已启用（默认电源计划里是启用）。
这是**整条 USB 链路的空闲挂起开关**，也是 RNDIS 场景下唯一还能造成「USB 侧瞬断」的系统级开关，所以 `-Apply` 会处理它。
副作用只是待机功耗略增，可逆。

### 6. 集线器层省电

对每个 `-Class USB` 且名称命中 `Hub|集线器` 的设备，读其
`HKLM\SYSTEM\CurrentControlSet\Enum\<InstanceId>\Device Parameters`。

实测这些值**默认根本不存在**（`EnhancedPowerManagementEnabled` / `SelectiveSuspendEnabled` 皆为空），也就是说勾选框处于默认（允许挂起）状态。
由于不存在可验证的注册表等价物，脚本**不代改**，只打印清单：

> 设备管理器 → 通用串行总线控制器 → 逐个「USB 根集线器(USB 3.0)」/「通用 USB 集线器」/「通用 SuperSpeed USB 集线器」→ 属性 → 电源管理 → 取消「允许计算机关闭此设备以节约电源」

### 7. 默认路由与跃点

`Get-NetRoute -DestinationPrefix '0.0.0.0/0'` 返回多条时，说明同时有多个网络在线（典型：Wi-Fi + USB 共享）。
两条默认路由会让流量在两个出口之间摆动，表现为忽快忽慢、偶发断流。
`-Apply` 仅在**确实存在多路由**时才把共享网卡的 `InterfaceMetric` 设为 1（把共享作为首选出口），避免无谓改动。

### 8. DNS

DHCP 下发的通常是网关地址（运营商 DNS）。换公共 DNS 主要收益在**解析耗时**，对「打开网页的体感」影响远大于带宽。
默认写入 `223.5.5.5 / 119.29.29.29`（国内公共 DNS），可用 `-Dns` 覆盖。

### 9. MTU 探测

先用普通 ICMP 探一次可达性；不可达就直接放弃（有些网络/安全软件会拦 ICMP，此时换 MTU 也没依据）。
可达则在 **1472 → 1200 按 8 字节步进递减**，用 `PingOptions(64, $true)` 打 DF 位，第一个成功的尺寸 + 28 即为 MTU。

- 结果粒度是 8 字节，所以是**近似值**：报 1428 意味着真实最大 MTU 落在 1428–1435。
- 步进 8 是刻意选择：更细的粒度收益极小，却会成倍增加探测次数。
- 改 MTU 的收益场景是「小包正常、大包丢」；`netsh interface ipv4 set subinterface "<接口名>" mtu=<n> store=persistent` 应用，`mtu=1500` 还原。

### 10. 异常设备归因

取 `Get-PnpDevice -PresentOnly` 中 `Status -ne 'OK'` 的设备，再判断它是否**属于本手机**：
用共享网卡的实例 ID 去掉 `&MI_xx` 后缀作为前缀匹配（`USB\VID_xxxx&PID_xxxx*`），并排除 `&MI_00`（那正是 RNDIS 本身，绝不能动）。

典型命中：华为/荣耀机型开启 USB 调试后出现的 `HDB Interface`（`...&MI_02`），未安装官方驱动时长期处于 Error。
**为什么它重要**：一个复合设备里只要有一个接口加载失败，Windows 会周期性重试枚举该设备，表现为共享网络毫无规律的瞬断。
`-Apply` 会 `Disable-PnpDevice` 它；`-Revert` 用 `Enable-PnpDevice` 恢复。

### 11. `-Test` 延迟实测

用 `TcpClient.BeginConnect` + 5s 超时，对两个目标各打 N 次：

- `223.5.5.5:443` —— 纯 IP，不依赖 DNS，测纯链路往返；
- `www.baidu.com:443` —— 真实站点，含 DNS 解析与首连开销。

输出最小 / 中位 / 平均 / 最大 / 相邻抖动均值。判定：出现失败、或最大值 >300ms、或抖动 >30ms 则标黄/标红。
**曾经踩过的坑**：早期版本探测 `119.29.29.29:443`，但该地址本就不在 443 提供服务，于是永远报「丢包 100%」——假警报比没有检查更糟。教训是**探测目标必须确知在该端口有服务**。

## 已知限制与取舍

| 限制 | 原因 / 取舍 |
|---|---|
| 仅 Windows | 依赖 `Get-NetAdapter` / `Get-PnpDevice` / `powercfg`，这些是 Windows 专有 |
| 集线器省电只能手点 | 无可验证的注册表映射，写猜测值风险大于收益 |
| MTU 为近似值 | DF 试探步进 8 字节，且部分网络拦截 ICMP |
| 不做带宽测速 | 用户常在按流量计费的链路上运行，大文件测速是伤害而非帮助 |
| 手机菜单路径会过期 | 以 MagicOS 为准；脚本第 11 节只是清单，不影响其余判定的正确性 |

## 调试与验证建议

- 想验证「USB 侧没问题」，对照第 2 节的 `LinkSpeed` 与第 10 节的实测抖动：若两者都正常而速度仍差，问题在无线侧。
- 想验证改动是否生效：跑完 `-Apply` 立刻再跑一次只读体检，第 4、7、9 节会反映新状态。
- 脚本本身是纯文本，`[System.Management.Automation.Language.Parser]::ParseFile()` 可在不执行的情况下做语法校验。
- **编辑 `tether-doctor.ps1` 后必须以 UTF-8 with BOM 保存**，否则 Windows PowerShell 5.1 会按 ANSI 解码中文，直接抛一堆 `Unexpected token`。

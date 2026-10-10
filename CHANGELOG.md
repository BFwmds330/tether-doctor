# Changelog

本项目的所有重要变更都会记录在这里。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.0] - 2026-10-10

本次新增三块能力：**长时间挂机监控**、**CI 与自动发版**、**全品牌手机菜单清单**。

### 新增

- **`-Watch <分钟>` 长时间挂机监控（抓「偶发瞬断」的证据链）**
  - 按 `-Interval`（默认 3 秒）持续采样：TCP 往返 + 网卡状态 + 链路速率 + IPv4 + 网关
  - **断流事件**：连续失败 `-FailThreshold` 次（默认 2）判定为一次断流，记录起止与持续时长
  - **接口状态变化**：适配器 Up/Down、链路速率变化、IP 或网关变化，逐条带时间戳记录
  - **自动结论**：断流时适配器是否仍为 Up，直接分清「USB 侧」还是「无线侧」；
    出现 12Mbps 会点名为线材/接口问题；延迟劣化与抖动超标单独提示
  - **同期 Windows 系统事件**：把 NDIS / RNDIS / Netwtw / USB / DHCP / Tcpip 等来源的事件与断流时间对齐
  - 输出 Markdown 报告（总览 / 断流事件 / 状态变化 / 每 5 分钟趋势 / 系统事件 / 自动结论）
    + CSV 原始数据（可直接用 Excel 画图）
  - `Ctrl+C` 中断也会照常生成报告；建议配合手记「开热点 / 接电话 / 换位置」的时刻做因果对齐

- **显式指定网卡：`-AdapterName <接口名>` / `-InterfaceIndex <编号>`**
  - 用于自动识别不中、或想监控 Wi-Fi / 以太网链路的场景
  - 指向非 USB 网卡时，USB 专属判定（父设备链还原、USB 全速判定、复合设备接口归因）会**自动跳过**并说明原因

- **GitHub Actions 自动化**
  - `CI`：编码校验（`.ps1` 必须 UTF-8 with BOM + CRLF，`.bat` 必须无 BOM + CRLF）、
    语法校验、冒烟运行（含 `-Watch` 报告生成）、打包并上传产物；PSScriptAnalyzer 作信息性检查
  - `Release`：推 `v*.*.*` tag 即自动校验 → 打包 → 从 CHANGELOG 生成发布说明 → 创建/更新 Release 并上传 zip
  - 两者复用同一套脚本：`build/build.ps1`、`build/get-release-notes.ps1`、`tests/*.ps1`

- **`docs/PHONE-SETTINGS.md` 全品牌菜单清单**
  - 覆盖华为/荣耀、小米/Redmi/POCO、OPPO/一加/realme、vivo/iQOO、三星、魅族、努比亚/红魔、原生 Android/Pixel
  - 每品牌给出：USB 共享开关、关智能切换数据卡、关 WLAN 助理、休眠保持连接、锁 4G、开发者选项
  - 附「同一功能的各种叫法」对照表与关键词搜法（比记路径可靠）

### 变更

- 脚本头部改为规范的**注释帮助**（`.SYNOPSIS` / `.PARAMETER` / `.EXAMPLE`），便于 `Get-Help`（注意：若系统缺 PSHOME 帮助文件，`Get-Help` 可能整体不可用）
- 监控循环不再在最后一次采样后空等一个 `-Interval`
- 手机端清单精简为通用项，详细路径移入 `docs/PHONE-SETTINGS.md`

### 修复

- 挂机监控的**每 5 分钟分桶失效**：原实现只清掉秒、未清毫秒，导致每个采样自成一桶；
  改为按 `yyyy-MM-dd HH:mm` 字符串分桶
- 挂机监控在**同期没有任何系统事件时误报「读取系统事件失败」**：`Get-WinEvent` 在无匹配时会抛
  「No events were found」，现单独识别该情形并正确表述
- 「预计结束时间」被当成字面量文本打印（字符串内子表达式边界错误）

### 说明

- 兼容 Windows PowerShell 5.1 与 PowerShell 7+；`tether-doctor.ps1` 必须以 **UTF-8 with BOM** 保存，否则 5.1 会把中文读成乱码并报语法错误（CI 已加校验）。
- 不修改注册表；不代改集线器层省电开关（无可靠注册表等价物，改为打印手动清单）。

## [1.0.0] - 2026-10-10

首个发布版本。

### 新增

- **体检（默认只读，零写入）**
  - 自动识别 RNDIS / Tethering 共享网卡，输出 IP、网关、MTU、跃点、DNS
  - USB 链路协商速率判定（`<100 Mbps` 直接判定为线材或 USB 口问题）
  - 沿父设备链还原物理链路：手机 → 复合设备 → 集线器 → 控制器 → 端口
  - 网卡电源管理能力探测：不支持时明确说明「没有该标签页是正常的」
  - 全局 USB 选择性暂停状态（AC / DC 分别报告）
  - USB 集线器省电开关清单，并标出手机所挂的那一个
  - 默认路由条数与跃点检查（多网关 = 抖动）
  - DNS 现状检查
  - MTU 探测（ICMP DF 位试探，输出建议值与 `netsh` 命令）
  - 异常设备归因：标出属于本手机且处于 Error 状态的接口（如 `HDB Interface`）
  - 手机端设置清单

- **`-Test` 实测**：TCP 往返 ×N（最小 / 中位 / 平均 / 最大 / 抖动）+ DNS 解析耗时；不做大文件下载

- **`-Apply` 落地（4 项，全部可逆）**：关闭全局 USB 选择性暂停、设置共享网卡 DNS、
  网卡支持电源管理时禁用之、禁用属于本手机且报错的非 RNDIS 接口

- **`-Revert` 回滚**：撤销上述可逆项

- **配套脚本**：`1-check.bat` / `2-apply.bat` / `3-revert.bat`，双击即用、自动提权

# optimize_fix.sh — TCP/IP 网络优化脚本

> 版本 3.2 · 适用系统：Debian / Ubuntu / CentOS / AlmaLinux / Rocky Linux

根据**目标带宽、目标 RTT 和物理内存**推导并写入一套保守的 TCP/IP 内核参数，可选启用 BBR + FQ、IPv4/IPv6 转发和 nf_conntrack 调优。所有修改先备份，失败自动回滚，并支持按次逐层恢复。

---

## 目录

- [特性](#特性)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [命令行用法](#命令行用法)
- [交互流程](#交互流程)
- [参数计算规则](#参数计算规则)
- [写入与管理的文件](#写入与管理的文件)
- [备份、回滚与恢复](#备份回滚与恢复)
- [冲突配置处理](#冲突配置处理)
- [安全设计](#安全设计)
- [输出与退出码](#输出与退出码)
- [注意事项与边界](#注意事项与边界)
- [常见问题](#常见问题)
- [卸载](#卸载)

---

## 特性

1. **按链路条件计算缓冲区**：以 `BDP = 带宽 × RTT` 为基准，单连接缓冲默认取 2×BDP，内存不足时退到 1.5×BDP，并受物理内存硬性收敛。
2. **全局 TCP 内存水位**：`net.ipv4.tcp_mem` 按单连接页数和可支撑大流数推导，上限不超过物理内存的 25%。
3. **队列参数按内存伸缩**：`netdev_max_backlog`、`somaxconn`、`tcp_max_syn_backlog` 随内存线性增长并取 2 的幂，小内存机器不会被大队列拖垮。
4. **自动检测 BBR / FQ**：仅在内核确实提供时启用；BBR 可用但 FQ 不可用时，保留原 qdisc 并给出提示。
5. **可选 UDP 最小缓冲区**：避免小包/低速率 UDP 流量被默认值压制。
6. **可选 IPv4 / IPv6 转发**，并在检测到本机已在转发时，把 conntrack 相关选项的默认值改为 `y`。
7. **可选 nf_conntrack 调优**：容量与超时分开控制；容量不会低于当前使用量。
8. **安全备份 + 事务回滚**：写配置前完整备份，应用失败或收到 INT/TERM 信号时自动恢复。
9. **冲突配置检测**：识别会覆盖本脚本参数的其他 sysctl 文件，可按需移除或只注释冲突行。
10. **逐层恢复**：每次优化都记录上一次备份，可连续回退多个历史版本。

---

## 环境要求

- Linux，**root 权限**（脚本启动即检查 `EUID`）。
- **Bash 4.0+**（脚本使用关联数组）。
- 基础命令：`sysctl mktemp cp mv rm mkdir chmod chown stat date grep tee basename dirname awk cat id`，缺失会直接退出。
- 可选命令：`modprobe`（加载 BBR/FQ/conntrack）、`getconf`（页大小探测）、`dpkg`（提示冲突文件所属软件包）。

脚本通过 `/etc/os-release`（回退 `/etc/debian_version`、`/etc/redhat-release`）识别系统，从 `/proc/meminfo` 读取内存；读取失败时按 1024 MB 估算并告警。

> 建议在 `tmux` / `screen` 或带外控制台的会话中运行，尤其是要开启转发或机器承担生产流量时。

---

## 快速开始

```bash
# 1. 赋予执行权限
chmod +x optimize_fix.sh

# 2. 以 root 运行（进入交互菜单）
sudo ./optimize_fix.sh

# 也可以直接指定动作
sudo ./optimize_fix.sh --optimize
```

不想改权限时可用 `sudo bash optimize_fix.sh`。

---

## 命令行用法

```
用法:
  ./optimize_fix.sh              交互菜单（优化 / 恢复 / 退出）
  ./optimize_fix.sh --optimize   直接进入优化流程
  ./optimize_fix.sh --restore    恢复最近一次配置
  ./optimize_fix.sh --help       显示帮助
```

| 参数 | 行为 |
| --- | --- |
| 无参数 | 显示横幅后进入菜单：`1) 优化网络配置` `2) 恢复最近一次配置` `3) 退出` |
| `--optimize` | 跳过菜单，直接执行优化流程（仍然会逐项询问配置） |
| `--restore` | 恢复最近一次成功备份，恢复前需再次确认 |
| `--help` / `-h` | 打印用法后退出，**不要求 root** |
| 其他值 | 打印用法并以状态码 1 退出 |

脚本**没有非交互模式**，也不支持通过命令行覆盖带宽、RTT、转发等选项；所有选项都在运行过程中询问。

---

## 交互流程

`--optimize` 的完整顺序如下：

1. 询问**是否开启 IPv4 转发**（默认 `N`，仅路由器/NAT 网关需要）。
2. 询问**是否开启 IPv6 转发**（默认 `N`，可能影响 RA/SLAAC 默认路由）。
3. 读取当前 `ip_forward` / `IPv6 forwarding`；若本机已在转发（或上一步选了开启），提示 conntrack 表更容易打满，并把下面两项默认值改为 `y`：
   - 是否调优 `nf_conntrack`；
   - 是否缩短 conntrack 空闲连接超时（仅在上一步选 `y` 时询问）。
4. 输入**目标带宽**（Mbps，1–1000000，默认 1000）。
5. 输入**目标 RTT**（毫秒，1–60000，默认 100）。
6. 询问**是否写入登录会话 nofile 限制**（默认 `N`；systemd 服务通常需在单元里单独配置 `LimitNOFILE`）。
7. 检测内核功能（BBR / FQ / conntrack）→ 计算参数 → 检查 sysctl 冲突 → 备份 → 写入并应用 → 验证并打印摘要。

输入校验：布尔问题只接受 `y/Y/yes/...` 与 `n/N/no/...`；数字必须是非负整数且落在给定区间，否则重新询问。

---

## 参数计算规则

以下 `memory` 为物理内存，`page_size` 默认 4096（用 `getconf PAGESIZE` 探测），所有除法均为整数运算。

### 单连接缓冲区

```
BDP            = 带宽(Mbps) × 125 × RTT(ms)        # 1 Mbps × 1 ms = 125 字节
memory_cap     = memory / 8
socket_cap     = max(memory / 16, 8 MiB)
effective_cap  = min(memory_cap, socket_cap)

desired_buffer = 2   × BDP      # 首选：留一倍余量，能跑满单流
若 > effective_cap：desired_buffer = 1.5 × BDP   # 内存受限，换更多并发
最低 8 MiB；最终仍不得超过 effective_cap
```

写入结果：

```
net.core.rmem_max = net.core.wmem_max = desired_buffer
net.ipv4.tcp_rmem = 4096 262144 desired_buffer
net.ipv4.tcp_wmem = 4096  65536 desired_buffer
```

### 全局 TCP 内存（tcp_mem，单位：页）

```
buffer_pages = desired_buffer / page_size
flows        = clamp(memory_MB / 128, 8, 64)      # 1 GB≈8 条，8 GB≈64 条

high         = buffer_pages × flows × 1.2
high         = min(high, memory_pages / 4)        # 不超过物理内存 25%
high         = max(high, memory_pages × 3 / 32)   # 不压过内核默认量级
high         = max(high, 16384)

pressure     = high × 3/4
low          = high × 5/8
flows_affordable = max(pressure / buffer_pages, 1)  # 摘要里的“可支撑大流数”
```

### 队列长度

```
backlog      = round_pow2(memory_MB × 8, 2048, 32768)   # net.core.netdev_max_backlog
somaxconn    = round_pow2(memory_MB × 8, 4096, 32768)   # net.core.somaxconn
syn_backlog  = round_pow2(memory_MB × 8, 4096, 32768)   # net.ipv4.tcp_max_syn_backlog
```

`round_pow2` 向上取最近的 2 的幂，再夹到上下限。

### 文件句柄

```
nofile_target = min(262144, fs.nr_open)
```

`limits.d` 中 `*` 与 `root` 的 soft/hard nofile 都写为该值。

`fs.file-max` 只在“当前值是有限值（`0 < 当前值 < 2^31`）且小于目标”时抬高，目标为 `max(nofile × 4, 1048576)`；现代内核默认近乎无上限，因此多数情况下脚本不会改它。

### TIME_WAIT 与端口

```
tcp_max_tw_buckets = clamp(memory_MB × 64, 65536, 1048576)
tcp_fin_timeout    = 30 秒
ip_local_port_range= 10240 65535
tcp_notsent_lowat  = 131072
```

### 连接追踪（仅在启用 nf_conntrack 调优时）

```
memory_conntrack_cap = max(memory / 16384, 32768)     # 每条约预留 16 KiB
conntrack_max        = min(262144, memory_conntrack_cap)
conntrack_live_min   = max(当前 count × 1.25 + 1024, 32768)
若 conntrack_max < live_min：抬到 live_min 并告警
```

启用超时调优时写入：`established 7200`、`time_wait 120`、`close_wait 60`、`fin_wait 120`、`syn_recv 60`、`UDP 30`、`UDP stream 120`（秒）。

### 固定写入的参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `net.ipv4.tcp_mtu_probing` | `1` | PMTU 黑洞探测 |
| `net.ipv4.tcp_window_scaling` | `1` | TCP 窗口缩放 |
| `net.ipv4.tcp_moderate_rcvbuf` | `1` | 接收缓冲区自动调整 |
| `net.ipv4.tcp_fastopen` | `3` | TFO 客户端 + 服务端 |
| `net.ipv4.tcp_slow_start_after_idle` | `0` | 空闲后不重置拥塞窗口（利于长连接） |
| `net.ipv4.tcp_timestamps` | `1` | 时间戳，TW 复用的前提 |
| `net.ipv4.tcp_tw_reuse` | `1` | 允许出站连接复用 TIME_WAIT |
| `net.ipv4.tcp_abort_on_overflow` | `0` | 队列溢出保持默认，避免“慢”变“断” |
| `net.ipv4.tcp_syncookies` | `1` | SYN 洪泛保护 |
| `net.ipv4.udp_rmem_min` / `udp_wmem_min` | `16384` | UDP 最小收发缓冲 |

条件写入：`ip_forward`、`net.ipv6.conf.all/default.forwarding`、`nf_conntrack_*`、`tcp_congestion_control=bbr`、`net.core.default_qdisc=fq`、`fs.file-max`。

**不存在的键会被跳过**并汇总提示（例如容器内受限的 netns），不会导致失败。

---

## 写入与管理的文件

| 路径 | 作用 | 何时出现 |
| --- | --- | --- |
| `/etc/sysctl.d/99-z-network-optimize.conf` | 主 sysctl 配置，由脚本生成 | 每次优化 |
| `/etc/modules-load.d/network-optimize.conf` | 开机加载所需模块（`tcp_bbr`、`sch_fq`、`nf_conntrack`） | 每次优化（无模块时只有注释头） |
| `/etc/security/limits.d/99-network-optimize.conf` | 登录会话 nofile 限制 | 仅选择写入时；否则不存在 |
| `/etc/sysctl.d/99-network-optimize.conf` | v3.1 及更早版本的主配置 | 迁移后**删除**（先备份） |
| `/etc/systemd/journald.conf.d/99-network-optimize.conf` | 旧版脚本残留的 journald 配置 | 清理时**删除**（先备份） |
| `/var/lib/network-optimize/` | 状态目录与备份根目录（`0700 root:root`） | 首次运行 |

主配置文件为原子写入：先在同目录创建 `mktemp` 临时文件，`chmod 0644` + `chown root:root` 后 `mv -f` 覆盖，避免半写状态。文件头包含脚本版本、策略、带宽、RTT 和 BDP，便于事后核对。

---

## 备份、回滚与恢复

### 备份结构

```
/var/lib/network-optimize/
├── current                         # 最近一次成功备份的目录名（单行）
└── backups/
    └── 20261126T083000Z.a1b2c3/    # UTC 时间戳 + mktemp 随机后缀
        ├── metadata                # 版本/系统/内存/带宽/RTT/各开关
        ├── manifest                # 每个受管文件 present / absent
        ├── previous                # 上一次备份名，用于逐层回退
        ├── files/                  # 受管文件的原始副本（cp -a 保留属性）
        ├── runtime-sysctl.tsv      # 修改前的运行时参数快照（key<TAB>value）
        ├── apply.log               # sysctl -p 的输出
        ├── conflicts.tsv           # 冲突文件清单及处理方式（如有）
        ├── conflict-files/         # 冲突文件原始副本（如有）
        └── restore-*.log           # 恢复 / 回滚日志
```

`current`、备份目录、`files/` 均为 `0700` 且属主 root；写入 `current` 时同样走“临时文件 + `mv`”。

### 自动回滚

脚本以 `set -Eeuo pipefail` 运行，并注册了 `ERR`、`INT`、`TERM` 陷阱。事务从**备份创建后**开始（`TRANSACTION_ACTIVE=1`），到配置应用成功、`current` 更新完成时结束（`TRANSACTION_ACTIVE=0`）。

在事务窗口内，任何命令失败或收到 Ctrl-C / SIGTERM，都会：

1. 恢复受管配置文件的原始状态（含删除原本不存在的文件）；
2. 还原被移除或注释的冲突文件；
3. 执行 `sysctl --system`；
4. 按 `runtime-sysctl.tsv` 逐项 `sysctl -w` 还原运行时值；
5. 保留失败事务的备份目录以便排查。

注意：应用成功后的**验证阶段只报告差异，不会回滚**（此时事务已经提交）。

### 恢复最近一次配置

`--restore`（或菜单选 2）会：

1. 校验 `current` 指向的备份存在、不是符号链接、目录名合法；
2. 显示备份路径并要求输入 `y` 确认（默认 `N`）；
3. 从 `manifest` 恢复受管文件：`present` 覆盖回去，`absent` 删除；
4. 还原冲突文件（若目标已被重新创建，则写成 `<path>.restored`）；
5. `sysctl --system` 重新加载所有 sysctl 配置；
6. 用运行时快照覆盖回优化前的值；
7. 把 `current` 指向上一次备份（`previous`），从而支持**逐层回退**；链上无更早备份时清空 `current`。

恢复的边界：

- 已加载的内核模块**不会被卸载**；
- `limits.d` 的改动只影响**新的登录会话**；
- 恢复日志写在对应备份目录下，便于核对；
- 不会删除 `/var/lib/network-optimize` 中的历史备份。

---

## 冲突配置处理

`sysctl --system` 的实际加载规则是：

1. 按 `/etc/sysctl.d` → `/run/sysctl.d` → `/usr/local/lib/sysctl.d` → `/usr/lib/sysctl.d` → `/lib/sysctl.d` 的优先级扫描；
2. 同名文件只在优先级最高的目录生效一次；
3. 生效文件按**文件名全局字典序**排序加载；
4. `/etc/sysctl.conf` **最后**加载。

因此，只有文件名排在 `99-z-network-optimize.conf` 之后的文件，或 `/etc/sysctl.conf`，才可能覆盖脚本参数。

脚本会把包含本次同名参数的文件分成两类：

- **无害**：加载顺序更早，会被脚本覆盖，仅列出并保留；
- **冲突**：会覆盖脚本参数，逐条列出文件、冲突键和所属 Debian 包（`dpkg -S` 可查时），并询问是否处理。

选择处理时：

- 文件里**只有**冲突参数 → 整个文件移除；
- 文件里**还含其他配置** → 只把冲突行注释成 `# [network-optimize YYYY-MM-DD] <原行>`，其余原样保留。

处理前文件完整备份到 `backup/conflict-files/`，映射写入 `conflicts.tsv`，可用“恢复最近一次配置”还原。

> ⚠️ 对 `/etc/sysctl.conf` 也按同一规则处理。如果该文件所有生效行都与脚本参数冲突，会被整体移除（有备份可恢复）。不确定时请在确认前先查看列出的冲突键，或直接回答 `N` 保留冲突文件——代价是相关参数会在重启后被覆盖。

---

## 安全设计

- **符号链接防护**：状态目录、`current`、受管配置文件、备份内的恢复源都会拒绝符号链接，避免被重定向写入任意文件。
- **权限收敛**：`umask 077`；状态目录与备份 `0700 root:root`；临时配置文件 `0600/0644`；`current` 由临时文件原子替换。
- **属主校验**：状态目录若不属于 root 直接终止。
- **状态文件内容校验**：`current` 只接受 `[A-Za-z0-9._-]+`，且必须指向真实目录。
- **先备份后修改**：所有受管文件先 `cp -a` 到事务备份，`manifest` 记录 `present/absent`。
- **原子落盘**：配置写入通过 `mktemp` + `mv -f` 完成，不会出现截断文件。
- **键存在性检查**：写入前用 `sysctl -n` 探测，不存在的键跳过，避免 `sysctl -p` 整体失败。
- **失败即回滚**：`ERR` / `INT` / `TERM` 三种路径都会触发恢复。

---

## 输出与退出码

运行时会用颜色区分（非终端时自动关闭颜色）：

- `[信息]` 绿色，`[警告]` 黄色（stderr），`[错误]` 红色（stderr）。

应用后打印两项内容：

1. **应用验证**：逐项对比期望值与实际值，显示 `OK` / `不一致`（附期望与实际）/ `无法读取`；
2. **配置摘要**：策略、带宽、RTT、BDP、内存、缓冲、中间值、队列、`tcp_mem`、单连接页数、可支撑大流数、缓冲区倍率、TIME_WAIT、端口范围、拥塞控制、qdisc、转发、conntrack、limits、冲突处理情况和备份路径。

被跳过的内核键会在摘要末尾列出。

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功（或用户取消恢复/主动退出菜单） |
| `1` | 权限/依赖缺失、未知参数、执行失败（可能已自动回滚） |
| `130` / `143` | 收到 INT / TERM，已尝试回滚 |

---

## 注意事项与边界

- **不做 NAT 与防火墙**：开启 `ip_forward` 只是第一步，NAT 规则、转发链和防火墙仍需 nftables / iptables / firewalld 配置。
- **不修改 systemd 服务限制**：`limits.d` 只作用于 PAM 登录会话；服务请在 unit 中设置 `LimitNOFILE`。
- **不卸载模块**：恢复后 `tcp_bbr` / `sch_fq` / `nf_conntrack` 可能仍在内存中。
- **IPv6 转发有副作用**：可能改变 RA 接收行为，若上游通过 RA 下发默认路由，请检查对应接口的 `accept_ra`。
- **重启后才完全生效的部分**：`modules-load.d` 在开机时由 `systemd-modules-load` 处理；`limits.d` 需重新登录。
- **没有 dry-run**：脚本会直接写入；如需预演，请在测试机或快照环境中运行。
- **与容器/云镜像共存**：Docker、K8s、云厂商镜像常自带 sysctl 配置；脚本会检测冲突，但容器内部分键可能不存在而被跳过。
- **参数偏保守**：单连接缓冲受内存上限收敛、最低 8 MiB，小内存机器不会得到超大缓冲；`tcp_mem` 上限为物理内存的 25%。
- **可重复运行**：每次优化都会新建备份，`previous` 形成恢复链，可连续回退。

---

## 常见问题

**Q：运行后 SSH 会断吗？**
脚本只调整内核缓冲、队列和可选转发，不重置网卡、不改路由表、不碰防火墙规则，一般不会中断已有连接。但开启 IPv6 转发等操作可能影响路由行为，生产环境建议保留带外控制台或 `tmux`。

**Q：为什么实际值和公式不完全一致？**
单连接缓冲会先按 2×BDP 计算，内存不够时退到 1.5×BDP，再受 `min(内存/8, max(内存/16, 8 MiB))` 和最低 8 MiB 约束；`tcp_mem` 还有 25% 内存上限和下限保护。

**Q：重启后参数被打回原样？**
说明存在加载顺序更晚的 sysctl 文件（或 `/etc/sysctl.conf`）覆盖了脚本。重新运行并处理“冲突文件”，或检查摘要中的“冲突文件处理”状态。

**Q：为什么没有修改 `fs.file-max`？**
当前值已经是天文数字（≥ 2^31）或已高于目标值时，脚本会跳过，避免无意义改动。

**Q：恢复了配置，为什么 BBR / conntrack 看起来还在？**
内核模块不会被强制卸载，恢复的是 sysctl 值和配置文件。拥塞控制会按备份的运行时快照恢复为原来的算法。

**Q：nofile 为什么没生效？**
`limits.d` 仅对新登录会话生效；已在运行的服务需要重启，systemd 服务需单独配置 `LimitNOFILE`。

**Q：能不看提示直接跑吗？**
不能。脚本没有非交互模式，也没有 `--bandwidth` 之类的参数；请通过标准输入依次回答，或使用 `yes` / 管道时自行承担误答风险（不推荐）。

**Q：怎么确认脚本改了什么？**
查看 `/etc/sysctl.d/99-z-network-optimize.conf`（含版本、带宽、RTT、BDP 注释）、摘要输出，以及备份中的 `metadata`、`manifest`、`apply.log`。

---

## 卸载

```bash
# 1. 恢复最近一次配置（可重复执行以逐层回退）
sudo ./optimize_fix.sh --restore

# 2. 确认无残留且不再需要历史备份后，删除状态目录
sudo rm -rf /var/lib/network-optimize
```

恢复会把受管配置文件还原为优化前的状态（原本不存在的文件会被删除），但不会删除状态目录、日志和备份；模块也不会自动卸载。确认无误后再手动清理 `/var/lib/network-optimize`。
# Linux-tcp-optimize-shell

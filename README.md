# Snell Server 管理脚本

面向 Debian 与 Alpine 的单文件 Snell Server 管理脚本，支持 Snell v5 / v6、systemd / OpenRC，以及安装、配置、更新、切换和卸载。

[Surge 官方下载源](https://nssurge.com) · [Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)

## 快速开始

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/fexumo/snell/main/snell.sh)
```

运行条件：

- Root 权限
- Debian 或 Alpine Linux
- 可访问 GitHub 与 Surge 官方下载源
- Alpine 需先安装 Bash：`apk add bash`

脚本会自动安装运行所需依赖，但不会修改系统防火墙。安装完成后，请手动放行监听端口；默认端口为 `8443`。

## 功能

```text
server: installed v6 · latest v6.0.0rc2 · running

 1) 安装服务    2) 启动服务
 3) 停止服务    4) 重启服务
 5) 设置配置    6) 查看配置
 7) 查看状态    8) 更新服务
 9) 卸载服务    0) 退出脚本
```

面板中的 `installed` 是本机已安装版本；`latest` 来自 Surge 官方发布页，并会验证当前架构的官方下载地址。若官网版本更新，会显示 `update available`。官网暂时不可访问时，面板只显示本地版本，不影响菜单使用。

- 安装、更新和协议切换时，从 Surge 官方发布页自动获取对应主版本的最新可下载版本
- 修改端口、密钥、TFO 等配置
- 在 v5 与 v6 之间切换
- 将 v5 升级至 v6，或更新 v6
- 显示服务状态与 Surge 配置
- 完整卸载服务及脚本创建的系统用户

## 内部架构

仓库仍只包含 `snell.sh` 与 `README.md`。脚本内部按职责分层：

| 层 | 职责 |
|---|---|
| 平台与运行时 | 一次性识别系统、架构、服务管理器和安装状态 |
| 服务适配 | 统一封装 systemd / OpenRC 的安装、状态与控制 |
| 版本与制品 | 查询 Surge 官方版本、选择当前架构可下载版本并验证二进制 |
| 配置模型 | 统一解析、校验和生成配置，保留未托管键与其他 INI 节 |
| 事务引擎 | 原子应用安装、更新、协议切换和配置修改，失败时恢复全部状态 |
| 界面与动作 | 菜单只收集输入并调用动作，不直接修改系统文件 |

运行态、配置态和事务态分别使用 `rt_*`、`cfg_*`、`tx_*` 状态域，避免菜单输入污染服务状态。服务文件由配置派生；使用 `egress-interface` 时，脚本会仅按需授予 `CAP_NET_RAW` 与 `CAP_NET_ADMIN`。

## 配置

| 配置项 | v5 | v6 |
|---|:---:|:---:|
| 监听端口 | ✓ | ✓ |
| 密钥 | ✓ | ✓ |
| TCP Fast Open | ✓ | ✓ |
| OBFS / OBFS 域名 | ✓ | — |
| 目标域名 IPv6 解析 | ✓ | — |
| 目标地址 DNS IP 偏好 | — | ✓ |
| 混淆模式 | — | ✓ |

密钥规则：

- Snell v5 技术上接受任意非空密钥
- Snell v6 官方要求 12–255 字节
- 本脚本统一要求 v5 / v6 密钥至少 16 位、最多 255 位
- 允许字符：字母、数字、`.`、`_`、`~`、`-`

已有配置的密钥少于 16 位或超过 255 位时，脚本会要求先更新密钥。

`目标域名 IPv6 解析` 与 `目标地址 DNS IP 偏好` 控制服务端解析和连接目标网站时使用 IPv4 还是 IPv6，不控制客户端如何连接 Snell 服务端。服务端监听地址由 `listen` 决定。

修改配置时会保留 `[snell-server]` 中脚本未管理的键，以及其他 INI 配置节。新配置导致服务启动失败时，脚本会自动恢复旧配置。

## Surge 配置

菜单 `6` 会获取服务器公网地址并生成可直接复制的配置：

```ini
# v6
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=6, mode=default, reuse=true, tfo=true

# v5 + TLS OBFS
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=5, obfs=tls, obfs-host=www.wechat.com, reuse=true, tfo=true
```

服务器名称取自主机名；地址优先使用公网 IPv4，获取失败时回退 IPv6。

## 安全与回滚

- 服务使用专用 `snell-server` 系统用户运行
- 配置文件为 `root:snell-server`、权限 `640`，服务进程只读
- systemd 环境启用 `NoNewPrivileges`、`ProtectSystem` 等沙箱限制
- 固定版本不写入脚本；安装、更新、切换前均从 Surge 官方发布页检测最新版本
- 动态版本校验 HTTPS、ZIP 单文件结构、解压大小、ELF 类型、目标架构及本机可执行性
- 配置文件与 systemd/OpenRC 服务定义均由事务引擎提交；出口网卡能力只在需要时授予
- 更新和协议切换先下载并完成全部验证，再停止服务
- 安装、更新、协议切换、配置写入、服务启动或操作中断失败时，自动恢复程序、配置、版本记录、服务定义、启用状态及原运行状态
- 卸载后检查服务文件、配置和残留进程

> Surge 官方发布页或下载源不可访问时，安装、更新和协议切换会中止，不会回退到脚本内置版本。

## 支持范围

| 项目 | 支持 |
|---|---|
| 系统 | Debian、Alpine |
| 服务管理 | systemd、OpenRC |
| 架构 | i386、amd64、armv7l、aarch64 |
| 协议 | Snell v5、Snell v6 |

Snell v6 官方当前未提供 Linux `armv7l` 构建，脚本会拒绝在该架构安装或切换至 v6。`armv6l` 会尝试使用 v5 的 `armv7l` 构建，但不保证能够运行。

## 文件路径

```text
/usr/local/bin/snell-server                     # 主程序
/etc/snell/config.conf                          # 配置（root:snell-server，640）
/etc/snell/ver.txt                              # 已安装版本记录
/etc/snell/.user-created                        # 系统用户创建标记
/etc/systemd/system/snell-server.service        # systemd 服务
/etc/init.d/snell-server                        # OpenRC 服务
/run/snell-server.pid                           # OpenRC PID
/var/log/snell-server.log                       # Alpine 日志
```

## 注意事项

- `config.conf` 包含明文 PSK，请勿公开或上传
- 脚本不会开放或关闭防火墙端口
- 下载版本以 Surge 官方发布页为准，不读取二进制自报版本
- 仅删除带有创建标记的专用系统用户，不会删除同名的既有用户

## 免责声明

本项目仅供学习与个人使用。请遵守所在地法律法规及相关服务条款。使用本脚本造成的直接或间接损失由使用者自行承担。

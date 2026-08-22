# Snell Server 管理脚本

Debian / Alpine 单文件 Snell Server 管理脚本，支持 Snell v5/v6、systemd/OpenRC，以及安装、配置、更新、切换和卸载。

[Surge 官网](https://nssurge.com) · [Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell) · [下载源](https://dl.nssurge.com/snell/)

## 快速开始

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/fexumo/snell/main/snell.sh)
```

需要 Root、Debian/Alpine、可用的 systemd/OpenRC 和网络连接。Alpine 先安装 Bash：

```sh
apk add bash
```

脚本自动安装依赖，但不修改防火墙；默认监听端口为 `8443`，请自行放行。

## 菜单

```text
 1) 安装服务    2) 启动服务
 3) 停止服务    4) 重启服务
 5) 设置配置    6) 查看配置
 7) 查看状态    8) 更新服务
 9) 卸载服务    0) 退出脚本
```

设置配置子菜单（v5 显示 3–5 项，v6 显示 9–10 项，其余通用）：

```text
 1) 监听端口       2) 密钥
 3) OBFS           4) OBFS 域名        (v5)
 5) 目标域名 IPv6 解析                  (v5)
 6) TCP Fast Open  7) 出口网卡
 8) 切换协议版本
 9) 目标地址 DNS IP 偏好                (v6)
10) 混淆模式                            (v6)
11) 全部配置
```

输入菜单项编号执行，回车返回主菜单；所有编辑项直接回车均保留当前值（密钥除外，回车会生成新的随机密钥）。

支持安装/更新官方最新可下载版本，显示依赖、版本查询、下载、校验、提交和启动进度；

面板显示本机安装版本；官网可访问时同步显示 Surge 发布页中当前架构可下载的最新版本，有更新时提示「可更新」。官网不可访问时只显示本地状态，60 秒后自动重试。

## 配置

| 配置项 | v5 | v6 |
|---|:---:|:---:|
| 监听端口、密钥、TFO | ✓ | ✓ |
| OBFS / OBFS 域名 | ✓ | — |
| 目标域名 IPv6 解析 | ✓ | — |
| 目标地址 DNS IP 偏好、混淆模式 | — | ✓ |
| 出口网卡 | ✓ | ✓ |

密钥为 **16–255 位**，仅允许字母和数字；安装和「设置配置 → 密钥」中直接回车都会生成新的 16 位随机密钥（不会保留原密钥）。旧配置密钥含特殊字符时，需先手动修复。

配置键名大小写不敏感（`PSK`、`Listen` 等均被识别，写回时统一为小写）；修改监听端口会保留原有监听地址（含多地址），仅替换端口号；出口网卡留空表示不指定，输入 `none` 清除。

`目标域名 IPv6 解析` 和 `目标地址 DNS IP 偏好`控制服务端访问目标时的 IPv4/IPv6 选择，不控制客户端连接服务器的方式；服务器监听由 `listen` 决定。

脚本会保留 `[snell-server]` 中未托管的键和其他 INI 节；被注释掉的旧 `psk` 行会在写回时过滤，避免密钥残留。

## Surge 配置

菜单 `6` 获取公网地址并生成配置：

```ini
# v6
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=6, mode=default, reuse=true, tfo=true

# v5 + TLS OBFS
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=5, obfs=tls, obfs-host=www.wechat.com, reuse=true, tfo=true
```

公网地址通过多源查询获取：IPv4 依次尝试 ipinfo.io、api.ip.sb、3322（公云），IPv6 依次尝试 ifconfig.co、icanhazip、ipify，单个源失败自动切换，全部失败时提示无法获取（此时可手动填写）。

## 版本与安全

- 脚本不内置固定版本号；安装、更新、切换和面板提示均查询 Surge 发布页。
- 自动验证当前架构下载地址、HTTPS、ZIP 单文件结构、大小、ELF 类型、架构和本机可执行性；Alpine 自动处理 v5 UPX 包，`upx` 缺失时仅影响 v5 的安装/更新（按提示 `apk add upx` 即可），v6 不受影响。
- 服务以专用 `snell-server` 用户运行；配置为 `root:snell-server`、权限 `640`。
- systemd/OpenRC 服务定义由当前配置生成；设置 `egress-interface` 时才授予所需网络能力。
- 安装、更新、切换和配置修改共用事务流程；失败或中断时恢复程序、配置、版本记录、服务定义、启用状态和原运行状态。
- 回滚不完整时保留事务备份；安装失败会清理已创建的服务、账户和文件。

> Surge 未为动态下载提供固定 checksum，因此无法进行摘要级供应链验证。发布页或下载源不可用时不会回退到旧内置版本。

## 支持范围

| 项目 | 支持 |
|---|---|
| 系统 | Debian、Alpine |
| 服务 | systemd、OpenRC |
| 架构 | i386、amd64、armv7l、aarch64 |
| 协议 | Snell v5、Snell v6 |

Snell v6 官方没有 Linux `armv7l` 构建；`armv6l` 仅尝试 v5 的 armv7l 包，不保证可运行。

## 文件路径

```text
/usr/local/bin/snell-server              # 主程序
/etc/snell/config.conf                   # 配置，root:snell-server 640
/etc/snell/ver.txt                       # 已安装版本
/etc/snell/.user-created                 # 用户创建标记
/etc/systemd/system/snell-server.service # systemd 服务
/etc/init.d/snell-server                 # OpenRC 服务
/run/snell-server.pid                    # OpenRC PID
/var/log/snell-server.log                # OpenRC 日志
```

更新事务目录为 `/usr/local/bin/.snell-tx.*`，仅在回滚不完整时保留。

## 注意

- `config.conf` 含明文 PSK，请勿公开或上传。
- 脚本不操作防火墙。
- 仅删除带创建标记的专用用户；配置损坏时不会自动猜测或覆盖。

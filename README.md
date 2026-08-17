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

支持安装/更新官方最新可下载版本、v5/v6 切换、配置管理、状态查看和 Surge 配置生成。

面板中的 `installed` 是本机版本；`latest` 是 Surge 发布页中当前架构可下载的版本；有更新时显示 `update available`。官网不可访问时只显示本地状态。

## 配置

| 配置项 | v5 | v6 |
|---|:---:|:---:|
| 监听端口、密钥、TFO | ✓ | ✓ |
| OBFS / OBFS 域名 | ✓ | — |
| 目标域名 IPv6 解析 | ✓ | — |
| 目标地址 DNS IP 偏好、混淆模式 | — | ✓ |
| 出口网卡 | ✓ | ✓ |

密钥为 **16–255 位**，允许字母、数字、`.`、`_`、`~`、`-`；回车默认生成 16 位随机密钥。旧配置密钥不符合范围时，需先手动修复。

`目标域名 IPv6 解析` 和 `目标地址 DNS IP 偏好`控制服务端访问目标时的 IPv4/IPv6 选择，不控制客户端连接服务器的方式；服务器监听由 `listen` 决定。

脚本会保留 `[snell-server]` 中未托管的键和其他 INI 节。

## Surge 配置

菜单 `6` 获取公网地址并生成配置：

```ini
# v6
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=6, mode=default, reuse=true, tfo=true

# v5 + TLS OBFS
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=5, obfs=tls, obfs-host=www.wechat.com, reuse=true, tfo=true
```

## 版本与安全

- 脚本不内置固定版本号；安装、更新、切换和面板提示均查询 Surge 发布页。
- 自动验证当前架构下载地址、HTTPS、ZIP 单文件结构、大小、ELF 类型、架构和本机可执行性；Alpine 自动处理 v5 UPX 包。
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

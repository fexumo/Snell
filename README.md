# Snell Server 管理脚本

> 简洁、适配 Debian / Alpine 的 Snell Server 管理脚本，支持 Snell v5 / v6。安装、切换和更新共用同一条工作流。

[GitHub 仓库](https://github.com/fexumo/Snell) · [官方网站](https://nssurge.com) · [发布说明](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)

---

## 快速开始

### 安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/fexumo/Snell/main/snell.sh)
```

- 需在 bash 中执行：Debian 自带；Alpine 默认无 bash，需先 `apk add bash`
- 需要 Root 权限，能访问 GitHub 与 Snell 下载源
- 下载版本以 `ver.txt` 为准，不读取二进制自报版本；官方未提供 checksum，脚本仅校验 HTTPS、ZIP 结构与文件类型
- 服务使用专用 `snell-server` 系统用户运行；systemd 自动启用安全沙箱
- 重新运行本命令即可获取脚本最新版

### 首次连接

1. 菜单 `1` 安装，选择 v5 或 v6，按提示设置端口与密钥
2. 菜单 `6` 查看配置，复制输出的 Surge 配置行
3. 将配置行粘贴到 Surge 客户端

> 脚本不操作系统防火墙，请手动放行监听端口。

---

## 使用

### 主菜单

```text
server: v6 · running

 1) 安装服务    2) 启动服务
 3) 停止服务    4) 重启服务
 5) 设置配置    6) 查看配置
 7) 查看状态    8) 更新服务
 9) 卸载服务    0) 退出脚本
```

| 选项 | 说明 |
|:---:|:---|
| `1` | 安装服务（v5 / v6） |
| `2` | 启动服务 |
| `3` | 停止服务 |
| `4` | 重启服务 |
| `5` | 设置配置（见下表） |
| `6` | 查看配置，生成 Surge 配置 |
| `7` | 查看运行状态（版本、端口、PID、TCP/UDP） |
| `8` | 更新：v5 升级 v6；v6 更新到官网最新版 |
| `9` | 卸载服务 |
| `0` | 退出 |

### 配置项（菜单 `5`）

| 选项 | 内容 | 适用 |
|:---:|:---|:---:|
| `1` | 监听端口 | v5 / v6 |
| `2` | 密钥 | v5 / v6 |
| `3` | OBFS | v5 |
| `4` | OBFS 域名 | v5 |
| `5` | IPv6 解析 | v5 |
| `6` | TCP Fast Open | v5 / v6 |
| `7` | 切换协议版本 | v5 / v6 |
| `8` | DNS IP 偏好 | v6 |
| `9` | 混淆模式 | v6 |
| `10` | 全部配置 | v5 / v6 |

v6 密钥要求 16–255 位；默认端口 `8443`。

### Surge 配置（菜单 `6`）

```text
# v6
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=6, mode=default, reuse=true, tfo=true

# v5
my-server = snell, 1.2.3.4, 8443, psk=your-psk, version=5, obfs=tls, obfs-host=www.wechat.com, reuse=true, tfo=true
```

`my-server` 为服务器主机名，脚本自动填充；优先使用公网 IPv4，不可用时回退 IPv6。

---

## 文件路径

```text
/usr/local/bin/snell-server                     # 主程序
/etc/snell/config.conf                          # 配置（属主 snell-server，权限 600）
/etc/snell/ver.txt                              # 版本记录
/etc/snell/.user-created                        # 专用系统用户创建标记
/etc/systemd/system/snell-server.service        # systemd 服务
/etc/init.d/snell-server                        # OpenRC 服务
/run/snell-server.pid                           # PID
/var/log/snell-server.log                       # Alpine 日志
```

---

## 注意事项

- **安全**：`config.conf` 含明文 PSK，请限制访问权限，勿公开分享
- **切换版本**：先确认配置与服务状态；脚本不保留旧二进制，启动失败时需根据日志手动处理

---

## 免责声明

本项目仅供学习与个人使用。请遵守当地法律法规及服务提供商的使用条款。因使用本脚本造成的任何直接或间接损失，由使用者自行承担。

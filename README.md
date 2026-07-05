# CIP

CIP 是一个 Linux systemd 监控服务。它会通过你配置的 HTTP API 检测当前公网 IP 的指定端口是否可用；如果连续失败达到阈值，就调用你配置的换 IP 接口，并可选推送 Telegram 通知。

## 一键安装

在目标服务器用 root 执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunyuchentrx/cip/main/install.sh)"
```

安装后会创建：

- `/root/ssh_monitor.sh`：监控脚本
- `/usr/local/bin/cip`：服务管理菜单
- `/usr/local/bin/cip-update`：一键更新脚本
- `/etc/systemd/system/cip.service`：systemd 服务
- `/etc/cip/cip.env`：本机配置文件

## 一键更新

安装过以后，直接执行：

```bash
cip-update
```

也可以直接远程执行更新脚本：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunyuchentrx/cip/main/update.sh)"
```

更新时会保留 `/etc/cip/cip.env`，删除并重装其它程序文件。

## 配置

安装后编辑本机配置：

```bash
nano /etc/cip/cip.env
```

需要修改的主要配置：

- `DEVICE_NAME`：设备名称，TG 推送里会显示，用来区分多台机器
- `TARGET_PORT`：要检测的端口
- `CHECK_API_URL`：检测 API 1
- `CHECK_API_URL_2`：检测 API 2
- `SWITCH_IP_URL`：换 IP 接口地址
- `TELEGRAM_BOT_TOKEN`：Telegram Bot Token，可留空
- `TELEGRAM_CHAT_ID`：Telegram Chat ID，可留空

真实 API 地址、换 IP 地址、Token、Chat ID 只放在服务器本地的 `/etc/cip/cip.env`，不要提交到 GitHub。

## 检测 API 格式

脚本会请求：

```text
GET CHECK_API_URL?address=<公网IP>&port=<端口>
```

检测 API 需要返回类似：

```json
{
  "code": 200,
  "address": "1.2.3.4",
  "port": "32491"
}
```

只要两个检测 API 中任意一个返回成功，就认为端口正常。

## 启动和管理

启动服务：

```bash
systemctl start cip
```

查看状态：

```bash
systemctl status cip --no-pager
```

打开中文管理菜单：

```bash
cip
```

查看实时日志：

```bash
journalctl -u cip -f
```

# CIP

CIP is a Linux systemd service that checks whether a target public IP and port are reachable through configured HTTP APIs. If checks fail repeatedly, it calls a configured IP switch URL and can send optional Telegram notifications.

## One-command install

Run on the target Linux server as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunyuchentrx/cip/main/install.sh)"
```

The installer creates:

- `/root/ssh_monitor.sh`
- `/usr/local/bin/cip`
- `/etc/systemd/system/cip.service`
- `/etc/cip/cip.env`

## Configure

Edit the local config file after installation:

```bash
nano /etc/cip/cip.env
```

Set your own values for:

- `TARGET_PORT`
- `CHECK_API_URL`
- `CHECK_API_URL_2`
- `SWITCH_IP_URL`
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` if Telegram notifications are needed

Real API URLs, switch URLs, tokens, and chat IDs should only live in `/etc/cip/cip.env` on your server. Do not commit them to GitHub.

## Start and manage

```bash
systemctl start cip
systemctl status cip --no-pager
```

Open the service manager menu:

```bash
cip
```

View logs:

```bash
journalctl -u cip -f
```

## Update

Run the installer again. Existing `/etc/cip/cip.env` will be kept.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunyuchentrx/cip/main/install.sh)"
```

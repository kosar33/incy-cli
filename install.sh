#!/bin/sh
set -e

# ================= ЦВЕТА =================
RED=$(printf '\033[1;31m')
GREEN=$(printf '\033[1;32m')
CYAN=$(printf '\033[1;36m')
YELLOW=$(printf '\033[1;33m')
BOLD=$(printf '\033[1m')
RESET=$(printf '\033[0m')

# ================= 1. ПРОВЕРКА ROOT =================
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}[-] Ошибка: скрипт должен быть запущен с правами root (sudo)!${RESET}" >&2
    echo "Запустите команду: ${BOLD}${CYAN}sudo $0${RESET}" >&2
    exit 1
fi

echo "${CYAN}${BOLD}"
echo "=============================================="
echo "    Установка INCY-CLI Linux VPN Client       "
echo "=============================================="
echo "${RESET}"

# ================= 2. УСТАНОВКА БАЗОВЫХ УТИЛИТ =================
echo "${CYAN}[*] Проверка и установка базовых пакетов...${RESET}"

if command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python curl unzip
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y python3 curl unzip ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 curl unzip
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add python3 curl unzip
elif command -v zypper >/dev/null 2>&1; then
    zypper refresh && zypper install -y python3 curl unzip
fi

# ================= 3. УСТАНОВКА ЯДРА XRAY =================
if ! command -v xray >/dev/null 2>&1; then
    echo "${YELLOW}[*] Установка ядра Xray напрямую из официального репозитория XTLS...${RESET}"
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
fi

if ! command -v xray >/dev/null 2>&1; then
    echo "${RED}[-] Не удалось установить Xray. Проверьте интернет-соединение.${RESET}" >&2
    exit 1
fi

echo "${GREEN}[+] Ядро Xray готово: $(xray -version | head -n 1)${RESET}"

# ================= 4. НАСТРОЙКА SYSTEMD ПОД TUN =================
echo "${CYAN}[*] Настройка systemd-сервиса под TUN...${RESET}"
OVERRIDE_DIR="/etc/systemd/system/xray.service.d"
mkdir -p "$OVERRIDE_DIR"
cat << 'EOF' > "$OVERRIDE_DIR/override.conf"
[Service]
User=root
EOF

systemctl daemon-reload
echo "${GREEN}[+] Служба Xray сконфигурирована под TUN.${RESET}"

mkdir -p /etc/incy-cli /etc/xray

# ================= 5. РАЗВЕРТЫВАНИЕ INCY-CLI =================
echo "${CYAN}[*] Создание утилиты /usr/local/bin/incy-cli...${RESET}"

cat << 'EOF' > /usr/local/bin/incy-cli
#!/usr/bin/env python3
import os
import sys
import json
import uuid
import shutil
import urllib.request
from urllib.parse import urlparse, parse_qs, urlencode, urlunparse
import subprocess

CONFIG_DIR = "/etc/incy-cli"
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
SERVERS_FILE = os.path.join(CONFIG_DIR, "servers.json")
XRAY_CONFIG = "/etc/xray/config.json"
TIMER_SERVICE = "/etc/systemd/system/incy-cli-update.service"
TIMER_FILE = "/etc/systemd/system/incy-cli-update.timer"

GREEN = "\033[1;32m"
RED = "\033[1;31m"
CYAN = "\033[1;36m"
YELLOW = "\033[1;33m"
BOLD = "\033[1m"
RESET = "\033[0m"

def check_root():
    if os.geteuid() != 0:
        print(f"{RED}[-] Ошибка: эту команду нужно запускать с sudo!{RESET}")
        sys.exit(1)

def ensure_xray():
    if not shutil.which("xray"):
        print(f"{RED}[-] Ядро Xray не найдено!{RESET}")
        sys.exit(1)

def load_config():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)

    initial_config = {
        "hwid": str(uuid.uuid4()),
        "sub_url": "",
        "user_agent": "INCY/3.7.0/android",
        "active_label": None
    }
    save_config(initial_config)
    return initial_config

def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

def normalize_url(raw_url):
    p = urlparse(raw_url.strip())
    qs = parse_qs(p.query)
    qs['client'] = ['incy']
    new_query = urlencode(qs, doseq=True)
    return urlunparse((p.scheme, p.netloc, p.path, p.params, new_query, p.fragment))

def get_node_name(s, idx):
    for field in ("remarks", "name", "ps", "description", "comment", "title"):
        val = s.get(field)
        if val and str(val).strip():
            return str(val).strip()

    tag = s.get("tag")
    if tag and str(tag).strip() and not str(tag).startswith("proxy-") and str(tag) not in ("proxy", "vless"):
        return str(tag).strip()

    vnext = s.get("settings", {}).get("vnext", [])
    if vnext and isinstance(vnext, list) and len(vnext) > 0:
        addr = vnext[0].get("address", "")
        port = vnext[0].get("port", "")
        if addr:
            return f"Локация {idx} [{addr}:{port}]"

    return f"Сервер {idx}"

def fetch_servers(url, hwid, ua, silent=False):
    if not silent:
        print(f"{CYAN}[*] Запрос нод через INCY API...{RESET}")
    req = urllib.request.Request(url, headers={"User-Agent": ua, "X-HWID": hwid})
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = resp.read().decode("utf-8")
            servers = json.loads(data)
            if not isinstance(servers, list):
                raise ValueError("Сервер вернул не список серверов.")
            with open(SERVERS_FILE, "w", encoding="utf-8") as f:
                json.dump(servers, f, ensure_ascii=False, indent=2)
            if not silent:
                print(f"{GREEN}[+] Успешно получено серверов: {len(servers)}{RESET}")
            return servers
    except Exception as e:
        if not silent:
            print(f"{RED}[-] Ошибка при получении подписки: {e}{RESET}")
        sys.exit(1)

def generate_xray_config(node, fallback_tag):
    node_copy = node.copy()
    if not node_copy.get("tag"):
        node_copy["tag"] = fallback_tag

    return {
        "log": {"loglevel": "warning"},
        "dns": {"servers": ["1.1.1.1", "8.8.8.8"]},
        "inbounds": [
            {
                "tag": "tun-in",
                "protocol": "tun",
                "settings": {
                    "name": "xray0",
                    "mtu": 1500,
                    "autoRoute": True,
                    "strictRoute": True
                }
            },
            {
                "tag": "socks-in",
                "port": 10808,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True}
            },
            {
                "tag": "http-in",
                "port": 10809,
                "listen": "127.0.0.1",
                "protocol": "http"
            }
        ],
        "outbounds": [
            node_copy,
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"],
                    "outboundTag": "direct"
                }
            ]
        }
    }

def cmd_sub(args):
    check_root()
    if not args:
        print(f"{RED}[-] Укажите ссылку: sudo incy-cli sub \"https://...\"{RESET}")
        sys.exit(1)

    cfg = load_config()
    clean_url = normalize_url(args[0])
    cfg["sub_url"] = clean_url
    save_config(cfg)
    print(f"{GREEN}[+] Ссылка сохранена в /etc/incy-cli/config.json{RESET}")
    print(f"{GREEN}[+] Привязан постоянный HWID: {cfg['hwid']}{RESET}")
    fetch_servers(clean_url, cfg["hwid"], cfg["user_agent"])
    print(f"\n{YELLOW}Теперь выберите сервер: sudo incy-cli connect{RESET}")

def cmd_update(args):
    check_root()
    cfg = load_config()
    if not cfg.get("sub_url"):
        print(f"{RED}[-] Подписка не задана! Сначала выполните: sudo incy-cli sub \"URL\"{RESET}")
        sys.exit(1)
    silent = "--silent" in args
    servers = fetch_servers(cfg["sub_url"], cfg["hwid"], cfg["user_agent"], silent=silent)

    if cfg.get("active_label"):
        matched = None
        for i, s in enumerate(servers):
            if get_node_name(s, i) == cfg["active_label"]:
                matched = (s, i)
                break

        if matched:
            node, i = matched
            os.makedirs("/etc/xray", exist_ok=True)
            with open(XRAY_CONFIG, "w", encoding="utf-8") as f:
                json.dump(generate_xray_config(node, f"proxy-{i}"), f, ensure_ascii=False, indent=2)
            subprocess.run(["systemctl", "restart", "xray"], stdout=subprocess.DEVNULL)
            if not silent:
                print(f"{GREEN}[+] Активное подключение ({cfg['active_label']}) обновлено.{RESET}")

def cmd_list():
    if not os.path.exists(SERVERS_FILE):
        print(f"{YELLOW}[!] Серверы еще не загружены. Запустите: sudo incy-cli update{RESET}")
        sys.exit(1)
    cfg = load_config()
    with open(SERVERS_FILE, "r", encoding="utf-8") as f:
        servers = json.load(f)

    print(f"\n{CYAN}--- Доступные серверы INCY ---{RESET}")
    for idx, s in enumerate(servers):
        label = get_node_name(s, idx)
        proto = s.get("protocol", "vless")
        active = f" {GREEN}* [АКТИВЕН]{RESET}" if label == cfg.get("active_label") else ""
        print(f"  {YELLOW}[{idx:2d}]{RESET} {label} ({proto}){active}")
    print("")

def cmd_connect(args):
    check_root()
    ensure_xray()
    cfg = load_config()

    if not os.path.exists(SERVERS_FILE):
        if not cfg.get("sub_url"):
            print(f"{RED}[-] Сначала добавьте подписку: sudo incy-cli sub \"URL\"{RESET}")
            sys.exit(1)
        fetch_servers(cfg["sub_url"], cfg["hwid"], cfg["user_agent"])

    with open(SERVERS_FILE, "r", encoding="utf-8") as f:
        servers = json.load(f)

    idx = None
    if args:
        try:
            idx = int(args[0])
        except ValueError:
            print(f"{RED}[-] Индекс должен быть числом!{RESET}")
            return
    else:
        cmd_list()
        try:
            val = input(f"{CYAN}Введите номер сервера для подключения: {RESET}")
            idx = int(val)
        except (ValueError, KeyboardInterrupt):
            print("\nОтмена.")
            return

    if idx < 0 or idx >= len(servers):
        print(f"{RED}[-] Неверный индекс сервера!{RESET}")
        return

    chosen = servers[idx]
    label = get_node_name(chosen, idx)
    print(f"{CYAN}[*] Подключение к: {label}...{RESET}")

    os.makedirs("/etc/xray", exist_ok=True)
    with open(XRAY_CONFIG, "w", encoding="utf-8") as f:
        json.dump(generate_xray_config(chosen, f"proxy-{idx}"), f, ensure_ascii=False, indent=2)

    cfg["active_label"] = label
    save_config(cfg)

    res = subprocess.run(["systemctl", "restart", "xray"])
    if res.returncode == 0:
        print(f"{GREEN}[+] Подключено! Вся система в TUN-режиме через: {label}{RESET}")
    else:
        print(f"{RED}[-] Ошибка запуска службы Xray!{RESET}")

def cmd_status():
    cfg = load_config()
    res = subprocess.run(["systemctl", "is-active", "xray"], stdout=subprocess.PIPE, text=True)
    is_active = res.stdout.strip() == "active"

    t_res = subprocess.run(["systemctl", "is-active", "incy-cli-update.timer"], stdout=subprocess.PIPE, text=True)
    timer_active = t_res.stdout.strip() == "active"

    print(f"\n{BOLD}Конфигурация INCY-CLI:{RESET}")
    print(f"  HWID устройства:    {CYAN}{cfg.get('hwid')}{RESET}")
    print(f"  Статус VPN:         {GREEN}РАБОТАЕТ{RESET}" if is_active else f"  Статус VPN:         {RED}ОТКЛЮЧЕН{RESET}")
    print(f"  Выбранный узел:     {YELLOW}{cfg.get('active_label', 'Не выбран')}{RESET}")
    print(f"  Автообновление:     {GREEN}ВКЛЮЧЕНО{RESET}" if timer_active else f"  Автообновление:     {YELLOW}ВЫКЛЮЧЕНО{RESET}")

    if is_active:
        print("[*] Проверка внешнего IP...")
        try:
            ip = subprocess.check_output(["curl", "-s", "--max-time", "4", "https://ifconfig.me"], text=True).strip()
            print(f"  Внешний IP:         {GREEN}{ip}{RESET}")
        except Exception:
            print(f"  Внешний IP:         {RED}Не удалось определить{RESET}")
    print("")

def cmd_stop():
    check_root()
    cfg = load_config()
    subprocess.run(["systemctl", "stop", "xray"])
    cfg["active_label"] = None
    save_config(cfg)
    print(f"{YELLOW}[+] VPN выключен. Трафик идет напрямую.{RESET}")

def cmd_autostart(args):
    check_root()
    if not args or args[0] not in ["on", "off"]:
        print(f"{YELLOW}Использование: sudo incy-cli autostart on|off{RESET}")
        return

    if args[0] == "on":
        subprocess.run(["systemctl", "enable", "xray"], check=True)

        with open(TIMER_SERVICE, "w") as f:
            f.write("[Unit]\nDescription=INCY-CLI Daily Update\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/incy-cli update --silent\n")

        with open(TIMER_FILE, "w") as f:
            f.write("[Unit]\nDescription=Run INCY-CLI Auto Update Daily\n\n[Timer]\nOnCalendar=*-*-* 04:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n")

        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "--now", "incy-cli-update.timer"], check=True)
        print(f"{GREEN}[+] Автозапуск VPN при загрузке включен.{RESET}")
        print(f"{GREEN}[+] Ежедневное автообновление серверов настроено.{RESET}")
    else:
        subprocess.run(["systemctl", "disable", "xray"], stdout=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "--now", "incy-cli-update.timer"], stdout=subprocess.DEVNULL)
        print(f"{YELLOW}[+] Автозапуск и таймер обновлений выключены.{RESET}")

def main():
    if len(sys.argv) < 2:
        print(f"\n{BOLD}INCY-CLI Linux VPN Client{RESET}")
        print("Использование: incy-cli <команда> [параметры]")
        print("\nКоманды:")
        print("  sub <URL>       - Добавить/заменить ссылку на подписку (авто-HWID)")
        print("  update          - Обновить сервера по подписке вручную")
        print("  list, ls        - Показать список серверов")
        print("  connect [N]     - Подключиться к серверу по номеру (или выбрать)")
        print("  status          - Проверить статус, HWID и внешний IP")
        print("  stop, down      - Отключить VPN")
        print("  autostart on|off- Включить автозапуск при старте ОС и автообновление")
        print("")
        sys.exit(0)

    cmd = sys.argv[1].lower()
    args = sys.argv[2:]

    if cmd == "sub":
        cmd_sub(args)
    elif cmd == "update":
        cmd_update(args)
    elif cmd in ("list", "ls"):
        cmd_list()
    elif cmd in ("connect", "up"):
        cmd_connect(args)
    elif cmd == "status":
        cmd_status()
    elif cmd in ("stop", "down"):
        cmd_stop()
    elif cmd == "autostart":
        cmd_autostart(args)
    else:
        print(f"{RED}[-] Неизвестная команда: {cmd}{RESET}")

if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/incy-cli
/usr/local/bin/incy-cli >/dev/null 2>&1 || true

echo ""
echo "${GREEN}${BOLD}==============================================${RESET}"
echo "${GREEN}${BOLD}    Установка incy-cli успешно завершена!     ${RESET}"
echo "${GREEN}${BOLD}==============================================${RESET}"
echo ""
echo "Команды для управления (${CYAN}incy-cli${RESET}):"
echo ""
echo "  1. Привязать подписку:"
echo "     ${BOLD}sudo incy-cli sub \"https://YOUR_SUBSCRIPTION_URL\"${RESET}"
echo ""
echo "  2. Посмотреть серверы:"
echo "     ${BOLD}incy-cli list${RESET}"
echo ""
echo "  3. Подключиться:"
echo "     ${BOLD}sudo incy-cli connect${RESET}"
echo ""
echo "  4. Включить автозапуск при старте системы:"
echo "     ${BOLD}sudo incy-cli autostart on${RESET}"
echo ""

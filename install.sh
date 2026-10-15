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
    pacman -Sy --noconfirm python curl unzip iproute2
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y python3 curl unzip iproute2 ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 curl unzip iproute
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add python3 curl unzip iproute2
elif command -v zypper >/dev/null 2>&1; then
    zypper refresh && zypper install -y python3 curl unzip iproute2
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
cat << 'OVR_EOF' > "$OVERRIDE_DIR/override.conf"
[Service]
User=root
OVR_EOF

systemctl daemon-reload
echo "${GREEN}[+] Служба Xray сконфигурирована под TUN.${RESET}"

mkdir -p /etc/incy-cli /etc/xray /usr/local/etc/xray

# ================= 5. РАЗВЕРТЫВАНИЕ INCY-CLI =================
echo "${CYAN}[*] Создание утилиты /usr/local/bin/incy-cli...${RESET}"

cat << 'INCY_EOF' > /usr/local/bin/incy-cli
#!/usr/bin/env python3
import os
import sys
import json
import uuid
import shutil
import socket
import time
import urllib.request
from urllib.parse import urlparse, parse_qs, urlencode, urlunparse
import subprocess

CONFIG_DIR = "/etc/incy-cli"
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
SERVERS_FILE = os.path.join(CONFIG_DIR, "servers.json")
ROUTE_FILE = os.path.join(CONFIG_DIR, "route.txt")

XRAY_CONFIG = "/usr/local/etc/xray/config.json" if os.path.exists("/usr/local/etc/xray") else "/etc/xray/config.json"

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
    for field in ("remarks", "serverDescription", "name", "ps", "title"):
        val = s.get(field)
        if val and str(val).strip():
            return str(val).strip()
    return f"Сервер {idx}"

def get_external_ip(timeout=3):
    endpoints = ["https://ifconfig.me", "https://api.ipify.org", "https://icanhazip.com"]
    for url in endpoints:
        try:
            res = subprocess.check_output(["curl", "-s", "--max-time", str(timeout), url], text=True).strip()
            if res and len(res.split()) == 1 and ("." in res or ":" in res):
                return res
        except Exception:
            continue
    return None

def check_port_conflict(port):
    try:
        res = subprocess.check_output(f"ss -tlpn 'sport = :{port}'", shell=True, text=True)
        lines = [l.strip() for l in res.strip().split("\n") if f":{port}" in l]
        if lines:
            return lines[0]
    except Exception:
        pass
    return None

def check_other_vpn_interfaces():
    try:
        res = subprocess.check_output(["ip", "-o", "link", "show"], text=True)
        active = []
        for line in res.splitlines():
            parts = line.split(": ")
            if len(parts) >= 2:
                name = parts[1].split("@")[0].strip()
                if name in ("xray0", "lo"):
                    continue
                if any(name.startswith(p) for p in ["tun", "wg", "ppp", "tailscale", "proton", "nord", "sing"]):
                    if "state UP" in line or "UP" in line:
                        active.append(name)
        return active
    except Exception:
        return []

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

def generate_xray_config(profile):
    cfg = json.loads(json.dumps(profile))
    tun_inbound = {
        "tag": "tun-in",
        "protocol": "tun",
        "settings": {
            "name": "xray0",
            "mtu": 1500
        }
    }
    socks_inbound = {
        "tag": "socks-in",
        "port": 10808,
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": True}
    }
    cfg["inbounds"] = [tun_inbound, socks_inbound]
    return cfg

def setup_system_routing(chosen_node):
    for _ in range(30):
        res = subprocess.run(["ip", "link", "show", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            break
        time.sleep(0.1)

    subprocess.run(["ip", "addr", "replace", "198.18.0.1/16", "dev", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "link", "set", "xray0", "up"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    gw, dev = None, None
    try:
        res = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        parts = res.strip().split()
        if "via" in parts and "dev" in parts:
            gw = parts[parts.index("via") + 1]
            dev = parts[parts.index("dev") + 1]
    except Exception:
        pass

    server_ip = None
    try:
        outbounds = chosen_node.get("outbounds", [])
        for ob in outbounds:
            vnext = ob.get("settings", {}).get("vnext", [])
            if vnext and vnext[0].get("address"):
                raw_addr = vnext[0].get("address")
                server_ip = socket.gethostbyname(raw_addr)
                break
    except Exception:
        pass

    if server_ip and gw and dev:
        subprocess.run(["ip", "route", "replace", server_ip, "via", gw, "dev", dev], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            with open(ROUTE_FILE, "w") as f:
                f.write(f"{server_ip} {gw} {dev}")
        except Exception:
            pass

    subprocess.run(["ip", "route", "replace", "0.0.0.0/1", "dev", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "route", "replace", "128.0.0.0/1", "dev", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def cleanup_system_routing():
    subprocess.run(["ip", "route", "del", "0.0.0.0/1", "dev", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "route", "del", "128.0.0.0/1", "dev", "xray0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists(ROUTE_FILE):
        try:
            with open(ROUTE_FILE, "r") as f:
                parts = f.read().strip().split()
                if len(parts) >= 3:
                    s_ip, s_gw, s_dev = parts[0], parts[1], parts[2]
                    subprocess.run(["ip", "route", "del", s_ip, "via", s_gw, "dev", s_dev], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.remove(ROUTE_FILE)
        except Exception:
            pass

def save_xray_config(data):
    os.makedirs(os.path.dirname(XRAY_CONFIG), exist_ok=True)
    with open(XRAY_CONFIG, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    if XRAY_CONFIG != "/etc/xray/config.json":
        try:
            os.makedirs("/etc/xray", exist_ok=True)
            with open("/etc/xray/config.json", "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

# ================= КОМАНДЫ CLI =================

def cmd_sub(args):
    check_root()
    if not args:
        print(f"{RED}[-] Укажите ссылку: sudo incy-cli sub \"https://...\"{RESET}")
        sys.exit(1)
    
    cfg = load_config()
    clean_url = normalize_url(args[0])
    cfg["sub_url"] = clean_url
    save_config(cfg)
    print(f"{GREEN}[+] Ссылка сохранена. Привязан постоянный HWID: {cfg['hwid']}{RESET}")
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
                matched = s
                break
        
        if matched:
            save_xray_config(generate_xray_config(matched))
            cleanup_system_routing()
            subprocess.run(["systemctl", "restart", "xray"], stdout=subprocess.DEVNULL)
            setup_system_routing(matched)
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
        active = f" {GREEN}* [АКТИВЕН]{RESET}" if label == cfg.get("active_label") else ""
        print(f"  {YELLOW}[{idx:2d}]{RESET} {label}{active}")
    print("")

def cmd_connect(args):
    check_root()
    ensure_xray()
    cfg = load_config()
    
    # Обработка флага принудительного подключения
    force = "--force" in args or "-f" in args
    args = [a for a in args if a not in ("--force", "-f")]

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

    # ПРОВЕРКА: не подключены ли мы уже к этому серверу
    res_active = subprocess.run(["systemctl", "is-active", "xray"], stdout=subprocess.PIPE, text=True)
    is_active = res_active.stdout.strip() == "active"
    if is_active and cfg.get("active_label") == label and not force:
        print(f"{YELLOW}[!] Вы уже подключены к узлу: {label}{RESET}")
        print(f"    Для принудительного переподключения: {CYAN}sudo incy-cli connect {idx} --force{RESET}")
        return

    # 1. Замеряем исходный IP до подключения
    print(f"{CYAN}[*] Определение текущего IP-адреса системы...{RESET}")
    old_ip = get_external_ip(timeout=3)
    if old_ip:
        print(f"    Исходный IP: {YELLOW}{old_ip}{RESET}")

    # 2. Проверяем другие VPN-интерфейсы
    other_vpns = check_other_vpn_interfaces()
    if other_vpns:
        print(f"{YELLOW}[!] Внимание: обнаружены другие активные VPN-интерфейсы: {', '.join(other_vpns)}{RESET}")
        print(f"{YELLOW}    Они могут перехватывать системные маршруты.{RESET}")

    # 3. Останавливаем службу перед проверкой портов
    cleanup_system_routing()
    subprocess.run(["systemctl", "stop", "xray"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # 4. Проверяем занятость портов 10808 / 10809 сторонними программами
    conflict_10808 = check_port_conflict(10808)
    conflict_10809 = check_port_conflict(10809)
    if conflict_10808 or conflict_10809:
        print(f"{RED}[!] Ошибка: порты 10808 или 10809 уже заняты другим процессом/VPN!{RESET}")
        if conflict_10808:
            print(f"    Детали (10808): {conflict_10808}")
        if conflict_10809:
            print(f"    Детали (10809): {conflict_10809}")
        print(f"{YELLOW}[?] Завершите мешающий процесс перед подключением.{RESET}")
        return

    print(f"{CYAN}[*] Подключение к: {label}...{RESET}")
    save_xray_config(generate_xray_config(chosen))

    res = subprocess.run(["systemctl", "restart", "xray"])
    if res.returncode == 0:
        setup_system_routing(chosen)
        cfg["active_label"] = label
        save_config(cfg)
        print(f"{GREEN}[+] Служба Xray запущена, системные маршруты установлены.{RESET}")

        # 5. Проверяем и сравниваем результат
        print(f"{CYAN}[*] Проверка нового внешнего IP...{RESET}")
        time.sleep(0.5)
        new_ip = get_external_ip(timeout=4)
        if new_ip:
            if old_ip and new_ip != old_ip:
                print(f"{GREEN}[+] Успешно! IP изменился: {YELLOW}{old_ip}{RESET} -> {GREEN}{new_ip}{RESET}")
            elif old_ip and new_ip == old_ip:
                print(f"{RED}[!] Внимание: IP НЕ изменился ({new_ip})! Трафик идет мимо туннеля.{RESET}")
            else:
                print(f"{GREEN}[+] Текущий внешний IP: {new_ip}{RESET}")
        else:
            print(f"{YELLOW}[?] Туннель поднят, но контрольный сервис проверки IP не ответил.{RESET}")
    else:
        print(f"{RED}[-] Ошибка запуска службы Xray!{RESET}")

def cmd_status():
    cfg = load_config()
    res = subprocess.run(["systemctl", "is-active", "xray"], stdout=subprocess.PIPE, text=True)
    is_active = res.stdout.strip() == "active"
    
    t_res = subprocess.run(["systemctl", "is-active", "incy-cli-update.timer"], stdout=subprocess.PIPE, text=True)
    timer_active = t_res.stdout.strip() == "active"

    other_vpns = check_other_vpn_interfaces()

    print(f"\n{BOLD}Конфигурация INCY-CLI:{RESET}")
    print(f"  HWID устройства:    {CYAN}{cfg.get('hwid')}{RESET}")
    print(f"  Статус VPN:         {GREEN}РАБОТАЕТ{RESET}" if is_active else f"  Статус VPN:         {RED}ОТКЛЮЧЕН{RESET}")
    print(f"  Выбранный узел:     {YELLOW}{cfg.get('active_label', 'Не выбран')}{RESET}")
    print(f"  Автообновление:     {GREEN}ВКЛЮЧЕНО{RESET}" if timer_active else f"  Автообновление:     {YELLOW}ВЫКЛЮЧЕНО{RESET}")

    if other_vpns:
        print(f"  Сторонние VPN:      {YELLOW}Обнаружены ({', '.join(other_vpns)}){RESET}")

    if is_active:
        print("[*] Проверка внешнего IP...")
        ip = get_external_ip(timeout=4)
        if ip:
            print(f"  Внешний IP:         {GREEN}{ip}{RESET}")
        else:
            print(f"  Внешний IP:         {RED}Не удалось определить{RESET}")
    print("")

def cmd_stop():
    check_root()
    cfg = load_config()
    cleanup_system_routing()
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
INCY_EOF

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

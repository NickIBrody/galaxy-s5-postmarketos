#!/bin/sh
# Настройка телефонной части postmarketOS на Samsung Galaxy S5 (SM-G900FD)
# Запуск: sudo sh phone-setup.sh
set -e
echo "=== [1/7] Пакеты ==="
apk add yad alsa-utils alsa-ucm-conf || true

echo "=== [2/7] Отключаю ModemManager (мешает AT/QMI) ==="
systemctl disable --now ModemManager 2>/dev/null || true

echo "=== [3/7] Автоподъём модема при загрузке ==="
cat > /usr/local/bin/modem-up <<'XEOF'
#!/bin/sh
QMI=/dev/wwan0qmi0
AID=A0:00:00:00:87:10:02:FF:49:FF:05:89
for i in $(seq 1 60); do [ -e "$QMI" ] && break; sleep 1; done
sleep 3
qmicli -d $QMI --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID" 2>/dev/null
qmicli -d $QMI --dms-set-operating-mode=online
XEOF
chmod +x /usr/local/bin/modem-up
cat > /etc/systemd/system/modem-up.service <<'XEOF'
[Unit]
Description=Bring up modem (slot select + online)
After=rmtfs.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/modem-up
[Install]
WantedBy=multi-user.target
XEOF
systemctl enable modem-up
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-wwan-perms.rules <<'XEOF'
KERNEL=="wwan0at*", MODE="0660", GROUP="plugdev"
KERNEL=="wwan0qmi*", MODE="0660", GROUP="plugdev"
XEOF
udevadm control --reload || true
udevadm trigger /dev/wwan0at0 /dev/wwan0at1 /dev/wwan0qmi0 2>/dev/null || true

echo "=== [4/7] Команды: atcmd, call, hangup, answer, contact, sms, smscheck ==="
cat > /usr/local/bin/atcmd <<'XEOF'
#!/bin/sh
PORT="${PORT:-/dev/wwan0at0}"
W="${2:-2}"
cat "$PORT" & C=$!
sleep 0.3
printf '%s\r' "$1" > "$PORT"
sleep "$W"
kill $C 2>/dev/null
XEOF
cat > /usr/local/bin/call <<'XEOF'
#!/bin/sh
C="$HOME/.contacts"
N="$1"
[ -z "$N" ] && { echo "call <номер|имя>"; [ -f "$C" ] && cat "$C"; exit 1; }
case "$N" in
  *[!0-9+]*)
    L=$(grep -i -m1 "^$N " "$C" 2>/dev/null)
    [ -z "$L" ] && { echo "нет контакта '$N'"; exit 1; }
    N=$(echo "$L" | awk '{print $2}');;
esac
echo "Звоню: $N"
atcmd "ATD$N;" 3
XEOF
cat > /usr/local/bin/hangup <<'XEOF'
#!/bin/sh
atcmd "AT+CHUP"
XEOF
cat > /usr/local/bin/answer <<'XEOF'
#!/bin/sh
atcmd "ATA" 3
XEOF
cat > /usr/local/bin/contact <<'XEOF'
#!/bin/sh
C="$HOME/.contacts"; touch "$C"
case "$1" in
  add) echo "$2 $3" >> "$C"; echo "ok: $2 $3";;
  del) grep -vi "^$2 " "$C" > "$C.tmp" && mv "$C.tmp" "$C"; echo "удалён $2";;
  *) cat "$C";;
esac
XEOF
cat > /usr/local/bin/sms <<'XEOF'
#!/bin/sh
C="$HOME/.contacts"; N="$1"; T="$2"
[ -z "$T" ] && { echo 'sms <номер|имя> "text latin"'; exit 1; }
case "$N" in
  *[!0-9+]*)
    L=$(grep -i -m1 "^$N " "$C" 2>/dev/null)
    [ -z "$L" ] && { echo "нет контакта '$N'"; exit 1; }
    N=$(echo "$L" | awk '{print $2}');;
esac
P=/dev/wwan0at0
atcmd 'AT+CMGF=1' 1 >/dev/null
cat "$P" & R=$!
sleep 0.3
printf 'AT+CMGS="%s"\r' "$N" > "$P"
sleep 1
printf '%s\032' "$T" > "$P"
sleep 6
kill $R 2>/dev/null
XEOF
cat > /usr/local/bin/smscheck <<'XEOF'
#!/bin/sh
atcmd 'AT+CMGF=1' 1 >/dev/null
atcmd 'AT+CPMS="SM"' 2 >/dev/null
atcmd 'AT+CMGL="ALL"' 8 | python3 -c '
import sys,re
for line in sys.stdin:
    s=line.strip()
    if re.fullmatch(r"[0-9A-Fa-f]{8,}",s) and len(s)%4==0:
        try: print(bytes.fromhex(s).decode("utf-16-be","replace"))
        except Exception: print(s)
    else: print(line,end="")
'
XEOF
chmod +x /usr/local/bin/atcmd /usr/local/bin/call /usr/local/bin/hangup \
         /usr/local/bin/answer /usr/local/bin/contact /usr/local/bin/sms /usr/local/bin/smscheck

echo "=== [5/7] GUI-звонилка ==="
cat > /usr/local/bin/phone-gui <<'XEOF'
#!/bin/sh
while true; do
  DATA=$(yad --title="Телефон" --form --geometry=400x220+10+60 \
    --field="Номер или имя" "" \
    --button="Позвонить:2" --button="Трубку:4" --button="SMS:6" --button="Выход:1")
  RET=$?
  NUM=$(echo "$DATA" | cut -d'|' -f1)
  case $RET in
    2) [ -n "$NUM" ] && call "$NUM" | yad --text-info --title="Звонок" --geometry=400x200+10+60 --button=OK --timeout=6;;
    4) hangup >/dev/null 2>&1;;
    6) smscheck | yad --text-info --title="SMS" --geometry=600x700+10+60 --button=OK;;
    *) exit 0;;
  esac
done
XEOF
chmod +x /usr/local/bin/phone-gui
cat > /usr/share/applications/phone.desktop <<'XEOF'
[Desktop Entry]
Type=Application
Name=Телефон
Exec=phone-gui
Icon=call-start
Categories=Network;
XEOF

echo "=== [6/7] Срез мёртвой зоны + клавиатура + VNC (если ещё не стояло) ==="
cat > /usr/local/bin/shrink-screen <<'XEOF'
#!/bin/sh
CUT=100
[ -f /etc/shrink-screen.conf ] && . /etc/shrink-screen.conf
[ -n "$1" ] && CUT="$1"
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -z "$OUT" ] && { echo "нет X11-дисплея"; exit 1; }
GEO=$(xrandr | awk -v o="$OUT" '$1==o {print $3; exit}' | cut -d+ -f1)
H=${GEO#*x}
case "$H" in ''|*[!0-9]*) H=1920;; esac
VIS=$((H - CUT))
SY=$(awk -v v="$VIS" -v h="$H" 'BEGIN{printf "%.6f", v/h}')
TY=$(awk -v v="$VIS" -v h="$H" 'BEGIN{printf "%.6f", h/v}')
xrandr --output "$OUT" --transform "1,0,0,0,${SY},0,0,0,1"
TOUCH=$(xinput list --name-only 2>/dev/null | grep -i -m1 -E "touch|mxt|atmel|rmi4")
[ -n "$TOUCH" ] && xinput set-prop "$TOUCH" "Coordinate Transformation Matrix" 1 0 0 0 "$TY" 0 0 0 1
echo "срезано ${CUT}px снизу"
XEOF
chmod +x /usr/local/bin/shrink-screen
[ -f /etc/shrink-screen.conf ] || echo CUT=100 > /etc/shrink-screen.conf
cat > /etc/xdg/autostart/shrink-screen.desktop <<'XEOF'
[Desktop Entry]
Type=Application
Name=Shrink Screen
Exec=sh -c "sleep 3; /usr/local/bin/shrink-screen"
OnlyShowIn=XFCE;
XEOF
cat > /etc/xdg/autostart/onboard-autostart.desktop <<'XEOF'
[Desktop Entry]
Type=Application
Name=Onboard
Exec=onboard
OnlyShowIn=XFCE;
XEOF
cat > /usr/local/bin/share-screen <<'XEOF'
#!/bin/sh
echo "VNC: подключайтесь к 172.16.42.1:5900 (USB) или к Wi-Fi IP, пароль 147147"
exec x11vnc -display :0 -auth guess -passwd 147147 -forever -shared -noxdamage
XEOF
chmod +x /usr/local/bin/share-screen

echo "=== [7/7] ДИАГНОСТИКА ЗВУКА — пришли этот блок целиком ==="
echo "--- aplay -l ---"
aplay -l 2>&1 || true
echo "--- карты ---"
cat /proc/asound/cards 2>&1 || true
echo "--- ucm2 профили ---"
ls /usr/share/alsa/ucm2/ 2>/dev/null | head -20 || true
ls /usr/share/alsa/ucm2/conf.d/ 2>/dev/null | head -20 || true
echo "--- контролы (voice/rx/tx) ---"
amixer -c 0 controls 2>/dev/null | grep -iE "voice|rx|tx|ear|spk|mic" | head -40 || true
echo
echo "=== ГОТОВО. Перезагрузись: sudo reboot ==="
echo "После перезагрузки: call <номер|имя>, hangup, sms, smscheck, contact add <имя> <номер>"

echo "=== [8/8] mobiledata ==="
cat > /usr/local/bin/mobiledata <<'XEOF'
#!/bin/sh
# mobiledata on [apn] | off     (APN: МТС internet.mts.ru, Мегафон internet, Билайн internet.beeline.ru, Tele2/Yota internet.tele2.ru / internet.yota)
QMI=/dev/wwan0qmi0
IF=wwan0
case "$1" in
on)
  APN="${2:-internet}"
  sudo ip link set $IF up
  sudo qmicli -d $QMI --wds-start-network="apn=$APN,ip-type=4" --client-no-release-cid >/dev/null 2>&1
  S=$(sudo qmicli -d $QMI --wds-get-current-settings 2>/dev/null)
  IP=$(echo "$S" | awk -F': ' '/IPv4 address/{print $2}')
  GW=$(echo "$S" | awk -F': ' '/IPv4 gateway address/{print $2}')
  D1=$(echo "$S" | awk -F': ' '/IPv4 primary DNS/{print $2}')
  M=$(echo "$S" | awk -F': ' '/IPv4 subnet mask/{print $2}')
  [ -z "$IP" ] && { echo "IP не получен — проверь APN: mobiledata on <apn>"; exit 1; }
  P=$(echo "$M" | awk -F. '{c=0; for(i=1;i<=4;i++){x=$i; while(x>0){c+=x%2; x=int(x/2)}} print c}')
  [ -z "$P" ] && P=24
  sudo ip addr flush dev $IF
  sudo ip addr add "$IP/$P" dev $IF
  sudo ip route replace default via "$GW" dev $IF metric 700
  if systemctl is-active -q systemd-resolved 2>/dev/null; then
    sudo resolvectl dns $IF "$D1" 2>/dev/null
  else
    grep -q "$D1" /etc/resolv.conf 2>/dev/null || echo "nameserver $D1" | sudo tee -a /etc/resolv.conf >/dev/null
  fi
  echo "интернет через SIM: $IP (APN $APN)"
;;
off)
  sudo ip addr flush dev $IF 2>/dev/null
  sudo ip link set $IF down
  echo "мобильные данные выключены"
;;
*) echo "mobiledata on [apn] | off";;
esac
XEOF
chmod +x /usr/local/bin/mobiledata
echo "mobiledata установлен"

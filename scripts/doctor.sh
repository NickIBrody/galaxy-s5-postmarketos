#!/bin/sh
# Лечилка двух болячек: пропавшая сотовая сеть и «не заряжается».
#
#   sudo sh doctor.sh            — диагностика + починка сети + отчёт по зарядке
#   sudo sh doctor.sh net        — только сеть
#   sudo sh doctor.sh power      — только отчёт по зарядке
#   sudo sh doctor.sh power 900  — поднять лимит входного тока до 900 мА
#
# Идемпотентно, запускать можно сколько угодно раз.

QMI=/dev/wwan0qmi0
AT=/dev/wwan0at0

# ─────────────────────────────── ЗАРЯДКА ───────────────────────────────
power_report() {
  echo "=============== ПИТАНИЕ ==============="
  if [ ! -d /sys/class/power_supply ] || [ -z "$(ls /sys/class/power_supply 2>/dev/null)" ]; then
    echo "  /sys/class/power_supply ПУСТ — драйвера зарядки в ядре нет вообще."
    echo "  Заряжать только внешней 'лягушкой' (батарея съёмная)."
    return
  fi
  for ps in /sys/class/power_supply/*; do
    [ -d "$ps" ] || continue
    echo "--- $(basename "$ps")"
    for f in type status online present health capacity voltage_now current_now \
             current_max input_current_limit constant_charge_current \
             constant_charge_current_max charge_type usb_type temp; do
      [ -f "$ps/$f" ] && printf '   %-28s %s\n' "$f" "$(cat "$ps/$f" 2>/dev/null)"
    done
  done
  echo
  echo "--- что ядро говорило про зарядку:"
  dmesg 2>/dev/null | grep -iE 'charg|smb[0-9]|bq2[0-9]|max77|extcon|vbus|battery' | tail -25
  echo
  echo "ПОДСКАЗКА:"
  echo " * status=Charging и current_now>0  -> заряд ИДЁТ (медленно = мало тока, см. ниже)"
  echo " * online=1, но status=Discharging  -> ток есть, но зарядка не включена драйвером"
  echo " * ни одного 'usb'/'charger' supply  -> драйвера нет, лечится только 'лягушкой'"
}

power_set() {
  MA="$1"
  case "$MA" in ''|*[!0-9]*) echo "нужно число мА, например: sudo sh doctor.sh power 900"; return 1;; esac
  [ "$MA" -gt 1500 ] && { echo "больше 1500 мА не дам — рискованно"; return 1; }
  UA=$((MA * 1000))
  DONE=0
  for f in /sys/class/power_supply/*/input_current_limit \
           /sys/class/power_supply/*/current_max \
           /sys/class/power_supply/*/constant_charge_current; do
    [ -w "$f" ] || continue
    OLD=$(cat "$f" 2>/dev/null)
    if echo "$UA" > "$f" 2>/dev/null; then
      echo "  $f: $OLD -> $(cat "$f")"
      DONE=1
    fi
  done
  [ "$DONE" = 0 ] && echo "  ни один лимит тока не редактируется — драйвер не даёт."
  echo "ВНИМАНИЕ: сбросится после перезагрузки. Если помогло — скажи, вобьём в автозапуск."
}

# ──────────────────────────────── СЕТЬ ────────────────────────────────
at() {
  # одиночная AT-команда с чтением ответа
  [ -c "$AT" ] || { echo "  нет $AT"; return 1; }
  cat "$AT" & C=$!
  sleep 0.3
  printf '%s\r' "$1" > "$AT"
  sleep "${2:-3}"
  kill $C 2>/dev/null
}

net_fix() {
  echo "=============== СЕТЬ ==============="

  echo "--- ModemManager убираем с дороги (он держит порты и глушит ответы)"
  systemctl stop ModemManager 2>/dev/null
  systemctl disable ModemManager 2>/dev/null

  echo "--- модем жив?"
  ls -l /dev/wwan0* 2>/dev/null || echo "  портов модема НЕТ — модем не поднялся"
  if [ ! -c "$QMI" ]; then
    echo "  перезапускаю rmtfs и жду порты..."
    systemctl restart rmtfs 2>/dev/null
    i=0; while [ $i -lt 40 ] && [ ! -c "$QMI" ]; do sleep 1; i=$((i+1)); done
  fi
  [ -c "$QMI" ] || { echo "  QMI-порт так и не появился. Нужна перезагрузка: sudo reboot"; return 1; }

  echo "--- активирую SIM-слот (тот самый костыль)"
  /usr/local/bin/modem-up 2>&1 | tail -5

  echo "--- статус карты"
  qmicli -d "$QMI" --uim-get-card-status 2>/dev/null | grep -iE 'card state|application state|session' | head -8

  echo "--- регистрация в сети (ждём до 40 с)"
  REG=""
  i=0
  while [ $i -lt 8 ]; do
    REG=$(qmicli -d "$QMI" --nas-get-serving-system 2>/dev/null | grep -i 'registration state' | head -1)
    echo "  $REG"
    echo "$REG" | grep -qi 'registered' && echo "$REG" | grep -qvi 'not-registered' && break
    sleep 5
    i=$((i+1))
  done

  echo "--- уровень сигнала и оператор"
  at 'AT+CSQ' 3
  at 'AT+COPS?' 3

  echo
  if echo "$REG" | grep -qi 'registered' && ! echo "$REG" | grep -qi 'not-registered'; then
    echo "СЕТЬ ЕСТЬ. Звонить:  call <имя|номер>"
  else
    echo "СЕТЬ НЕ ПОДНЯЛАСЬ."
    echo "Частая причина — сменилась/переставлялась SIM: AID в скрипте зашит жёстко."
    echo "Переснять AID:"
    echo "  sudo qmicli -d $QMI --uim-get-card-status | grep -A3 -i 'application id'"
    echo "и вписать его в /usr/local/bin/modem-up (строка AID=...)"
  fi
}

net_keeper() {
  # сторож: раз в 2 минуты проверяет регистрацию, при потере — перезапускает активацию слота
  cat > /usr/local/bin/net-keeper <<'XEOF'
#!/bin/sh
QMI=/dev/wwan0qmi0
while true; do
    sleep 120
    [ -c "$QMI" ] || continue
    S=$(qmicli -d "$QMI" --nas-get-serving-system 2>/dev/null | grep -i 'registration state')
    echo "$S" | grep -qi 'registered' && ! echo "$S" | grep -qi 'not-registered' && continue
    logger -t net-keeper "сеть потеряна, переактивирую слот SIM"
    /usr/local/bin/modem-up >/dev/null 2>&1
done
XEOF
  chmod +x /usr/local/bin/net-keeper
  cat > /etc/systemd/system/net-keeper.service <<'XEOF'
[Unit]
Description=Keep the modem registered on the network
After=modem-up.service rmtfs.service
[Service]
ExecStart=/usr/local/bin/net-keeper
Restart=always
[Install]
WantedBy=multi-user.target
XEOF
  systemctl daemon-reload
  systemctl enable modem-up 2>/dev/null
  systemctl enable --now net-keeper
  echo "--- сторож сети установлен (проверка раз в 2 минуты)"
}

# ─────────────────────────────── ЗАПУСК ───────────────────────────────
case "$1" in
  power) shift; [ -n "$1" ] && power_set "$1" || power_report ;;
  net)   net_fix; net_keeper ;;
  *)     net_fix; net_keeper; echo; power_report ;;
esac

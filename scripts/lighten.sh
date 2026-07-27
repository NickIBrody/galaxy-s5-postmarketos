#!/bin/sh
# Разгон phosh на слабом железе (2 ГБ ОЗУ, Adreno 330).
#
#   sudo sh lighten.sh          — применить всё
#   sudo sh lighten.sh status   — показать, что сейчас
#
# Ничего не удаляет: всё обратимо, службы только маскируются.
set -e

USER_NAME=user
USER_HOME=/home/$USER_NAME

say() { echo "== $*"; }

if [ "$1" = "status" ]; then
  echo "ОЗУ:"; free -m | head -2
  echo; echo "Подкачка:"; swapon --show 2>/dev/null || cat /proc/swaps
  echo; echo "Управление частотой:"
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "нет cpufreq"
  echo; echo "Анимации:"
  sudo -u $USER_NAME gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null
  exit 0
fi

# 1. Сжатая подкачка в оперативке.
# 2 ГБ для phosh мало: при нехватке система начинает убивать процессы и дёргаться.
# zram отдаёт примерно втрое больше памяти ценой небольшой нагрузки на процессор —
# на этом железе размен выгодный.
say "включаю zram"
if modprobe zram num_devices=1 2>/dev/null || [ -e /sys/block/zram0 ]; then
  if ! grep -q zram0 /proc/swaps; then
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo 1G > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0
  fi
  cat > /etc/systemd/system/zram.service <<'XEOF'
[Unit]
Description=compressed swap in RAM
DefaultDependencies=no
Before=swap.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe zram num_devices=1
ExecStart=/bin/sh -c 'echo lz4 > /sys/block/zram0/comp_algorithm || true'
ExecStart=/bin/sh -c 'echo 1G > /sys/block/zram0/disksize'
ExecStart=/sbin/mkswap /dev/zram0
ExecStart=/sbin/swapon -p 100 /dev/zram0
ExecStop=/sbin/swapoff /dev/zram0
[Install]
WantedBy=multi-user.target
XEOF
  systemctl daemon-reload
  systemctl enable zram >/dev/null 2>&1 || true
  echo "   zram на 1 ГБ подключён"
else
  echo "   модуля zram в ядре нет, пропускаю"
fi

# Подкачку в zram имеет смысл использовать охотно — она быстрая.
say "настраиваю поведение памяти"
cat > /etc/sysctl.d/99-lighten.conf <<'XEOF'
vm.swappiness=100
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=15
XEOF
sysctl -p /etc/sysctl.d/99-lighten.conf >/dev/null 2>&1 || true

# 2. Анимации. Adreno 330 их тянет, но каждая — лишние кадры на каждое действие.
say "выключаю анимации в оболочке"
for k in "enable-animations false" "gtk-enable-primary-paste false"; do
  sudo -u $USER_NAME DISPLAY= dbus-run-session -- gsettings set org.gnome.desktop.interface $k 2>/dev/null || \
  sudo -u $USER_NAME gsettings set org.gnome.desktop.interface $k 2>/dev/null || true
done

# 3. Индексатор файлов GNOME. На телефоне бесполезен, а процессор ест регулярно.
say "глушу индексатор файлов (tracker)"
for s in tracker-miner-fs-3 tracker-extract-3 tracker-miner-rss-3 tracker-store; do
  sudo -u $USER_NAME systemctl --user mask $s.service 2>/dev/null || true
done
sudo -u $USER_NAME systemctl --user stop tracker-miner-fs-3.service 2>/dev/null || true

# 4. Управление частотой. ondemand/schedutil разгоняются лениво, отсюда
# ощущение «подтормаживает при каждом касании». Ставим отзывчивый режим.
say "настраиваю частоту процессора"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo schedutil > "$g" 2>/dev/null || true
done
cat > /etc/systemd/system/cpugov.service <<'XEOF'
[Unit]
Description=set cpu governor
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo schedutil > $g 2>/dev/null || true; done'
[Install]
WantedBy=multi-user.target
XEOF
systemctl daemon-reload
systemctl enable cpugov >/dev/null 2>&1 || true

# 5. Мелочи, которые крутятся впустую на телефоне без соответствующего железа.
say "отключаю лишние службы"
for s in ModemManager.service cups.service avahi-daemon.service packagekit.service; do
  systemctl mask $s 2>/dev/null || true
done
echo "   (ModemManager и так был отключён — он мешает модему)"

echo
echo "=== ГОТОВО. Перезагрузка: sudo reboot ==="
echo "Проверить потом:  sudo sh lighten.sh status"
echo
echo "Что даст больше всего: zram (память) и отключение анимаций (отзывчивость)."
echo "Если станет хуже — всё снимается:"
echo "  sudo swapoff /dev/zram0; sudo systemctl disable zram cpugov"
echo "  sudo rm /etc/sysctl.d/99-lighten.conf"

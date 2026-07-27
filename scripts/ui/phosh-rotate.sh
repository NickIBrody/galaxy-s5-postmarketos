#!/bin/sh
# Возврат к phosh (родной мобильной оболочке) с поворотом экрана на 180°.
# Смысл: мёртвая нижняя полоса тачскрина оказывается СВЕРХУ, а домашняя полоска
# и клавиатура phosh — в живой части экрана.
#
# Запуск:  sudo sh phosh-rotate.sh          — включить phosh + поворот
#          sudo sh phosh-rotate.sh 0        — phosh без поворота
#          sudo sh phosh-rotate.sh tui      — вернуться в терминальный режим
set -e

USER_NAME=user
USER_HOME=/home/$USER_NAME

if [ "$1" = "tui" ]; then
  systemctl disable greetd 2>/dev/null || true
  systemctl enable lightdm
  echo "вернул терминальный режим. sudo reboot"
  exit 0
fi

ROT="${1:-180}"

# 1. Имя дисплея (обычно DSI-1)
OUT=$(ls /sys/class/drm/ 2>/dev/null | grep -m1 -o 'card[0-9]*-.*' | cut -d- -f2- || true)
[ -z "$OUT" ] && OUT=DSI-1
echo "дисплей: $OUT, поворот: $ROT"

# 2. Конфиг phoc (композитора phosh)
mkdir -p "$USER_HOME/.config/phoc"
cat > "$USER_HOME/.config/phoc/phoc.ini" <<XEOF
[core]
xwayland = true

[output:$OUT]
scale = 2
rotate = $ROT
XEOF
chown -R $USER_NAME:$USER_NAME "$USER_HOME/.config/phoc"

# 3. Возврат на greetd (родной вход phosh) вместо lightdm
systemctl disable lightdm 2>/dev/null || true
systemctl enable greetd

echo
echo "=== ГОТОВО ==="
echo "sudo reboot — и загрузится phosh с экраном, повёрнутым на ${ROT}°."
echo "Мёртвая полоса окажется сверху; домашняя полоска — снизу, в рабочей зоне."
echo
echo "Если не понравится:"
echo "  sudo sh phosh-rotate.sh 0     — phosh без поворота"
echo "  sudo sh phosh-rotate.sh tui   — обратно в терминальный режим"
echo "SSH работает в любом случае: ssh user@172.16.42.1"

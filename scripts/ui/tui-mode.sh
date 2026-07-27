#!/bin/sh
# TUI-режим: терминал на весь экран + плавающая экранная клавиатура, без рабочего стола.
# Запуск:  sudo sh tui-mode.sh          — включить
#          sudo sh tui-mode.sh xfce     — вернуть обычный Xfce
set -e

if [ "$1" = "xfce" ]; then
  sed -i 's/^autologin-session=.*/autologin-session=xfce/' /etc/lightdm/lightdm.conf.d/50-autologin.conf
  echo "вернул Xfce. sudo reboot"
  exit 0
fi

echo "=== пакеты ==="
apk add xterm openbox onboard xrandr xinput >/dev/null
echo "=== сессия ==="

cat > /usr/local/bin/tui-session <<'XEOF'
#!/bin/sh
# срез мёртвой зоны снизу
( sleep 2; /usr/local/bin/shrink-screen ) &

# лёгкий оконный менеджер: держит клавиатуру поверх и даёт двигать её пальцем
openbox &

# плавающая клавиатура
( sleep 1; onboard ) &

# терминал на весь экран, крупный шрифт, тёмная тема
exec xterm -fa "Monospace" -fs 14 -bg black -fg white -maximized \
  -xrm 'XTerm*scrollBar: false' -xrm 'XTerm*allowBoldFonts: false' \
  -e /bin/sh -lc 'echo "== postmarketOS S5 =="; echo "call <номер|имя> | hangup | answer | sms | smscheck | contact | mobiledata on|off"; echo; exec /bin/sh -l'
XEOF
chmod +x /usr/local/bin/tui-session

cat > /usr/share/xsessions/tui.desktop <<'XEOF'
[Desktop Entry]
Name=TUI
Comment=Terminal + onscreen keyboard
Exec=/usr/local/bin/tui-session
Type=Application
XEOF

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<'XEOF'
[Seat:*]
autologin-user=user
autologin-session=tui
XEOF

# openbox: без декораций у клавиатуры, клик-в-фокус
mkdir -p /home/user/.config/openbox
cat > /home/user/.config/openbox/rc.xml <<'XEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application name="onboard">
      <decor>no</decor>
      <layer>above</layer>
    </application>
  </applications>
</openbox_config>
XEOF
chown -R user:user /home/user/.config/openbox

echo
echo "=== ГОТОВО ==="
echo "sudo reboot  — и телефон загрузится сразу в терминал с клавиатурой."
echo "Вернуть Xfce:  sudo sh tui-mode.sh xfce"

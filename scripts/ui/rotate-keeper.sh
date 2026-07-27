#!/bin/sh
# Держит экран повёрнутым на 180° в phosh.
#
# Зачем: phoc сбрасывает поворот каждый раз, когда заново включает дисплей
# (разблокировка, пробуждение). Штатного пользовательского конфига,
# который бы это переживал, в этой сборке нет — поэтому сторож.
#
# Запуск:  sh rotate-keeper.sh install   — поставить в автозапуск (служба пользователя)
#          sh rotate-keeper.sh           — разово повернуть сейчас
#          sh rotate-keeper.sh remove    — убрать из автозапуска

OUT=DSI-1
ROT=180

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

case "$1" in
install)
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.local/bin/rotate-keeper" <<'XEOF' 2>/dev/null || true
XEOF
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/rotate-keeper" <<XEOF
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-0
while true; do
    # применяем поворот только когда выход включён и повёрнут неправильно
    S=\$(wlr-randr 2>/dev/null | grep -A20 "^$OUT" )
    echo "\$S" | grep -q "Enabled: yes" && \\
    ! echo "\$S" | grep -qi "Transform: $ROT" && \\
        wlr-randr --output $OUT --transform $ROT >/dev/null 2>&1
    sleep 2
done
XEOF
  chmod +x "$HOME/.local/bin/rotate-keeper"

  cat > "$HOME/.config/systemd/user/rotate-keeper.service" <<XEOF
[Unit]
Description=Keep display rotated ${ROT} degrees
After=graphical-session.target
[Service]
ExecStart=$HOME/.local/bin/rotate-keeper
Restart=always
[Install]
WantedBy=default.target
XEOF
  systemctl --user daemon-reload
  systemctl --user enable --now rotate-keeper
  echo "сторож поворота установлен и запущен"
  ;;
remove)
  systemctl --user disable --now rotate-keeper 2>/dev/null
  rm -f "$HOME/.config/systemd/user/rotate-keeper.service" "$HOME/.local/bin/rotate-keeper"
  systemctl --user daemon-reload
  wlr-randr --output $OUT --transform normal >/dev/null 2>&1
  echo "сторож удалён, поворот сброшен"
  ;;
*)
  wlr-randr --output $OUT --transform $ROT && echo "повёрнуто на ${ROT}°"
  ;;
esac

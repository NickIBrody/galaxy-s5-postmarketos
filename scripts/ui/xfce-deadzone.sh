#!/bin/sh
# Резервирует нижнюю полосу экрана в Xfce пустой панелью-заглушкой,
# чтобы окна никогда не попадали в мёртвую зону тачскрина.
# Запуск (от обычного пользователя, НЕ через sudo):  sh xfce-deadzone.sh [высота_px]
# По умолчанию 200 px (~1.2 см на экране S5). 1 см ≈ 170 px.
DEAD="${1:-200}"
export DISPLAY="${DISPLAY:-:0}"

# панель-заглушка = panel-9 (чтобы не конфликтовать с обычными панелями Xfce)
xfconf-query -c xfce4-panel -p /panels -t int -s 1 -t int -s 9 -a --create 2>/dev/null || \
xfconf-query -c xfce4-panel -p /panels -t int -s 1 -t int -s 9 -a

xfconf-query -c xfce4-panel -p /panels/panel-9/position     -t string -s "p=11;x=540;y=1920" --create
xfconf-query -c xfce4-panel -p /panels/panel-9/size         -t int    -s "$DEAD"             --create
xfconf-query -c xfce4-panel -p /panels/panel-9/length       -t uint   -s 100                 --create
xfconf-query -c xfce4-panel -p /panels/panel-9/mode         -t uint   -s 0                   --create
xfconf-query -c xfce4-panel -p /panels/panel-9/autohide-behavior -t uint -s 0                --create
xfconf-query -c xfce4-panel -p /panels/panel-9/position-locked   -t bool -s true             --create
xfconf-query -c xfce4-panel -p /panels/panel-9/plugin-ids -t int -s 0 -a --create 2>/dev/null

xfce4-panel -r 2>/dev/null &
echo "Готово: нижние ${DEAD}px зарезервированы. Окна туда больше не попадут."
echo "Изменить:  sh xfce-deadzone.sh 255      Убрать:  sh xfce-deadzone.sh remove"

if [ "$1" = "remove" ]; then
  xfconf-query -c xfce4-panel -p /panels -t int -s 1 -a
  xfconf-query -c xfce4-panel -p /panels/panel-9 -r -R 2>/dev/null
  xfce4-panel -r 2>/dev/null &
  echo "заглушка убрана"
fi

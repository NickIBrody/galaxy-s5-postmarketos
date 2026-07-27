#!/usr/bin/env python3
"""
Зарядка для samsung-klte, которой нет в ядре.

Что это: в mainline нет драйвера зарядного чипа max77804k, и шины, на которой
он висит, тоже нет. Чип при этом жив: он питает телефон от кабеля, но заряд
держит выключенным. Эта служба вручную дёргает две ножки процессора как
I2C-шину, находит чип по адресу 0x66 и включает заряд регистрами.

Дополнительно делает то, чего не делает даже штатное ядро на этом аппарате:
останавливает заряд на заданном проценте, чтобы не мучить батарею.

  sudo python3 chargectl.py install   — поставить как службу
  sudo python3 chargectl.py status    — показать, что происходит сейчас
  sudo python3 chargectl.py run       — гонять в текущем терминале
  sudo python3 chargectl.py remove    — убрать

Настройки в /etc/chargectl.conf
"""
import os
import sys
import time

SYS = "/sys/class/gpio"
DELAY = 5e-5

# Ножки процессора, на которых висит шина зарядного чипа.
# В стоковом device tree это msmgpio 60/61; база gpiochip в mainline = 512.
SDA, SCL = 572, 573
ADDR = 0x66

REG_INT_OK = 0xB2      # бит 6 — есть ли годное питание на входе
REG_DETAILS = 0xB4     # младшая цифра: 1 = идёт заряд, 8 = выключен
REG_MODE = 0xB7        # 0x05 = заряд + питание, 0x04 = только питание
REG_CURRENT = 0xB9     # ток заряда, шаг ~33 мА
REG_INLIMIT = 0xC0     # лимит тока из кабеля, шаг 20 мА

MODE_CHARGE = 0x05
MODE_OFF = 0x04

CAPACITY = "/sys/class/power_supply/battery/capacity"
VOLTAGE = "/sys/class/power_supply/battery/voltage_now"
LOG = "/var/log/battery.log"
CONF = "/etc/chargectl.conf"

# значения по умолчанию
CFG = {
    "STOP": 95,          # на этом проценте заряд выключается
    "START": 85,         # ниже этого — включается снова
    "CURRENT": 0x15,     # ~700 мА
    "INLIMIT": 0x32,     # ~1000 мА из кабеля
    "INTERVAL": 15,
}


def load_conf():
    if not os.path.exists(CONF):
        return
    for line in open(CONF):
        line = line.split("#")[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            k = k.strip().upper()
            if k in CFG:
                try:
                    CFG[k] = int(v.strip(), 0)
                except ValueError:
                    pass


class Pin:
    def __init__(self, num):
        self.num = num
        self.path = f"{SYS}/gpio{num}"
        if not os.path.isdir(self.path):
            with open(f"{SYS}/export", "w") as f:
                f.write(str(num))
            time.sleep(0.05)
        self.dir_f = open(f"{self.path}/direction", "w")
        self.val_f = open(f"{self.path}/value", "r")
        self.release()

    def _dir(self, mode):
        self.dir_f.write(mode)
        self.dir_f.flush()

    def low(self):
        self._dir("low")

    def release(self):
        self._dir("in")

    def read(self):
        self.val_f.seek(0)
        return 1 if self.val_f.read().strip() == "1" else 0


class I2C:
    def __init__(self, sda, scl):
        self.sda = Pin(sda)
        self.scl = Pin(scl)

    def _wait(self):
        for _ in range(1000):
            if self.scl.read():
                return
            time.sleep(DELAY)

    def start(self):
        self.sda.release()
        self.scl.release()
        time.sleep(DELAY)
        self.sda.low()
        time.sleep(DELAY)
        self.scl.low()

    def stop(self):
        self.sda.low()
        time.sleep(DELAY)
        self.scl.release()
        self._wait()
        time.sleep(DELAY)
        self.sda.release()
        time.sleep(DELAY)

    def _wbit(self, bit):
        self.sda.release() if bit else self.sda.low()
        time.sleep(DELAY)
        self.scl.release()
        self._wait()
        time.sleep(DELAY)
        self.scl.low()

    def _rbit(self):
        self.sda.release()
        time.sleep(DELAY)
        self.scl.release()
        self._wait()
        v = self.sda.read()
        time.sleep(DELAY)
        self.scl.low()
        return v

    def _wbyte(self, b):
        for i in range(7, -1, -1):
            self._wbit((b >> i) & 1)
        return self._rbit() == 0

    def _rbyte(self, ack=True):
        v = 0
        for _ in range(8):
            v = (v << 1) | self._rbit()
        self._wbit(0 if ack else 1)
        return v

    def read_reg(self, reg, addr=ADDR):
        self.start()
        if not (self._wbyte(addr << 1) and self._wbyte(reg)):
            self.stop()
            return None
        self.start()
        if not self._wbyte((addr << 1) | 1):
            self.stop()
            return None
        v = self._rbyte(ack=False)
        self.stop()
        return v

    def write_reg(self, reg, val, addr=ADDR):
        self.start()
        ok = self._wbyte(addr << 1) and self._wbyte(reg) and self._wbyte(val)
        self.stop()
        return ok


def read_int(path):
    try:
        return int(open(path).read().strip())
    except Exception:
        return None


def log(msg):
    line = f"{time.strftime('%m-%d %H:%M')} {msg}"
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)


def status():
    bus = I2C(SDA, SCL)
    ok = bus.read_reg(REG_INT_OK)
    det = bus.read_reg(REG_DETAILS)
    mode = bus.read_reg(REG_MODE)
    cur = bus.read_reg(REG_CURRENT)
    lim = bus.read_reg(REG_INLIMIT)
    if ok is None:
        print("чип не отвечает")
        return
    states = {0x0: "предзаряд", 0x1: "быстрый заряд", 0x2: "добор напряжения",
              0x3: "финиш", 0x4: "заряжено", 0x8: "выключен"}
    print(f"питание в кабеле : {'есть' if ok & (1 << 6) else 'нет'}")
    print(f"состояние        : {states.get(det & 0xF, hex(det & 0xF))}")
    print(f"режим чипа       : 0x{mode:02x} ({'заряд' if mode == MODE_CHARGE else 'только питание'})")
    print(f"ток заряда       : ~{int(cur * 33.3)} мА")
    print(f"лимит из кабеля  : ~{lim * 20} мА")
    print(f"батарея          : {read_int(CAPACITY)}%  {read_int(VOLTAGE)} мкВ")


def run():
    load_conf()
    bus = I2C(SDA, SCL)
    log(f"chargectl запущен: стоп на {CFG['STOP']}%, старт на {CFG['START']}%")
    paused = False
    last = None
    while True:
        try:
            cap = read_int(CAPACITY)
            volt = read_int(VOLTAGE)
            ok = bus.read_reg(REG_INT_OK)
            plugged = ok is not None and bool(ok & (1 << 6))

            if cap is not None:
                if cap >= CFG["STOP"]:
                    paused = True
                elif cap <= CFG["START"]:
                    paused = False

            want = MODE_OFF if (paused or not plugged) else MODE_CHARGE
            mode = bus.read_reg(REG_MODE)

            if plugged and want == MODE_CHARGE:
                # чип сбрасывает настройки при переподключении кабеля
                if bus.read_reg(REG_CURRENT) != CFG["CURRENT"]:
                    bus.write_reg(REG_CURRENT, CFG["CURRENT"])
                if bus.read_reg(REG_INLIMIT) != CFG["INLIMIT"]:
                    bus.write_reg(REG_INLIMIT, CFG["INLIMIT"])

            if mode is not None and mode != want:
                bus.write_reg(REG_MODE, want)

            det = bus.read_reg(REG_DETAILS)
            state = (det & 0xF) if det is not None else -1
            now = (plugged, paused, state)
            if now != last:
                log(f"{cap}% {volt} кабель={'да' if plugged else 'нет'} "
                    f"состояние=0x{state:x} {'пауза(заряжено)' if paused else ''}")
                last = now
        except Exception as e:
            log(f"ошибка: {e}")
            try:
                bus = I2C(SDA, SCL)
            except Exception:
                pass
        time.sleep(CFG["INTERVAL"])


SERVICE = """[Unit]
Description=Charging control for max77804k (no kernel driver exists)
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/chargectl.py run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""


def install():
    src = os.path.abspath(__file__)
    dst = "/usr/local/bin/chargectl.py"
    if src != dst:
        with open(src) as a, open(dst, "w") as b:
            b.write(a.read())
        os.chmod(dst, 0o755)
    if not os.path.exists(CONF):
        with open(CONF, "w") as f:
            f.write("# настройки зарядки\n"
                    "STOP=95        # на этом проценте заряд выключается\n"
                    "START=85       # ниже этого включается снова\n"
                    "CURRENT=0x15   # ток заряда, ~700 мА (0x1e ~ 1000 мА)\n"
                    "INLIMIT=0x32   # лимит из кабеля, ~1000 мА\n"
                    "INTERVAL=15\n")
    with open("/etc/systemd/system/chargectl.service", "w") as f:
        f.write(SERVICE)
    os.system("systemctl daemon-reload && systemctl enable --now chargectl")
    print("готово. смотреть:  sudo python3 /usr/local/bin/chargectl.py status")
    print("настройки:         /etc/chargectl.conf")
    print("лог:               tail -f /var/log/battery.log")


def remove():
    os.system("systemctl disable --now chargectl 2>/dev/null")
    for p in ("/etc/systemd/system/chargectl.service",):
        if os.path.exists(p):
            os.remove(p)
    os.system("systemctl daemon-reload")
    print("служба убрана (заряд снова выключится при следующем переподключении кабеля)")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"install": install, "remove": remove, "run": run, "status": status}.get(cmd, status)()

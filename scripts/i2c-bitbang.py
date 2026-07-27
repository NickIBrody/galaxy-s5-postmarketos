#!/usr/bin/env python3
"""
I2C, реализованная руками на двух GPIO (bit-banging).

Зачем: на samsung-klte зарядные чипы (max77804k, smb1357) висят на
самодельных i2c-шинах, которых нет в mainline device tree. Драйвера нет,
шины нет — но сами ножки процессора доступны через /sys/class/gpio.
Этот скрипт дёргает их вручную и разговаривает с чипами напрямую.

Нумерация GPIO: номер из device tree + база gpiochip (на klte это 512).
  msmgpio 60/61  -> 572/573   (шина max77804k, адрес 0x66)
  msmgpio 87/88  -> 599/600   (шина smb1357 0x1c и топливомера 0x36)

Использование:
  sudo python3 i2c-bitbang.py 572 573 scan
  sudo python3 i2c-bitbang.py 599 600 scan
  sudo python3 i2c-bitbang.py 599 600 dump 0x1c 0x00 0x20
  sudo python3 i2c-bitbang.py 599 600 read 0x1c 0x31
  sudo python3 i2c-bitbang.py 599 600 write 0x1c 0x31 0x01
"""
import os
import sys
import time

SYS = "/sys/class/gpio"
DELAY = 5e-5  # полпериода такта; медленно, зато надёжно


class Pin:
    """Ножка с открытым стоком: тянем в ноль или отпускаем (подтяжка на плате)."""

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

    def close(self):
        try:
            self.release()
            self.dir_f.close()
            self.val_f.close()
            with open(f"{SYS}/unexport", "w") as f:
                f.write(str(self.num))
        except Exception:
            pass


class BitBangI2C:
    def __init__(self, sda, scl):
        self.sda = Pin(sda)
        self.scl = Pin(scl)
        self.sda.release()
        self.scl.release()

    def _wait_scl(self):
        # растягивание такта ведомым
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
        self._wait_scl()
        time.sleep(DELAY)
        self.sda.release()
        time.sleep(DELAY)

    def _write_bit(self, bit):
        if bit:
            self.sda.release()
        else:
            self.sda.low()
        time.sleep(DELAY)
        self.scl.release()
        self._wait_scl()
        time.sleep(DELAY)
        self.scl.low()

    def _read_bit(self):
        self.sda.release()
        time.sleep(DELAY)
        self.scl.release()
        self._wait_scl()
        v = self.sda.read()
        time.sleep(DELAY)
        self.scl.low()
        return v

    def write_byte(self, b):
        for i in range(7, -1, -1):
            self._write_bit((b >> i) & 1)
        return self._read_bit() == 0  # True = чип ответил ACK

    def read_byte(self, ack=True):
        v = 0
        for _ in range(8):
            v = (v << 1) | self._read_bit()
        self._write_bit(0 if ack else 1)
        return v

    def probe(self, addr):
        self.start()
        ok = self.write_byte(addr << 1)
        self.stop()
        return ok

    def read_reg(self, addr, reg):
        self.start()
        if not self.write_byte(addr << 1):
            self.stop()
            return None
        if not self.write_byte(reg):
            self.stop()
            return None
        self.start()
        if not self.write_byte((addr << 1) | 1):
            self.stop()
            return None
        v = self.read_byte(ack=False)
        self.stop()
        return v

    def write_reg(self, addr, reg, val):
        self.start()
        ok = self.write_byte(addr << 1) and self.write_byte(reg) and self.write_byte(val)
        self.stop()
        return ok

    def close(self):
        self.sda.close()
        self.scl.close()


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    sda, scl, cmd = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    bus = BitBangI2C(sda, scl)
    try:
        if cmd == "scan":
            found = [hex(a) for a in range(0x03, 0x78) if bus.probe(a)]
            print("найдено:", found if found else "ничего")
        elif cmd == "dump":
            addr = int(sys.argv[4], 0)
            first = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0
            count = int(sys.argv[6], 0) if len(sys.argv) > 6 else 0x20
            for r in range(first, first + count):
                v = bus.read_reg(addr, r)
                print(f"  0x{r:02x} = {'--' if v is None else '0x%02x' % v}")
        elif cmd == "read":
            addr, reg = int(sys.argv[4], 0), int(sys.argv[5], 0)
            v = bus.read_reg(addr, reg)
            print("нет ответа" if v is None else f"0x{v:02x}")
        elif cmd == "write":
            addr, reg, val = (int(sys.argv[i], 0) for i in (4, 5, 6))
            print("записано" if bus.write_reg(addr, reg, val) else "нет ответа")
        elif cmd == "poke":
            # записать и проследить, держится ли значение
            addr, reg, val = (int(sys.argv[i], 0) for i in (4, 5, 6))
            before = bus.read_reg(addr, reg)
            ok = bus.write_reg(addr, reg, val)
            now = bus.read_reg(addr, reg)
            print(f"было 0x{before:02x} -> записали 0x{val:02x} (ack={ok}) -> сразу 0x{now:02x}")
            for i in (1, 3, 5):
                time.sleep(i if i == 1 else 2)
                v = bus.read_reg(addr, reg)
                print(f"  через {i}с: 0x{v:02x}")
        else:
            print(__doc__)
    finally:
        bus.close()


if __name__ == "__main__":
    main()

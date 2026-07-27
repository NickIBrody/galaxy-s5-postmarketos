#!/usr/bin/env python3
"""
Прослойка для MTProto-прокси с маскировкой под TLS (секрет с префиксом ee).

Зачем: библиотека Telethon такие прокси не умеет — она отрезает от секрета
префикс и домен и стучится в обычном режиме, а сервер с fake-TLS на это
не отвечает вообще. Здесь fake-TLS реализован руками.

Как работает: слушает порт на 127.0.0.1, при подключении сам идёт к прокси,
притворяется браузером, который открывает https-сайт из секрета, проходит
рукопожатие и дальше просто перекладывает байты, заворачивая их в TLS-записи.
Для клиента это выглядит как обычный MTProto-прокси без всякого TLS.

Запуск:
  python3 mtproxy-tls.py                 — с вшитым прокси, порт 1443
  python3 mtproxy-tls.py --test          — только проверить рукопожатие и выйти
  python3 mtproxy-tls.py --proxy СЕРВЕР:ПОРТ:СЕКРЕТ --port 1443 -v

Потом клиент направляем на прослойку:
  TG_PROXY=127.0.0.1:1443:ee0ed5... python3 tg.py
"""
import argparse
import asyncio
import hmac
import os
import struct
import sys
import time
from hashlib import sha256

DEFAULT = ("194.87.126.47", 8443,
           "ee0ed5b8c525391d6e7647dd4acf38a08d7777772e6d6963726f736f66742e636f6d")

REC_HANDSHAKE = 0x16
REC_CHANGE_CIPHER = 0x14
REC_APP_DATA = 0x17
MAX_CHUNK = 16384 - 64

VERBOSE = False


def log(*a):
    if VERBOSE:
        print("[tls]", *a, file=sys.stderr, flush=True)


def parse_secret(raw):
    """Из ee<16 байт секрета><домен в hex> достаём секрет и домен."""
    if raw.startswith("ee") or raw.startswith("dd"):
        raw = raw[2:]
    secret = bytes.fromhex(raw[:32])
    domain = bytes.fromhex(raw[32:]).decode() if len(raw) > 32 else "www.microsoft.com"
    return secret, domain


def build_client_hello(secret, domain):
    """Собираем правдоподобный TLS 1.3 ClientHello с подписью секретом в поле random."""
    session_id = os.urandom(32)

    ciphers = bytes.fromhex(
        "1a1a130113021303c02bc02fc02cc030cca9cca8c013c014009c009d002f0035000a"
    )

    def ext(t, data):
        return struct.pack(">HH", t, len(data)) + data

    host = domain.encode()
    sni = ext(0x0000, struct.pack(">HBH", len(host) + 3, 0, len(host)) + host)
    ext_supported_groups = ext(0x000A, struct.pack(">H", 8) + bytes.fromhex("001d00170018001e"))
    ext_ec_points = ext(0x000B, b"\x01\x00")
    ext_sig_algs = ext(0x000D, struct.pack(">H", 18) + bytes.fromhex(
        "040308040401050308050501080606010201"))
    ext_supported_versions = ext(0x002B, b"\x04\x03\x04\x03\x03")
    ext_psk_modes = ext(0x002D, b"\x01\x01")
    ext_key_share = ext(0x0033, struct.pack(">H", 38) + struct.pack(">HH", 0x001D, 32) + os.urandom(32))
    ext_alpn = ext(0x0010, struct.pack(">H", 11) + b"\x08http/1.1\x02h2"[:11])
    ext_session_ticket = ext(0x0023, b"")
    ext_renegotiation = ext(0xFF01, b"\x00")
    ext_sct = ext(0x0012, b"")
    ext_status = ext(0x0005, b"\x01\x00\x00\x00\x00")

    exts = (sni + ext_renegotiation + ext_supported_groups + ext_ec_points +
            ext_session_ticket + ext_status + ext_sig_algs + ext_sct +
            ext_alpn + ext_psk_modes + ext_supported_versions + ext_key_share)

    def assemble(random32, padding_len):
        e = exts + ext(0x0015, b"\x00" * padding_len)  # padding
        body = (b"\x03\x03" + random32 + bytes([len(session_id)]) + session_id +
                struct.pack(">H", len(ciphers)) + ciphers +
                b"\x01\x00" + struct.pack(">H", len(e)) + e)
        handshake = b"\x01" + len(body).to_bytes(3, "big") + body
        return b"\x16\x03\x01" + struct.pack(">H", len(handshake)) + handshake

    # настоящие браузеры добивают ClientHello до 517 байт — повторим
    probe = assemble(b"\x00" * 32, 0)
    pad = max(0, 517 - len(probe) - 4)
    hello = assemble(b"\x00" * 32, pad)

    digest = hmac.new(secret, hello, sha256).digest()
    stamp = int(time.time())
    tail = bytes(a ^ b for a, b in zip(digest[28:32], struct.pack("<I", stamp)))
    random32 = digest[:28] + tail
    hello = assemble(random32, pad)
    log(f"ClientHello {len(hello)} байт, домен {domain}")
    return hello


async def read_exactly(reader, n):
    data = await reader.readexactly(n)
    return data


async def read_record(reader):
    head = await read_exactly(reader, 5)
    rtype = head[0]
    length = struct.unpack(">H", head[3:5])[0]
    body = await read_exactly(reader, length) if length else b""
    return rtype, body


async def handshake(host, port, secret, domain, timeout=15):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    writer.write(build_client_hello(secret, domain))
    await writer.drain()

    # ответ: ServerHello, смена шифра, и запись с данными
    for expect in (REC_HANDSHAKE, REC_CHANGE_CIPHER, REC_APP_DATA):
        rtype, body = await asyncio.wait_for(read_record(reader), timeout)
        log(f"получена запись 0x{rtype:02x}, {len(body)} байт")
        if rtype != expect:
            log(f"ожидалась 0x{expect:02x} — сервер отвечает не то")

    writer.write(b"\x14\x03\x03\x00\x01\x01")  # своя смена шифра
    await writer.drain()
    return reader, writer


async def pump_out(local_reader, remote_writer):
    """Наружу: заворачиваем в TLS-записи."""
    try:
        while True:
            data = await local_reader.read(MAX_CHUNK)
            if not data:
                break
            remote_writer.write(b"\x17\x03\x03" + struct.pack(">H", len(data)) + data)
            await remote_writer.drain()
    except Exception as e:
        log("наружу оборвалось:", e)
    finally:
        remote_writer.close()


async def pump_in(remote_reader, local_writer):
    """Внутрь: разбираем TLS-записи, отдаём только полезные данные."""
    try:
        while True:
            rtype, body = await read_record(remote_reader)
            if rtype == REC_APP_DATA:
                local_writer.write(body)
                await local_writer.drain()
            elif rtype == REC_CHANGE_CIPHER:
                continue
            else:
                log(f"неожиданная запись 0x{rtype:02x}")
    except Exception as e:
        log("внутрь оборвалось:", e)
    finally:
        local_writer.close()


def make_handler(host, port, secret, domain):
    async def handle(local_reader, local_writer):
        peer = local_writer.get_extra_info("peername")
        log("подключение от", peer)
        try:
            remote_reader, remote_writer = await handshake(host, port, secret, domain)
        except asyncio.IncompleteReadError:
            print("прокси оборвал соединение на рукопожатии — секрет не подошёл",
                  file=sys.stderr, flush=True)
            local_writer.close()
            return
        except Exception as e:
            print(f"не соединилось с прокси: {e}", file=sys.stderr, flush=True)
            local_writer.close()
            return
        log("рукопожатие прошло, включаю перекачку")
        await asyncio.gather(
            pump_out(local_reader, remote_writer),
            pump_in(remote_reader, local_writer),
        )
    return handle


async def main():
    global VERBOSE
    p = argparse.ArgumentParser()
    p.add_argument("--proxy", default=":".join(map(str, DEFAULT)))
    p.add_argument("--port", type=int, default=1443)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--test", action="store_true", help="проверить рукопожатие и выйти")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    VERBOSE = a.verbose or a.test

    host, port, raw = a.proxy.split(":", 2)
    secret, domain = parse_secret(raw)
    print(f"прокси {host}:{port}, маскировка под {domain}")

    if a.test:
        try:
            reader, writer = await handshake(host, int(port), secret, domain)
            print("РУКОПОЖАТИЕ ПРОШЛО — прокси нас принял")
            writer.close()
        except asyncio.IncompleteReadError:
            print("ПРОВАЛ: прокси закрыл соединение. Секрет не тот или это не fake-TLS.")
        except Exception as e:
            print(f"ПРОВАЛ: {e}")
        return

    server = await asyncio.start_server(
        make_handler(host, int(port), secret, domain), a.host, a.port)
    print(f"слушаю {a.host}:{a.port} — направляйте клиент сюда:")
    print(f"  TG_PROXY={a.host}:{a.port}:{raw[:34]} python3 tg.py")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

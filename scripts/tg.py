#!/usr/bin/env python3
"""
Минимальный терминальный Telegram для телефона без нормальной клавиатуры.

Почему не готовый клиент: под armv7 с musl графических клиентов нет,
а TUI-клиенты (tg, nchat) тянут за собой tdlib, который на этом железе
собирается часами и требует памяти больше, чем здесь есть.
Здесь всё на чистом питоне — ничего компилировать не нужно.

Прокси MTProto вшит: телефон ходит в Telegram через него всегда.

Первый запуск попросит номер телефона и код из SMS (или из другого Telegram).
Дальше вход сохраняется в файле сессии.

Команды:
  /l           список последних чатов
  /o НОМЕР     открыть чат из списка
  /h [N]       показать последние N сообщений (по умолчанию 20)
  /s ТЕКСТ     отправить, даже если текст начинается со слэша
  /r           отметить прочитанным
  /q           выход
  любой текст  отправить в открытый чат

Настройки в ~/.tg.conf:
  api_id = ...
  api_hash = ...
  proxy = server:port:secret     (необязательно, по умолчанию вшитый)
"""
import asyncio
import os
import sys

try:
    from telethon import TelegramClient, events, utils
    from telethon.network import ConnectionTcpMTProxyRandomizedIntermediate
except ImportError:
    sys.exit("Нет библиотеки telethon. Установка:\n"
             "  python3 -m venv ~/tg-venv && ~/tg-venv/bin/pip install telethon\n"
             "  ~/tg-venv/bin/python tg.py")

CONF = os.path.expanduser("~/.tg.conf")
SESSION = os.path.expanduser("~/.tg-session")

# Прокси по умолчанию. Меняется строкой proxy = ... в ~/.tg.conf
DEFAULT_PROXY = (
    "194.87.126.47",
    8443,
    "ee0ed5b8c525391d6e7647dd4acf38a08d7777772e6d6963726f736f66742e636f6d",
)


def load_conf():
    cfg = {}
    if os.path.exists(CONF):
        for line in open(CONF):
            line = line.split("#")[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    if "api_id" not in cfg or "api_hash" not in cfg:
        print("Нет ключей приложения. Заведите свои — это бесплатно и занимает три минуты:")
        print("  my.telegram.org -> API development tools -> любое название")
        print(f"Потом создайте {CONF} с двумя строками:")
        print("  api_id = 1234567")
        print("  api_hash = abcdef0123456789abcdef0123456789")
        print()
        print("Чужие api_id из открытых клиентов не берите: Telegram за это блокирует аккаунт.")
        sys.exit(1)
    return cfg


def get_proxy(cfg):
    """Возвращает (вид, параметры). Вид: 'mtproto', 'socks5' или None."""
    if os.environ.get("TG_NOPROXY"):
        return None, None
    raw = os.environ.get("TG_PROXY") or cfg.get("proxy")
    if not raw:
        return "mtproto", DEFAULT_PROXY
    parts = raw.split(":")
    if parts[0] in ("socks5", "socks4", "http"):
        # socks5:127.0.0.1:1080  — например, туннель от  ssh -N -D 1080 сервер
        return "socks5", (parts[0], parts[1], int(parts[2]))
    host, port, secret = raw.split(":", 2)
    return "mtproto", (host, int(port), secret)


class Chat:
    """Текущий открытый чат и список диалогов."""

    def __init__(self):
        self.dialogs = []
        self.current = None
        self.title = None


async def show_dialogs(client, state, limit=15):
    state.dialogs = []
    async for d in client.iter_dialogs(limit=limit):
        state.dialogs.append(d)
    for i, d in enumerate(state.dialogs, 1):
        unread = f" ({d.unread_count})" if d.unread_count else ""
        mark = "*" if state.current and d.id == state.current else " "
        print(f"{mark}{i:2}. {d.name}{unread}")


async def show_history(client, state, limit=20):
    if state.current is None:
        print("сначала откройте чат: /l потом /o НОМЕР")
        return
    msgs = []
    async for m in client.iter_messages(state.current, limit=limit):
        msgs.append(m)
    for m in reversed(msgs):
        who = "я" if m.out else (utils.get_display_name(m.sender) or "?")
        text = m.text or f"[{type(m.media).__name__ if m.media else 'пусто'}]"
        stamp = m.date.astimezone().strftime("%H:%M")
        print(f"{stamp} {who}: {text}")


async def repl(client, state):
    loop = asyncio.get_event_loop()
    print("готово. /l список чатов, /q выход")
    while True:
        try:
            line = await loop.run_in_executor(None, input, "> ")
        except (EOFError, KeyboardInterrupt):
            return
        line = line.strip()
        if not line:
            continue

        if line in ("/q", "/quit", "/exit"):
            return
        if line in ("/l", "/list"):
            await show_dialogs(client, state)
            continue
        if line.startswith("/o"):
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                print("нужен номер из списка: /o 3")
                continue
            n = int(parts[1])
            if not (1 <= n <= len(state.dialogs)):
                print("нет такого номера, сделайте /l")
                continue
            d = state.dialogs[n - 1]
            state.current, state.title = d.id, d.name
            print(f"--- открыт: {d.name} ---")
            await show_history(client, state, 10)
            continue
        if line.startswith("/h"):
            parts = line.split()
            n = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 20
            await show_history(client, state, n)
            continue
        if line == "/r":
            if state.current:
                await client.send_read_acknowledge(state.current)
                print("отмечено прочитанным")
            continue
        if line.startswith("/s "):
            line = line[3:]
        elif line.startswith("/"):
            print("неизвестная команда. /l /o /h /r /s /q")
            continue

        if state.current is None:
            print("сначала откройте чат: /l потом /o НОМЕР")
            continue
        try:
            await client.send_message(state.current, line)
        except Exception as e:
            print(f"не отправилось: {e}")


async def main():
    cfg = load_conf()
    kind, proxy = get_proxy(cfg)
    kwargs = {}
    if kind == "mtproto":
        kwargs = dict(connection=ConnectionTcpMTProxyRandomizedIntermediate, proxy=proxy)
        print(f"через MTProto-прокси {proxy[0]}:{proxy[1]}")
    elif kind == "socks5":
        kwargs = dict(proxy=proxy)
        print(f"через {proxy[0]} {proxy[1]}:{proxy[2]}")
    else:
        print("напрямую, без прокси")

    # без таймаута клиент молча висит вечно, если прокси не отвечает
    client = TelegramClient(
        SESSION, int(cfg["api_id"]), cfg["api_hash"],
        timeout=15, connection_retries=2, retry_delay=1, request_retries=2,
        **kwargs
    )
    print("подключаюсь...", flush=True)
    state = Chat()

    @client.on(events.NewMessage(incoming=True))
    async def on_new(event):
        who = utils.get_display_name(await event.get_sender()) or "?"
        chat = utils.get_display_name(await event.get_chat()) or "?"
        here = state.current is not None and event.chat_id == state.current
        prefix = "" if here else f"[{chat}] "
        print(f"\n{prefix}{who}: {event.raw_text}\n> ", end="", flush=True)

    try:
        await client.start()
    except Exception as e:
        print(f"не подключилось: {e}")
        print("Если дело в прокси, проверьте без него:  TG_NOPROXY=1 python3 tg.py")
        return

    me = await client.get_me()
    print(f"вошли как {utils.get_display_name(me)}")
    await show_dialogs(client, state)
    await repl(client, state)
    await client.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

#!/usr/bin/env python3
"""Rewrite only our Nginx virtual host's public HTTPS listener/redirect.
This is a configuration text transform; no network or system changes.
"""
import re
import sys
from pathlib import Path


def updated_config(source: str, previous_port: int, new_port: int) -> str:
    managed_new = "# Configured by WhatsApp Translator deploy.sh" in source
    managed_existing = "# WhatsApp Translator: отдельный сайт" in source
    if not (managed_new or managed_existing):
        raise ValueError("Это не конфигурация Nginx нашего приложения")
    if not 1 <= new_port <= 65535 or not 1 <= previous_port <= 65535:
        raise ValueError("Недопустимый HTTPS-порт")
    ssl_listener = re.compile(r"(?m)^([ \t]*listen[ \t]+)" + str(previous_port)
                              + r"([ \t]+ssl[ \t]*;)")
    result, found = ssl_listener.subn(lambda m: m[1] + str(new_port) + m[2],
                                      source, count=1)
    if found != 1:
        raise ValueError("Не найден ровно один TLS listener для исходного порта")
    redirect = re.compile(
        r"(return[ \t]+301[ \t]+https://\$host)(?::[0-9]+)?(\$request_uri;)"
    )
    suffix = "" if new_port == 443 else ":" + str(new_port)
    result, found = redirect.subn(lambda m: m[1] + suffix + m[2], result, count=1)
    if found != 1 and managed_new:
        raise ValueError("Не найден HTTP→HTTPS редирект виртуального хоста")
    # .vcf files up to 2 MB must be accepted by Nginx.
    result = result.replace("client_max_body_size 32k;", "client_max_body_size 3m;")
    return result


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Использование: change-nginx-port.py путь_к_vhost старый_порт новый_порт")
    filename = Path(sys.argv[1])
    old, new = int(sys.argv[2]), int(sys.argv[3])
    original = filename.read_text(encoding="utf-8")
    rewritten = updated_config(original, old, new)
    filename.write_text(rewritten, encoding="utf-8")

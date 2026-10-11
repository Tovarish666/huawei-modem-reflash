#!/bin/bash
# Подготовка Debian / Proxmox VE к перепрошивке модемов:
#   - пакеты (fastboot, adb, usb-modeswitch, сборка);
#   - утилиты forth32 (balong-usbdload, balongflash) в tools/;
#   - прошивки из релиза GitHub в <модель>/firmware/ со сверкой SHA-256.
# Повторный запуск безопасен: собранное и скачанное не трогается.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=Tovarish666/huawei-modem-reflash
FW_TAG=e3372h-firmware-v1

[ "$(id -u)" -eq 0 ] || { echo "Запустите от root"; exit 1; }

echo "=== Пакеты ==="
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  gcc make git zlib1g-dev fastboot adb usb-modeswitch curl python3

echo "=== Утилиты forth32 ==="
mkdir -p "$ROOT/tools"
for r in balong-usbdload balongflash; do
  [ -d "$ROOT/tools/$r" ] || git clone -q --depth 1 "https://github.com/forth32/$r.git" "$ROOT/tools/$r"
  make -s -C "$ROOT/tools/$r" 2>&1 | grep -iE "error" || true
done
[ -x "$ROOT/tools/balong-usbdload/balong-usbdload" ] || { echo "balong-usbdload не собрался"; exit 1; }
[ -x "$ROOT/tools/balongflash/balong_flash" ] || { echo "balong_flash не собрался"; exit 1; }

echo "=== Прошивки E3372h ==="
cd "$ROOT/e3372h/firmware"
while read -r sum name; do
  if [ -f "$name" ] && echo "$sum  $name" | sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "есть: $name"
    continue
  fi
  echo "скачиваю: $name"
  curl -fL --retry 3 -o "$name" "https://github.com/$REPO/releases/download/$FW_TAG/$name"
done < SHA256SUMS
sha256sum -c SHA256SUMS

echo
echo "Готово. Проверка без изменений модема: $ROOT/e3372h/reflash.sh --check"

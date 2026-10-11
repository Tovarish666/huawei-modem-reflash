#!/bin/bash
# Автоматическая перепрошивка Huawei E3372h-153 (Balong V7R11) на Linux по схеме "Игла 2.0":
#   аварийка -> балон -> аварийка -> GO x3 -> балон -> переходная прошивка -> итоговая прошивка
#
#   e3372h/reflash.sh [ключи] [итоговая.exe]       (от root; перед первым запуском - ./setup.sh)
#     --via FILE   переходная прошивка (по умолчанию #2 M_AT_05.10_nv; --via none - без неё)
#     --go N       сколько раз выполнить GO (по умолчанию 3)
#     --keep-bbt   GO без сброса таблицы бэдблоков (-f, ответ "1" в "Это GO.cmd")
#     --force-1443 модем вставлен сразу в аварийке (иглой): модель не проверить, под вашу ответственность
#     --check      только проверить файлы и показать режим модема
#
# Перед любым разрушающим шагом скрипт проверяет, что это E3372h-153 (плата CL2E3372HM):
# по веб-API, по AT^VERSION? или по AT^DLOADINFO? в режиме обновления. E3372s и другие - отказ.
#
# Модем лучше вставлять после запуска: тогда он приходит в стартовом режиме (1f01), и скрипт
# ведёт его через AT-порт, не завися от сети старой (возможно, убитой) прошивки:
#   AT-порт -> AT^GODLOAD -> предварительная прошивка итоговой (в ней есть ADB) -> через ADB
#   затирается загрузчик -> аварийка (1443) -> балон -> GO -> балон -> переходная -> итоговая.
# Если модем уже в HiLink и его сеть отвечает, ADB используется сразу, без предварительной прошивки.
# Если загрузчик уже повреждён, модем приходит в аварийку сам; иглой - с ключом --force-1443.
# В конце сверяет версию и IMEI через веб-API и пишет ГОТОВО или ОШИБКА.
set -u

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
MDIR=$ROOT/e3372h
FINAL=$MDIR/firmware/E3372h-153_Update_22.333.01.00.00_WEBUI_17.100.12.06.03_HILINK.exe
VIA=$MDIR/firmware/E3372h-153_Update_22.333.01.00.00_M_AT_05.10_nv.exe
GO_N=3; BBT=-b; CHECK=0; FORCE1443=0
while [ $# -gt 0 ]; do
  case $1 in
    --via)        VIA=$2; shift 2 ;;
    --go)         GO_N=$2; shift 2 ;;
    --keep-bbt)   BBT=-f; shift ;;
    --force-1443) FORCE1443=1; shift ;;
    --check)      CHECK=1; shift ;;
    -*)         echo "неизвестный ключ: $1"; exit 2 ;;
    *)          FINAL=$1; shift ;;
  esac
done
[ "$VIA" = none ] && VIA=""

UL=$ROOT/tools/balong-usbdload/balong-usbdload
BF=$ROOT/tools/balongflash/balong_flash
LOADER=$ROOT/tools/balong-usbdload/usblsafe-3372h.bin
PTABLE=$MDIR/ptable-hilink.bin
AT=$ROOT/lib/at.py
DHCP=$ROOT/lib/dhcp-probe.py
HW_OK="CL2E3372HM"
ERASE="m3boot fastboot nvimg nvdload oeminfo kernel kernelbk m3image dsp vxworks wbdata om app webui system userdata online cdromiso"
MSG_HILINK=55534243123456780000000000000011062000000101000100000000000000
MSG_DEBUG=55534243123456780000000000000011063000000100010000000000000000
MODEM_IP=192.168.8.1
HOST_IP=192.168.8.100
UDEV_OVERRIDE=/run/udev/rules.d/40-usb_modeswitch.rules
DEADLINE=$(( $(date +%s) + 2400 ))

mkdir -p "$ROOT/logs"
LOG=$ROOT/logs/e3372h-$(date +%Y%m%d-%H%M%S).log
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; N=$'\e[0m'

say()  { echo "$(date +%T) $*" | tee -a "$LOG"; }
fail() { say "${R}ОШИБКА: $*${N}"; say "Лог: $LOG"; exit 1; }
# adb kill-server зависает, если сервер держит подключение к уже вынутому модему
adb_reset() { timeout 5 adb kill-server >/dev/null 2>&1 || pkill -9 -x adb; }
cleanup() {
  rm -f "$UDEV_OVERRIDE"
  udevadm control --reload 2>/dev/null
  adb_reset
}
trap cleanup EXIT
trap 'fail "прервано"' INT TERM

# ---------- состояние USB ----------
usbdev() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = 12d1 ] && { basename "$d"; return; }
  done
}
mode() {
  local d; d=$(usbdev)
  [ -z "$d" ] && { echo none; return; }
  cat "/sys/bus/usb/devices/$d/idProduct" 2>/dev/null || echo none
}
devnum() { local d; d=$(usbdev); [ -n "$d" ] && cat "/sys/bus/usb/devices/$d/devnum" 2>/dev/null; }
desc() {
  case $1 in
    1443) echo "аварийка (BootROM)" ;;
    36dd) echo "fastboot загрузчика usblsafe" ;;
    1c05) echo "режим прошивки usblsafe" ;;
    1442) echo "AT-порт + накопитель (режим обновления или первая загрузка)" ;;
    155e|1506|1001) echo "отладочный режим (AT-порты)" ;;
    1f01) echo "стартовый режим (накопитель)" ;;
    14dc) echo "HiLink" ;;
    none) echo "модем не подключён" ;;
    *)    echo "неизвестный режим" ;;
  esac
}
# ждать режим $1 не дольше $2 секунд
wait_mode() { local i; for i in $(seq "$2"); do [ "$(mode)" = "$1" ] && return 0; sleep 1; done; return 1; }
# ждать переподключения модема (сменится номер устройства или модем пропадёт), не дольше $1 секунд
wait_reenum() { local n0 i; n0=$(devnum); for i in $(seq "$1"); do [ "$(devnum)" != "$n0" ] && return 0; sleep 1; done; return 1; }
# /dev/ttyUSB* для интерфейса $1 текущего модема, ждать до $2 секунд
wait_tty() {
  local i t
  for i in $(seq "$2"); do
    t=$(ls -d /sys/bus/usb/devices/"$(usbdev)":1."$1"/ttyUSB* 2>/dev/null | head -1)
    [ -n "$t" ] && { echo "/dev/$(basename "$t")"; return 0; }
    sleep 1
  done
  return 1
}
all_ttys() { ls -d /sys/bus/usb/devices/"$(usbdev)":1.*/ttyUSB* 2>/dev/null | xargs -rn1 basename | sed 's|^|/dev/|'; }
at_port() { local t; for t in $(all_ttys); do "$AT" "$t" ATI 2 2>/dev/null | grep -q OK && { echo "$t"; return 0; }; done; return 1; }
# порт режима обновления, готовый к новой сессии (после -k модем переподключается сам), ждать до $1 секунд
dload_ready() {
  local i t
  for i in $(seq $(( $1 / 3 ))); do
    t=$(wait_tty 0 3) && "$AT" "$t" "AT^DLOADINFO?" 2 2>/dev/null | grep -q "dload type:1" && { echo "$t"; return 0; }
    sleep 3
  done
  return 1
}
flash() {  # flash <tty> <файл> [ключи balong_flash]
  local tty=$1 f=$2 rc; shift 2
  say "  balong_flash -p $tty $* $(basename "$f")"
  timeout 900 "$BF" -p "$tty" "$@" "$f" >>"$LOG" 2>&1; rc=$?
  [ $rc -eq 0 ] || say "  код завершения: $rc"
  return $rc
}
xml() { echo "$2" | sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" | head -1; }

# ---------- HiLink / веб-API / ADB ----------
hilink_up() {  # hilink_up <сек на линк>; 0 - веб отвечает, 1 - нет интерфейса, 2 - нет линка, 3 - не отвечает веб
  local i ifc=""
  for i in $(seq 15); do ifc=$(ls /sys/bus/usb/devices/"$(usbdev)":1.0/net/ 2>/dev/null | head -1); [ -n "$ifc" ] && break; sleep 1; done
  [ -z "$ifc" ] && return 1
  ip link set "$ifc" up
  say "  жду сетевой линк от модема (до $1 с)..."
  for i in $(seq "$1"); do [ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)" = 1 ] && break; sleep 1; done
  [ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)" = 1 ] || return 2
  ip addr flush dev "$ifc"
  ip addr add "$HOST_IP/24" dev "$ifc"
  say "  линк есть, проверяю веб-интерфейс на $MODEM_IP (до 30 с)..."
  for i in $(seq 30); do curl -s -m 2 -o /dev/null http://$MODEM_IP/api/webserver/SesTokInfo && return 0; sleep 1; done
  # адрес веб-интерфейса бывает не 192.168.8.1 - узнаём через DHCP, маршрут по умолчанию не трогаем
  say "  на $MODEM_IP не отвечает, узнаю адрес модема по DHCP..."
  local p
  p=$("$DHCP" "$ifc" 2>/dev/null) || return 3
  set -- $p
  MODEM_IP=$1; HOST_IP=$2
  ip addr flush dev "$ifc"
  ip addr add "$HOST_IP/24" dev "$ifc"
  say "  модем на $MODEM_IP, жду веб-интерфейс (до 30 с)..."
  for i in $(seq 30); do curl -s -m 2 -o /dev/null http://$MODEM_IP/api/webserver/SesTokInfo && return 0; sleep 1; done
  return 3
}
hl_err() { case $1 in 1) echo "нет сетевого интерфейса" ;; 2) echo "нет сетевого линка" ;; *) echo "веб-интерфейс не отвечает" ;; esac; }
api() {  # api <путь> [xml для POST]
  local tok ses tk
  tok=$(curl -s -m 5 http://$MODEM_IP/api/webserver/SesTokInfo)
  ses=$(xml SesInfo "$tok"); tk=$(xml TokInfo "$tok")
  if [ -n "${2:-}" ]; then
    curl -s -m 10 -H "Cookie: $ses" -H "__RequestVerificationToken: $tk" -H "Content-Type: application/xml" -d "$2" "http://$MODEM_IP/api/$1"
  else
    curl -s -m 10 -H "Cookie: $ses" -H "__RequestVerificationToken: $tk" "http://$MODEM_IP/api/$1"
  fi
}
adb_ok() {
  adb_reset
  timeout 15 adb connect $MODEM_IP:5555 2>&1 | grep -q "^connected" || return 1
  [ "$(timeout 10 adb -s $MODEM_IP:5555 shell echo ok 2>/dev/null | tr -d '\r')" = ok ]
}
adb_wipe() {
  local A="timeout 60 adb -s $MODEM_IP:5555 shell" e0 e1 g0 g1
  say "Затираю загрузчик (m3boot, fastboot) через ADB - модем уйдёт в аварийку без иглы"
  # dd из канала читает короткими порциями, поэтому сначала готовим файл 0xFF в памяти модема
  $A 'T=/tmp; [ -d $T ] && [ -w $T ] || T=/online; busybox tr "\000" "\377" < /dev/zero | busybox head -c 786432 > $T/ff.bin; busybox dd if=$T/ff.bin of=/dev/block/mtdblock0 bs=131072 count=2; busybox dd if=$T/ff.bin of=/dev/block/mtdblock1 bs=131072 count=6; sync; busybox rm -f $T/ff.bin' >>"$LOG" 2>&1
  e0=$(head -c 262144 /dev/zero | tr '\0' '\377' | md5sum | cut -d' ' -f1)
  e1=$(head -c 786432 /dev/zero | tr '\0' '\377' | md5sum | cut -d' ' -f1)
  g0=$($A 'busybox md5sum /dev/block/mtdblock0' 2>/dev/null | cut -d' ' -f1)
  g1=$($A 'busybox md5sum /dev/block/mtdblock1' 2>/dev/null | cut -d' ' -f1)
  [ "$e0" = "$g0" ] && [ "$e1" = "$g1" ] || fail "проверка затирания загрузчика не совпала (m3boot $g0, fastboot $g1)"
  $A 'echo -e "AT^RESET\r" > /dev/appvcom1' >>"$LOG" 2>&1
  adb disconnect $MODEM_IP:5555 >/dev/null 2>&1
}

# ---------- проверка модели ----------
check_hw() {  # check_hw <HardwareVersion> <откуда узнали>
  [ -z "$1" ] && fail "не удалось узнать модель модема ($2)"
  echo "$1" | grep -q "$HW_OK" || fail "это не E3372h-153: плата $1 ($2). Загрузчик и прошивки скрипта только для E3372h-153 ($HW_OK)"
  [ $MODEL_OK -eq 0 ] && say "Модель: плата $1 ($2) - E3372h-153, подходит"
  MODEL_OK=1
}

# ---------- шаги ----------
fb_ready() {
  local i p
  wait_mode 36dd 30 || { say "загрузчик не перешёл в fastboot (36dd)"; return 1; }
  for i in $(seq 30); do fastboot devices 2>/dev/null | grep -q . && break; sleep 1; done
  p=$(timeout 30 fastboot getvar product 2>&1)
  echo "$p" | grep -q "product: balongv7r2" || { say "fastboot product: $p"; return 1; }
}
stage_1443() {
  local tty part bad
  [ $STEP -gt 0 ] && fail "после прошивки модем снова в аварийке - прошивка не загрузилась"
  if [ $MODEL_OK -eq 0 ]; then
    [ $FORCE1443 -eq 1 ] || fail "модем сразу в аварийке - модель не проверить. Если это точно E3372h-153, запустите с --force-1443"
    say "${Y}Модель в аварийке не проверить - продолжаю по --force-1443${N}"
    MODEL_OK=1
  fi
  N1443=$((N1443 + 1))
  [ $N1443 -gt $((GO_N + 4)) ] && fail "модем раз за разом возвращается в аварийку"
  tty=$(wait_tty 0 20) || fail "в аварийке не появился ttyUSB"
  if [ $BALON -eq 0 ]; then
    say "Балон: usblsafe -> fastboot, стираю загрузчик (дальше модем сам уходит в аварийку)"
    "$UL" -p "$tty" -f "$LOADER" >>"$LOG" 2>&1
    fb_ready || fail "балон не удался"
    for part in m3boot fastboot; do timeout 90 fastboot erase "$part" >>"$LOG" 2>&1 || fail "балон: не стёрся $part"; done
    BALON=1
  elif [ $GO_DONE -lt "$GO_N" ]; then
    GO_DONE=$((GO_DONE + 1))
    say "GO $GO_DONE/$GO_N ($BBT): usblsafe -> fastboot -> стирание разделов"
    "$UL" -p "$tty" $BBT -c -t "$PTABLE" -s4 -s14 -s16 "$LOADER" >>"$LOG" 2>&1
    fb_ready || fail "GO $GO_DONE не удался"
    bad=0
    for part in $ERASE; do timeout 90 fastboot erase "$part" >>"$LOG" 2>&1 || { bad=$((bad + 1)); say "  не стёрся $part"; }; done
    say "  стёрто, ошибок: $bad"
  else
    say "Балон: usblsafe в режиме прошивки"
    "$UL" -p "$tty" "$LOADER" >>"$LOG" 2>&1
    wait_mode 1c05 40 || fail "загрузчик не перешёл в режим прошивки (1c05)"
    return
  fi
  timeout 30 fastboot reboot >>"$LOG" 2>&1
  wait_reenum 30
}
stage_36dd() {  # fastboot без нашего участия (например, скрипт перезапущен посреди GO)
  timeout 30 fastboot reboot >>"$LOG" 2>&1
  wait_reenum 30
}
stage_1c05() {
  local tty
  tty=$(wait_tty 2 20) || fail "в режиме прошивки нет порта (интерфейс 2)"
  if [ -n "$VIA" ] && [ $STEP -eq 0 ]; then
    say "Переходная прошивка: $(basename "$VIA")"
    flash "$tty" "$VIA" -k || fail "переходная прошивка не записалась"
    STEP=1
    sleep 3
    # бывает, что модем несмотря на -k перезагружается в режим обновления (1442) - итоговую запишем там
    if [ "$(mode)" != 1c05 ] || ! tty=$(wait_tty 2 20); then
      say "Модем переподключился после переходной прошивки, итоговую запишу в следующем режиме"
      wait_reenum 30
      return
    fi
  fi
  say "Итоговая прошивка: $(basename "$FINAL")"
  flash "$tty" "$FINAL" || fail "итоговая прошивка не записалась"
  STEP=2
  say "Записано, модем перезагружается"
  wait_reenum 60
}
stage_ports() {  # 1442 / отладочный режим: модем отдал AT-порт
  local tty info t
  tty=$(wait_tty 0 15) || fail "в режиме $(mode) нет ttyUSB"
  info=$("$AT" "$tty" "AT^DLOADINFO?" 3 2>/dev/null | tr '\n' ' ')
  if echo "$info" | grep -q "dload type:1"; then
    echo "$info" | grep -q "product name:BV7R11HS" || fail "режим обновления: платформа не BV7R11HS (E3372h-153): $info"
    MODEL_OK=1
    NDLOAD=$((NDLOAD + 1))
    [ $NDLOAD -gt 3 ] && fail "модем снова и снова возвращается в режим обновления"
    say "Режим обновления загрузчика"
    if [ $STEP -eq 0 ] && [ $PRE -eq 0 ] && [ $BALON -eq 0 ]; then
      # до зачистки: сначала ставим итоговую прошивку - в ней точно есть ADB, через него потом
      # затрём загрузчик и пройдём балон и GO. От сети старой прошивки ничего не зависит.
      say "Предварительная прошивка (ради ADB): $(basename "$FINAL")"
      flash "$tty" "$FINAL" || fail "предварительная прошивка не записалась"
      PRE=1
      say "Записано, модем перезагружается"
      wait_reenum 60
      return
    fi
    if [ -n "$VIA" ] && [ $STEP -eq 0 ]; then
      say "Переходная прошивка: $(basename "$VIA")"
      flash "$tty" "$VIA" -k || fail "переходная прошивка не записалась"
      STEP=1
      tty=$(dload_ready 90) || fail "после переходной прошивки порт режима обновления не готов"
    fi
    say "Итоговая прошивка: $(basename "$FINAL")"
    flash "$tty" "$FINAL" || fail "итоговая прошивка не записалась"
    STEP=2
    say "Записано, модем перезагружается"
    wait_reenum 60
    return
  fi
  t=$(at_port) || fail "в режиме $(mode) не найден AT-порт"
  check_hw "$("$AT" "$t" "AT^VERSION?" 3 2>/dev/null | sed -n 's/.*EXTH:\([^ ]*\).*/\1/p' | head -1)" "AT^VERSION?"
  if [ $STEP -eq 0 ] && [ $PRE -eq 0 ] && [ $BALON -eq 0 ]; then
    say "AT^GODLOAD: перевожу в режим обновления"
    "$AT" "$t" "AT^GODLOAD" >>"$LOG" 2>&1
  else
    # 1442 с dload type:0 - первая загрузка после прошивки, из неё выводит только перезагрузка
    say "AT^RESET: перезагружаю модем"
    "$AT" "$t" "AT^RESET" >>"$LOG" 2>&1
  fi
  wait_reenum 60 || fail "модем не перезагрузился"
}
stage_1f01() {
  # до зачистки идём через AT-порт: он работает и тогда, когда сеть старой прошивки мертва
  if [ $STEP -eq 0 ] && [ $PRE -eq 0 ] && [ $BALON -eq 0 ] && [ $DBG_FAIL -eq 0 ]; then
    say "Перевожу в отладочный режим (AT-порты)"
    usb_modeswitch -v 12d1 -p 1f01 -M $MSG_DEBUG >>"$LOG" 2>&1
    wait_reenum 30 || { DBG_FAIL=1; say "${Y}в отладочный режим не переключился, пробую HiLink${N}"; }
    return
  fi
  say "Перевожу в HiLink"
  usb_modeswitch -v 12d1 -p 1f01 -M $MSG_HILINK >>"$LOG" 2>&1
  wait_reenum 30 || fail "модем не переключился из режима накопителя"
}
stage_14dc() {
  local rc i t=20
  # всерьёз ждём сеть только от свежей прошивки; на сеть старой не полагаемся
  { [ $STEP -eq 2 ] || [ $PRE -eq 1 ]; } && t=120
  hilink_up $t; rc=$?
  if [ $rc -ne 0 ]; then
    [ $STEP -eq 2 ] && fail "после прошивки HiLink не работает: $(hl_err $rc)"
    [ $PRE -eq 1 ] && fail "после предварительной прошивки HiLink не работает ($(hl_err $rc)) - без ADB в аварийку не попасть: вставьте модем с замкнутой бутовой точкой и запустите с --force-1443"
    say "${Y}Сеть старой прошивки не отвечает ($(hl_err $rc)). Выньте модем и вставьте снова - дальше скрипт пойдёт через AT-порт${N}"
    for i in $(seq 600); do [ "$(mode)" != 14dc ] && return; sleep 1; done
    fail "модем не переподключили за 10 минут"
  fi
  [ $STEP -eq 2 ] && finish
  check_hw "$(xml HardwareVersion "$(api device/information)")" "веб-API"
  if adb_ok; then
    adb_wipe
    wait_mode 1443 90 || fail "после затирания загрузчика модем не вошёл в аварийку - нужна игла"
    return
  fi
  [ $PRE -eq 1 ] && fail "в итоговой прошивке нет ADB - без иглы в аварийку не попасть (вставьте модем с иглой и запустите с --force-1443)"
  say "ADB нет - перезагружаю модем через веб-API, дальше через AT-порт"
  api device/control '<?xml version="1.0" encoding="UTF-8"?><request><Control>1</Control></request>' >>"$LOG" 2>&1
  wait_reenum 90 || fail "модем не перезагрузился по API - выньте и вставьте его"
}
finish() {
  local info sw web imei
  info=$(api device/information)
  sw=$(xml SoftwareVersion "$info"); web=$(xml WebUIVersion "$info"); imei=$(xml Imei "$info")
  say "Модем: $(xml DeviceName "$info") $(xml HardwareVersion "$info"), IMEI ${imei:-?}"
  say "  ПО $sw, WebUI $web"
  [ "$sw" = "$FWVER" ] || fail "на модеме ПО '$sw', а записывалось $FWVER"
  [ -n "$imei" ] || fail "IMEI пустой - NV не восстановились"
  echo "$imei" | grep -qE '^0+$' && fail "IMEI нулевой - данные NV не восстановились (вероятно, повреждены износом памяти)"
  [ -n "$WEBVER" ] && [ "$web" != "$WEBVER" ] && say "${Y}  WebUI $web не совпадает с ожидаемой $WEBVER${N}"
  say "${G}ГОТОВО${N} - модем прошит, веб-интерфейс http://$MODEM_IP"
  exit 0
}

# ---------- запуск ----------
[ "$(id -u)" -eq 0 ] || fail "нужен root"
for f in "$UL" "$BF" "$LOADER" "$PTABLE" "$AT" "$DHCP" "$FINAL" ${VIA:+"$VIA"}; do [ -e "$f" ] || fail "нет файла $f (сначала запустите $ROOT/setup.sh)"; done
for f in fastboot adb usb_modeswitch curl python3 udevadm; do command -v $f >/dev/null || fail "не установлена утилита $f"; done
for f in "$FINAL" ${VIA:+"$VIA"}; do
  "$BF" -m "$f" 2>&1 | grep -q "BV7R11HS" || fail "$(basename "$f"): прошивка не для платформы BV7R11HS (E3372h-153)"
done
FWVER=$("$BF" -m "$FINAL" 2>&1 | tr '\r' '\n' | sed -n 's/.*Версия прошивки: *\([0-9.]*[0-9]\).*/\1/p' | head -1)
WEBVER=$(basename "$FINAL" | sed -n 's/.*WEBUI_\([0-9.]*[0-9]\).*/\1/p')
say "Итоговая:   $(basename "$FINAL") (ПО $FWVER, WebUI ${WEBVER:-?})"
say "Переходная: $([ -n "$VIA" ] && basename "$VIA" || echo нет)"
say "GO: $GO_N раз, ключ $BBT"
modprobe option
echo "12d1 1443" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || true

if [ $CHECK -eq 1 ]; then
  M=$(mode); say "Модем сейчас: $M - $(desc "$M")"
  exit 0
fi

# usb_modeswitch из udev сам переключает 1f01 -> HiLink; на время работы скрипта режимы переключаем сами
mkdir -p /run/udev/rules.d
: > "$UDEV_OVERRIDE"
udevadm control --reload

BALON=0; GO_DONE=0; STEP=0; PRE=0; DBG_FAIL=0; N1443=0; NDLOAD=0; MODEL_OK=0; LAST=""
[ "$(mode)" = none ] && say "Вставьте модем в USB-порт сервера..."
while :; do
  [ "$(date +%s)" -gt $DEADLINE ] && fail "не уложились в 40 минут"
  M=$(mode)
  [ "$M" != "$LAST" ] && { say "Модем: $M - $(desc "$M")"; LAST=$M; }
  case $M in
    none) sleep 1 ;;
    1443) stage_1443 ;;
    36dd) stage_36dd ;;
    1c05) stage_1c05 ;;
    1442|155e|1506|1001) stage_ports ;;
    1f01) stage_1f01 ;;
    14dc) stage_14dc ;;
    *) fail "неизвестный режим 12d1:$M" ;;
  esac
done

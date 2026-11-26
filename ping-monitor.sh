#!/usr/bin/env bash
# ping-monitor v3.2. Linux, Bash >= 4.4, iputils-ping.
# root не требуется, если разрешён запуск ping.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'Ошибка: требуется Bash 4.4 или новее.\n' >&2
    exit 2
fi
set -uo pipefail
# Английская локаль для стабильного разбора ответов ping и чисел.
export LC_ALL=C
umask 077

# ── Настройки по умолчанию и параметры командной строки ───────────────
INTERVAL=1
TIMEOUT=1
SOURCE=''
LOG_FILE=''
SAMPLES=0
PROFILE=auto
STOP_GRACE_MS=1500
PAGE_MS=5000
PLAIN=0
COLOR=1
LIMIT=0
PAYLOAD=''
PMTU=''
REFRESH=0.500
STALE=''
QUEUE_SLOTS=128
DRAIN_MS=3000
MIN_IP_WIDTH=15
# Минимальная ширина столбцов; длинные значения расширяют таблицу.
COMPACT_WIDTHS=("$MIN_IP_WIDTH" 10 6)
FULL_WIDTHS=("$MIN_IP_WIDTH" 10 6 6 6 6 5 5 11 11 11 7 7 7 8 8 9 9 9)
ips=()
targets=()
declare -A seen=()

usage() {
    cat <<EOF
Мониторинг доступности узлов по ICMP, версия 3.2.
Использование: ${0##*/} [ПАРАМЕТРЫ] IP [IP ...]
               ${0##*/} [ПАРАМЕТРЫ] -f ФАЙЛ [IP ...]

  -f, --file ФАЙЛ       Читать IP из файла (пробелы, комментарии #, CRLF;
                        параметр можно указывать несколько раз)
  -i, --interval СЕК    Минимальный интервал между проверками каждого узла (1 с)
  -W, --timeout СЕК     Тайм-аут ожидания ответа ping (1 с)
  -I, --interface ИСТ   Исходный интерфейс, VRF или IP-адрес (ping -I)
  -s, --size БАЙТ       Размер полезной нагрузки ICMP (ping -s)
  -M, --pmtu РЕЖИМ      Режим Path MTU Discovery: do, dont, want, probe (ping -M)
      --refresh СЕК     Интервал обновления экрана (0.5 с; от 0.1 до 10)
  -l, --log ФАЙЛ        Дописывать события и итоговую статистику в TSV версии 3.2 (новый файл, 28 полей)
      --samples         Записывать каждую завершённую проверку (требует -l)
      --queue N         Максимум ожидающих записей на узел (128; 2–4096)
      --stale СЕК       Порог устаревания результата (автоматически по умолчанию)
      --compact         IP, статус, потери
      --standard        Основные показатели: потери, RTT, сбои, ошибки
      --extended        Дополнительно длительность сбоев и доступность
      --full            Все показатели (широкий терминал)
      --auto            Автоматический профиль по ширине терминала (по умолчанию)
                        При нехватке ширины профиль понижается; страницы сменяются каждые 5 с.
                        Итоговый отчёт всегда полный.
      --plain           Выводить таблицы последовательно, без перерисовки экрана
      --no-color        Отключить цвета ANSI
  -n, --count N         Завершить после N проверок каждого узла (включая ошибки)
  -h, --help            Показать эту справку

Интервал и тайм-аут: от 0.1 до 3600 секунд, до трёх знаков после точки.
Цели: числовые IPv4/IPv6, включая зону IPv6; DNS-имена не поддерживаются.
Неопределённые, multicast и ограниченный broadcast адреса исключены.
Каждый узел проверяется независимо; проверки одного узла не перекрываются.
Фактический интервал может быть больше заданного из-за тайм-аута и нагрузки.
ПОТЕРИ: завершённые проверки без ответа (rc=1, счётчик отправки ping;
явные локальные ошибки отправки исключаются).
ОШИБ.: ошибки ping; не включаются в процент потерь и доступности.
ДОСТ.%: доля успешных проверок среди учтённых отправок, не SLA по времени.
СБОИ: число последовательностей DOWN; ERROR завершает текущую последовательность.
Время сбоя: от начала первой неуспешной проверки до завершения проверки UP
или ERROR; текущий сбой продолжается до момента наблюдения/остановки.
При -n наблюдение отдельного узла заканчивается последней завершённой пробой.
RTT MIN/AVG/MAX: по числовым RTT успешных проверок; значения вида time<1
отображаются в текущем RTT, но исключаются из агрегатов.
RTT ОШИБ.: успешные ответы, из которых не удалось извлечь RTT; не потери.
RTT MDEV: приближённое стандартное отклонение числовых RTT (мс).
ПЕРИОД: интервал между началами двух последних проб; ДАВН.: возраст результата.
УСТАРЕЛО: нет свежего результата или воркер завершился аварийно; не равно DOWN.
При -n штатно завершённые узлы не считаются устаревшими.
Автопорог: максимум из 3 × max(интервал, тайм-аут) и абсолютного
лимита ping плюс два интервала экрана. При STALE текущая оценка сбоя
на экране ограничивается последней завершённой пробой; это не SLA.
Журнал пишет отдельный процесс; STATE и SAMPLE — разные записи одной проверки.
При заполнении очереди новые записи отбрасываются с явным счётчиком; завершение
ожидает опустошения очереди до 3 с при задержках блокировки. Порядок записей
разных узлов может отличаться от хронологического; сортируйте по меткам проб.
Ctrl+C — ограниченное ожидание остановки и полный итоговый отчёт. Для полного режима нужен широкий терминал.
Проверки выполняются отдельными процессами ping с внешним watchdog (GNU timeout).
Для больших списков проверьте фактический ПЕРИОД: ориентир 1–10 узлов 0.1–0.2 с,
30–50 узлов 0.5 с, 50–100 узлов 0.5–1 с, свыше 100 — от 1 с.
Это рекомендации, не гарантированные пределы. UTF-8 необходим для экрана.
Зависимости: Bash 4.4+, iputils-ping, GNU coreutils (включая timeout, stty), flock (для журнала).

Примеры:
  ${0##*/} 192.0.2.1 192.0.2.10
  ${0##*/} -f hosts.txt -i 0.2 -W 0.2
  ${0##*/} -I bond5 -f hosts.txt -l network-v3.2.tsv --samples
  ${0##*/} -I bond5 -s 8972 -M do -f hosts.txt
EOF
}
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 2; }
need_arg() { (( $# >= 2 )) && [[ -n $2 ]] || fail "Не задано значение параметра $1"; }
# Нормализуем секунды без восьмеричной интерпретации и внешних утилит.
seconds() {
    local raw=$1 whole frac ms
    [[ $raw =~ ^([0-9]{1,4})(\.([0-9]{1,3}))?$ ]] || return 1
    whole=${BASH_REMATCH[1]}; frac=${BASH_REMATCH[3]}000
    ms=$(( 10#$whole * 1000 + 10#${frac:0:3} ))
    (( ms >= 100 && ms <= 3600000 )) || return 1
    printf '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"
}
read_file() {
    local line
    local -a fields=()
    [[ -f $1 && -r $1 ]] || fail "Не удалось прочитать файл адресов: $1"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line%$'\r'}
        IFS=$' \t' read -r -a fields <<< "$line"
        ips+=("${fields[@]}")
    done < "$1" || fail "Не удалось прочитать файл адресов: $1"
}
while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -f|--file) need_arg "$@"; read_file "$2"; shift 2 ;;
        -i|--interval) need_arg "$@"; INTERVAL=$(seconds "$2") || fail "Недопустимый интервал: $2"; shift 2 ;;
        -W|--timeout) need_arg "$@"; TIMEOUT=$(seconds "$2") || fail "Недопустимый тайм-аут: $2"; shift 2 ;;
        -I|--interface) need_arg "$@"; SOURCE=$2; shift 2 ;;
        -s|--size) need_arg "$@"; [[ $2 =~ ^[0-9]{1,5}$ ]] && (( 10#$2 <= 65507 )) || fail "Недопустимый размер полезной нагрузки: $2"; PAYLOAD=$((10#$2)); shift 2 ;;
        -M|--pmtu) need_arg "$@"; case $2 in do|dont|want|probe) PMTU=$2;; *) fail "Недопустимый режим PMTU: $2";; esac; shift 2 ;;
        --refresh) need_arg "$@"; REFRESH=$(seconds "$2") || fail "Недопустимый интервал экрана: $2"; (( ${REFRESH%.*} < 10 || ( ${REFRESH%.*} == 10 && 10#${REFRESH#*.} == 0 ) )) || fail 'Интервал экрана не более 10 секунд'; shift 2 ;;
        -l|--log) need_arg "$@"; LOG_FILE=$2; shift 2 ;;
        -n|--count) need_arg "$@"; [[ $2 =~ ^[0-9]{1,9}$ ]] && (( 10#$2 > 0 )) || fail "Недопустимое число проверок: $2"; LIMIT=$((10#$2)); shift 2 ;;
        --samples) SAMPLES=1; shift ;;
        --queue) need_arg "$@"; [[ $2 =~ ^[0-9]{1,4}$ ]] && (( 10#$2 >= 2 && 10#$2 <= 4096 )) || fail 'Размер очереди: 2–4096'; QUEUE_SLOTS=$((10#$2)); shift 2 ;;
        --stale) need_arg "$@"; STALE=$(seconds "$2") || fail "Недопустимый порог устаревания: $2"; shift 2 ;;
        --compact) PROFILE=compact; shift ;;
        --standard) PROFILE=standard; shift ;;
        --extended) PROFILE=extended; shift ;;
        --full) PROFILE=full; shift ;;
        --auto) PROFILE=auto; shift ;;
        --plain) PLAIN=1; shift ;;
        --no-color) COLOR=0; shift ;;
        --) shift; ips+=("$@"); break ;;
        -*) fail "Неизвестный параметр: $1" ;;
        *) ips+=("$1"); shift ;;
    esac
done
(( ${#ips[@]} > 0 )) || { usage >&2; exit 2; }
[[ $LOG_FILE != *[[:cntrl:]]* ]] || fail 'Недопустимые управляющие символы в имени журнала'
(( ! SAMPLES )) || [[ -n $LOG_FILE ]] || fail 'Параметр --samples требует --log'
[[ $SOURCE != -* && $SOURCE != *[[:space:][:cntrl:]]* ]] || fail 'Недопустимый исходный интерфейс или адрес'
for cmd in ping sleep mktemp rm mv timeout cat; do command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда: $cmd"; done
[[ -r /proc/uptime ]] || fail 'Необходим доступ к /proc/uptime'

# ── Валидация и идентификация целей ───────────────────────────────────
valid_v4() {
    local a b c d oct
    [[ $1 =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for oct in "$a" "$b" "$c" "$d"; do (( 10#$oct <= 255 )) || return 1; done
}
# Проверяем число групп IPv6, сокращённую запись и встроенный IPv4; без DNS.
valid_v6() {
    local addr=$1 left right tail part groups=0 compressed=0
    local -a pieces=()
    if [[ $addr == *%* ]]; then
        [[ ${addr#*%} =~ ^[a-zA-Z0-9_.@-]+$ ]] || return 1
        addr=${addr%%%*}
    fi
    [[ $addr == *:* && $addr =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    if [[ $addr == *.* ]]; then
        tail=${addr##*:}; valid_v4 "$tail" || return 1
        addr=${addr%:*}:0:0
    fi
    if [[ $addr == *::* ]]; then
        compressed=1; left=${addr%%::*}; right=${addr#*::}
    else
        left=$addr; right=''
    fi
    for part in "$left" "$right"; do
        [[ -n $part ]] || continue
        [[ $part != :* && $part != *: && $part != *::* ]] || return 1
        IFS=: read -r -a pieces <<< "$part"
        for tail in "${pieces[@]}"; do
            [[ $tail =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
            groups=$((groups + 1))
        done
    done
    if (( compressed )); then (( groups < 8 )); else (( groups == 8 )); fi
}
# Канонический ключ IPv6: восемь групп без ведущих нулей; зона без изменения регистра.
# Для отображения сохраняем первый введённый вариант адреса.
canonical_v6() {
    local a=${1%%%*} zone='' left right part oct1 oct2 oct3 oct4 h1 h2 x zeros
    local -a l=() r=() groups=()
    [[ $1 != *%* ]] || zone=%${1#*%}
    if [[ $a == *.* ]]; then
        IFS=. read -r oct1 oct2 oct3 oct4 <<< "${a##*:}"
        printf -v h1 '%x' "$((10#$oct1*256+10#$oct2))"
        printf -v h2 '%x' "$((10#$oct3*256+10#$oct4))"
        a=${a%:*}:$h1:$h2
    fi
    if [[ $a == *::* ]]; then
        left=${a%%::*}; right=${a#*::}
        [[ -z $left ]] || IFS=: read -r -a l <<< "$left"
        [[ -z $right ]] || IFS=: read -r -a r <<< "$right"
        zeros=$((8-${#l[@]}-${#r[@]})); groups=("${l[@]}")
        for ((x=0; x<zeros; x++)); do groups+=(0); done
        groups+=("${r[@]}")
    else IFS=: read -r -a groups <<< "$a"; fi
    KEY=''
    for part in "${groups[@]}"; do
        printf -v part '%x' "$((16#$part))"
        KEY+=${KEY:+:}$part
    done
    KEY+=$zone
}
for ip in "${ips[@]}"; do
    if ! valid_v4 "$ip" && ! valid_v6 "$ip"; then fail "Некорректный IP-адрес: $(printf '%q' "$ip")"; fi
    # Неопределённый адрес, multicast и ограниченный broadcast не являются отдельными узлами.
    addr=${ip%%%*}
    if [[ $addr == *:* ]]; then
        addr=${addr,,}
        [[ $addr != *:0.0.0.0 ]] || addr=${addr%:*}:0:0
        [[ ! $addr =~ ^[0:]+$ && $addr != ff* ]] || fail "Неадресуемая индивидуальная цель: $ip"
    else
        first=${addr%%.*}
        [[ $addr != 0.0.0.0 && $addr != 255.255.255.255 ]] && (( first < 224 || first > 239 )) || fail "Неадресуемая индивидуальная цель: $ip"
    fi
    KEY=$ip
    if [[ $addr == *:* ]]; then canonical_v6 "$ip"; fi
    [[ ${seen[$KEY]+yes} ]] && continue
    seen[$KEY]=1; targets+=("$ip")
done

# ── Часы, преобразования и предварительные проверки ───────────────────
# /proc/uptime использует время с момента загрузки (включая suspend), не часы NTP.
# В Linux точность опубликованного значения обычно 10 мс.
mono_ms() {
    local up whole frac
    read -r up _ < /proc/uptime || return 1
    [[ $up =~ ^([0-9]+)\.([0-9]+)$ ]] || return 1
    whole=${BASH_REMATCH[1]}; frac=${BASH_REMATCH[2]}000
    NOW=$((10#$whole * 1000 + 10#${frac:0:3}))
}
# Преобразуем уже нормализованные секунды в миллисекунды, без float/awk.
sec_ms() {
    local raw=$1
    MS=$((10#${raw%.*} * 1000 + 10#${raw#*.}))
}
# Доли секунды сохраняются при любой продолжительности, дни не смешиваются с часами.
format_duration() {
    local ms=$1 s days
    (( ms >= 0 )) || ms=0
    s=$((ms/1000)); days=$((s/86400))
    if (( days )); then
        printf -v DURATION '%dд %02d:%02d:%02d.%02d' "$days" "$((s/3600%24))" "$((s/60%60))" "$((s%60))" "$((ms%1000/10))"
    elif (( s >= 60 )); then
        printf -v DURATION '%02d:%02d:%02d.%02d' "$((s/3600))" "$((s/60%60))" "$((s%60))" "$((ms%1000/10))"
    else
        printf -v DURATION '%d.%02d с' "$s" "$((ms%1000/10))"
    fi
}
format_rtt() { printf -v RTT_FMT '%d.%03d' "$(($1/1000))" "$(($1%1000))"; }
# Точные числовые RTT храним в целых микросекундах. time<... не является точным RTT.
rtt_to_us() {
    local value=$1 whole frac
    [[ $value =~ ^([0-9]{1,9})(\.([0-9]+))?$ ]] || return 1
    whole=${BASH_REMATCH[1]}; frac=${BASH_REMATCH[3]}0000
    RTT_US=$((10#$whole * 1000 + 10#${frac:0:3} + (10#${frac:3:1} >= 5)))
}
sec_ms "$(seconds "$INTERVAL")"; INTERVAL_MS=$MS
sec_ms "$(seconds "$TIMEOUT")"; TIMEOUT_MS=$MS
# Внешний watchdog: -c 1 совместно с -w в iputils может отправлять несколько пакетов.
# Запас 1 с для запуска/локальной обработки, затем TERM и KILL через 0.2 с.
DEADLINE=$(((TIMEOUT_MS+999)/1000+1))
sec_ms "$(seconds "$REFRESH")"; REFRESH_MS=$MS
if [[ -n $STALE ]]; then sec_ms "$STALE"; STALE_MS=$MS
else
    STALE_MS=$((3*(INTERVAL_MS > TIMEOUT_MS ? INTERVAL_MS : TIMEOUT_MS)))
    (( STALE_MS >= DEADLINE*1000+200+2*REFRESH_MS )) || STALE_MS=$((DEADLINE*1000+200+2*REFRESH_MS))
fi
# Проверяем только локальную среду, не отправляя обязательный тестовый пакет.
PING_VERSION=$(ping -V 2>&1) || fail 'Не удалось определить версию ping'
[[ $PING_VERSION == *iputils* ]] || fail 'Требуется ping из iputils'
preflight=()
rate=$(( (${#targets[@]}*1000+INTERVAL_MS-1)/INTERVAL_MS ))
if (( rate >= 200 || ${#targets[@]} >= 100 )); then
    preflight+=("Высокая расчётная нагрузка: ${#targets[@]} узлов, до $rate проб/с. Контролируйте фактический период.")
fi
if [[ -n $PMTU ]]; then
    PING_HELP=$(ping -h 2>&1) || :
    if [[ $PING_HELP != *"-M"* || $PING_HELP != *"$PMTU"* ]]; then
        preflight+=("Режим PMTU $PMTU не найден в справке ping; проверяем при запуске проб.")
    fi
fi
if [[ -n $SOURCE ]] && ! valid_v4 "$SOURCE" && ! valid_v6 "$SOURCE"; then
    if [[ $SOURCE == */* || ! -d /sys/class/net/$SOURCE ]]; then
        preflight+=("Интерфейс $SOURCE сейчас отсутствует; возможны ошибки ping.")
    elif [[ -n $PAYLOAD ]] && read -r mtu < "/sys/class/net/$SOURCE/mtu" && [[ $mtu =~ ^[0-9]+$ ]]; then
        for ip in "${targets[@]}"; do
            overhead=28; [[ $ip != *:* ]] || overhead=48
            if (( PAYLOAD+overhead > mtu )); then
                preflight+=("Размер IP-пакета превышает MTU $SOURCE ($mtu); проверьте PMTU."); break
            fi
        done
    fi
fi
[[ -t 1 && ${TERM:-dumb} != dumb ]] || PLAIN=1
tty_fd=''
if (( ! PLAIN )); then
    command -v stty >/dev/null 2>&1 || PLAIN=1
    if (( ! PLAIN )); then
        # stdout — терминал, даже если stdin перенаправлен.
        stty size <&1 >/dev/null 2>&1 && exec {tty_fd}>&1 || PLAIN=1
    fi
fi
(( ! PLAIN )) || COLOR=0
GREEN='' RED='' YELLOW='' ORANGE='' RESET=''
if (( COLOR )); then GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; ORANGE=$'\033[38;5;208m'; RESET=$'\033[0m'; fi

# ── Состояние узлов и производные показатели ──────────────────────────
# У каждого фонового процесса своя копия счётчиков. Главный процесс получает
# целостные снимки через атомарный rename; пропущенный кадр экрана не теряет статистику.
declare -a attempts=() sent=() lost=() errors=() state=() rtt=() rtt_count=() rtt_sum=() rtt_min=() rtt_max=()
declare -a outages=() down_start=() total_closed=() max_closed=() last_down=() probe_start=() probe_end=() detail=() worker_log_failed=() workers=() rtt_sq=() period_ms=() dropped=() worker_dead=() rtt_parse_errors=()
for i in "${!targets[@]}"; do
    attempts[i]=0; sent[i]=0; lost[i]=0; errors[i]=0; state[i]=WAIT; rtt[i]='-'
    rtt_count[i]=0; rtt_sum[i]=0; rtt_min[i]=0; rtt_max[i]=0
    outages[i]=0; down_start[i]=-1; total_closed[i]=0; max_closed[i]=0; last_down[i]=-1
    probe_start[i]=-1; probe_end[i]=-1; detail[i]='-'; worker_log_failed[i]=0
    rtt_sq[i]=0; period_ms[i]=-1; dropped[i]=0; worker_dead[i]=0; rtt_parse_errors[i]=0
done
# Целочисленный квадратный корень; не используем внешние процессы на каждую пробу.
isqrt() {
    local n=$1 a b
    if (( n <= 0 )); then ROOT=0; return; fi
    a=$n; b=$((a/2+a%2))
    while (( b < a )); do a=$b; b=$(((a+n/a)/2)); done
    ROOT=$a
}
# Производные величины на момент at. Открытый сбой учитывается ровно один раз.
metrics() {
    local idx=$1 at=$2 p q rem n var
    CURRENT=0; TOTAL=${total_closed[idx]}; LONGEST=${max_closed[idx]}
    if (( down_start[idx] >= 0 )); then
        CURRENT=$((at-down_start[idx])); (( CURRENT >= 0 )) || CURRENT=0
        TOTAL=$((TOTAL+CURRENT)); (( CURRENT <= LONGEST )) || LONGEST=$CURRENT
    fi
    LOSS_PCT=-; AVAIL_PCT=-; MIN_RTT=-; AVG_RTT=-; MAX_RTT=-; MDEV_RTT=-
    if (( sent[idx] )); then
        p=$(((lost[idx]*1000+sent[idx]/2)/sent[idx]))
        printf -v LOSS_PCT '%d.%d' "$((p/10))" "$((p%10))"
        p=$((((sent[idx]-lost[idx])*1000+sent[idx]/2)/sent[idx]))
        printf -v AVAIL_PCT '%d.%d' "$((p/10))" "$((p%10))"
    fi
    if (( rtt_count[idx] )); then
        format_rtt "${rtt_min[idx]}"; MIN_RTT=$RTT_FMT
        format_rtt "$(((rtt_sum[idx]+rtt_count[idx]/2)/rtt_count[idx]))"; AVG_RTT=$RTT_FMT
        format_rtt "${rtt_max[idx]}"; MAX_RTT=$RTT_FMT
        # E[x²] - E[x]²; защищаем накопитель квадратов и промежуточные произведения.
        n=${rtt_count[idx]}
        if (( rtt_sq[idx] >= 0 && n <= 1000000000 )); then
            q=$((rtt_sum[idx]/n)); rem=$((rtt_sum[idx]%n))
            var=$((rtt_sq[idx]/n-q*q-(2*q*rem)/n-(rem*rem/n)/n))
            isqrt "$var"; format_rtt "$ROOT"; MDEV_RTT=$RTT_FMT
        fi
    fi
}

# ── Асинхронный журнал и ограниченные очереди ──────────────────────────
log_fd=''; log_failed=0; tmp=''; queue_seq=0; queue_drop=0; logger_pid=''; logger_pending=0; logger_bad=0; screen=0; started=0; stop_requested=0; stop_ms=-1; shutdown_incomplete=0
session="$(printf '%(%Y%m%dT%H%M%S)T' -1)-$$"
# Первые 13 полей совместимы по расположению с v2. Новые поля добавлены в конец.
# Старый заголовок не дополняем молча: иначе журнал содержал бы строки разной длины.
LOG_HEADER=$'timestamp\tsession\tevent\tip\tprevious\tstatus\tsent\tlost\terrors\trtt_ms\tdown_ms\tmax_down_ms\tdetail\tattempts\toutages\ttotal_down_ms\tlast_down_ms\trtt_count\trtt_min_ms\trtt_avg_ms\trtt_max_ms\tavailability_pct\tprobe_start_elapsed_ms\tprobe_end_elapsed_ms\trtt_mdev_ms\tperiod_ms\tlog_dropped\trtt_parse_errors'
# Каждый производитель владеет собственной кольцевой очередью файлов.
# Публикация rename атомарна; при занятом слоте НЕ ждём logger и не перезаписываем запись.
# Родительская очередь вмещает START, FINAL всех целей и STOP.
queue_line() {
    local owner=$1 line=$2 cap=$QUEUE_SLOTS slot path
    [[ $owner != p ]] || cap=$((${#targets[@]}+2))
    slot=$((queue_seq%cap)); path=$tmp/q.$owner.$slot
    if [[ -e $path || -e $tmp/logger.failed ]]; then queue_drop=$((queue_drop+1)); return 0; fi
    if printf '%s\n' "$line" > "$tmp/q.$owner.new" && mv -f -- "$tmp/q.$owner.new" "$path"; then
        queue_seq=$((queue_seq+1))
    else
        queue_drop=$((queue_drop+1)); log_failed=1
    fi
}
# Календарные метки не используются для длительности. Bash 5: без fork date.
wall_stamp() {
    local t sec frac base
    if (( BASH_VERSINFO[0] >= 5 )); then
        t=$EPOCHREALTIME; sec=${t%.*}; frac=${t#*.}000
        printf -v base '%(%Y-%m-%dT%H:%M:%S %z)T' "$sec"
        STAMP=${base% *}.${frac:0:3}${base##* }
    else
        STAMP=$(date '+%Y-%m-%dT%H:%M:%S.%3N%z') || return 1
    fi
}
# Только logger обращается к общему журналу после запуска воркеров.
log_event() {
    [[ -n $LOG_FILE ]] || return 0
    local event=$1 idx=$2 previous=$3 current=$4 msg=$5 at=$6 stamp=${7:-} owner=p line mdev=- period=- drops=- parse_errors=-
    local host=- good=- missing=- err=- latency=- outage=- longest=- n=- count=- total=- last=- nrtt=- min=- avg=- max=- avail=- ps=- pe=-
    if [[ $idx != - ]]; then
        metrics "$idx" "$at"
        host=${targets[idx]}; good=${sent[idx]}; missing=${lost[idx]}; err=${errors[idx]}; latency=${rtt[idx]}
        outage=$CURRENT; longest=$LONGEST; n=${attempts[idx]}; count=${outages[idx]}; total=$TOTAL
        if (( last_down[idx] >= 0 )); then last=${last_down[idx]}; fi
        nrtt=${rtt_count[idx]}; min=$MIN_RTT; avg=$AVG_RTT; max=$MAX_RTT; avail=$AVAIL_PCT; mdev=$MDEV_RTT
        if (( period_ms[idx] >= 0 )); then period=${period_ms[idx]}; fi
        drops=${dropped[idx]}; parse_errors=${rtt_parse_errors[idx]}
        case $event in STATE|SAMPLE|RTT_PARSE) owner=$idx;; esac
        if (( probe_start[idx] >= 0 )); then ps=$((probe_start[idx]-start_ms)); pe=$((probe_end[idx]-start_ms)); fi
    fi
    if [[ -z $stamp ]]; then wall_stamp || { STAMP=-; log_failed=1; }; stamp=$STAMP; fi
    msg=${msg//$'\n'/; }; msg=${msg//[[:cntrl:]]/ }
    printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$stamp" "$session" "$event" "$host" "$previous" "$current" "$good" "$missing" "$err" "$latency" "$outage" "$longest" "$msg" "$n" "$count" "$total" "$last" "$nrtt" "$min" "$avg" "$max" "$avail" "$ps" "$pe" "$mdev" "$period" "$drops" "$parse_errors"
    queue_line "$owner" "$line"
}
# Один потребитель. Не держим блокировку в воркерах; за проход ограничиваем пакет.
logger() {
    set +m
    trap - EXIT
    trap 'exit 143' TERM HUP
    trap '' INT
    local owner cap slot path line j deadline=-1 busy work
    local -A head=([p]=0)
    for owner in "${!targets[@]}"; do head[$owner]=0; done
    local -a owners=("${!targets[@]}")
    # START всегда предшествует измерениям, FINAL/STOP — после опустошения очередей.
    while :; do
        if [[ -e $tmp/logger.stop && $deadline == -1 ]]; then
            mono_ms || exit 2; deadline=$((NOW+DRAIN_MS))
        fi
        if (( deadline >= 0 )); then mono_ms || exit 2; (( NOW < deadline )) || break; fi
        if ! flock -n -x "$log_fd"; then sleep 0.05; continue; fi
        work=0; busy=0
        if (( head[p] == 0 )); then
            path=$tmp/q.p.0
            if [[ -f $path ]]; then
                if ! IFS= read -r line < "$path" || ! printf '%s\n' "$line" >&"$log_fd" || ! rm -f -- "$path"; then
                    : > "$tmp/logger.failed"; exit 2
                fi
                head[p]=1; work=1
            fi
        fi
        for owner in "${owners[@]}"; do
            for ((j=0; j<16; j++)); do
                slot=$((head[$owner]%QUEUE_SLOTS)); path=$tmp/q.$owner.$slot
                [[ -f $path ]] || break
                if ! IFS= read -r line < "$path" || ! printf '%s\n' "$line" >&"$log_fd" || ! rm -f -- "$path"; then
                    : > "$tmp/logger.failed"; exit 2
                fi
                head[$owner]=$((head[$owner]+1)); work=1
            done
            [[ ! -f $tmp/q.$owner.$((head[$owner]%QUEUE_SLOTS)) ]] || busy=1
        done
        if (( deadline >= 0 && ! busy )); then
            cap=$((${#targets[@]}+2))
            while (( head[p] < cap )); do
                path=$tmp/q.p.${head[p]}
                [[ -f $path ]] || break
                if ! IFS= read -r line < "$path" || ! printf '%s\n' "$line" >&"$log_fd" || ! rm -f -- "$path"; then
                    : > "$tmp/logger.failed"; exit 2
                fi
                head[p]=$((head[p]+1))
            done
            flock -u "$log_fd" || :
            break
        fi
        flock -u "$log_fd" || { : > "$tmp/logger.failed"; exit 2; }
        (( work )) || sleep 0.05
    done
    : > "$tmp/logger.done"
}

if [[ -n $LOG_FILE ]]; then
    for cmd in date flock; do command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда: $cmd"; done
    [[ ! -e $LOG_FILE || -f $LOG_FILE ]] || fail 'Журнал должен быть обычным файлом'
    exec {log_fd}>> "$LOG_FILE" || fail "Не удалось открыть журнал: $LOG_FILE"
    flock -x -w 2 "$log_fd" || fail "Не удалось заблокировать журнал: $LOG_FILE"
    if [[ -s $LOG_FILE ]]; then
        IFS= read -r header < "$LOG_FILE" || fail 'Не удалось прочитать заголовок журнала'
        [[ $header == "$LOG_HEADER" ]] || fail 'Несовместимый заголовок TSV. Укажите новый файл журнала для v3.2.'
    else
        printf '%s\n' "$LOG_HEADER" >&"$log_fd" || fail 'Не удалось записать заголовок журнала'
    fi
    flock -u "$log_fd" || fail 'Не удалось разблокировать журнал'
fi

# ── Публикация снимков и независимые циклы опроса ──────────────────────
# Один файл результата на узел и один временный файл для атомарной замены.
# Содержимое ping также перезаписывается, поэтому объём не растёт с числом проверок.
publish() {
    local idx=$1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${attempts[idx]}" "${sent[idx]}" "${lost[idx]}" "${errors[idx]}" "${state[idx]}" "${rtt[idx]}" \
        "${rtt_count[idx]}" "${rtt_sum[idx]}" "${rtt_min[idx]}" "${rtt_max[idx]}" "${outages[idx]}" \
        "${down_start[idx]}" "${total_closed[idx]}" "${max_closed[idx]}" "${last_down[idx]}" \
        "${probe_start[idx]}" "${probe_end[idx]}" "${detail[idx]}" "$log_failed" "${rtt_sq[idx]}" "${period_ms[idx]}" "$queue_drop" "${rtt_parse_errors[idx]}" > "$tmp/$idx.new" && \
        mv -f -- "$tmp/$idx.new" "$tmp/$idx.state"
}
collect() {
    local i
    for i in "${!targets[@]}"; do
        [[ -f $tmp/$i.state ]] || continue
        IFS=$'\t' read -r 'attempts[i]' 'sent[i]' 'lost[i]' 'errors[i]' 'state[i]' 'rtt[i]' \
            'rtt_count[i]' 'rtt_sum[i]' 'rtt_min[i]' 'rtt_max[i]' 'outages[i]' 'down_start[i]' \
            'total_closed[i]' 'max_closed[i]' 'last_down[i]' 'probe_start[i]' 'probe_end[i]' \
            'detail[i]' 'worker_log_failed[i]' 'rtt_sq[i]' 'period_ms[i]' 'dropped[i]' 'rtt_parse_errors[i]' < "$tmp/$i.state" || return 1
    done
}
# Останавливаем только собственные активные дочерние задания. Не используем kill 0.
# Ограниченное ожидание собственных заданий; не вызываем wait для живого процесса.
# В главном процессе группы выделены job control, в воркере — обычные PID.
terminate_jobs() {
    local mode=$1 pid dest until alive
    shift
    local -a ids=("$@")
    for pid in "${ids[@]}"; do
        dest=$pid; [[ $mode != group ]] || dest=-$pid
        kill -TERM -- "$dest" 2>/dev/null || :
        kill -CONT -- "$dest" 2>/dev/null || :
    done
    mono_ms || return 1; until=$((NOW+STOP_GRACE_MS))
    while :; do
        alive=0
        for pid in "${ids[@]}"; do
            dest=$pid; [[ $mode != group ]] || dest=-$pid
            if kill -0 -- "$dest" 2>/dev/null; then alive=1; fi
        done
        (( alive )) || break
        mono_ms || break; (( NOW < until )) || break
        sleep 0.05
    done
    for pid in "${ids[@]}"; do
        dest=$pid; [[ $mode != group ]] || dest=-$pid
        if kill -0 -- "$dest" 2>/dev/null; then kill -KILL -- "$dest" 2>/dev/null || :; fi
    done
    mono_ms || return 1; until=$((NOW+300))
    while :; do
        alive=0
        for pid in "${ids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        (( alive )) || break
        mono_ms || break; (( NOW < until )) || break
        sleep 0.05
    done
    for pid in "${ids[@]}"; do
        dest=$pid; [[ $mode != group ]] || dest=-$pid
        if kill -0 -- "$dest" 2>/dev/null; then shutdown_incomplete=1
        else wait "$pid" 2>/dev/null || :; fi
    done
}
stop_jobs() {
    local -a active=()
    local pid
    for pid in $(jobs -p); do active+=("$pid"); done
    terminate_jobs pid "${active[@]}"
}
worker_cleanup() {
    trap - EXIT
    trap '' INT TERM HUP
    stop_jobs
}
# Независимый цикл одного узла. При коротком интервале медленный сосед не влияет на него.
worker() {
    local idx=$1 family rc output previous msg stamp elapsed remain delay pid stop=0 duration
    set +m
    queue_seq=0; queue_drop=0
    trap worker_cleanup EXIT
    trap 'stop=1' INT TERM HUP
    if [[ -n $log_fd ]]; then exec {log_fd}>&-; log_fd=''; fi
    if [[ ${targets[idx]} == *:* ]]; then family=-6; else family=-4; fi
    while (( ! stop )); do
        mono_ms || exit 2
        if (( probe_start[idx] >= 0 )); then period_ms[idx]=$((NOW-probe_start[idx])); fi
        probe_start[idx]=$NOW
        timeout --foreground -k 0.2 "$DEADLINE" ping "$family" "${ping_args[@]}" -- "${targets[idx]}" > "$tmp/$idx.ping" 2>&1 & pid=$!
        (( ! stop )) || break
        if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
        (( ! stop )) || break
        mono_ms || exit 2
        probe_end[idx]=$NOW
        previous=${state[idx]}; msg='-'; rtt[idx]='-'
        output=$(<"$tmp/$idx.ping")
        attempts[idx]=$((attempts[idx]+1))
        if (( rc == 0 )); then
            state[idx]=UP; sent[idx]=$((sent[idx]+1))
            if [[ $output =~ time([=\<])([0-9]+([.][0-9]+)?)[[:space:]]*ms ]]; then
                if [[ ${BASH_REMATCH[1]} == '<' ]]; then rtt[idx]="<${BASH_REMATCH[2]}"
                else
                    rtt[idx]=${BASH_REMATCH[2]}
                    if rtt_to_us "${rtt[idx]}"; then
                        if (( rtt_count[idx] == 0 || RTT_US < rtt_min[idx] )); then rtt_min[idx]=$RTT_US; fi
                        if (( rtt_count[idx] == 0 || RTT_US > rtt_max[idx] )); then rtt_max[idx]=$RTT_US; fi
                        rtt_count[idx]=$((rtt_count[idx]+1)); rtt_sum[idx]=$((rtt_sum[idx]+RTT_US))
                        if (( rtt_sq[idx] >= 0 )); then
                            if (( RTT_US <= 3037000499 && rtt_sq[idx] <= 9223372036854775807-RTT_US*RTT_US )); then
                                rtt_sq[idx]=$((rtt_sq[idx]+RTT_US*RTT_US))
                            else rtt_sq[idx]=-1; fi
                        fi
                    else
                        rtt[idx]='-'; rtt_parse_errors[idx]=$((rtt_parse_errors[idx]+1))
                    fi
                fi
            else
                # Не превращаем неизвестное значение в ноль и не меняем статус UP.
                rtt_parse_errors[idx]=$((rtt_parse_errors[idx]+1))
            fi
            if [[ ${rtt[idx]} == - ]]; then msg='RTT_PARSE: успешная проба без распознанного RTT'; fi
        elif (( rc == 1 )) && [[ $output =~ (^|[[:space:]])1[[:space:]]+packets?[[:space:]]+transmitted ]] &&
            [[ $output != *"local error:"* && $output != *"sendmsg:"* && $output != *"sendto:"* ]]; then
            state[idx]=DOWN; sent[idx]=$((sent[idx]+1)); lost[idx]=$((lost[idx]+1))
            msg="ping rc=1: ${output:0:500}"
        else
            state[idx]=ERROR; errors[idx]=$((errors[idx]+1))
            if (( rc == 124 || rc == 137 )); then msg="watchdog rc=$rc: превышен абсолютный лимит выполнения ping; ${output:0:400}"
            else msg="ping rc=$rc: ${output:0:500}"; fi
        fi
        # DOWN начинается с отправки первой неуспешной пробы (оценка, не точная граница отказа).
        # UP/ERROR закрывает наблюдаемый эпизод; ERROR не доказывает восстановление сети.
        if [[ ${state[idx]} == DOWN ]]; then
            if [[ $previous != DOWN ]]; then down_start[idx]=${probe_start[idx]}; outages[idx]=$((outages[idx]+1)); fi
        elif (( down_start[idx] >= 0 )); then
            duration=$((probe_end[idx]-down_start[idx])); last_down[idx]=$duration
            total_closed[idx]=$((total_closed[idx]+duration))
            (( duration <= max_closed[idx] )) || max_closed[idx]=$duration
            down_start[idx]=-1
        fi
        msg=${msg//$'\n'/; }; msg=${msg//[[:cntrl:]]/ }; detail[idx]=$msg
        # Очередь локальна: ожидания блокировки общего файла здесь нет.
        if [[ -n $LOG_FILE ]] && { [[ ${state[idx]} != "$previous" ]] || (( SAMPLES )) || [[ $msg == RTT_PARSE:* ]]; }; then
            wall_stamp || { STAMP=-; log_failed=1; }; stamp=$STAMP
            dropped[idx]=$queue_drop
            if [[ ${state[idx]} != "$previous" ]]; then log_event STATE "$idx" "$previous" "${state[idx]}" "$msg" "${probe_end[idx]}" "$stamp"; fi
            dropped[idx]=$queue_drop
            if [[ $msg == RTT_PARSE:* ]] && (( ! SAMPLES )) && [[ ${state[idx]} == "$previous" ]]; then log_event RTT_PARSE "$idx" "$previous" "${state[idx]}" "$msg" "${probe_end[idx]}" "$stamp"; fi
            if (( SAMPLES )); then log_event SAMPLE "$idx" "$previous" "${state[idx]}" "$msg" "${probe_end[idx]}" "$stamp"; fi
        fi
        publish "$idx" || exit 2
        (( ! LIMIT || attempts[idx] < LIMIT )) || break
        (( ! stop )) || break
        mono_ms || exit 2
        elapsed=$((NOW-probe_start[idx])); remain=$((INTERVAL_MS-elapsed))
        # /proc/uptime округлён до 10 мс; запас в один квант не позволяет
        # начать следующую пробу раньше заданного интервала из-за округления.
        if (( remain >= 0 )); then
            remain=$((remain+10))
            printf -v delay '%d.%03d' "$((remain/1000))" "$((remain%1000))"
            sleep "$delay" & pid=$!
            (( ! stop )) || break
            wait "$pid" || :
        fi
    done
    exit 0
}

# ── Контроль актуальности и отображение ──────────────────────────────
# Актуальность — отдельное качество измерения, не доказательство потери ICMP.
view_state() {
    local idx=$1 at=$2 base=${start_ms}
    VIEW=${state[idx]}
    (( probe_end[idx] < 0 )) || base=${probe_end[idx]}
    AGE=$((at-base)); (( AGE >= 0 )) || AGE=0
    if (( LIMIT && attempts[idx] >= LIMIT && ! worker_dead[idx] )); then return; fi
    if (( worker_dead[idx] || AGE > STALE_MS )); then VIEW=STALE; fi
}
# Для конечного запуска узел больше не наблюдается после последней проверки.
observed_at() {
    AT=$2
    view_state "$1" "$2"
    if (( LIMIT && attempts[$1] >= LIMIT )) || [[ $VIEW == STALE ]]; then
        AT=${probe_end[$1]}; (( AT >= 0 )) || AT=$start_ms
    fi
    # Снимок мог появиться уже после чтения времени главным процессом.
    (( AT >= probe_end[$1] )) || AT=${probe_end[$1]}
}
# Дополняем кириллицу по числу символов, а не байтов. ANSI добавляется после выравнивания.
pad() {
    local value=$1 min_width=$2 align=$3 spaces n
    n=$((min_width-${#value})); (( n >= 0 )) || n=0
    printf -v spaces '%*s' "$n" ''
    if [[ $align == left ]]; then PAD=$value$spaces; else PAD=$spaces$value; fi
}
# Получаем реальные размеры при каждом кадре, включая изменение размера SSH/PTY.
terminal_size() {
    local size
    size=$(stty size <&"$tty_fd" 2>/dev/null) || return 1
    [[ $size =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] || return 1
    TERM_ROWS=${BASH_REMATCH[1]}; TERM_COLS=${BASH_REMATCH[2]}
    (( TERM_ROWS > 0 && TERM_COLS > 0 ))
}
# Только SGR из собственного интерфейса разрешены. Все прочие управляющие
# символы и неизвестные по ширине символы заменяем; кириллица занимает одну ячейку.
# Не используем последний столбец терминала: иначе возможно автоматическое обёртывание.
clip_line() {
    local LC_ALL=C.UTF-8
    local rest=$1 limit=$2 part escape n out='' used=0
    while [[ -n $rest ]] && (( used < limit )); do
        part=${rest%%$'\033'*}
        rest=${rest:${#part}}
        # Внешние пути/сообщения могут содержать широкие символы; оставляем
        # ASCII, кириллицу и фиксированную пунктуацию интерфейса.
        part=${part//[^\ -~А-Яа-яЁё–—×≥≤]/?}
        n=${#part}
        if (( n > limit-used )); then out+=${part:0:limit-used}; used=$limit; break; fi
        out+=$part; used=$((used+n))
        [[ -n $rest ]] || break
        if [[ $rest =~ ^($'\033'\[[0-9\;]*m) ]]; then
            escape=${BASH_REMATCH[1]}; out+=$escape; rest=${rest:${#escape}}
        else rest=${rest:1}; fi
    done
    CLIPPED=$out
}
# Один кадр, абсолютное позиционирование, очистка КАЖДОЙ строки и хвоста экрана.
# Ни один диагностический текст не может перенести курсор за границы кадра.
paint_frame() {
    local frame=$1 rows=$2 cols=$3 line y=1 output='' pos
    while IFS= read -r line; do
        (( y <= rows )) || break
        clip_line "$line" "$((cols>1 ? cols-1 : 0))"
        printf -v pos '\033[%d;1H\033[2K' "$y"
        output+="$pos$CLIPPED"$'\033[0m'
        y=$((y+1))
    done <<< "${frame%$'\n'}"
    if (( y <= rows )); then printf -v pos '\033[%d;1H\033[J' "$y"; output+=$pos; fi
    printf '%s' "$output"
}
# Профили используют общую таблицу данных и не меняют сбор статистики.
profile_columns() {
    case $1 in
        compact) selected=(0 1 2);;
        standard) selected=(0 1 2 4 6 7 11 17);;
        extended) selected=(0 1 2 3 4 5 6 7 8 9 10 11 17);;
        *) selected=(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18);;
    esac
    table_width=0
    local j
    for j in "${selected[@]}"; do table_width=$((table_width+widths[j]+2)); done
    table_width=$((table_width-2))
}
render() {
    local LC_ALL=C.UTF-8
    local at=$1 final=${2:-0} profile=$PROFILE i j k n label color val row frame stamp PAD
    local up=0 down=0 err=0 pending=0 stale=0 min_checks=-1 max_checks=0 warn=$log_failed drops=$queue_drop parse_total=0
    local interactive=0 rows=0 cols=0 table_width=0 page_size page pages first last diag='' total_nodes=${#targets[@]} footer_count
    local -a headers=(IP СТАТУС ПОТЕРИ ОТПР. 'ПОТ.%' 'ДОСТ.%' ОШИБ. СБОИ 'ТЕК. СБОЙ' 'МАКС. СБОЙ' 'ВСЕГО СБОЙ' RTT 'RTT МИН' 'RTT СР' 'RTT МАКС' 'RTT MDEV' ПЕРИОД ДАВН. 'RTT ОШИБ.')
    local -a widths=("${FULL_WIDTHS[@]}") cells=() colors=() selected=() footer=() choices=()
    local stride=${#headers[@]}
    if (( ! PLAIN && ! final )); then
        interactive=1
        if terminal_size; then rows=$TERM_ROWS; cols=$TERM_COLS; else return 0; fi
    fi
    for j in "${!headers[@]}"; do (( widths[j] >= ${#headers[j]} )) || widths[j]=${#headers[j]}; done
    for i in "${!targets[@]}"; do
        view_state "$i" "$at"
        case $VIEW in
            STALE) label=УСТАРЕЛО; color=$ORANGE; stale=$((stale+1));;
            UP) label=ДОСТУПЕН; color=$GREEN; up=$((up+1));;
            DOWN) label=НЕДОСТУПЕН; color=$RED; down=$((down+1));;
            ERROR) label=ОШИБКА; color=$YELLOW; err=$((err+1));;
            *) label=ОЖИДАНИЕ; color=''; pending=$((pending+1));;
        esac
        colors[i]=$color
        n=${attempts[i]}; (( min_checks >= 0 && n >= min_checks )) || min_checks=$n
        (( n <= max_checks )) || max_checks=$n
        (( ! worker_log_failed[i] )) || warn=1
        drops=$((drops+dropped[i])); parse_total=$((parse_total+rtt_parse_errors[i]))
        k=$((i*stride)); cells[k]=${targets[i]}; cells[k+1]=$label; cells[k+2]=${lost[i]}
        observed_at "$i" "$at"; metrics "$i" "$AT"
        cells[k+3]=${sent[i]}; cells[k+4]=$LOSS_PCT; cells[k+5]=$AVAIL_PCT
        cells[k+6]=${errors[i]}; cells[k+7]=${outages[i]}; cells[k+8]='-'
        if [[ ${state[i]} == DOWN ]]; then format_duration "$CURRENT"; cells[k+8]=$DURATION; fi
        format_duration "$LONGEST"; cells[k+9]=$DURATION
        format_duration "$TOTAL"; cells[k+10]=$DURATION
        cells[k+11]=${rtt[i]}; cells[k+12]=$MIN_RTT; cells[k+13]=$AVG_RTT; cells[k+14]=$MAX_RTT; cells[k+15]=$MDEV_RTT
        cells[k+16]='-'; if (( period_ms[i] >= 0 )); then format_duration "${period_ms[i]}"; cells[k+16]=$DURATION; fi
        view_state "$i" "$at"; cells[k+17]='-'
        if (( probe_end[i] >= 0 )) || [[ $VIEW == STALE ]]; then format_duration "$AGE"; cells[k+17]=$DURATION; fi
        cells[k+18]=${rtt_parse_errors[i]}
        for ((j=0; j<stride; j++)); do
            val=${cells[k+j]}; (( widths[j] >= ${#val} )) || widths[j]=${#val}
        done
    done
    (( ! final )) || profile=full
    if [[ $profile == auto ]]; then
        profile=full
        if (( interactive )); then
            for profile in full extended standard compact; do
                profile_columns "$profile"
                (( table_width < cols )) && break
            done
        fi
    fi
    profile_columns "$profile"
    # При явном выборе слишком широкого профиля понижаем его только для экрана.
    # Итоговый отчёт и журнал всегда сохраняют все показатели.
    if (( interactive && table_width >= cols )); then
        case $profile in full) choices=(extended standard compact);; extended) choices=(standard compact);; *) choices=(compact);; esac
        for profile in "${choices[@]}"; do profile_columns "$profile"; (( table_width < cols )) && break; done
    fi
    format_duration "$((at-start_ms))"; printf -v stamp '%(%F %T)T' -1
    if (( final )); then label='ИТОГОВЫЙ ОТЧЁТ'; else label='Мониторинг ICMP v3.2'; fi
    printf -v frame '%s | %s | Время работы: %s\nИсточник: %s | Интервал: %s с | Тайм-аут: %s с | Экран: %s с | Payload: %s | PMTU: %s\nДоступны: %d  Недоступны: %d  Ошибки: %d  Ожидание: %d  Устарело: %d | Проверок на узел: %d–%d\n' \
        "$label" "$stamp" "$DURATION" "${SOURCE:-авто}" "$INTERVAL" "$TIMEOUT" "$REFRESH" "${PAYLOAD:-по умолчанию}" "${PMTU:-по умолчанию}" "$up" "$down" "$err" "$pending" "$stale" "$min_checks" "$max_checks"
    if (( interactive && cols < 105 )); then
        format_duration "$((at-start_ms))"
        printf -v frame '%s | %s | %s\nИсточник: %s | I=%s с W=%s с\nДост.: %d  Недост.: %d  Ошиб.: %d  Ожид.: %d  Устар.: %d\n' \
            "$label" "$stamp" "$DURATION" "${SOURCE:-авто}" "$INTERVAL" "$TIMEOUT" "$up" "$down" "$err" "$pending" "$stale"
    fi
    format_duration "$STALE_MS"
    footer+=("Профиль: $profile | STALE: $DURATION | RTT ошиб.: $parse_total")
    if (( interactive && table_width >= cols )); then footer+=('Терминал слишком узкий: таблица сокращена.'); fi
    if (( final )); then footer+=('Незавершённые проверки не включены в счётчики.'); else footer+=('Ctrl+C: остановить и вывести итоговый отчёт'); fi
    if [[ -n $LOG_FILE ]]; then
        footer+=("Журнал: $LOG_FILE | Отброшено записей: $drops")
        [[ ! -e $tmp/logger.failed ]] || warn=1
        if [[ -n $logger_pid ]] && (( ! final )) && ! kill -0 "$logger_pid" 2>/dev/null; then warn=1; fi
        if (( final )); then footer+=("Не выгружено записей: $logger_pending"); fi
    fi
    (( ! warn && ! logger_bad && ! drops && ! logger_pending )) || footer+=('ВНИМАНИЕ: журнал неполон; проверьте счётчики очереди и ошибки записи.')
    (( ! parse_total )) || footer+=('ВНИМАНИЕ: не все успешные ответы содержат распознаваемый RTT.')
    if (( interactive )); then
        # Диагностика имеет постоянную максимальную высоту: одна строка.
        # Полный текст доступен в журнале и обычном выводе.
        if (( err )); then
            for i in "${!targets[@]}"; do
                if [[ ${state[i]} == ERROR && ${worker_dead[i]} == 0 ]]; then diag="Ошибка ${targets[i]}: ${detail[i]}"; break; fi
            done
            footer+=("$diag")
        fi
        if (( ${#preflight[@]} )); then footer+=("ВНИМАНИЕ: ${preflight[0]}"); fi
        # Верхние 3 строки, заголовок и разделитель таблицы, строка страниц и подвал.
        page_size=$((rows-6-${#footer[@]})); (( page_size >= 1 )) || page_size=1
        pages=$(((total_nodes+page_size-1)/page_size))
        page=$((((at-start_ms)/PAGE_MS)%pages))
        first=$((page*page_size)); last=$((first+page_size)); (( last <= total_nodes )) || last=$total_nodes
    else
        first=0; last=$total_nodes; page=0; pages=1
        for val in "${preflight[@]}"; do footer+=("ВНИМАНИЕ: $val"); done
        for i in "${!targets[@]}"; do
            if [[ ${state[i]} == ERROR ]]; then footer+=("Ошибка ${targets[i]}: ${detail[i]}"); fi
            if (( worker_dead[i] )); then
                footer+=("Воркер ${targets[i]} завершился аварийно.")
                if [[ -s $tmp/$i.worker.stderr ]] && IFS= read -r val < "$tmp/$i.worker.stderr"; then
                    val=${val//[[:cntrl:]]/ }; footer+=("Диагностика: ${val:0:500}")
                fi
            fi
            if (( dropped[i] )); then footer+=("${targets[i]}: отброшено ${dropped[i]} записей"); fi
        done
        footer+=('RTT — мс; ПОТ.% и ДОСТ.% — доли учтённых отправок. Сбои — оценка по ICMP.')
    fi
    row=''
    for j in "${selected[@]}"; do
        label=right; (( j > 1 )) || label=left
        pad "${headers[j]}" "${widths[j]}" "$label"
        row+=${row:+  }$PAD
    done
    frame+="$row"$'\n'; printf -v val '%*s' "${#row}" ''; frame+="${val// /-}"$'\n'
    for ((i=first; i<last; i++)); do
        row=''; k=$((i*stride))
        for j in "${selected[@]}"; do
            label=right; (( j > 1 )) || label=left
            pad "${cells[k+j]}" "${widths[j]}" "$label"
            [[ -z $row ]] || row+='  '
            if (( ! final && j == 1 )); then row+="${colors[i]}$PAD$RESET"
            elif (( ! final && j == 2 && lost[i] > 0 )); then row+="$RED$PAD$RESET"
            else row+=$PAD; fi
        done
        frame+="$row"$'\n'
    done
    if (( interactive )); then
        frame+="Узлы $((first+1))–$last из $total_nodes | Страница $((page+1))/$pages"$'\n'
        if (( pages > 1 )); then frame=${frame%$'\n'}' (смена каждые 5 с)'$'\n'; fi
    fi
    for val in "${footer[@]}"; do frame+="$val"$'\n'; done
    if (( interactive )); then paint_frame "$frame" "$rows" "$cols"; else printf '%s\n' "$frame"; fi
}
# ── Жизненный цикл, сигналы и итоговый отчёт ──────────────────────────
request_stop() {
    if (( ! stop_requested )); then
        stop_requested=$1
        if mono_ms; then stop_ms=$NOW; fi
    fi
}
cleanup() {
    local exit_code=$? i at pid total_dropped=0
    trap - EXIT
    trap '' INT TERM HUP
    if (( stop_requested )); then exit_code=$stop_requested; fi
    if (( stop_ms < 0 )); then mono_ms && stop_ms=$NOW; fi
    # Каждая рабочая группа отдельна от терминала и соседних воркеров.
    # SIGTERM/CONT, затем ограниченный grace и SIGKILL для оставшихся.
    terminate_jobs group "${workers[@]}"
    if [[ -n ${refresh_pid:-} ]] && kill -0 "$refresh_pid" 2>/dev/null; then terminate_jobs pid "$refresh_pid"; fi
    if (( screen )); then printf '\033[0m\033[?25h\033[?1049l'; screen=0; fi
    if (( started )); then
        collect || printf 'ВНИМАНИЕ: не удалось прочитать один из последних снимков.\n' >&2
        (( stop_ms >= 0 )) || stop_ms=$start_ms
        at=$stop_ms
        # Сначала FINAL для каждой цели, затем STOP. Все рабочие процессы уже завершены.
        for i in "${!targets[@]}"; do
            observed_at "$i" "$at"
            log_event FINAL "$i" "${state[i]}" "$VIEW" 'monitor stopped; incomplete probes excluded' "$AT"
            total_dropped=$((total_dropped+dropped[i]))
        done
        log_event STOP - - - "exit=$exit_code; dropped=$((total_dropped+queue_drop))" "$at"
        if [[ -n $logger_pid ]]; then
            : > "$tmp/logger.stop"
            # Ограничиваем также ожидание родителя на случай зависания logger.
            mono_ms && local until=$((NOW+DRAIN_MS+1000)) || local until=0
            while kill -0 "$logger_pid" 2>/dev/null; do
                mono_ms || break
                if (( NOW >= until )); then terminate_jobs group "$logger_pid"; logger_bad=1; break; fi
                sleep 0.05
            done
            if ! kill -0 "$logger_pid" 2>/dev/null; then wait "$logger_pid" 2>/dev/null || logger_bad=1; else logger_bad=1; fi
            local -a pending_files=()
            shopt -s nullglob
            pending_files=("$tmp"/q.*.[0-9]*)
            logger_pending=${#pending_files[@]}
            shopt -u nullglob
        fi
        render "$at" 1
    fi
    if (( shutdown_incomplete )); then
        printf 'ВНИМАНИЕ: не все процессы завершились; возможна блокировка в ядре. Временный каталог сохранён: %s\n' "$tmp" >&2
        (( exit_code != 0 )) || exit_code=2
    else [[ -z $tmp ]] || rm -rf -- "$tmp"; fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'request_stop 130' INT
trap 'request_stop 143' TERM
trap 'request_stop 129' HUP
# Временный каталог живёт ровно один сеанс; файлы имеют ограниченное число имён.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ping-monitor.XXXXXXXX") || fail 'Не удалось создать временный каталог'
mono_ms || fail 'Не удалось прочитать монотонные часы'; start_ms=$NOW
started=1
log_event START - - - "interval=$INTERVAL; timeout=$TIMEOUT; refresh=$REFRESH; source=${SOURCE:-auto}; payload=${PAYLOAD:-default}; pmtu=${PMTU:-default}; targets=${#targets[@]}" "$start_ms"
set -m
if [[ -n $LOG_FILE ]]; then
    logger > "$tmp/logger.stderr" 2>&1 & logger_pid=$!
    # Только logger сохраняет открытый дескриптор общего журнала.
    exec {log_fd}>&-; log_fd=''
fi
# Абсолютный предел обеспечивается timeout; ping отправляет ровно одну пробу.
ping_args=(-n -c 1 -W "$TIMEOUT")
[[ -z $SOURCE ]] || ping_args+=(-I "$SOURCE")
[[ -z $PAYLOAD ]] || ping_args+=(-s "$PAYLOAD")
[[ -z $PMTU ]] || ping_args+=(-M "$PMTU")
if (( ! PLAIN )); then screen=1; printf '\033[?1049h\033[2J\033[H\033[?25l'; fi
for i in "${!targets[@]}"; do
    (( ! stop_requested )) || break
    worker "$i" > "$tmp/$i.worker.stderr" 2>&1 & workers[i]=$!
done
set +m
# Частота отрисовки не задаёт частоту проверок; здесь нет ожидания отдельных ping.
while (( ! stop_requested )); do
    collect || fail 'Не удалось прочитать снимок состояния'
    done_count=0; dead_count=0
    for i in "${!targets[@]}"; do
        if (( LIMIT && attempts[i] >= LIMIT && ! worker_dead[i] )); then
            done_count=$((done_count+1))
            if [[ -n ${workers[i]:-} ]] && ! kill -0 -- "-${workers[i]}" 2>/dev/null; then
                wait "${workers[i]}" 2>/dev/null || { worker_dead[i]=1; done_count=$((done_count-1)); dead_count=$((dead_count+1)); }
                unset 'workers[i]'
            fi
        elif [[ -z ${workers[i]:-} ]] || ! kill -0 "${workers[i]}" 2>/dev/null; then
            collect || fail 'Не удалось прочитать итоговый снимок'
            if (( LIMIT && attempts[i] >= LIMIT && ! worker_dead[i] )); then done_count=$((done_count+1))
            else
                if (( ! worker_dead[i] )); then
                    worker_dead[i]=1
                    if [[ -n ${workers[i]:-} ]]; then
                        terminate_jobs group "${workers[i]}"
                        if ! kill -0 -- "-${workers[i]}" 2>/dev/null; then unset 'workers[i]'; fi
                    fi
                fi
                dead_count=$((dead_count+1))
            fi
        fi
    done
    if (( done_count+dead_count == ${#targets[@]} )); then
        # Все итоговые снимки опубликованы; ограниченная остановка в cleanup.
        (( ! stop_requested )) || break
        (( ! dead_count )) || exit 2
        break
    fi
    mono_ms || fail 'Не удалось прочитать монотонные часы'
    render "$NOW"
    (( ! stop_requested )) || break
    sleep "$REFRESH" & refresh_pid=$!
    (( ! stop_requested )) || break
    wait "$refresh_pid" || :
    refresh_pid=''
done
exit "$stop_requested"

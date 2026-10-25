sudo tee /usr/local/bin/pihole-watchdog.sh > /dev/null <<'WATCHDOG_EOF'
#!/bin/bash
# Pi-hole watchdog: checks Pi-hole, Unbound, blocking, the clock and the Pi's hardware,
# and pushes alerts (with suggested fixes) to your phone through the free ntfy app.
# Usage: pihole-watchdog.sh check | summary | guard | test
# Your settings live in /etc/pihole-watchdog.conf (written by the installer).
TOPIC=""            # your private ntfy channel name
ROUTER_IP=""        # your router's address, used in fix instructions
PI_IP=""            # this Pi's address, used in fix instructions
USE_UNBOUND=0       # 1 = Pi-hole uses Unbound on UNBOUND_PORT, 0 = it doesn't
UNBOUND_PORT=5335
BACKUP_DNS='["1.1.1.1","1.0.0.1"]'   # used if Unbound breaks (Cloudflare)
WATCHDOG_CONF="${WATCHDOG_CONF:-/etc/pihole-watchdog.conf}"
[ -r "$WATCHDOG_CONF" ] && . "$WATCHDOG_CONF"
[ -n "$TOPIC" ] || { echo "No TOPIC set in /etc/pihole-watchdog.conf"; exit 1; }
if [ -n "$ROUTER_IP" ]; then ROUTER_AT="http://$ROUTER_IP"; else ROUTER_AT="the router admin page"; fi
if [ -n "$PI_IP" ]; then PI_AT="$PI_IP"; else PI_AT="the address of this Pi"; fi
STATE_DIR="${STATE_DIR:-/var/lib/pihole-watchdog}"
FAILS_FILE="$STATE_DIR/fail_count"
ALERTED_FILE="$STATE_DIR/alerted"
AUTOFIX_FILE="$STATE_DIR/autofixed"
QUEUE_FILE="$STATE_DIR/queue"
FALLBACK_FILE="$STATE_DIR/on_backup_dns"
HW_WARN_FILE="$STATE_DIR/hw_warnings"
BOOT_ID_FILE="$STATE_DIR/boot_id"
LOG="$STATE_DIR/watchdog.log"
# Hardware paths (overridable for testing)
THERMAL="${THERMAL:-/sys/class/thermal/thermal_zone0/temp}"
BOOT_ID_SRC="${BOOT_ID_SRC:-/proc/sys/kernel/random/boot_id}"
TEMP_WARN=${TEMP_WARN:-75}      # degrees C (Pi slows itself down around 80-85)
DISK_WARN=${DISK_WARN:-90}      # percent full
MEM_WARN=${MEM_WARN:-10}       # percent memory available
REPEAT_HOURS=${REPEAT_HOURS:-4}    # re-send an alert every N hours while the problem is still there
HW_ALERT_DIR="$STATE_DIR/hw_alerted"
SNOOZE_HOURS=${SNOOZE_HOURS:-3}    # how long the "Snooze" button on an alert silences repeat alerts
CMD_TOPIC="${TOPIC}-cmd"          # the alert buttons post here; the Pi reads it
SNOOZE_FILE="$STATE_DIR/snooze_until"
CMD_LAST_FILE="$STATE_DIR/cmd_last_id"
GUARD_HOT=${GUARD_HOT:-85}      # emergency shutdown temperature, degrees C
GUARD_MINUTES=${GUARD_MINUTES:-3}   # critical readings in a row (one per minute) before shutting down
GUARD_COUNT_FILE="$STATE_DIR/guard_count"
SHUTDOWN_REASON_FILE="$STATE_DIR/shutdown_reason"
mkdir -p "$STATE_DIR"

now() { echo "${NOW:-$(date +%s)}"; }
# True if file exists and was last touched REPEAT_HOURS or more ago.
due() { [ -f "$1" ] && [ $(( $(now) - $(stat -c %Y "$1") )) -ge $(( REPEAT_HOURS * 3600 )) ]; }
# stamp: record first-seen time; refresh: mark "reminded just now".
stamp() { now > "$1"; touch -d "@$(now)" "$1"; }
refresh() { touch -d "@$(now)" "$1"; }
snoozed() { [ -f "$SNOOZE_FILE" ] && [ "$(now)" -lt "$(cat "$SNOOZE_FILE")" ]; }

# Check the command channel for "snooze" taps from the phone.
read_commands() {
  local since_arg last feed id msg got=""
  last=$(cat "$CMD_LAST_FILE" 2>/dev/null)
  since_arg=${last:-10m}
  feed=$(curl -fsS -m 10 $(ntfy_resolve) "https://ntfy.sh/${CMD_TOPIC}/json?poll=1&since=${since_arg}" 2>/dev/null) || return
  while read -r line; do
    grep -q '"event":"message"' <<<"$line" || continue
    id=$(grep -oE '"id":"[^"]+"' <<<"$line" | head -n1 | cut -d'"' -f4)
    [ -n "$id" ] && [ "$id" = "$last" ] && continue
    msg=$(grep -oE '"message":"[^"]*"' <<<"$line" | head -n1 | cut -d'"' -f4)
    [ -n "$id" ] && echo "$id" > "$CMD_LAST_FILE"
    [ "$msg" = "snooze" ] && got=1
  done <<<"$feed"
  if [ -n "$got" ]; then
    echo $(( $(now) + SNOOZE_HOURS * 3600 )) > "$SNOOZE_FILE"
    log "snoozed for ${SNOOZE_HOURS}h"
    notify "Repeat alerts snoozed" low "Snoozed for ${SNOOZE_HOURS} hours (until $(date -d "@$(cat "$SNOOZE_FILE")" '+%-I:%M %p')). New problems will still alert you, and the emergency shutdown is never snoozed."
  fi
}

since() { date -d "@$(cat "$1" 2>/dev/null || stat -c %Y "$1")" '+%b %d %-I:%M %p' 2>/dev/null; }

log() { echo "$(date '+%F %T') $*" >> "$LOG"; tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }

# Send to ntfy. Looks up ntfy.sh through Cloudflare directly so alerts still go out when Pi-hole/Unbound is broken.
ntfy_resolve() {
  local ip; ip=$(dig +short +time=3 +tries=2 ntfy.sh A @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1)
  [ -n "$ip" ] && echo "--resolve ntfy.sh:443:$ip"
}
send_raw() {
  local title="$1" prio="$2" msg="$3" actions="$4"
  local resolve=($(ntfy_resolve)) hdr=()
  [ -n "$actions" ] && hdr=(-H "Actions: $actions")
  curl -fsS -m 15 "${resolve[@]}" "${hdr[@]}" -H "Title: $title" -H "Priority: $prio" -d "$msg" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1
}
# Button added to alerts that repeat: tapping it posts "snooze" to the command channel.
SNOOZE_ACTION="http, Snooze ${SNOOZE_HOURS}h, https://ntfy.sh/${CMD_TOPIC}, body=snooze, clear=true"

# Queue messages that fail to send (e.g. home internet down) and retry on the next run.
notify() {
  local title="$1" prio="$2" msg="$3" actions="$4"
  if ! send_raw "$title" "$prio" "$msg" "$actions"; then
    printf '%s\t%s\t%s\n' "$title" "$prio" "$(printf '%s' "$msg
[Delayed - happened $(date '+%b %d %H:%M')]" | base64 -w0)" >> "$QUEUE_FILE"
    log "send failed, queued: $title"
  fi
}

flush_queue() {
  [ -s "$QUEUE_FILE" ] || return
  local remaining="" title prio enc
  while IFS=$'\t' read -r title prio enc; do
    [ -n "$enc" ] || continue
    if ! send_raw "$title" "$prio" "$(base64 -d <<<"$enc")"; then remaining+="$title"$'\t'"$prio"$'\t'"$enc"$'\n'; fi
  done < "$QUEUE_FILE"
  printf '%s' "$remaining" > "$QUEUE_FILE"
}

# Each check prints a problem line, or nothing if OK.
run_checks() {
  local out
  systemctl is-active --quiet pihole-FTL || echo "FTL|Pi-hole service (pihole-FTL) is not running."

  if [ "$USE_UNBOUND" = 1 ]; then
    out=$(dig +time=5 +tries=2 google.com @127.0.0.1 -p "$UNBOUND_PORT" 2>&1)
    if ! grep -q 'status: NOERROR' <<<"$out" || ! grep -qE 'ANSWER: [1-9]' <<<"$out"; then
      local st; st=$(grep -oE 'status: [A-Z]+' <<<"$out" | head -n1); st=${st:-no reply}
      echo "UNBOUND|Unbound is not resolving (${st})."
    fi
  fi

  out=$(dig +time=5 +tries=2 google.com @127.0.0.1 2>&1)
  if ! grep -q 'status: NOERROR' <<<"$out" || ! grep -qE 'ANSWER: [1-9]' <<<"$out"; then
    echo "PIHOLE|Pi-hole is not answering lookups - house internet is probably down."
  fi

  out=$(dig +short +time=5 +tries=2 doubleclick.net @127.0.0.1 2>&1)
  if ! grep -q '^0\.0\.0\.0$' <<<"$out"; then
    echo "BLOCK|Ad blocking is not working (doubleclick.net was not blocked)."
  fi

  if command -v timedatectl >/dev/null && [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
    echo "CLOCK|Pi clock is not synced (shows $(date '+%b %d %Y %H:%M')). Unbound can fail with a wrong clock."
  fi
}

# One restart attempt for whatever is broken.
auto_fix() {
  local problems="$1"
  if grep -q '^UNBOUND' <<<"$problems"; then systemctl restart unbound; log "restarted unbound"; fi
  if grep -qE '^(FTL|PIHOLE|BLOCK)' <<<"$problems"; then systemctl restart pihole-FTL; log "restarted pihole-FTL"; fi
  if grep -q '^CLOCK' <<<"$problems"; then systemctl restart systemd-timesyncd 2>/dev/null; log "restarted timesyncd"; fi
}

# Suggested fix for each problem type.
fix_for() {
  case "$1" in
    FTL)      echo "Over SSH: sudo systemctl restart pihole-FTL. If it won't start: pihole -r (choose Repair). If the house is offline meanwhile, log into your router at ${ROUTER_AT} and set its DNS back to automatic (your internet provider's DNS)." ;;
    UNBOUND)  echo "Check that no router feature is intercepting DNS (parental controls or 'security' add-ons such as Netgear Circle/Armor break Unbound). Then over SSH: sudo systemctl restart unbound and test with: dig google.com @127.0.0.1 -p ${UNBOUND_PORT} (look for NOERROR). The house stays online on the backup DNS meanwhile." ;;
    PIHOLE)   echo "Over SSH: sudo systemctl restart pihole-FTL. If the house is offline and you can't get to the Pi, log into your router at ${ROUTER_AT} and set its DNS back to automatic (your internet provider's DNS)." ;;
    BLOCK)    echo "Check blocking isn't switched off (Pi-hole dashboard, left menu). Then rebuild the lists: Tools > Update Gravity > Update, or over SSH: pihole -g" ;;
    CLOCK)    echo "Over SSH: sudo systemctl restart systemd-timesyncd, wait a minute, then run timedatectl - it should say 'System clock synchronized: yes'. If not, check the Pi's network cable." ;;
    BACKUP)   echo "Check that no router parental-control/security feature is intercepting DNS, then over SSH: sudo systemctl restart unbound. The watchdog switches back to Unbound by itself once it works." ;;
    HOT)      echo "Check the fan and case vents for dust or blockage and that the Pi isn't next to something warm. A case with a fan or heatsink fixes this." ;;
    UV_NOW|UV_PAST|VOLTS) echo "Use the official Raspberry Pi power supply (Pi 4: 5.1V 3A USB-C, Pi 5: 27W 5.1V 5A) plugged straight into the Pi - no phone chargers, long/thin cables or USB hubs." ;;
    THROTTLE_NOW|TEMPLIMIT) echo "Caused by heat or weak power - improve cooling (fan/heatsink) and use the official power supply." ;;
    FAN)      echo "Unplug the Pi and check the fan cable is seated on the FAN header and nothing is jamming the blades. Replace the fan if it still won't spin." ;;
    DISK)     echo "Over SSH: sudo apt clean and sudo journalctl --vacuum-size=100M. If it's still full, find what's big with: sudo du -xh / | sort -h | tail -n 15" ;;
    READONLY|SDERR) echo "Back up NOW: Pi-hole dashboard > Settings > Teleporter > Export. Get a new name-brand SD card (or a USB SSD), reinstall Pi-hole + Unbound and import the backup. Check the power supply too - bad power ruins cards." ;;
    HOT_CRIT) echo "Before plugging the Pi back in: check the fan spins and nothing is covering or blocking the case. Let it cool down first." ;;
    UV_CRIT)  echo "Before plugging the Pi back in: swap in the official Raspberry Pi power supply (Pi 4: 5.1V 3A USB-C, Pi 5: 27W 5.1V 5A), plugged straight into the Pi." ;;
    MEM)      echo "Over SSH: sudo reboot. If it keeps happening, run top (press q to quit) to see what's using the memory." ;;
  esac
}

# Problem lines as "- message" with a "Fix:" line under each.
format() {
  local key msg fix
  while IFS='|' read -r key msg; do
    [ -n "$key" ] || continue
    echo "- $msg"
    fix=$(fix_for "$key"); [ -n "$fix" ] && echo "  Fix: $fix"
  done <<<"$1"
}
# Problem lines only, no fixes (for "fixed itself" notices).
format_plain() { cut -d'|' -f2- <<<"$1" | grep -v '^$' | sed 's/^/- /'; }

# ---------- Hardware health ----------
cpu_temp() { [ -r "$THERMAL" ] && awk '{printf "%d", $1/1000}' "$THERMAL"; }

throttled_hex() { command -v vcgencmd >/dev/null && vcgencmd get_throttled 2>/dev/null | cut -d= -f2; }

fan_rpm() { local f; f=$(ls ${FAN_GLOB:-/sys/devices/platform/cooling_fan/hwmon/*/fan1_input} 2>/dev/null | head -n1); [ -n "$f" ] && cat "$f"; }

# Pi 5 only: 5V input voltage from the power chip.
input_volts() {
  command -v vcgencmd >/dev/null || return
  vcgencmd pmic_read_adc EXT5V_V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1
}

# Each hardware check prints KEY|message, or nothing if OK.
hw_checks() {
  local t th v rpm used avail
  t=$(cpu_temp)
  [ -n "$t" ] && [ "$t" -ge "$TEMP_WARN" ] && echo "HOT|CPU is running hot: ${t}°C."

  th=$(throttled_hex)
  if [ -n "$th" ]; then
    th=$((th))
    (( th & 0x1 ))     && echo "UV_NOW|Low voltage RIGHT NOW - the power supply or cable is too weak. This is the #1 cause of SD card corruption."
    (( th & 0x10000 )) && ! (( th & 0x1 )) && echo "UV_PAST|Low voltage has happened since the last boot. Power supply or cable may be marginal."
    (( th & 0x4 ))     && echo "THROTTLE_NOW|The Pi is slowing itself down right now (heat or power)."
    (( th & 0x8 ))     && echo "TEMPLIMIT|The Pi hit its soft temperature limit."
  fi

  v=$(input_volts)
  [ -n "$v" ] && awk -v v="$v" 'BEGIN{exit !(v < 4.8)}' && echo "VOLTS|Power supply voltage is low: ${v}V (should be about 5.0-5.1V)."

  rpm=$(fan_rpm)
  [ -n "$rpm" ] && [ -n "$t" ] && [ "$t" -ge 65 ] && [ "$rpm" -eq 0 ] && echo "FAN|Fan isn't spinning even though the CPU is ${t}°C."

  used=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  [ -n "$used" ] && [ "$used" -ge "$DISK_WARN" ] && echo "DISK|SD card is ${used}% full."

  findmnt -no OPTIONS / 2>/dev/null | grep -qE '(^|,)ro(,|$)' && echo "READONLY|SD card has switched to read-only - usually means the card is failing."

  if command -v journalctl >/dev/null && journalctl -k --since "-35 min" --no-pager 2>/dev/null | grep -qiE 'mmc[0-9]+.*(error|timeout)|I/O error|EXT4-fs error'; then
    echo "SDERR|SD card read/write errors in the system log - the card may be starting to fail."
  fi

  avail=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if(t) printf "%d", 100*a/t}' /proc/meminfo 2>/dev/null)
  [ -n "$avail" ] && [ "$avail" -lt "$MEM_WARN" ] && echo "MEM|Memory is nearly full (${avail}% free)."
}

# Alert once when a hardware warning first appears, and once when it clears.
do_hw() {
  local warns new cleared old_keys new_keys
  warns=$(hw_checks)
  old_keys=$(cut -d'|' -f1 "$HW_WARN_FILE" 2>/dev/null | sort)
  new_keys=$(cut -d'|' -f1 <<<"$warns" | grep -v '^$' | sort)
  new=$(comm -13 <(echo "$old_keys") <(echo "$new_keys") | grep -v '^$')
  cleared=$(comm -23 <(echo "$old_keys") <(echo "$new_keys") | grep -v '^$')
  mkdir -p "$HW_ALERT_DIR"
  local k
  if [ -n "$new" ]; then
    notify "Pi hardware warning" high "$(format "$(awk -F'|' 'NR==FNR{k[$1];next} ($1 in k)' <(echo "$new") <(echo "$warns"))")" "$SNOOZE_ACTION"
    log "hw warning: $(tr '\n' ' ' <<<"$new")"
    for k in $new; do stamp "$HW_ALERT_DIR/$k"; done
  fi
  # Repeat warnings that are still there after REPEAT_HOURS.
  local still="" stillkeys=""
  for k in $new_keys; do
    if due "$HW_ALERT_DIR/$k" && ! snoozed; then
      stillkeys+="$k "
      still+="$(grep "^$k|" <<<"$warns") (first seen $(since "$HW_ALERT_DIR/$k"))"$'\n'
      refresh "$HW_ALERT_DIR/$k"
    fi
  done
  if [ -n "$still" ]; then
    notify "Pi hardware warning (still happening)" high "$(format "$still")" "$SNOOZE_ACTION"
    log "reminder: hw still: $stillkeys"
  fi
  if [ -n "$cleared" ]; then
    for k in $cleared; do rm -f "$HW_ALERT_DIR/$k"; done
    log "hw cleared: $(tr '\n' ' ' <<<"$cleared")"
    [ -z "$new_keys" ] && notify "Pi hardware OK again" default "The earlier hardware warning has cleared."
  fi
  printf '%s\n' "$warns" | grep -v '^$' > "$HW_WARN_FILE"

  # Detect restarts (power outage, crash) since the last check.
  local bid; bid=$(cat "$BOOT_ID_SRC" 2>/dev/null)
  if [ -n "$bid" ]; then
    if [ -f "$BOOT_ID_FILE" ] && [ "$(cat "$BOOT_ID_FILE")" != "$bid" ]; then
      if [ -f "$SHUTDOWN_REASON_FILE" ]; then
        notify "Pi back on after emergency shutdown" high "The Pi is running again (started $(uptime -s 2>/dev/null)). It had shut itself down because:
$(format_plain "$(cat "$SHUTDOWN_REASON_FILE")")
  Fix: If you switched your router's DNS to automatic, set it back: log into ${ROUTER_AT} and set the primary DNS to ${PI_AT}. If the cause wasn't fixed, the Pi will shut down again in a few minutes."
        rm -f "$SHUTDOWN_REASON_FILE"
      else
        notify "Pi restarted" default "The Pi rebooted at $(uptime -s 2>/dev/null) (power outage or crash?). It's back up."
      fi
      log "reboot detected"
    fi
    echo "$bid" > "$BOOT_ID_FILE"
  fi
}

hw_summary() {
  local t th pw v rpm used parts=()
  t=$(cpu_temp); [ -n "$t" ] && parts+=("CPU ${t}°C")
  th=$(throttled_hex)
  if [ -n "$th" ]; then (( $((th)) & 0x10001 )) && pw="LOW VOLTAGE seen" || pw="power OK"; parts+=("$pw"); fi
  v=$(input_volts); [ -n "$v" ] && parts+=("${v}V")
  rpm=$(fan_rpm); [ -n "$rpm" ] && parts+=("fan ${rpm} rpm")
  used=$(df -P / 2>/dev/null | awk 'NR==2{print $5}'); [ -n "$used" ] && parts+=("SD ${used} full")
  parts+=("up since $(uptime -s 2>/dev/null)")
  local out; printf -v out '%s, ' "${parts[@]}"; echo "${out%, }"
}

# Point Pi-hole at Unbound (normal) or Cloudflare (backup), then make sure lookups work.
set_upstream() {
  local val="[\"127.0.0.1#${UNBOUND_PORT}\"]"
  [ "$1" = backup ] && val="$BACKUP_DNS"
  pihole-FTL --config dns.upstreams "$val" >/dev/null 2>&1
  sleep 3
  if ! dig +time=3 +tries=2 google.com @127.0.0.1 2>&1 | grep -q 'status: NOERROR'; then
    systemctl restart pihole-FTL; sleep 5
  fi
  log "upstream set to $1 ($val)"
}

do_check() {
  flush_queue
  read_commands
  do_hw
  local problems fails switched_back=""
  problems=$(run_checks)
  fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)

  # On backup DNS and Unbound works again -> switch back automatically.
  if [ -f "$FALLBACK_FILE" ] && ! grep -q '^UNBOUND' <<<"$problems"; then
    set_upstream unbound
    rm -f "$FALLBACK_FILE"
    problems=$(run_checks)
    if grep -q '^UNBOUND' <<<"$problems"; then
      set_upstream backup; stamp "$FALLBACK_FILE"; problems=$(run_checks)
      log "unbound failed again after switch-back, stayed on backup"
    else
      notify "Pi-hole: back on Unbound" default "Unbound is working again. Switched back from the Cloudflare backup automatically."
      switched_back=1
    fi
  fi

  # Unbound failing (not already on backup): restart it once, recheck right away,
  # and switch to Cloudflare in this same check if it's still broken.
  if grep -q '^UNBOUND' <<<"$problems" && [ ! -f "$FALLBACK_FILE" ]; then
    systemctl restart unbound; log "restarted unbound"; sleep 5
    problems=$(run_checks)
    if grep -q '^UNBOUND' <<<"$problems"; then
      set_upstream backup
      stamp "$FALLBACK_FILE"
      problems=$(run_checks)
      notify "Pi-hole: switched to backup DNS" high "Unbound stopped working and a restart didn't fix it. Pi-hole switched to Cloudflare so the house stays online, and will switch back on its own when Unbound recovers.
$(format "$(grep '^UNBOUND' <<<"$problems")")" "$SNOOZE_ACTION"
      log "switched to backup DNS"
    else
      log "unbound restart fixed it"
      [ -z "$problems" ] && notify "Pi-hole: fixed itself" low "Unbound stopped answering and a restart fixed it."
    fi
  fi

  # While on backup, Unbound being down is already handled - remind every REPEAT_HOURS,
  # and otherwise only watch for other problems.
  if [ -f "$FALLBACK_FILE" ]; then
    if due "$FALLBACK_FILE" && ! snoozed; then
      notify "Pi-hole: still on backup DNS" default "Unbound has been down since $(since "$FALLBACK_FILE"). The house is still online through Cloudflare.
$(format "$(grep '^UNBOUND' <<<"$problems")")" "$SNOOZE_ACTION"
      refresh "$FALLBACK_FILE"; log "reminder: still on backup"
    fi
    problems=$(grep -v '^UNBOUND' <<<"$problems")
  fi

  if [ -z "$problems" ]; then
    if [ -n "$switched_back" ]; then
      log "all clear (after switch-back)"
    elif [ -f "$ALERTED_FILE" ]; then
      if [ -f "$FALLBACK_FILE" ]; then
        notify "Pi-hole: working again" default "Pi-hole is working again. Still on the Cloudflare backup until Unbound recovers."
      else
        notify "Pi-hole: all clear" default "Everything is working again."
      fi
      log "all clear"
    elif [ -f "$AUTOFIX_FILE" ]; then
      notify "Pi-hole: fixed itself" low "A problem was found and a service restart fixed it:
$(cat "$AUTOFIX_FILE")"
      log "auto-fix succeeded"
    fi
    rm -f "$ALERTED_FILE" "$AUTOFIX_FILE"
    echo 0 > "$FAILS_FILE"
    return
  fi

  fails=$((fails + 1))
  echo "$fails" > "$FAILS_FILE"
  log "check failed ($fails): $(cut -d'|' -f1 <<<"$problems" | tr '\n' ' ')"

  if [ "$fails" -eq 1 ]; then
    format_plain "$problems" > "$AUTOFIX_FILE"
    auto_fix "$problems"
  elif [ ! -f "$ALERTED_FILE" ]; then
    notify "Pi-hole PROBLEM" high "Failed two checks in a row (a restart didn't fix it):
$(format "$problems")" "$SNOOZE_ACTION"
    stamp "$ALERTED_FILE"
  elif due "$ALERTED_FILE" && ! snoozed; then
    notify "Pi-hole PROBLEM (still happening)" high "Still broken - first seen $(since "$ALERTED_FILE"):
$(format "$problems")" "$SNOOZE_ACTION"
    refresh "$ALERTED_FILE"; log "reminder: problem still happening"
  fi
}

do_summary() {
  flush_queue
  local problems stats="" since total blocked pct
  problems=$(run_checks)
  since=$(( $(date +%s) - 86400 ))
  if command -v pihole-FTL >/dev/null; then
    read -r total blocked < <(pihole-FTL sqlite3 -separator ' ' /etc/pihole/pihole-FTL.db \
      "SELECT COUNT(*), SUM(CASE WHEN status IN (1,4,5,6,7,8,9,10,11,15) THEN 1 ELSE 0 END) FROM queries WHERE timestamp > $since;" 2>/dev/null)
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      pct=$(awk -v b="${blocked:-0}" -v t="$total" 'BEGIN{printf "%.1f", 100*b/t}')
      stats=" Last 24h: $total queries, ${blocked:-0} blocked ($pct%)."
    fi
  fi
  local hw hwwarn
  hw=$(hw_summary)
  hwwarn=$(hw_checks)
  [ -f "$FALLBACK_FILE" ] && problems=$(printf '%s\n%s' "$problems" "BACKUP|Running on the Cloudflare backup (Unbound still down)." | grep -v '^$')
  if [ -z "$problems" ] && [ -z "$hwwarn" ]; then
    notify "Pi-hole OK" low "All checks passing.$stats
Pi: $hw"
  else
    notify "Pi-hole daily: needs attention" default "$( [ -n "$problems" ] && format "$problems")$( [ -n "$problems" ] && [ -n "$hwwarn" ] && echo)$( [ -n "$hwwarn" ] && format "$hwwarn")
$stats
Pi: $hw"
  fi
}

# ---------- Emergency guard (runs every minute) ----------
# Shuts the Pi down cleanly if it's critically hot or the power supply is failing
# for GUARD_MINUTES checks in a row, to protect the hardware and SD card.
do_guard() {
  read_commands
  local t th reasons="" cnt
  t=$(cpu_temp); th=$(throttled_hex)
  [ -n "$t" ] && [ "$t" -ge "$GUARD_HOT" ] && reasons="HOT_CRIT|CPU at ${t}°C - still too hot even after the Pi slowed itself down."
  if [ -n "$th" ] && (( $((th)) & 0x1 )); then
    reasons+="${reasons:+$'\n'}UV_CRIT|Power supply voltage stayed too low for ${GUARD_MINUTES} minutes straight - risk of SD card corruption."
  fi

  if [ -z "$reasons" ]; then
    rm -f "$GUARD_COUNT_FILE"
    return 0
  fi
  cnt=$(( $(cat "$GUARD_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$cnt" > "$GUARD_COUNT_FILE"
  log "guard: critical reading $cnt/$GUARD_MINUTES: $(cut -d'|' -f1 <<<"$reasons" | tr '\n' ' ')"
  [ "$cnt" -lt "$GUARD_MINUTES" ] && return

  echo "$reasons" > "$SHUTDOWN_REASON_FILE"
  rm -f "$GUARD_COUNT_FILE"
  notify "Pi SHUTTING DOWN to protect itself" urgent "The Pi is shutting down now. House internet will stop working until it's back.
FIRST, get the house online: log into your router at ${ROUTER_AT} and set its DNS back to automatic (your internet provider's DNS).
$(format "$reasons")
The Pi stays off until you unplug it and plug it back in."
  log "guard: SHUTTING DOWN"
  sync
  systemctl poweroff
}

case "$1" in
  check) do_check ;;
  summary) do_summary ;;
  guard) do_guard ;;
  test) notify "Pi-hole watchdog" default "Test message - alerts are reaching your phone." && echo "Sent (or queued if offline)."
        echo "Current checks:"; p=$(run_checks); [ -z "$p" ] && echo "  all passing" || format "$p" ;;
  *) echo "Usage: $0 check|summary|guard|test"; exit 1 ;;
esac
WATCHDOG_EOF
sudo bash <<'SETUP_EOF'
chmod +x /usr/local/bin/pihole-watchdog.sh
CONF="${CONF:-/etc/pihole-watchdog.conf}"
if [ ! -f "$CONF" ]; then
  TOPIC="pihole-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
  ROUTER_IP=$(ip route | awk '/^default/{print $3; exit}')
  PI_IP=$(hostname -I | awk '{print $1}')
  USE_UNBOUND=0
  dig +time=3 +tries=1 google.com @127.0.0.1 -p 5335 2>/dev/null | grep -q 'status: NOERROR' && USE_UNBOUND=1
  cat > "$CONF" <<EOF
# Pi-hole watchdog settings. Edit with: sudo nano $CONF
# Changes apply on the next check - no restart needed.
TOPIC="$TOPIC"
ROUTER_IP="$ROUTER_IP"
PI_IP="$PI_IP"
USE_UNBOUND=$USE_UNBOUND
UNBOUND_PORT=5335
BACKUP_DNS='["1.1.1.1","1.0.0.1"]'
# Optional - remove the # to change a default:
#TEMP_WARN=75       # warn at this CPU temperature (C)
#GUARD_HOT=85       # emergency shutdown at this CPU temperature (C)
#GUARD_MINUTES=3    # minutes in a row before an emergency shutdown
#DISK_WARN=90       # warn when the SD card is this % full
#MEM_WARN=10        # warn when free memory drops below this %
#REPEAT_HOURS=4     # repeat an alert every N hours while a problem lasts
#SNOOZE_HOURS=3     # how long the Snooze button silences repeats
EOF
  echo "Created $CONF"
else
  echo "Keeping your existing settings in $CONF"
fi
printf '*/30 * * * * root /usr/local/bin/pihole-watchdog.sh check\n30 5 * * * root /usr/local/bin/pihole-watchdog.sh summary\n* * * * * root /usr/local/bin/pihole-watchdog.sh guard\n' > "${CRON_FILE:-/etc/cron.d/pihole-watchdog}"
. "$CONF"
echo
echo "=================================================="
echo "  Your ntfy channel name:  $TOPIC"
echo "  Router: $ROUTER_IP    This Pi: $PI_IP    Unbound: $([ "$USE_UNBOUND" = 1 ] && echo yes || echo no)"
echo "=================================================="
if grep -qE "^nameserver (127\.|::1|${PI_IP//./\\.}\$|${ROUTER_IP//./\\.}\$)" "${RESOLV:-/etc/resolv.conf}"; then
  echo "NOTE: this Pi looks up names through itself or the router."
  echo "      See 'Before you start' in the guide so it can recover after a power outage."
fi
echo "Next: subscribe to the channel above in the ntfy app, then run:"
echo "      sudo pihole-watchdog.sh test"
SETUP_EOF

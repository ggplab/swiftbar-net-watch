#!/bin/bash
# <bitbar.title>net-watch</bitbar.title>
# <bitbar.version>v1.0.0</bitbar.version>
# <bitbar.author>BuildnWrite</bitbar.author>
# <bitbar.author.github>ggplab</bitbar.author.github>
# <bitbar.desc>공유기와 자주 쓰는 서버의 지연과 손실을 메뉴바에 띄우고, 끊기면 알린다.</bitbar.desc>
# <bitbar.dependencies>bash,ping</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/ggplab/swiftbar-net-watch</bitbar.abouturl>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# SwiftBar가 파일명의 30s 대로 30초마다 실행한다.
# 설정은 ~/.config/net-watch/config 에 둔다(없으면 아래 기본값). 이 파일을 고치지 않아도 된다.
# 단독 시험: NET_WATCH_NO_NOTIFY=1 bash net-watch.30s.sh

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ---- 기본값 (설정 파일에서 덮어쓴다) ----
HOSTS=(github.com api.anthropic.com)   # 외부 감시 대상
PING_COUNT=5
EXT_WARN_MS=150      # 외부 평균 지연이 이 값을 넘으면 노랑
GW_WARN_MS=30        # 공유기 평균 지연이 이 값을 넘으면 노랑
RED_LOSS=50          # 손실률이 이 값 이상이면 빨강
RED_STREAK=2         # 빨강이 연속 이 횟수면 알림 (30초 간격이면 약 1분)
NOTIFY=1             # 0이면 알림을 보내지 않는다
DIAG_SCRIPT=""       # 메뉴에서 실행할 진단 스크립트 경로(선택)

CONFIG="${NET_WATCH_CONFIG:-$HOME/.config/net-watch/config}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

STATE_DIR="$HOME/Library/Caches/net-watch"
STATE_FILE="$STATE_DIR/state"
mkdir -p "$STATE_DIR"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP"/*; rmdir "$TMP"' EXIT

ROUTE="$(route -n get default 2>/dev/null)"
GW="$(printf '%s\n' "$ROUTE" | awk '/gateway:/{print $2}')"
IFACE="$(printf '%s\n' "$ROUTE" | awk '/interface:/{print $2}')"

# ping 한 번 돌려 "손실률 평균ms" 를 파일에 쓴다. 응답이 하나도 없으면 평균은 -.
probe() {
  local host="$1" out="$2" raw loss avg
  raw="$(ping -c "$PING_COUNT" -i 0.2 -t 4 "$host" 2>&1)"
  loss="$(printf '%s\n' "$raw" | awk -F', ' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){split($i,a,"%"); print a[1]}}')"
  avg="$(printf '%s\n' "$raw" | awk -F'/' '/round-trip/{print $5}')"
  [ -z "$loss" ] && loss=100          # 이름 풀이 실패 등
  [ -z "$avg" ] && avg="-"
  printf '%s %s\n' "$loss" "$avg" > "$out"
}

# 0=초록 1=노랑 2=빨강
grade() {
  local loss="$1" avg="$2" warn="$3"
  local l=${loss%.*}
  if [ "$avg" = "-" ] || [ "$l" -ge "$RED_LOSS" ]; then echo 2; return; fi
  if [ "$l" -gt 0 ] || awk -v a="$avg" -v w="$warn" 'BEGIN{exit !(a>w)}'; then echo 1; return; fi
  echo 0
}

dot() { case "$1" in 0) echo "🟢";; 1) echo "🟡";; *) echo "🔴";; esac; }
color() { case "$1" in 0) echo "#2e9e44";; 1) echo "#c98a00";; *) echo "#d0342c";; esac; }
fmt_ms() { [ "$1" = "-" ] && echo "응답 없음" || printf '%.0fms' "$1"; }

# 모든 바이트를 %XX로 바꾼다(한글 UTF-8 포함)
urlencode() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'
}

# SwiftBar 자체 알림으로 보낸다
notify() {
  [ "$NOTIFY" = "1" ] || return
  [ "${NET_WATCH_NO_NOTIFY:-0}" = "1" ] && return
  open -g "swiftbar://notify?plugin=net-watch&title=$(urlencode "$1")&body=$(urlencode "$2")"
}

footer() {
  echo "---"
  echo "${IFACE:-인터페이스 없음}, $(date '+%H:%M:%S') 측정 | size=11"
  echo "지금 다시 재기 | refresh=true"
  if [ -n "$DIAG_SCRIPT" ] && [ -f "$DIAG_SCRIPT" ]; then
    echo "진단 스크립트 실행 | bash=/bin/bash param1=$DIAG_SCRIPT terminal=true"
  fi
  [ -f "$CONFIG" ] && echo "설정 파일 열기 | bash=/usr/bin/open param1=-t param2=$CONFIG terminal=false"
}

# 이전 상태: 연속 빨강 횟수, 알림을 이미 보냈는지
streak=0; alerted=0
[ -f "$STATE_FILE" ] && read -r streak alerted < "$STATE_FILE"

# 기본 경로가 아예 없으면 오프라인
if [ -z "$IFACE" ]; then
  streak=$((streak + 1))
  if [ "$streak" -ge "$RED_STREAK" ] && [ "$alerted" = "0" ]; then
    notify "네트워크 끊김" "연결된 네트워크가 없습니다."
    alerted=1
  fi
  echo "$streak $alerted" > "$STATE_FILE"
  echo "🔴 오프라인"
  echo "---"
  echo "연결된 네트워크가 없습니다 | color=$(color 2)"
  footer
  exit 0
fi

# 병렬 측정. VPN처럼 기본 경로에 게이트웨이가 없으면 공유기 측정은 건너뛴다.
[ -n "$GW" ] && probe "$GW" "$TMP/gw" &
for i in "${!HOSTS[@]}"; do probe "${HOSTS[$i]}" "$TMP/h$i" & done
wait

ext_worst=0; ext_max_avg=0; ext_max_loss=0
lines=()
for i in "${!HOSTS[@]}"; do
  read -r loss avg < "$TMP/h$i"
  g=$(grade "$loss" "$avg" "$EXT_WARN_MS")
  [ "$g" -gt "$ext_worst" ] && ext_worst=$g
  [ "$avg" != "-" ] && ext_max_avg=$(awk -v a="$avg" -v b="$ext_max_avg" 'BEGIN{print (a>b)?a:b}')
  ext_max_loss=$(awk -v a="${loss%.*}" -v b="$ext_max_loss" 'BEGIN{print (a>b)?a:b}')
  lines+=("$(dot "$g") ${HOSTS[$i]}  $(fmt_ms "$avg"), 손실 ${loss%.*}% | color=$(color "$g") font=Menlo size=12")
done

gw_grade=0; gw_line=""
if [ -n "$GW" ]; then
  read -r gw_loss gw_avg < "$TMP/gw"
  gw_grade=$(grade "$gw_loss" "$gw_avg" "$GW_WARN_MS")
  gw_line="$(dot "$gw_grade") 공유기 $GW  $(fmt_ms "$gw_avg"), 손실 ${gw_loss%.*}%"
  # 공유기가 ping에 전혀 답하지 않는데 외부는 멀쩡하면, 공유기가 ping을 막은 것으로 본다(호텔, 행사장 와이파이에 흔하다)
  if [ "$gw_avg" = "-" ] && [ "$ext_worst" -lt 2 ]; then
    gw_grade=0
    gw_line="⚪ 공유기 $GW  ping 응답 안 함(차단된 것으로 보고 판정에서 뺌)"
  fi
  gw_line="$gw_line | color=$(color "$gw_grade") font=Menlo size=12"
else
  gw_line="⚪ 공유기 측정 생략(VPN 등 게이트웨이 없는 경로) | font=Menlo size=12"
fi

overall=$ext_worst
[ "$gw_grade" -gt "$overall" ] && overall=$gw_grade

# 어느 구간이 문제인지: 공유기가 나쁘면 와이파이, 공유기는 괜찮은데 외부가 나쁘면 회선이나 상대 서버
if [ "$overall" = "0" ]; then
  where="정상"
elif [ "$gw_grade" -ge 1 ]; then
  where="와이파이 구간 문제 (공유기까지가 느리거나 끊김)"
elif [ -n "$GW" ]; then
  where="회선이나 외부 구간 문제 (공유기까지는 정상)"
else
  where="외부 구간 문제"
fi

# 메뉴바 제목
if [ "$overall" = "2" ]; then
  if [ "$ext_max_loss" -ge 100 ] && [ "$gw_grade" = "2" ]; then title="🔴 끊김"
  else title="🔴 손실 ${ext_max_loss}%"; fi
elif [ "$overall" = "1" ] && [ "$ext_max_loss" -gt 0 ]; then
  title="🟡 손실 ${ext_max_loss}%"
else
  title="$(dot "$overall") $(printf '%.0f' "$ext_max_avg")ms"
fi

# 알림: 빨강이 RED_STREAK 회 이어지면 한 번, 회복하면 한 번
if [ "$overall" = "2" ]; then
  streak=$((streak + 1))
  if [ "$streak" -ge "$RED_STREAK" ] && [ "$alerted" = "0" ]; then
    notify "네트워크 문제" "$where"
    alerted=1
  fi
else
  if [ "$alerted" = "1" ]; then notify "네트워크 회복" "지금은 $(dot "$overall") 상태입니다."; fi
  streak=0; alerted=0
fi
echo "$streak $alerted" > "$STATE_FILE"

echo "$title"
echo "---"
echo "$where | color=$(color "$overall")"
echo "---"
echo "$gw_line"
for l in "${lines[@]}"; do echo "$l"; done
footer

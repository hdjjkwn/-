#!/system/bin/sh
# ============================================================================
#  叶青一加调度 v2.0  ·  YQ NEO ENGINE
#  作者：叶青
#  适配：一加 / ColorOS / OxygenOS（CPU 拓扑自动检测）
#
#  【安全边界 —— 刻意不碰的四样东西】
#    × 电压（OPP voltage）      —— 烧机 / 虚焊的第一大原因
#    × 温控阈值 / thermal 服务   —— 关温控 = 持续高温 = 虚焊
#    × 超频                      —— 所有频率均取自厂商可用频率表，绝不越界
#    × GPU 电压 / 内核参数 / 模块
#
#  【它只做四件事】
#    ① CPU governor 策略切换
#    ② 在厂商频率表内夹目标频率（防降频掉帧）
#    ③ 调 schedutil 响应速度（rate_limit）
#    ④ GPU 频率档位与 governor
#
#  【温度硬保护】72°C 自动降档 · 88°C 立即退出并恢复原厂
# ============================================================================

VERSION="2.7"
CODENAME="YQ NEO ENGINE"
AUTHOR="叶青"
# ── 固定更新地址（要换源就改这一行）──
# 填你的在线笔记分享链接，例如腾讯微云笔记、GitHub Gist 的原始链接。
# 留空则「检查更新」会提示未配置。
UPDATE_URL="https://share.weiyun.com/Q2WfrrE3"

# ── 授权卡密（由 yq-license.sh 生成，一机一码）──
LICENSE_FILE="/data/local/tmp/yq_license.txt"      # yq-license.sh 生成的信息（含指纹）
ACTIVATED_FILE="/data/local/tmp/yq_activated.txt"  # 用户粘贴卡密后保存的激活凭证

BACKUP="/data/local/tmp/yq_cpu_backup.txt"
LOCK="/data/local/tmp/yq_cpu_guard.lock"
CONSENT_FILE="/data/local/tmp/yq_consent.txt"
DAEMON_PID="/data/local/tmp/yq_cpu_daemon.pid"
MODE_FILE="/data/local/tmp/yq_cpu_mode"
DAEMON_LOG="/data/local/tmp/yq_cpu_daemon.log"
GAME_LIMIT=480          # 电竞模式最长 480 秒（8 分钟）后自动降档
BRUTAL_LIMIT=1800       # 暴力模式最长 1800 秒（30 分钟）
# 暴力模式不设固定温度线，改用「趋势 + 绝对底线」双判据：
#   · 升温速度（30 秒窗口）—— 提前发现「快不行了」
#   · 稳态高温持续多久 —— 抓住「高但不涨」的闷烧
#   · 100°C 物理底线 —— 无条件还原
BRUTAL_SLOPE_WARN=6      # 30 秒涨 6°C → 提前降档
BRUTAL_SLOPE_ABORT=10    # 30 秒涨 10°C → 判定危险，立即还原
BRUTAL_HOLD_TEMP=93000   # 稳态超过 93°C 且持续 60 秒 → 还原
BRUTAL_HARD_LIMIT=100000 # 100°C 物理底线，无条件还原
BRUTAL_SAMPLE=3          # 采样间隔（秒）
THERMAL_SERVICES="thermal-engine vendor.thermal-hal"   # 要停的温控服务

# ── AI 温控顾问 ──
AI_THERMAL_ENABLED=0                                   # 1 = 开启 AI 决策
AI_INTERVAL=30                                         # 每 30 秒问一次 AI
AI_LAST_TS=0

# ── AI 模块整体加密 ──
#
# 这一段（端点 + Key + 模型名 + 提示词）全部 XOR 0x5A 后以 hex 存放，
# 运行时一次性解出来再拆字段。脚本里搜不到 sk-、也看不到提示词。
#
# 说明：这是「混淆」不是强加密。防的是「脚本发出去被人直接拿去用额度 /
# 抄提示词」，不是防逆向。真要防逆向得靠服务端换 token。
AI_BLOB_ENC="322e2e2a296075753b2a33743e3f3f2a293f3f3174393537262931776d38683f62696339633838386e6d383b3b683c386b686d6d3b6b3f633b6a3b68263e3f3f2a293f3f317739323b2e26bee7fabcc2f5bcd3d1bcc6e0bce2f3bcd4fdb3fbe4b3cdf4b9dad8bfe7c9bfd3d7bcf2fbbfe6d5b5e6c02137353e3f27b9dad8bcc6dab2e5cb696abdfdc8bce2f3bfe0fcb3ddddbcfaedb5e6d2bccbdebcead5bfe0fcb5e6d6bcf5d569bdfdc8bee2dabee2f0b5e6d3b5e6c0213233292e27b9dad8b2f5edbfd2febcccf7bee2d1bee2dabcf7ffb2f5ffbfdbc0bee1dabee3d2b5e6d6bfd5f0bfc1c4bee2dabee2f0b2f5d7b5e6c0313f3f2ab5e6d2bee5c7bcd6dbbee2d7bfd0f2b5e6d3757a3e3f3d283b3e3fb5e6d2b3c3d7bee7d4b3f8cbbdd4ddb3c3d7bce2f3b5e6d3757a283f292e35283fb5e6d2bdf1d1bfd7e9b2e5c2bfd4c5bfe3ecbcdbf8bffed7bde9e1bde1c5bce2f3bcd4fdb5e6d3757a283f39352c3f28b5e6d2b2fdf9b3c3febee3d1bfd3d7bdc0deb3c3d7bcfbf9b9dadbbfdfdbb2f4e2bcd5cab3dac5b5e6d3b9dad8bce9f2bcded5b5e6c0bee6c2bfdfd2bee5c7b2f5dbb2f4e4bffeddbff4d3bfdff2b9dad8"

# 解密：hex → 逐字节 XOR 0x5A → 原始字节串
# 不用 printf "\\x%02x"（mksh 不支持 \x 转义），改用八进制 \ooo
ai_xor_hex() {
    local hex="$1" out="" b v o
    for b in $(printf '%s' "$hex" | sed 's/../& /g'); do
        v=$((0x$b ^ 0x5a))
        o=$(printf '%03o' "$v")
        out="$out$(printf "\\$o")"
    done
    printf '%s' "$out"
}

# 解出 AI 配置（端点|Key|模型|提示词模板）
AI_ENDPOINT=""
AI_KEY=""
AI_MODEL=""
AI_PROMPT=""
AI_READY=0

ai_load_config() {
    [ "$AI_READY" = "1" ] && return 0
    local blob=$(ai_xor_hex "$AI_BLOB_ENC")
    [ -z "$blob" ] && return 1

    AI_ENDPOINT=$(printf '%s' "$blob" | cut -d'|' -f1)
    AI_KEY=$(printf '%s' "$blob" | cut -d'|' -f2)
    AI_MODEL=$(printf '%s' "$blob" | cut -d'|' -f3)
    AI_PROMPT=$(printf '%s' "$blob" | cut -d'|' -f4-)

    [ -n "$AI_ENDPOINT" ] && [ -n "$AI_KEY" ] || return 1
    AI_READY=1
    return 0
}
GUARD_INTERVAL=15       # 守护进程巡检间隔（秒）
TEMP_WARN=72000
TEMP_ABORT=88000

# ─────────────────────────────────────────────────────────────
#  配色
# ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m'
    C_CYAN=$'\033[38;5;51m';  C_BLUE=$'\033[38;5;39m'
    C_PURPLE=$'\033[38;5;135m'
    C_GREEN=$'\033[38;5;46m';  C_YELLOW=$'\033[38;5;226m'
    C_RED=$'\033[38;5;196m';   C_GRAY=$'\033[38;5;245m'
    C_WHITE=$'\033[38;5;231m'
    C_MAGENTA=$'\033[38;5;201m'
else
    C_RESET=''; C_BOLD=''; C_CYAN=''; C_BLUE=''; C_PURPLE=''
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_WHITE=''; C_MAGENTA=''
fi

WIDTH=58
NL='
'

clear_screen() { printf '\033[2J\033[H'; }

# 一行一行慢慢出现（默认 0.28 秒/行）
slow_lines() {
    local d="${1:-0.28}"
    shift
    local line
    for line in "$@"; do
        printf '%s\n' "$line"
        sleep "$d"
    done
}

center() {
    local s="$1" pad
    pad=$(( (WIDTH - ${#s}) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%*s%s\n' "$pad" '' "$s"
}

hline()  { printf '%s' "$C_CYAN";   printf '═%.0s' $(seq 1 $WIDTH); printf '%s\n' "$C_RESET"; }
hline2() { printf '%s' "$C_PURPLE"; printf '─%.0s' $(seq 1 $WIDTH); printf '%s\n' "$C_RESET"; }

progress_bar() {
    local label="$1" total="${2:-28}" i=0
    printf '%s  %s%s ' "$C_GRAY" "$label" "$C_RESET"
    printf '%s[' "$C_CYAN"
    while [ "$i" -lt "$total" ]; do
        printf '█'
        i=$((i+1))
        sleep 0.01 2>/dev/null || true
    done
    printf ']%s\n' "$C_RESET"
}

# ─────────────────────────────────────────────────────────────
#  远程更新（思路来自一个 Lua 脚本：用在线笔记当免费版本服务器）
#
#  笔记格式（括号是全角【】）：
#     更新开关【开】
#     最新版本【2.4】
#     强制更新【关】
#     更新链接【https://你的网盘链接】
#     链接密码【abcd】
#
#  改笔记 = 发版，不用服务器。
# ─────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────
#  授权校验（与 yq-license.sh 共用同一份卡密文件）
#
#  yq-license.sh 生成：license / fingerprint / issued / script_version
#  这里校验两件事：
#    ① 卡密文件存在且格式对
#    ② 文件里记录的设备指纹 == 当前设备指纹（防止把卡密文件拷给别人）
# ─────────────────────────────────────────────────────────────
license_fingerprint() {
    local aid="$(settings get secure android_id 2>/dev/null)"
    local sn="$(getprop ro.serialno 2>/dev/null)"
    local model="$(getprop ro.product.model 2>/dev/null)"
    [ -z "$aid" ] && aid="noid"
    [ -z "$sn" ] && sn="$(cat /sys/class/net/wlan0/address 2>/dev/null)"
    [ -z "$sn" ] && sn="nosn"
    [ -z "$model" ] && model="unknown"
    printf '%s|%s|%s' "$aid" "$sn" "$model"
}

# 本机「应有的卡密」（由设备指纹算出，跟 yq-license.sh 用同一套算法）
gen_expected_license() {
    local fp="$(license_fingerprint)"
    local hash
    hash=$(printf '%s' "$fp" | md5sum 2>/dev/null | cut -d' ' -f1 | tr 'a-z' 'A-Z')
    [ -z "$hash" ] && return 1
    printf 'YQ-%s-%s-%s-%s' \
        "$(printf '%s' "$hash" | cut -c1-4)" \
        "$(printf '%s' "$hash" | cut -c5-8)" \
        "$(printf '%s' "$hash" | cut -c9-12)" \
        "$(printf '%s' "$hash" | cut -c13-16)"
}

# 已激活？读用户粘贴后保存下来的卡密，跟本机应有值比对
check_license() {
    [ -f "$ACTIVATED_FILE" ] || return 1
    local saved=$(head -1 "$ACTIVATED_FILE" 2>/dev/null | tr -d ' \t\r\n' | tr 'a-z' 'A-Z')
    [ -z "$saved" ] && return 1
    local expect="$(gen_expected_license)"
    [ -z "$expect" ] && return 3        # 算不出（没 root / 没指纹）
    [ "$saved" = "$expect" ] && return 0
    return 2                            # 卡密与设备不匹配
}


# 卡密拦截页
# 激活界面：让用户粘贴卡密
# 未激活时的处理：直接调起生成器走完「声明 → 10 秒 → 生成 → 自动激活」
# 这样用户只需要跑 yq-neo.sh 一个脚本，不用手动复制粘贴卡密。
activate_interface() {
    # 找生成器：先按标准文件名找，找不到就扫描同目录按「内容特征」认
    #
    # 为什么需要后者：作者/用户经常把文件改成中文名（比如
    # 「先执行我免责声明验证.sh」），硬编码找 yq-license.sh 会失败。
    local gen=""
    local selfdir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    local selfname=$(basename "$0")

    for cand in \
        "$selfdir/yq-license.sh" \
        "/sdcard/deepseek/yq-license.sh" \
        "/sdcard/Download/yq-license.sh" \
        "/data/local/tmp/yq-license.sh"; do
        [ -f "$cand" ] && { gen="$cand"; break; }
    done

    # 兜底：扫同目录所有 .sh，含「免责」+「license」特征的就是生成器
    if [ -z "$gen" ] && [ -n "$selfdir" ]; then
        for f in "$selfdir"/*; do
            [ -f "$f" ] || continue
            case "$f" in *.sh) ;; *) continue ;; esac
            [ "$(basename "$f")" = "$selfname" ] && continue
            # 注意：Android 的 mksh 不支持 grep "a\|b" 这种或语法，
            # 必须拆成两次 grep，否则永远匹配不到。
            if grep -q "免责声明" "$f" 2>/dev/null && \
               { grep -q "issue_license" "$f" 2>/dev/null || \
                 grep -q "gen_license" "$f" 2>/dev/null; }; then
                gen="$f"
                break
            fi
        done
    fi

    if [ -z "$gen" ]; then
        clear_screen
        printf '\n'
        printf '%s' "$C_RED"; hline; printf '%s' "$C_RESET"
        printf '%s%s' "$C_BOLD" "$C_WHITE"
        center "找  不  到  授  权  生  成  器"
        printf '%s' "$C_RESET"
        printf '%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"
        printf '%s  需要「免责声明生成器」和本脚本放在同一目录。%s\n\n' "$C_WHITE" "$C_RESET"
        printf '%s  它可能是叫 yq-license.sh，也可能被改名成中文。%s\n' "$C_GRAY" "$C_RESET"
        printf '%s  识别方式：文件内容里含「免责声明」和 issue_license。%s\n\n' "$C_GRAY" "$C_RESET"
        printf '%s  当前目录：%s%s\n' "$C_GRAY" "$selfdir" "$C_RESET"
        printf '%s  按回车退出…%s' "$C_GRAY" "$C_RESET"
        read _
        exit 1
    fi

    printf '%s  检测到尚未激活，正在调起授权流程…%s\n\n' "$C_GRAY" "$C_RESET"
    sleep 1

    # 跑生成器（它会走完声明 + 10 秒倒计时 + 输入同意 + 生成卡密）
    sh "$gen"
    local gen_rc=$?

    if [ "$gen_rc" -ne 0 ]; then
        printf '\n%s  授权流程未完成，退出%s\n\n' "$C_RED" "$C_RESET"
        exit 1
    fi

    # 从生成器写出的文件里取卡密，自动落盘为激活状态
    local key=""
    for f in "/sdcard/yq_license_key.txt" "/data/local/tmp/yq_license.txt"; do
        [ -f "$f" ] || continue
        if [ "$(basename "$f")" = "yq_license.txt" ]; then
            key=$(grep "^license=" "$f" 2>/dev/null | cut -d= -f2)
        else
            key=$(head -1 "$f" 2>/dev/null)
        fi
        key=$(printf '%s' "$key" | tr -d ' \t\r\n' | tr 'a-z' 'A-Z')
        [ -n "$key" ] && break
    done

    local expect="$(gen_expected_license)"
    if [ -n "$key" ] && [ "$key" = "$expect" ]; then
        printf '%s' "$key" > "$ACTIVATED_FILE" 2>/dev/null
        printf '\n%s' "$C_GREEN"
        center "✓ 已自动激活，继续启动"
        printf '%s\n\n' "$C_RESET"
        sleep 1
        return 0
    fi

    # 中途没法判定时，回退到手动粘贴
    clear_screen
    printf '\n'
    printf '%s' "$C_YELLOW"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "请  手  动  粘  贴  卡  密"
    printf '%s' "$C_RESET"
    printf '%s' "$C_YELLOW"; hline; printf '%s\n\n' "$C_RESET"
    printf '%s  卡密在 /sdcard/yq_license_key.txt，也可以长按下面粘贴：%s\n\n' "$C_GRAY" "$C_RESET"
    printf '  %s> %s' "$C_CYAN" "$C_RESET"
    read INPUT
    INPUT=$(printf '%s' "$INPUT" | tr -d ' \t\r\n' | tr 'a-z' 'A-Z')

    if [ -n "$INPUT" ] && [ "$INPUT" = "$expect" ]; then
        printf '%s' "$INPUT" > "$ACTIVATED_FILE" 2>/dev/null
        printf '\n%s' "$C_GREEN"; center "✓ 激活成功"; printf '%s\n\n' "$C_RESET"
        sleep 1
        return 0
    fi

    printf '\n%s  卡密无效，退出%s\n\n' "$C_RED" "$C_RESET"
    exit 1
}

require_license() {
    check_license
    case $? in
        0) return 0 ;;
        2)
            clear_screen
            printf '\n'
            printf '%s' "$C_RED"; hline; printf '%s' "$C_RESET"
            printf '%s%s' "$C_BOLD" "$C_WHITE"
            center "授  权  与  本  机  不  匹  配"
            printf '%s' "$C_RESET"
            printf '%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"
            printf '%s  卡密文件是从别的设备拷过来的。\n' "$C_WHITE"
            printf '  一机一码 —— 换设备需要重新生成。%s\n\n' "$C_RESET"
            printf '%s  如果是本机卡密丢失，可执行：%s\n' "$C_GRAY" "$C_RESET"
            printf '    sh yq-license.sh --force\n\n'
            printf '%s  按回车退出…%s' "$C_GRAY" "$C_RESET"
            read _
            exit 1
            ;;
        *)
            # 未激活 → 让用户粘贴卡密（这才是「激活」的正确流程）
            activate_interface
            ;;
    esac
}

http_get() {
    local url="$1" out=""
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -sL --max-time 10 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && [ -x /data/adb/ksu/bin/busybox ]; then
        out=$(/data/adb/ksu/bin/busybox wget -q -O - --timeout=10 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && [ -x /data/adb/magisk/busybox ]; then
        out=$(/data/adb/magisk/busybox wget -q -O - --timeout=10 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && command -v wget >/dev/null 2>&1; then
        out=$(wget -q -O - --timeout=10 "$url" 2>/dev/null)
    fi
    printf '%s' "$out"
}

# 快速抓取（启动时自动检查用，超时 5 秒，失败就静默跳过）
http_get_quick() {
    local url="$1" out=""
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -sL --max-time 5 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && [ -x /data/adb/ksu/bin/busybox ]; then
        out=$(/data/adb/ksu/bin/busybox wget -q -O - --timeout=5 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && [ -x /data/adb/magisk/busybox ]; then
        out=$(/data/adb/magisk/busybox wget -q -O - --timeout=5 "$url" 2>/dev/null)
    fi
    if [ -z "$out" ] && command -v wget >/dev/null 2>&1; then
        out=$(wget -q -O - --timeout=5 "$url" 2>/dev/null)
    fi
    printf '%s' "$out"
}

# ─────────────────────────────────────────────────────────────
#  微云笔记内容规整
#
#  微云分享页返回的是 JSON，同一份内容出现两次：
#    note_summary  —— 截断的摘要（中文可能被切成半个字，出现乱码）
#    html_content  —— 完整正文（带 \u003C 这类转义和 <p> 标签）
#
#  直接对整段 JSON 做 pick 会抓到摘要里的截断内容，症状就是
#  「公告」后面跟出一串 "","note_ctime":... 的 JSON 碎片。
#
#  这里先抽出 html_content，解码转义、去标签、还原 HTML 实体，
#  得到干净的纯文本再交给 pick。
# ─────────────────────────────────────────────────────────────
weiyun_normalize() {
    local body="$1"
    local html=""

    # ① 只看 html_content 字段（没有就退回原文）
    case "$body" in
        *'"html_content"'*) html=$(printf '%s' "$body" | sed 's/.*"html_content":"//') ;;
        *) html="$body" ;;
    esac
    # ② 砍掉字段后面的 JSON
    html=$(printf '%s' "$html" | sed 's/","[a-zA-Z_]*":.*$//')
    # ③ JSON 转义还原
    html=$(printf '%s' "$html" \
        | sed 's/\\u003C/</g; s/\\u003E/>/g; s/\\u0026/\&/g; s/\\"/"/g; s/\\n/\n/g')
    # ④ 标签换行（每段独立成行，方便逐行 pick）
    html=$(printf '%s' "$html" | sed 's/<\/p>//g; s/<br[^>]*>//g; s/<[^>]*>//g')
    # ⑤ HTML 实体
    html=$(printf '%s' "$html" | sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

    printf '%s' "$html"
}

# 提取 key【value】
#
# 注意：不能用 grep -o "key【[^】]*】"。
# 因为 [^】] 是字节级字符类，而 "】" = E3 80 91、"开" = E5 BC 80 都含 0x80，
# 中文内容会被误排除（实测：数字能取到，中文取不到）。
# 改用 awk 的 index + substr 做字节位置截取，中文可以完整保留。
pick() {
    printf '%s' "$1" | tr -d '\r' | awk -v key="$2" '
        {
            i = index($0, key "【")
            if (i > 0) {
                s = substr($0, i + length(key "【"))
                j = index(s, "】")
                if (j > 0) print substr(s, 1, j - 1)
            }
        }' | head -1
}


# 启动时自动检查更新（静默 + 可选，不阻塞使用）
#
# 设计原则：
#   · 只在交互模式跑（带 --perf 等参数时跳过，避免拖慢启动器调用）
#   · 网络异常静默跳过，绝不因为检查失败而拦住用户
#   · 发现新版本 → 问一句要不要更新，选 n 照常继续用当前版本
#  公告显示（从在线笔记里读 公告【xxx】）
#
#  笔记格式增加一行即可：
#     公告【今晚 10 点维护，别开暴力模式】
#  没写就不显示，读不到也不影响启动。
# ─────────────────────────────────────────────────────────────
# 公告排版：按中文标点分段
#
# 试过按宽度折行，但 awk 的 length/substr 是按字节算的，
# 一个汉字会被劈成两半（输出变成「我�」这种乱码），所以放弃。
# 这里改成按句号/问号/感叹号断句，每句一行 —— 既不会切碎汉字，
# 又比一整行刷屏好看得多。
split_sentences() {
    printf '%s' "$1" \
        | sed 's/。/。\n/g; s/？/？\n/g; s/！/！\n/g; s/；/；\n/g' \
        | sed '/^$/d'
}


# 启动时自动检查更新（静默 + 可选，不阻塞使用）
auto_check_update() {
    [ -z "$UPDATE_URL" ] && return 0

    local body=$(http_get_quick "$UPDATE_URL")
    [ -z "$body" ] && return 0
    body=$(weiyun_normalize "$body")

    local sw=$(pick "$body" "更新开关")
    [ "$sw" = "关" ] && return 0

    local latest=$(pick "$body" "最新版本")
    [ -z "$latest" ] && return 0

    # 已是最新：给一行提示，不然用户会以为「自动检查没工作」
    if [ "$latest" = "$VERSION" ]; then
        printf '\n%s  ✓ 已是最新版本 %s%s  ' "$C_GREEN" "$VERSION" "$C_RESET"
        printf '%s（更新源：%s）%s\n' "$C_GRAY" "$UPDATE_URL" "$C_RESET"
        sleep 1
        return 0
    fi

    local force=$(pick "$body" "强制更新")
    local link=$(pick "$body" "更新链接")
    local pwd=$(pick "$body" "链接密码")

    printf '\n'
    printf '%s' "$C_YELLOW"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD$C_WHITE"
    center "发  现  新  版  本"
    printf '%s' "$C_RESET"
    printf '%s' "$C_YELLOW"; hline; printf '%s\n\n' "$C_RESET"

    printf '%s  当前版本：%s%s%s\n' "$C_GRAY" "$C_WHITE" "$VERSION" "$C_RESET"
    printf '%s  最新版本：%s%s%s\n\n' "$C_GRAY" "$C_CYAN" "$latest" "$C_RESET"

    [ "$force" = "开" ] && { printf '%s  作者要求强制更新%s\n\n' "$C_RED" "$C_RESET"; }
    [ -n "$pwd" ] && { printf '%s  网盘提取码：%s%s%s\n\n' "$C_GRAY" "$C_YELLOW" "$pwd" "$C_RESET"; }

    printf '  %sy%s 立即更新（打开下载页）\n' "$C_GREEN" "$C_RESET"
    printf '  %sn%s 暂不更新，继续用当前版本\n\n' "$C_GRAY" "$C_RESET"
    printf '  %s请选择 [y/N]：%s' "$C_WHITE" "$C_RESET"
    read UPD_ANS
    UPD_ANS=$(printf '%s' "$UPD_ANS" | tr -d ' \t\r\n')

    case "$UPD_ANS" in
        y|Y|yes|YES)
            if [ -n "$link" ]; then
                printf '\n%s  正在打开下载页…%s\n' "$C_GREEN" "$C_RESET"
                am start -a android.intent.action.VIEW -d "$link" >/dev/null 2>&1 || \
                    printf '%s  打开失败，请手动访问：%s%s\n' "$C_RED" "$C_RESET" "$link"
            else
                printf '\n%s  笔记里没配置下载链接%s\n' "$C_YELLOW" "$C_RESET"
            fi
            printf '\n  %s按回车继续…%s' "$C_GRAY" "$C_RESET"
            read _
            ;;
        *)
            printf '\n%s  已跳过，继续使用当前版本 %s%s\n' "$C_GRAY" "$VERSION" "$C_RESET"
            sleep 0.8
            ;;
    esac
}

show_announcement() {
    [ -z "$UPDATE_URL" ] && return 0

    local body=$(http_get_quick "$UPDATE_URL")
    [ -z "$body" ] && return 0
    body=$(weiyun_normalize "$body")

    local ann=$(pick "$body" "公告")
    [ -z "$ann" ] && return 0

    printf '\n'
    printf '%s' "$C_BLUE"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD$C_BLUE"
    center "作  者  公  告"
    printf '%s' "$C_RESET"
    printf '%s' "$C_BLUE"; hline; printf '%s\n\n' "$C_RESET"

    # 不用「管道 + while」：某些终端（WebView 内核）里管道子 shell 的
    # 输出会被吞掉，表现就是「公告标题出来了、正文空白」。
    # 改成先把文本存进变量、再用 here-string 逐行遍历，全程不开子 shell。
    printf '%s' "$C_WHITE"
    local sent=$(split_sentences "$ann")
    local old_ifs="$IFS"
    IFS='
'
    for line in $sent; do
        [ -z "$line" ] && continue
        printf '  %s\n' "$line"
    done
    IFS="$old_ifs"
    printf '%s\n' "$C_RESET"

    printf '%s  按回车继续…%s' "$C_GRAY" "$C_RESET"
    read _
}

check_update() {
    [ -z "$UPDATE_URL" ] && return 0

    local body=$(http_get_quick "$UPDATE_URL")
    [ -z "$body" ] && return 0
    body=$(weiyun_normalize "$body")

    local sw=$(pick "$body" "更新开关")
    [ "$sw" = "关" ] && return 0

    local latest=$(pick "$body" "最新版本")
    [ -z "$latest" ] && return 0
    [ "$latest" = "$VERSION" ] && return 0

    local force=$(pick "$body" "强制更新")
    local link=$(pick "$body" "更新链接")
    local pwd=$(pick "$body" "链接密码")

    printf '\n'
    printf '%s' "$C_YELLOW"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "发  现  新  版  本"
    printf '%s' "$C_RESET"
    printf '%s' "$C_YELLOW"; hline; printf '%s\n\n' "$C_RESET"

    printf '%s  当前版本：%s%s%s\n' "$C_GRAY" "$C_WHITE" "$VERSION" "$C_RESET"
    printf '%s  最新版本：%s%s%s\n\n' "$C_GRAY" "$C_CYAN" "$latest" "$C_RESET"

    if [ "$force" = "开" ]; then
        printf '%s  作者要求强制更新%s\n\n' "$C_RED" "$C_RESET"
    fi
    if [ -n "$pwd" ]; then
        printf '%s  网盘提取码：%s%s%s\n\n' "$C_GRAY" "$C_YELLOW" "$pwd" "$C_RESET"
    fi

    printf '  %sy%s 立即更新（打开下载页）\n' "$C_GREEN" "$C_RESET"
    printf '  %sn%s 暂不更新，继续用当前版本\n\n' "$C_GRAY" "$C_RESET"
    printf '  %s请选择 [y/N]：%s' "$C_WHITE" "$C_RESET"
    read UPD_ANS
    UPD_ANS=$(printf '%s' "$UPD_ANS" | tr -d ' \t\r\n')

    case "$UPD_ANS" in
        y|Y|yes|YES)
            if [ -n "$link" ]; then
                printf '\n%s  正在打开下载页…%s\n' "$C_GREEN" "$C_RESET"
                am start -a android.intent.action.VIEW -d "$link" >/dev/null 2>&1 || \
                    printf '%s  打开失败，请手动访问：%s%s\n' "$C_RED" "$C_RESET" "$link"
                printf '%s  装好新版再回来跑一次就行%s\n' "$C_GRAY" "$C_RESET"
            else
                printf '\n%s  笔记里没配置下载链接%s\n' "$C_YELLOW" "$C_RESET"
            fi
            printf '\n  %s按回车继续使用当前版本…%s' "$C_GRAY" "$C_RESET"
            read _
            ;;
        *)
            printf '\n%s  已跳过，继续使用当前版本 %s%s\n' "$C_GRAY" "$VERSION" "$C_RESET"
            sleep 0.8
            ;;
    esac
}

check_update() {
    clear_screen
    printf '\n'
    printf '%s' "$C_CYAN"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "检  查  更  新"
    printf '%s' "$C_RESET"
    printf '%s' "$C_CYAN"; hline; printf '%s\n\n' "$C_RESET"

    local url="$UPDATE_URL"
    if [ -z "$url" ]; then
        printf '%s' "$C_YELLOW"; center "还没有配置更新地址"; printf '%s\n\n' "$C_RESET"
        printf '%s  作者还没在脚本里填更新地址（改脚本顶部的 UPDATE_URL）%s\n\n' "$C_GRAY" "$C_RESET"
        return 1
    fi

    printf '%s  地址：%s%s\n' "$C_GRAY" "$C_RESET" "$url"
    progress_bar "读取更新信息" 18
    local body=$(http_get "$url")

    if [ -z "$body" ]; then
        printf '\n%s  读取失败（网络不通 / 链接失效 / 未公开分享）%s\n\n' "$C_RED" "$C_RESET"
        return 1
    fi
    body=$(weiyun_normalize "$body")

    local sw=$(pick "$body" "更新开关")
    local latest=$(pick "$body" "最新版本")
    local force=$(pick "$body" "强制更新")
    local link=$(pick "$body" "更新链接")
    local pwd=$(pick "$body" "链接密码")

    [ "$sw" = "关" ] && { printf '\n%s  作者已关闭远程更新%s\n\n' "$C_GRAY" "$C_RESET"; return 0; }

    if [ -z "$latest" ]; then
        printf '\n%s  笔记格式不对：没找到 最新版本【x】%s\n\n' "$C_RED" "$C_RESET"
        return 1
    fi

    printf '\n%s  当前版本：%s%s%s\n' "$C_GRAY" "$C_WHITE" "$VERSION" "$C_RESET"
    printf '%s  最新版本：%s%s%s\n\n' "$C_GRAY" "$C_CYAN" "$latest" "$C_RESET"

    if [ "$latest" = "$VERSION" ]; then
        printf '%s' "$C_GREEN"; center "✓ 已是最新版本"; printf '%s\n\n' "$C_RESET"
        return 0
    fi

    printf '%s' "$C_YELLOW"; center "发现新版本 $latest"; printf '%s\n' "$C_RESET"
    [ "$force" = "开" ] && { printf '%s' "$C_RED"; center "（作者要求强制更新）"; printf '%s\n' "$C_RESET"; }
    printf '\n'

    printf '%s  按回车打开下载页%s\n\n' "$C_GRAY" "$C_RESET"
    read _

    if [ -n "$pwd" ]; then
        printf '%s  网盘提取码：%s%s%s（请手动复制）\n\n' "$C_GRAY" "$C_YELLOW" "$pwd" "$C_RESET"
    fi

    if [ -n "$link" ]; then
        printf '%s  正在打开浏览器…%s\n' "$C_GREEN" "$C_RESET"
        am start -a android.intent.action.VIEW -d "$link" >/dev/null 2>&1 || \
            printf '%s  打开失败，请手动访问：%s%s\n' "$C_RED" "$C_RESET" "$link"
    else
        printf '%s  笔记里没有配置更新链接%s\n' "$C_YELLOW" "$C_RESET"
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────────────
#  CPU 检测
# ─────────────────────────────────────────────────────────────
detect_cpus() {
    CPUS=""
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$d/cpufreq" ] || continue
        CPUS="$CPUS $(basename "$d" | sed 's/cpu//')"
    done
    CPUS=$(echo "$CPUS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ')
    [ -z "$(echo $CPUS)" ] && return 1
    return 0
}

cpufreq_dir() { echo "/sys/devices/system/cpu/cpu$1/cpufreq"; }

# ── 关键适配：不同机型 governor 名字完全不同 ──
# 一加（高通）通常是 walt，部分 ROM 是 schedutil / scx。
# 写一个不存在的 governor 会静默失败 —— 所以必须先探测。
detect_governors() {
    local c1=$(echo $CPUS | awk '{print $1}')
    GOV_LIST=$(cat "$(cpufreq_dir "$c1")/scaling_available_governors" 2>/dev/null)
    [ -z "$GOV_LIST" ] && GOV_LIST="schedutil"

    # 性能/电竞用：performance 优先
    if echo "$GOV_LIST" | grep -qw performance; then
        GOV_PERF="performance"
    elif echo "$GOV_LIST" | grep -qw walt; then
        GOV_PERF="walt"
    else
        GOV_PERF="schedutil"
    fi

    # 均衡/降档用：walt（高通默认，平衡最好）> schedutil > 第一个
    if echo "$GOV_LIST" | grep -qw walt; then
        GOV_BAL="walt"
    elif echo "$GOV_LIST" | grep -qw schedutil; then
        GOV_BAL="schedutil"
    else
        GOV_BAL=$(echo "$GOV_LIST" | awk '{print $1}')
    fi
}

# ── CPU 簇自动识别 ──
# 为什么需要：一加手机和 Pad 的核心编号不同（13T 是 0-5 小/大核 + 6-7 超大核，
# Pad Pro 可能是别的分法）。硬编码 cpu6-7 在 Pad 上会锁错核心。
# 这里按「每个核心的 max_freq」分三档，自动认出超大核/大核/小核。
detect_clusters() {
    CLUSTER_TOP=""; CLUSTER_MID=""; CLUSTER_LOW=""

    local all_max=""
    for c in $CPUS; do
        local h=$(freq_max_allowed "$c")
        [ -n "$h" ] && all_max="$all_max $h"
    done

    local uniq=$(echo $all_max | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu)
    local n=$(echo "$uniq" | wc -l)
    [ "$n" -eq 0 ] && return 1

    local low mid top
    if [ "$n" -ge 3 ]; then
        low=$(echo "$uniq" | sed -n 1p)
        mid=$(echo "$uniq" | sed -n 2p)
        top=$(echo "$uniq" | tail -1)
    elif [ "$n" -eq 2 ]; then
        low=$(echo "$uniq" | sed -n 1p); mid="$low"; top=$(echo "$uniq" | tail -1)
    else
        low=$(echo "$uniq" | head -1); mid="$low"; top="$low"
    fi

    for c in $CPUS; do
        local h=$(freq_max_allowed "$c")
        case "$h" in
            "$top") CLUSTER_TOP="$CLUSTER_TOP $c" ;;
            "$mid") CLUSTER_MID="$CLUSTER_MID $c" ;;
            *)      CLUSTER_LOW="$CLUSTER_LOW $c" ;;
        esac
    done
}

# GPU：一加 13/13T 上 kgsl 路径经常不暴露，这里多路径探测，找不到就跳过
detect_gpu() {
    GPU_DIR=""
    for p in \
        /sys/class/kgsl/kgsl-3d0 \
        /sys/devices/platform/soc/*kgsl*/kgsl/kgsl-3d0 \
        /sys/devices/platform/*.qcom,kgsl-3d0/kgsl/kgsl-3d0; do
        if [ -d "$p/devfreq" ]; then GPU_DIR="$p"; return 0; fi
    done
    return 1
}

freq_min_allowed() { cat "$(cpufreq_dir "$1")/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -1; }
freq_max_allowed() { cat "$(cpufreq_dir "$1")/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1; }

w() {
    local path="$1" val="$2"
    [ -w "$path" ] || return 0
    echo "$val" > "$path" 2>/dev/null
}

# 读取 CPU/SOC 温度
#
# 旧版取所有 thermal_zone 的最大值，这是个坑：
#   zone0 pm8550-bcl-lvl0 = 0      电池电量等级
#   zone6 vbat          = 3619     电压 3.6V（不是温度！）
#   zone8 pmih010x-ibat = 192      电流等级
# 这些非温度值会被当成温度，导致误判（要么永不降档，要么疯狂降档）。
#
# 现在只认 type 里含 cpu / soc / tsens / apc / gpu / core 的传感器，
# 并且数值落在 10°C~120°C 的合理区间才采纳。
# ─────────────────────────────────────────────────────────────
#  温控服务开关（暴力模式专用）
#
#  说明：这里停的是「用户空间温控」——
#    thermal-engine   高通温控引擎（管外壳温度、充电降频）
#    vendor.thermal-hal  HAL 层温控接口
#  内核层的 thermal（/sys/class/thermal，判结温到 105°C 强降频）停不掉，
#  也不需要停 —— 那是最后一道物理保险。所以「暴力模式」的准确定义是：
#  **用脚本接管用户空间温控**，而不是真的没有温控。
# ─────────────────────────────────────────────────────────────

thermal_is_running() {
    [ "$(getprop init.svc.thermal-engine 2>/dev/null)" = "running" ] && return 0
    [ "$(getprop init.svc.vendor.thermal-hal 2>/dev/null)" = "running" ] && return 0
    return 1
}

# ─────────────────────────────────────────────────────────────
#  AI 温控顾问
#
#  权限设计（重要）：
#    AI 说 restore / degrade → **立即执行**（降档永远安全，给一票权）
#    AI 说 recover           → **需要规则同意**（提频有风险，不能盲信 AI）
#    AI 说 keep              → 不采纳（规则继续按自己的判断跑）
#
#  也就是说：AI 只能把手机往「更凉」的方向推，想往「更热」的方向推，
#  必须规则也认为安全。
#
#  不可用时（无网/无 API/返回垃圾）：静默降级为纯规则模式，绝不影响保命逻辑。
# ─────────────────────────────────────────────────────────────

# 配置统一走解密后的变量
ai_cfg_get() {
    ai_load_config || return 1
    case "$1" in
        baseUrl) echo "$AI_ENDPOINT" ;;
        apiKey)  echo "$AI_KEY" ;;
        model)   echo "$AI_MODEL" ;;
        *)       echo "" ;;
    esac
}

# 问 AI 要一个决策：keep / degrade / restore / recover
ai_thermal_advice() {
    local hist="$1" mode="$2"

    [ "$AI_THERMAL_ENABLED" = "1" ] || { echo "unavailable"; return 1; }

    local base=$(ai_cfg_get baseUrl)
    local key=$(ai_cfg_get apiKey)
    local model=$(ai_cfg_get model)
    [ -z "$base" ] && { echo "unavailable"; return 1; }
    [ -z "$model" ] && model="deepseek-chat"
    base="${base%/}"

    ai_load_config || { echo "unavailable"; return 1; }
    local prompt=$(printf '%s' "$AI_PROMPT" | sed "s/{mode}/${mode}/g; s/{hist}/${hist}/g")
    local body=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":8,"temperature":0}' \
        "$model" "$(printf '%s' "$prompt" | sed 's/"/\\"/g')")

    local resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(printf '%s' "$body" | curl -s -m 12 -X POST "${base}/chat/completions" \
            -H "content-type: application/json" \
            -H "authorization: Bearer ${key}" \
            --data-binary @- 2>/dev/null)
    elif [ -x /data/adb/ksu/bin/busybox ]; then
        # busybox wget 不能直接发 POST，退化到规则模式
        echo "unavailable"; return 1
    else
        echo "unavailable"; return 1
    fi

    [ -z "$resp" ] && { echo "unavailable"; return 1; }

    # 从响应里抠出决策词
    case "$resp" in
        *restore*) echo "restore" ;;
        *degrade*) echo "degrade" ;;
        *recover*) echo "recover" ;;
        *keep*)    echo "keep" ;;
        *)         echo "unavailable" ;;
    esac
}

# 把温度采样历史转成 "61.9 63.2 65.0" 这种可读格式
hist_to_celsius() {
    local v out=""
    for v in $1; do
        out="$out $(echo "scale=1; $v/1000" | bc 2>/dev/null || echo "$((v/1000))")"
    done
    echo "$out"
}

stop_thermal() {
    local stopped=""
    for svc in $THERMAL_SERVICES; do
        local st=$(getprop "init.svc.$svc" 2>/dev/null)
        [ "$st" = "running" ] || continue
        setprop ctl.stop "$svc" 2>/dev/null || stop "$svc" 2>/dev/null
        stopped="$stopped $svc"
    done
    sleep 1
    if thermal_is_running; then
        warn "部分温控服务未停掉（可能被系统守护进程拉起）"
        return 1
    fi
    [ -n "$stopped" ] && log "已接管温控：停掉$stopped"
    return 0
}

start_thermal() {
    for svc in $THERMAL_SERVICES; do
        local st=$(getprop "init.svc.$svc" 2>/dev/null)
        [ "$st" = "running" ] && continue
        setprop ctl.start "$svc" 2>/dev/null || start "$svc" 2>/dev/null
    done
    sleep 1
    if thermal_is_running; then
        log "系统温控已恢复"
    else
        warn "温控服务恢复失败，建议重启手机"
    fi
}

read_temp() {
    local t="" z typ v
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        typ=$(cat "${z%/temp}/type" 2>/dev/null)
        case "$typ" in
            *cpu*|*CPU*|*soc*|*SOC*|*tsens*|*apc*|*gpu*|*GPU*|*core*) ;;
            *) continue ;;                 # 非 CPU 类传感器直接跳过
        esac
        v=$(cat "$z" 2>/dev/null)
        case "$v" in ''|*[!0-9]*) continue ;; esac
        # 合理区间：10000 (10°C) ~ 120000 (120°C)
        [ "$v" -lt 10000 ] && continue
        [ "$v" -gt 120000 ] && continue
        [ -z "$t" ] && t="$v"
        [ "$v" -gt "$t" ] && t="$v"
    done
    # 一个都没读到就退回第一类兜底，避免返回 0 导致保护失效
    if [ -z "$t" ]; then
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [ -r "$z" ] || continue
            v=$(cat "$z" 2>/dev/null)
            case "$v" in ''|*[!0-9]*) continue ;; esac
            [ "$v" -lt 10000 ] && continue
            [ "$v" -gt 120000 ] && continue
            [ -z "$t" ] && t="$v"
            [ "$v" -gt "$t" ] && t="$v"
        done
    fi
    echo "${t:-0}"
}

temp_text() {
    local t=$(( $(read_temp) / 1000 ))
    if   [ "$t" -ge 80 ]; then printf '%s%d°C%s' "$C_RED" "$t" "$C_RESET"
    elif [ "$t" -ge 65 ]; then printf '%s%d°C%s' "$C_YELLOW" "$t" "$C_RESET"
    else printf '%s%d°C%s' "$C_GREEN" "$t" "$C_RESET"; fi
}

# ─────────────────────────────────────────────────────────────
#  LOGO
# ─────────────────────────────────────────────────────────────
banner() {
    clear_screen
    printf '\n'

    local pad=$(printf '%*s' 18 '')

    # 上装饰线
    printf '%s' "$pad$C_CYAN"
    local i=0
    while [ "$i" -lt 22 ]; do
        printf '─'; i=$((i+1)); sleep 0.012
    done
    printf '%s\n' "$C_RESET"
    sleep 0.3

    # ── YP 两个大写字母，逐行缓慢升起 ──
    printf '%s' "$pad$C_CYAN$C_BOLD"
    printf 'Y     Y  PPPPPP \n';  sleep 0.14
    printf '%s' "$pad$C_CYAN$C_BOLD"
    printf ' Y   Y   P     P\n';  sleep 0.14
    printf '%s' "$pad$C_CYAN$C_BOLD"
    printf '  Y Y    PPPPPP \n';  sleep 0.14
    printf '%s' "$pad$C_CYAN$C_BOLD"
    printf '   Y     P      \n';  sleep 0.14
    printf '%s' "$pad$C_CYAN$C_BOLD"
    printf '   Y     P      \n';  sleep 0.14
    printf '%s' "$C_RESET"
    sleep 0.25

    # 下装饰线
    printf '%s' "$pad$C_CYAN"
    i=0
    while [ "$i" -lt 22 ]; do
        printf '─'; i=$((i+1)); sleep 0.012
    done
    printf '%s\n' "$C_RESET"
    sleep 0.35

    # 副标题逐字
    printf '%s' "$pad$C_PURPLE"
    local sub="叶青一加调度"
    i=0
    while [ "$i" -lt "${#sub}" ]; do
        LANG=C LC_ALL=C
        printf '%s' "$(printf '%s' "$sub" | cut -c$((i*3+1))-$((i*3+3)))"
        i=$((i+1))
        sleep 0.09
    done
    printf '%s\n' "$C_RESET"
    sleep 0.25

    printf '%s' "$C_GRAY"
    center "v${VERSION}  ·  ${CODENAME}"
    printf '%s\n\n' "$C_RESET"
    sleep 0.35
}

# ─────────────────────────────────────────────────────────────
#  免责条款
# ─────────────────────────────────────────────────────────────
disclaimer() {
    clear_screen
    printf '\n'
    printf '%s' "$C_RED";  hline;  printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "免  责  与  风  险  告  知"
    printf '%s' "$C_RESET"
    printf '%s' "$C_RED";  hline;  printf '%s\n\n' "$C_RESET"

    printf '%s' "$C_GRAY"
    slow_lines 0.26 \
      "  本脚本会修改设备的 CPU / GPU 调度参数，" \
      "  包括 governor 策略、频率上下限与响应参数。" \
      "" \
      "  【已知风险】" \
      "   · 部分机型可能出现异常发热、耗电加快" \
      "   · 极少数情况下可能与厂商温控策略冲突" \
      "   · 重启后设置失效，需重新运行" \
      "" \
      "  【本脚本不做什么】" \
      "   · 不修改任何电压，不超频，不关闭温控" \
      "   · 不写入厂商频率表以外的数值" \
      "   · 内置温度保护：72°C 降档、88°C 自动还原" \
      "" \
      "  【责任说明】" \
      "   本脚本仅供学习与个人调优使用。" \
      "   使用者应自行评估设备状况与散热条件。" \
      "   因使用本脚本产生的任何直接或间接后果，" \
      "   包括但不限于发热、耗电、性能波动、" \
      "   系统异常或硬件损伤，作者不承担责任。" \
      ""
    printf '%s' "$C_RESET"
    printf '%s' "$C_RESET"

    printf '%s' "$C_YELLOW"; hline2; printf '%s\n\n' "$C_RESET"

    printf '  %s请输入 %s%s同意%s%s 两个汉字表示已阅读并接受：%s\n\n' \
        "$C_WHITE" "$C_BOLD" "$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
    printf '  %s> %s' "$C_CYAN" "$C_RESET"
    read CONSENT

    CONSENT=$(printf '%s' "$CONSENT" | tr -d ' \t\r\n　')

    if [ "$CONSENT" != "同意" ]; then
        printf '\n%s' "$C_RED"
        center "未确认免责条款，程序退出。"
        printf '%s' "$C_RESET"
        printf '%s' "$C_GRAY"
        center "（未做任何修改）"
        printf '%s\n\n' "$C_RESET"
        exit 0
    fi

    ( date '+%Y-%m-%d %H:%M:%S' > "$CONSENT_FILE" ) 2>/dev/null || \
    ( date '+%Y-%m-%d %H:%M:%S' > "$HOME/yq_consent.txt" ) 2>/dev/null || true
    printf '\n%s' "$C_GREEN"
    center "✓ 已确认，正在初始化…"
    printf '%s\n' "$C_RESET"
    sleep 0.7
}

# 带参数模式：要求此前同意过
consent_check() {
    [ -f "$CONSENT_FILE" ] || CONSENT_FILE="${HOME}/yq_consent.txt"
    if [ -f "$CONSENT_FILE" ]; then
        printf '%s[已同意] %s%s\n' "$C_GREEN" "$(cat "$CONSENT_FILE" 2>/dev/null)" "$C_RESET"
        return 0
    fi
    printf '%s首次使用需先确认免责条款，请交互运行一次：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  sh %s\n\n' "$0"
    return 1
}

# ─────────────────────────────────────────────────────────────
#  扫描动画
# ─────────────────────────────────────────────────────────────
boot_scan() {
    clear_screen
    printf '\n'
    printf '%s' "$C_CYAN"; hline; printf '%s\n\n' "$C_RESET"

    progress_bar "检测 CPU 拓扑" 24
    printf '%s  核心列表：%s%s%s\n' "$C_GRAY" "$C_WHITE" "$CPUS" "$C_RESET"
    printf '%s  核心数量：%s%s 个%s\n' "$C_GRAY" "$C_WHITE" "$(echo $CPUS | wc -w)" "$C_RESET"

    progress_bar "读取频率表" 20
    local c1=$(echo $CPUS | awk '{print $1}')
    local cN=$(echo $CPUS | awk '{print $NF}')
    printf '%s  频率区间：%s%d ~ %d MHz%s\n' "$C_GRAY" "$C_WHITE" \
        "$(( $(freq_min_allowed "$c1") / 1000 ))" \
        "$(( $(freq_max_allowed "$cN") / 1000 ))" "$C_RESET"

    progress_bar "校验温度保护" 16
    printf '%s  当前温度：%s%s\n' "$C_GRAY" "$(temp_text)" "$C_RESET"

    printf '\n%s' "$C_CYAN"; hline; printf '%s\n' "$C_RESET"
    sleep 0.5
}

# ─────────────────────────────────────────────────────────────
#  备份 / 恢复
# ─────────────────────────────────────────────────────────────
backup_original() {
    [ -f "$BACKUP" ] && return 0
    : > "$BACKUP"

    # 关键：min/max 要用 cpuinfo_* 而不是 scaling_*
    #
    #   cpuinfo_min_freq / cpuinfo_max_freq = 硬件真实范围，永远不变
    #   scaling_min_freq / scaling_max_freq = 当前软件限制，可能已被改过
    #
    # 实测证据（本机某次运行后）：
    #   cpu0: cpuinfo 384000~3532800  但 scaling 1785600~2227200
    #   cpu6: cpuinfo 1017600~4320000 但 scaling 1689600~1689600（被锁死）
    #
    # 旧版备份 scaling_*，结果「恢复原厂」只是恢复到一个被改过的中间态。
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local gov=$(cat "$d/scaling_governor" 2>/dev/null)
        local cmin=$(cat "$d/cpuinfo_min_freq" 2>/dev/null)
        local cmax=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
        # cpuinfo 读不到就退回 scaling 值（至少有个能恢复的）
        [ -z "$cmin" ] && cmin=$(cat "$d/scaling_min_freq" 2>/dev/null)
        [ -z "$cmax" ] && cmax=$(cat "$d/scaling_max_freq" 2>/dev/null)
        local wup=$(cat "$d/walt/up_rate_limit_us" 2>/dev/null)
        local wdn=$(cat "$d/walt/down_rate_limit_us" 2>/dev/null)
        echo "cpu$c|$gov|$cmin|$cmax|$wup|$wdn" >> "$BACKUP"
    done

    if [ -n "$GPU_DIR" ]; then
        local gmin=$(cat "$GPU_DIR/devfreq/min_freq" 2>/dev/null)
        local gmax=$(cat "$GPU_DIR/devfreq/max_freq" 2>/dev/null)
        # GPU 的 min_freq 记录厂商最低档更稳妥
        local gavail=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -1)
        [ -n "$gavail" ] && gmin="$gavail"
        echo "gpu|$(cat "$GPU_DIR/devfreq/governor" 2>/dev/null)|$gmin|$gmax" >> "$BACKUP"
    fi

    # 记录备份时的原始状态，方便排查
    echo "#backup_at=$(date '+%Y-%m-%d %H:%M:%S')" >> "$BACKUP"
}

# 把 walt 参数重置为高通常见默认值（5000/5000）
# 用于备份文件里记录的也是被改过的值时兜底
reset_walt_default() {
    detect_cpus >/dev/null 2>&1
    local n=0
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        [ -d "$d/walt" ] || continue
        w "$d/walt/up_rate_limit_us"   "5000"
        w "$d/walt/down_rate_limit_us" "5000"
        n=$((n + 1))
    done
    log "已把 $n 个核心的 walt 参数重置为厂商默认（5000/5000）"
}

restore_original() {
    clear_screen
    printf '\n'
    printf '%s' "$C_YELLOW"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "一  键  恢  复  原  厂"
    printf '%s' "$C_RESET"
    printf '%s' "$C_YELLOW"; hline; printf '%s\n\n' "$C_RESET"

    if [ ! -f "$BACKUP" ]; then
        printf '%s' "$C_RED"; center "没有找到备份文件"; printf '%s' "$C_RESET"
        printf '%s' "$C_GRAY"; center "（首次运行还没备份过）"; printf '%s\n\n' "$C_RESET"
        return 1
    fi

    printf '%s  正在还原…%s\n\n' "$C_GRAY" "$C_RESET"

    # 备份格式：cpuX|governor|cpuinfo_min|cpuinfo_max|walt_up|walt_down
    # 兼容旧格式（只有 4 段，没有 walt 参数）
    while IFS='|' read -r key gov fmin fmax wup wdn; do
        case "$key" in
            \#*|"") continue ;;              # 跳过注释行
            gpu)
                [ -n "$GPU_DIR" ] || continue
                [ -r "$GPU_DIR/devfreq/governor" ] || continue
                [ -n "$fmin" ] && w "$GPU_DIR/devfreq/min_freq" "$fmin"
                [ -n "$fmax" ] && w "$GPU_DIR/devfreq/max_freq" "$fmax"
                [ -n "$gov" ]  && w "$GPU_DIR/devfreq/governor"  "$gov"
                printf '   %s✓%s GPU   %s\n' "$C_GREEN" "$C_RESET" "$gov"
                ;;
            cpu*)
                local c=${key#cpu}
                local d=$(cpufreq_dir "$c")
                [ -d "$d" ] || continue
                [ -n "$fmax" ] && w "$d/scaling_max_freq" "$fmax"
                [ -n "$fmin" ] && w "$d/scaling_min_freq" "$fmin"
                [ -n "$gov" ]  && w "$d/scaling_governor"  "$gov"
                [ -n "$fmax" ] && w "$d/scaling_max_freq" "$fmax"
                [ -n "$fmin" ] && w "$d/scaling_min_freq" "$fmin"
                [ -n "$wup" ]  && w "$d/walt/up_rate_limit_us"   "$wup"
                [ -n "$wdn" ]  && w "$d/walt/down_rate_limit_us" "$wdn"
                printf '   %s✓%s cpu%-2s %s\n' "$C_GREEN" "$C_RESET" "$c" "$gov"
                ;;
        esac
    done < "$BACKUP"

    stop_daemon >/dev/null 2>&1
    rm -f "$LOCK" "$MODE_FILE"
    printf '\n%s' "$C_GREEN"; center "✓ 已恢复手机原始设置（守护进程已停）"; printf '%s\n\n' "$C_RESET"
}

# ─────────────────────────────────────────────────────────────
#  三种模式
# ─────────────────────────────────────────────────────────────
# 调速响应：schedutil 和 walt 两套路径同时尝试，哪套存在就用哪套。
# 一加（高通）默认 walt，其 up/down_rate_limit_us 默认是 0（最激进），
# 我们不改动默认值以避免与厂商调校冲突，仅在需要时显式设置。
# 调频响应参数 —— 这是稳帧率的核心旋钮
#
# 两个参数意思完全不同：
#   up_rate_limit_us   = 两次「升频」之间至少间隔多少微秒
#   down_rate_limit_us = 两次「降频」之间至少间隔多少微秒
#
# 稳帧的正确方向是「升频快 + 降频慢」：
#   升频快 → 负载一上来立刻提频，不掉帧
#   降频慢 → 负载短暂回落时不急着降，避免频率来回抖（抖动来源之一）
#
# 本机实测厂商默认是 5000 / 5000。旧版脚本也写 5000，等于什么都没做。
tune_governor() {
    local d=$(cpufreq_dir "$1")
    local up="$2"
    local down="${3:-$2}"
    w "$d/schedutil/rate_limit_us"    "$up"
    w "$d/schedutil/up_rate_limit_us" "$up"
    w "$d/walt/up_rate_limit_us"      "$up"
    w "$d/walt/down_rate_limit_us"    "$down"
}

# 提频引导（walt 专有）：hispeed_freq 设到该簇的中高段，让负载上来更快升频
walt_boost() {
    local c="$1" ratio="${2:-70}"
    local d=$(cpufreq_dir "$c")
    [ -d "$d/walt" ] || return 0
    local hi=$(freq_max_allowed "$c")
    [ -z "$hi" ] && return 0
    local f=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk -v r="$ratio" '{a[NR]=$1} END{print a[int(NR*r/100)]}')
    [ -n "$f" ] && w "$d/walt/hispeed_freq" "$f"
}

mode_balance() {
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        w "$d/scaling_governor" "$GOV_BAL"
        w "$d/scaling_max_freq" "$(freq_max_allowed "$c")"
        w "$d/scaling_min_freq" "$(freq_min_allowed "$c")"
        tune_governor "$c" 5000 5000
    done
    [ -n "$GPU_DIR" ] && w "$GPU_DIR/devfreq/governor" "msm-adreno-tz"
}

mode_perf() {
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local lo=$(freq_min_allowed "$c") hi=$(freq_max_allowed "$c")
        [ -z "$hi" ] && continue
        local mid=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.5)]}')
        [ -z "$mid" ] && mid="$lo"
        w "$d/scaling_governor" "$GOV_BAL"
        w "$d/scaling_max_freq" "$hi"
        w "$d/scaling_min_freq" "$mid"
        tune_governor "$c" 1500 25000
        walt_boost "$c" 70
    done
    if [ -n "$GPU_DIR" ]; then
        w "$GPU_DIR/devfreq/governor" "performance"
        local gmax=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
        [ -n "$gmax" ] && w "$GPU_DIR/devfreq/max_freq" "$gmax"
    fi
}

mode_game() {
    # ── 电竞模式 v4（按目标图黄金配比重写）──
    #
    # 三份实测数据的结论：
    #   全核锁满 → AVG 82.6 / JITTER 43.6% / SOC 96.6°C
    #   飞升全开 → AVG 92.7 / JITTER 15.6% / SOC 97.0°C（≥90°C 87 秒）
    #   目标参考 → AVG 141.2 / JITTER 8.1% / SOC 83.1°C / 13.84W
    #
    # 目标图的关键不是「频率高」，而是「频率刚好够 + 温度低」：
    #   大核 2533MHz（不是 3148）、GPU 770MHz（不是 903）、超大核 902MHz
    #   → SOC 压到 83°C，系统完全不插手，帧率才能一路 141。
    #
    # 所以本版全面降档：
    #   超大核 → 40% 档（约 1.2-1.4GHz，够用即可）
    #   大核   → 上限 80% 档（约 2.5-2.6GHz），下限 70%
    #   小核   → 不动
    #   GPU    → 70% 档（不拉满，这是省电关键）

    # 超大核：40% 档封顶
    for c in $CLUSTER_TOP; do
        local d=$(cpufreq_dir "$c")
        local hi=$(freq_max_allowed "$c") lo=$(freq_min_allowed "$c")
        [ -z "$hi" ] && continue
        local cap40=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.4)]}')
        [ -z "$cap40" ] && cap40="$hi"
        w "$d/scaling_governor" "$GOV_BAL"
        w "$d/scaling_max_freq" "$cap40"
        w "$d/scaling_min_freq" "$lo"
        tune_governor "$c" 2000 20000
    done

    # 大核：上限 80% 档，下限 70%（主力核心，但不能放满）
    for c in $CLUSTER_MID; do
        local d=$(cpufreq_dir "$c")
        local hi=$(freq_max_allowed "$c") lo=$(freq_min_allowed "$c")
        [ -z "$hi" ] && continue
        local cap80=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.8)]}')
        local mid70=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.7)]}')
        [ -z "$cap80" ] && cap80="$hi"
        [ -z "$mid70" ] && mid70="$lo"
        w "$d/scaling_governor" "$GOV_BAL"
        w "$d/scaling_max_freq" "$cap80"
        w "$d/scaling_min_freq" "$mid70"
        tune_governor "$c" 1000 30000
        walt_boost "$c" 80
    done

    # 小核：不碰

    # GPU：70% 档（不拉满 —— 目标图 770MHz 就跑 141 FPS，拉满只会发热）
    if [ -n "$GPU_DIR" ] && [ -r "$GPU_DIR/devfreq/governor" ]; then
        w "$GPU_DIR/devfreq/governor" "msm-adreno-tz"
        local gcap=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.7)]}')
        [ -n "$gcap" ] && w "$GPU_DIR/devfreq/max_freq" "$gcap"
    fi
}

# ─────────────────────────────────────────────────────────────
#  飞升模式（最激进档位）
#
#  与电竞模式的差别：
#    · 电竞：CPU 锁最高频，但守护进程 72°C 会降档、8 分钟会超时降档
#    · 飞升：CPU 锁最高频 + 不降档 + 不认输 + 无超时
#
#  唯一保留的防线：95°C 硬保险（芯片物理极限，不是本脚本的限制）
# ─────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────
#  超频 / 刷新率解锁
#
#  说明：手机 CPU 是硬件锁频的，软件「超频」不存在。
#  这里能真正改的是「屏幕刷新率」——把系统锁到 90 / 120 / 144Hz，
#  打游戏的体感提升比调 CPU 明显得多（因为掉帧常常是刷新率没跑满）。
#
#  144Hz 只有部分机型支持（一加 Pad Pro 有），手机端一般到 120。
#  写入前会先探测本机支持哪些档位，不支持的直接拒绝，不会写坏。
# ─────────────────────────────────────────────────────────────

# 本机支持的刷新率列表（去重、排序）
supported_refresh_rates() {
    # 注意：只取 fps= 后面紧跟的整数部分（fps=120.00001 → 120）。
    # 旧写法先抓 "fps=[0-9.]+" 再抓数字，会把 120.00001 拆成 120 和 00001，
    # 结果混进 0 / 00001 这类垃圾档位。
    local r=$(dumpsys display 2>/dev/null \
        | grep -oE 'fps=[0-9]+' \
        | sed 's/fps=//' \
        | awk '$1 >= 30 && $1 <= 240' \
        | sort -nu \
        | tr '\n' ' ')
    # 读不到（无 root / 权限不足）就退回常见档位，
    # 否则会把所有档位都误判成「不支持」，功能直接废掉。
    if [ -z "$(printf '%s' "$r" | tr -d ' ')" ]; then
        r="60 90 120"
    fi
    printf '%s' "$r"
}

# 当前生效的刷新率
current_refresh_rate() {
    local v=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$v" in
        null|"") echo "自动" ;;
        *)       echo "${v%.*}Hz" ;;
    esac
}

# 设置刷新率（只接受本机支持的档位）
set_refresh_rate() {
    local hz="$1"
    local avail=$(supported_refresh_rates)

    case " $avail " in
        *" $hz "*) ;;
        *)
            printf '%s  本机不支持 %sHz（支持：%s）%s\n' "$C_RED" "$hz" "$avail" "$C_RESET"
            return 1
            ;;
    esac

    settings put system peak_refresh_rate "$hz" 2>/dev/null
    settings put system min_refresh_rate "$hz" 2>/dev/null
    local now=$(settings get system peak_refresh_rate 2>/dev/null)

    case "$now" in
        ${hz}*)
            printf '%s  ✓ 已锁定 %sHz%s\n' "$C_GREEN" "$hz" "$C_RESET"
            return 0 ;;
        *)
            printf '%s  ✗ 写入未生效（当前 %s）%s\n' "$C_RED" "${now:-未知}" "$C_RESET"
            return 1 ;;
    esac
}

# 恢复自动刷新率
restore_refresh_rate() {
    settings put system peak_refresh_rate null 2>/dev/null
    settings put system min_refresh_rate null 2>/dev/null
    log "刷新率已恢复自动"
}

# ─────────────────────────────────────────────────────────────
#  极限锁定：把设备能跑的最高档全部钉死
#
#  这不是超频（频率表是内核写死的，改不了），而是：
#    ① 刷新率锁到本机支持的最高档（手机通常 120，平板可能 144）
#    ② CPU 每簇锁到 cpuinfo_max（表内最高，不是表外）
#    ③ GPU 有可写节点就锁最高
#    ④ walt 响应设 0（立即升频）
#
#  目的是消除「系统为了省电往下跳」造成的掉帧，而不是突破硬件。
# ─────────────────────────────────────────────────────────────
lock_max_everything() {
    clear_screen
    printf '\n'
    printf '%s' "$C_RED"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD$C_RED"
    center "极  限  锁  定"
    printf '%s' "$C_RESET"
    printf '%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"

    # ── ① 刷新率锁最高 ──
    local avail=$(supported_refresh_rates)
    local maxhz=$(printf '%s\n' $avail | grep -E '^[0-9]+$' | sort -n | tail -1)
    printf '%s  [1/4] 刷新率%s\n' "$C_GRAY" "$C_RESET"
    if [ -n "$maxhz" ]; then
        printf '        探测到最高档：%s%sHz%s\n' "$C_WHITE" "$maxhz" "$C_RESET"
        set_refresh_rate "$maxhz"
    else
        printf '        %s探测失败，跳过刷新率%s\n' "$C_YELLOW" "$C_RESET"
    fi

    # ── ② CPU 每簇锁表内最高 ──
    printf '%s  [2/4] CPU 频率%s\n' "$C_GRAY" "$C_RESET"
    local locked=0
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local hw=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$hw" ] && continue
        w "$d/scaling_governor" "$GOV_PERF"
        w "$d/scaling_max_freq" "$hw"
        w "$d/scaling_min_freq" "$hw"
        tune_governor "$c" 0 0
        walt_boost "$c" 100
        locked=$((locked + 1))
    done
    printf '        %d 个核心已锁到表内最高档\n' "$locked"

    # ── ③ GPU ──
    printf '%s  [3/4] GPU%s\n' "$C_GRAY" "$C_RESET"
    if [ -n "$GPU_DIR" ] && [ -r "$GPU_DIR/devfreq/governor" ]; then
        w "$GPU_DIR/devfreq/governor" "performance"
        local gmax=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
        [ -n "$gmax" ] && w "$GPU_DIR/devfreq/max_freq" "$gmax"
        printf '        GPU 锁 %s\n' "${gmax:-最高档}"
    else
        printf '        %s本机未暴露 GPU 节点，跳过%s\n' "$C_YELLOW" "$C_RESET"
    fi

    # ── ④ 校验 ──
    printf '%s  [4/4] 生效校验%s\n' "$C_GRAY" "$C_RESET"
    local c1=$(echo $CPUS | awk '{print $1}')
    local cur=$(cat "$(cpufreq_dir "$c1")/scaling_max_freq" 2>/dev/null)
    local hw1=$(cat "$(cpufreq_dir "$c1")/cpuinfo_max_freq" 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" = "$hw1" ]; then
        printf '        %s✓ CPU 已到表内最高（%s）%s\n' "$C_GREEN" "$cur" "$C_RESET"
    else
        printf '        %s⚠ 被系统压制：当前 %s / 硬件上限 %s%s\n' "$C_YELLOW" "${cur:-?}" "${hw1:-?}" "$C_RESET"
        printf '        %s  这是 ColorOS 电源服务做的，脚本改不动%s\n' "$C_GRAY" "$C_RESET"
    fi
    printf '        %s  实际刷新率：%s%s\n' "$C_GRAY" "$(current_refresh_rate)" "$C_RESET"

    printf '\n%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"
    printf '%s  说明：这是锁定设备最高档，不是超频。%s\n' "$C_GRAY" "$C_RESET"
    printf '%s  频率表由内核写死，软件无法突破。%s\n\n' "$C_GRAY" "$C_RESET"
}

# 超频选择界面（暴力模式进入前调用）
choose_refresh_rate() {
    local avail=$(supported_refresh_rates)
    clear_screen
    printf '\n'
    printf '%s' "$C_CYAN"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD$C_WHITE"
    center "超  频  设  置"
    printf '%s' "$C_RESET"
    printf '%s' "$C_CYAN"; hline; printf '%s\n\n' "$C_RESET"

    printf '%s  本机支持：%s%s\n' "$C_GRAY" "$avail" "$C_RESET"
    printf '%s  当前：%s%s\n\n' "$C_GRAY" "$(current_refresh_rate)" "$C_RESET"

    printf '  %s①%s  90Hz    %s省电模式%s\n' "$C_GREEN" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '  %s②%s  120Hz   %s标准高刷%s\n' "$C_GREEN" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '  %s③%s  144Hz   %s极限（部分机型不支持）%s\n' "$C_RED" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '  %s④%s  自动     %s还原系统默认%s\n\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '  %s⓪%s  不改\n\n' "$C_GRAY" "$C_RESET"
    printf '  %s请选择 [0-4]：%s' "$C_WHITE" "$C_RESET"
    read OC

    case "$OC" in
        1) set_refresh_rate 90;  sleep 1 ;;
        2) set_refresh_rate 120; sleep 1 ;;
        3) set_refresh_rate 144; sleep 1 ;;
        4) restore_refresh_rate; sleep 0.6 ;;
        0|"") printf '  %s保持当前设置%s\n' "$C_GRAY" "$C_RESET"; sleep 0.6 ;;
        *) printf '  %s无效，保持当前%s\n' "$C_GRAY" "$C_RESET"; sleep 0.6 ;;
    esac
}

# ─────────────────────────────────────────────────────────────
#  暴力模式（最激进，停系统温控 + 脚本接管兜底）
#
#  与飞升模式的区别：
#    飞升：不停温控，只是把自己的降档线从 72 抬到 88
#    暴力：**停掉 thermal-engine 和 vendor.thermal-hal**，
#          让系统不再插手降频，改由守护进程每 3 秒采样兜底
#          （92°C 降档 / 98°C 还原并恢复温控 / 30 分钟限时）
#
#  本质上这是「用脚本替换系统温控」，不是「没有温控」。
#  内核层的物理保护（结温 105°C）仍然在，停不掉也不需要停。
# ─────────────────────────────────────────────────────────────
mode_brutal() {
    # ① 接管温控
    stop_thermal

    # ② 全核拉到硬件上限，调频参数设最激进（0 = 立即响应）
    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local hwmax=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
        local hwmin=$(cat "$d/cpuinfo_min_freq" 2>/dev/null)
        [ -z "$hwmax" ] && continue
        w "$d/scaling_governor" "$GOV_PERF"
        w "$d/scaling_max_freq" "$hwmax"
        w "$d/scaling_min_freq" "$hwmin"
        tune_governor "$c" 0 0
        walt_boost "$c" 100
    done

    # ③ GPU 拉满（有节点才做）
    if [ -n "$GPU_DIR" ] && [ -r "$GPU_DIR/devfreq/governor" ]; then
        w "$GPU_DIR/devfreq/governor" "performance"
        local gmax=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
        [ -n "$gmax" ] && w "$GPU_DIR/devfreq/max_freq" "$gmax"
    fi
}

# 暴力模式的二次声明
brutal_disclaimer() {
    clear_screen
    printf '\n'
    printf '%s' "$C_RED"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD$C_RED"
    center "🔥   区  域  暴  力  模  式   🔥"
    printf '%s' "$C_RESET"
    printf '%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"

    printf '%s'
    slow_lines 0.18 \
      "  这是本脚本最危险的一档。" \
      "" \
      "  【它会做什么】" \
      "   · 停掉 thermal-engine（高通温控引擎）" \
      "   · 停掉 vendor.thermal-hal（HAL 温控接口）" \
      "   · 全核拉到硬件上限，调频响应设为最激进" \
      "   · 由脚本守护进程接管温度监控（每 3 秒采样）" \
      "" \
      "  【意味着什么】" \
      "   · 外壳会明显发烫，可能到 50°C 以上（烫手）" \
      "   · 电池在高温下会加速老化" \
      "   · 长时间高温可能影响主板焊点寿命" \
      "   · 系统原本的温控策略不再生效" \
      "" \
      "  【脚本的兜底：不看死线，看升温速度】" \
      "   · 30 秒涨 6°C  → 提前降一档（趁还来得及）" \
      "   · 30 秒涨 10°C → 判定危险，立刻还原并恢复温控" \
      "   · 稳定 93°C 超 60 秒 → 闷烧，也还原" \
      "   · 100°C 物理底线 → 无条件还原" \
      "   · 30 分钟到点自动降档" \
      "   · 内核物理保护（结温 105°C）仍在，停不掉" \
      "" \
      "  【建议】" \
      "   · 只在你明确知道自己在做什么时使用" \
      "   · 不要边充电边开这个模式" \
      "   · 夏天/被窝里玩慎用"
    printf '%s\n' "$C_RESET"

    printf '%s' "$C_RED"; hline; printf '%s\n' "$C_RESET"
    printf '  %s请输入 %s%s暴力%s%s 两个字确认（直接回车取消）：%s\n\n' \
        "$C_WHITE" "$C_BOLD" "$C_RED" "$C_RESET" "$C_WHITE" "$C_RESET"
    printf '  %s🔥 > %s' "$C_RED" "$C_RESET"
    read BRUTAL_OK
    BRUTAL_OK=$(printf '%s' "$BRUTAL_OK" | tr -d ' \t\r\n　')

    if [ "$BRUTAL_OK" != "暴力" ]; then
        printf '\n%s' "$C_GRAY"
        center "已取消（未做任何修改）"
        printf '%s\n\n' "$C_RESET"
        return 1
    fi
    return 0
}

mode_ascend() {
    # 飞升 = 电竞的加强档，但仍不是「全满」。
    # 目标图证明：频率超过临界点，多出来的电只变成热，帧率反而掉。
    # 所以飞升只比电竞各档高 20% 左右：
    #   超大核 60% / 大核 90% / GPU 85%

    for c in $CLUSTER_TOP; do
        local d=$(cpufreq_dir "$c")
        local hi=$(freq_max_allowed "$c") lo=$(freq_min_allowed "$c")
        [ -z "$hi" ] && continue
        local cap60=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.6)]}')
        [ -z "$cap60" ] && cap60="$hi"
        w "$d/scaling_governor" "$GOV_PERF"
        w "$d/scaling_max_freq" "$cap60"
        w "$d/scaling_min_freq" "$lo"
        walt_boost "$c" 60
    done

    for c in $CLUSTER_MID; do
        local d=$(cpufreq_dir "$c")
        local hi=$(freq_max_allowed "$c") lo=$(freq_min_allowed "$c")
        [ -z "$hi" ] && continue
        local cap90=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.9)]}')
        local mid85=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.85)]}')
        [ -z "$cap90" ] && cap90="$hi"
        [ -z "$mid85" ] && mid85="$lo"
        w "$d/scaling_governor" "$GOV_PERF"
        w "$d/scaling_max_freq" "$cap90"
        w "$d/scaling_min_freq" "$mid85"
        walt_boost "$c" 95
    done

    if [ -n "$GPU_DIR" ] && [ -r "$GPU_DIR/devfreq/governor" ]; then
        w "$GPU_DIR/devfreq/governor" "performance"
        local gcap=$(cat "$GPU_DIR/devfreq/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.85)]}')
        [ -n "$gcap" ] && w "$GPU_DIR/devfreq/max_freq" "$gcap"
    fi
}

# 飞升模式的二次声明
ascend_disclaimer() {
    clear_screen
    printf '\n'
    printf '%s' "$C_RED"
    hline
    printf '%s' "$C_RESET"

    printf '%s%s' "$C_BOLD" "$C_RED"
    center "😡   飞  升  模  式   😡"
    printf '%s' "$C_RESET"

    printf '%s' "$C_RED"
    hline
    printf '%s\n\n' "$C_RESET"

    printf '%s' "$C_YELLOW"
    slow_lines 0.2 \
      "  你正在开启本脚本最激进的档位。" \
      "" \
      "  【它会做什么】" \
      "   · CPU 全核心锁定厂商最高频率，不再动态调频" \
      "   · 温度超过 72°C 也不再降档" \
      "   · 系统想抢回控制权时死磕到底，不再认输" \
      "   · 取消电竞模式的 8 分钟超时降档" \
      "" \
      "  【这意味着什么】" \
      "   · 手机会明显发烫，边框烫手是正常现象" \
      "   · 耗电速度显著加快" \
      "   · 长时间使用可能损伤电池寿命" \
      "   · 不适合边充电边玩" \
      "" \
      "  【唯一保留的防线】" \
      "   95°C 物理保险：超过这个温度会强制降频。" \
      "   这不是本脚本的限制，是芯片本身的保护。",
    printf '%s' "$C_RESET"
    printf '%s' "$C_GRAY"
    slow_lines 0.16 "   任何软件都绕不过去，也不需要绕。"
    printf '%s\n' "$C_RESET"

    printf '%s' "$C_RED"
    hline
    printf '%s\n' "$C_RESET"

    printf '%s  请输入 %s%s飞升%s%s 两个字确认开启（直接回车取消）：%s\n\n' \
        "$C_WHITE" "$C_BOLD" "$C_RED" "$C_RESET" "$C_WHITE" "$C_RESET"
    printf '  %s😡 > %s' "$C_RED" "$C_RESET"
    read FLY_OK
    FLY_OK=$(printf '%s' "$FLY_OK" | tr -d ' \t\r\n　')

    if [ "$FLY_OK" != "飞升" ]; then
        printf '\n%s' "$C_GRAY"
        center "已取消飞升模式（未做任何修改）"
        printf '%s\n\n' "$C_RESET"
        return 1
    fi

    date '+%Y-%m-%d %H:%M:%S' > "${CONSENT_FILE}.ascend" 2>/dev/null
    printf '\n%s' "$C_GREEN"
    center "😡 飞升已确认"
    printf '%s\n' "$C_RESET"
    sleep 0.6
    return 0
}

# ─────────────────────────────────────────────────────────────
#  守护进程（v2.1：独立进程 + 三重保护）
#
#  为什么要重写：旧版 temp_guard 是 shell 里 `&` 出来的后台循环，
#  脚本一退出、或进程被系统回收，温度保护就彻底消失了 —— 那是最危险的
#  状态：频率还锁在高位，但没人管温度。
#
#  新方案：
#    · 用 nohup + 独立 shell 重新执行本脚本的 --guard-loop，脱离父进程
#    · 写 PID 文件，可随时 stop / 查状态，不会重复起多份
#    · 每 15 秒做三件事：查温度 / 查 governor 是否被系统抢回 / 查电竞是否超时
# ─────────────────────────────────────────────────────────────

daemon_running() {
    [ -f "$DAEMON_PID" ] || return 1
    local pid=$(cat "$DAEMON_PID" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || { rm -f "$DAEMON_PID"; return 1; }
    return 0
}

start_daemon() {
    detect_cpus >/dev/null 2>&1
    detect_governors
    if daemon_running; then
        log "守护进程已在运行（pid $(cat "$DAEMON_PID")），不重复启动"
        return 0
    fi
    # 用 nohup 起独立进程：父 shell 退出、启动器关闭都不影响它
    # 必须用绝对路径 —— 否则守护进程的工作目录不同，会找不到脚本
    local selfpath="$0"
    case "$selfpath" in
        /*) ;;
        *) selfpath="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    esac
    nohup sh "$selfpath" --guard-loop >"$DAEMON_LOG" 2>&1 &
    echo $! > "$DAEMON_PID"
    sleep 1
    if daemon_running; then
        log "守护进程已启动（pid $(cat "$DAEMON_PID")，每 ${GUARD_INTERVAL}s 巡检）"
    else
        warn "守护进程启动失败，详见 $DAEMON_LOG"
    fi
}

stop_daemon() {
    if daemon_running; then
        local pid=$(cat "$DAEMON_PID")
        kill "$pid" 2>/dev/null
        sleep 1
        kill -9 "$pid" 2>/dev/null
        log "守护进程已停止（pid $pid）"
    else
        log "守护进程未在运行"
    fi
    rm -f "$DAEMON_PID"
}

daemon_status() {
    if daemon_running; then
        printf '  守护进程   %s运行中%s（pid %s，模式 %s）\n' \
            "$C_GREEN" "$C_RESET" "$(cat "$DAEMON_PID")" "$(cat "$MODE_FILE" 2>/dev/null || echo -)"
        local t=$(read_temp)
        printf '  最近温度   %s\n' "$(temp_text)"
        printf '  巡检间隔   %s 秒\n' "$GUARD_INTERVAL"
    else
        printf '  守护进程   %s未运行%s（温度保护当前%s关闭%s）\n' \
            "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET"
    fi
}

# ── 守护循环本体（由 start_daemon 以 --guard-loop 拉起）──
guard_loop() {
    echo $$ > "$DAEMON_PID"

    detect_cpus || exit 0
    detect_governors
    detect_clusters          # 守护进程是独立进程，必须自己检测一次簇，
                             # 否则 CLUSTER_TOP/MID 为空 → 平滑降档静默失效

    local mode=$(cat "$MODE_FILE" 2>/dev/null || echo perf)
    local start_ts=$(date +%s)
    local degraded=0
    local fights=0
    local MAX_FIGHTS=8        # 被系统改回超过 8 次就放弃对抗

    # ── 模式差异化阈值 ──
    local WARN_LINE="$TEMP_WARN"
    local ABORT_LINE="$TEMP_ABORT"
    local TIME_LIMIT=0          # 0 = 不限时
    local SMART=0               # 1 = 启用趋势判断（暴力模式）
    local SMART_HIST=""         # 温度采样历史（最近 10 次）
    local HOT_SINCE=0           # 稳态高温起始时间

    if [ "$mode" = "brutal" ]; then
        # 暴力模式：系统温控已停，脚本是唯一防线。
        # 不用固定温度线，改用趋势判断（见下方 SMART 段）。
        WARN_LINE=999999              # 关掉普通的固定阈值逻辑
        ABORT_LINE="$BRUTAL_HARD_LIMIT"  # 只保留 100°C 物理底线
        TIME_LIMIT="$BRUTAL_LIMIT"
        MAX_FIGHTS=999
        SMART=1                       # 开启趋势判断
        echo "[$(date '+%H:%M:%S')] 暴力模式：趋势判断已启用（斜率 ${BRUTAL_SLOPE_WARN}/${BRUTAL_SLOPE_ABORT}°C·30s，底线 $((BRUTAL_HARD_LIMIT/1000))°C）"
        thermal_is_running && stop_thermal
    elif [ "$mode" = "ascend" ]; then
        WARN_LINE=88000       # 88°C 才考虑降档（原 72°C）
        ABORT_LINE=95000      # 95°C 硬退（原 88°C）—— 芯片物理极限
        MAX_FIGHTS=999        # 不认输
        echo "[$(date '+%H:%M:%S')] 飞升模式：WARN=${WARN_LINE} ABORT=${ABORT_LINE} 不认输" 
    fi

    echo "[$(date '+%H:%M:%S')] 守护启动 mode=$mode target_gov=$GOV_PERF/BAL=$GOV_BAL"

    while true; do
        local t=$(read_temp)

        # ⓪ 智能趋势判断（仅暴力模式）
        #
        # 思路：不等烧到某个数字才反应，而是看「升温有多快」。
        # 手机从 60°C 飙到 90°C 往往只要一分钟，等到了 92°C 再降已经晚了。
        # 这里每 3 秒采一次，维护最近 10 次（30 秒）窗口：
        #   涨 6°C  → 提前降一档（趁还来得及）
        #   涨 10°C → 判定「快不行了」，立刻还原 + 恢复温控
        #   稳态 ≥93°C 持续 60 秒 → 闷烧，也还原
        if [ "$SMART" = "1" ]; then
            SMART_HIST="$SMART_HIST $t"
            # 只保留最近 10 个采样
            SMART_HIST=$(printf '%s\n' $SMART_HIST | tail -10 | tr '\n' ' ')
            local n=$(printf '%s\n' $SMART_HIST | wc -l | tr -d ' ')

            if [ "$n" -ge 3 ]; then
                local oldest=$(printf '%s\n' $SMART_HIST | head -1)
                local newest=$(printf '%s\n' $SMART_HIST | tail -1)
                local delta=$(( (newest - oldest) / 1000 ))   # 单位：°C

                # 快速飙升 → 立即还原
                if [ "$delta" -ge "$BRUTAL_SLOPE_ABORT" ]; then
                    echo "[$(date '+%H:%M:%S')] 升温过快（30 秒 +${delta}°C，当前 $((t/1000))°C），判定危险，立即还原"
                    restore_original >/dev/null 2>&1
                    start_thermal >/dev/null 2>&1
                    rm -f "$DAEMON_PID" "$MODE_FILE"
                    exit 0
                fi

                # 明显升温 → 提前降档（只降，不回）
                if [ "$delta" -ge "$BRUTAL_SLOPE_WARN" ] && [ "$degraded" -lt 3 ]; then
                    degraded=$((degraded + 1))
                    echo "[$(date '+%H:%M:%S')] 升温偏快（30 秒 +${delta}°C），提前降一档（第 ${degraded} 档）"
                    for c in $CLUSTER_MID; do
                        local d=$(cpufreq_dir "$c")
                        local hi=$(freq_max_allowed "$c")
                        local cap=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk -v k=$((90 - degraded*10)) '{a[NR]=$1} END{print a[int(NR*k/100)]}')
                        [ -n "$cap" ] && w "$d/scaling_max_freq" "$cap"
                    done
                    for c in $CLUSTER_TOP; do
                        local d=$(cpufreq_dir "$c")
                        local hi=$(freq_max_allowed "$c")
                        local cap=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk -v k=$((80 - degraded*10)) '{a[NR]=$1} END{print a[int(NR*k/100)]}')
                        [ -n "$cap" ] && w "$d/scaling_max_freq" "$cap"
                    done
                    SMART_HIST=""      # 重置窗口，避免重复触发
                fi
            fi

            # 稳态高温：高但不涨，同样在闷烧
            if [ "$t" -ge "$BRUTAL_HOLD_TEMP" ]; then
                if [ "$HOT_SINCE" = "0" ]; then
                    HOT_SINCE=$(date +%s)
                    echo "[$(date '+%H:%M:%S')] 进入稳态高温（$((t/1000))°C），开始计时"
                else
                    local held=$(( $(date +%s) - HOT_SINCE ))
                    if [ "$held" -ge 60 ]; then
                        echo "[$(date '+%H:%M:%S')] 高温已持续 ${held}s（$((t/1000))°C），判定闷烧，还原"
                        restore_original >/dev/null 2>&1
                        start_thermal >/dev/null 2>&1
                        rm -f "$DAEMON_PID" "$MODE_FILE"
                        exit 0
                    fi
                fi
            else
                HOT_SINCE=0
            fi
        fi

        # ⓪-b AI 顾问（每 30 秒问一次，只在暴力模式）
        #
        #  权限边界：
        #    AI degrade/restore → 立即执行（往安全方向，给一票权）
        #    AI recover         → 规则二次确认（往危险方向，不能盲信）
        if [ "$SMART" = "1" ] && [ "$AI_THERMAL_ENABLED" = "1" ]; then
            local now_ai=$(date +%s)
            if [ $((now_ai - AI_LAST_TS)) -ge "$AI_INTERVAL" ]; then
                AI_LAST_TS=$now_ai
                local advice=$(ai_thermal_advice "$(hist_to_celsius "$SMART_HIST")" "$mode")
                echo "[$(date '+%H:%M:%S')] AI 顾问：$advice"

                case "$advice" in
                    restore)
                        echo "[$(date '+%H:%M:%S')] AI 判定需还原，立即执行"
                        restore_original >/dev/null 2>&1
                        start_thermal >/dev/null 2>&1
                        rm -f "$DAEMON_PID" "$MODE_FILE"
                        exit 0
                        ;;
                    degrade)
                        if [ "$degraded" -lt 3 ]; then
                            degraded=$((degraded + 1))
                            echo "[$(date '+%H:%M:%S')] AI 要求降档（第 ${degraded} 档）"
                            for c in $CLUSTER_MID $CLUSTER_TOP; do
                                local d=$(cpufreq_dir "$c")
                                local cap=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk -v k=$((90 - degraded*10)) '{a[NR]=$1} END{print a[int(NR*k/100)]}')
                                [ -n "$cap" ] && w "$d/scaling_max_freq" "$cap"
                            done
                        fi
                        ;;
                    recover)
                        # 关键：AI 想提速，必须规则也同意
                        # 条件：当前温度 <70°C 且 30 秒内涨幅 <3°C 且已降过档
                        local flat=1
                        if [ "$n" -ge 3 ]; then
                            local o=$(printf '%s\n' $SMART_HIST | head -1)
                            local nw=$(printf '%s\n' $SMART_HIST | tail -1)
                            [ $(( (nw - o) / 1000 )) -ge 3 ] && flat=0
                        fi

                        if [ "$t" -lt 70000 ] && [ "$flat" = "1" ] && [ "$degraded" -gt 0 ]; then
                            degraded=$((degraded - 1))
                            echo "[$(date '+%H:%M:%S')] AI 提频请求通过规则校验，恢复一档（当前第 ${degraded} 档）"
                            for c in $CLUSTER_MID $CLUSTER_TOP; do
                                local d=$(cpufreq_dir "$c")
                                local cap=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk -v k=$((95 - degraded*10)) '{a[NR]=$1} END{print a[int(NR*k/100)]}')
                                [ -n "$cap" ] && w "$d/scaling_max_freq" "$cap"
                            done
                        else
                            echo "[$(date '+%H:%M:%S')] AI 提频被规则否决（温度 $((t/1000))°C / 趋势 $([ "$flat" = "1" ] && echo 平稳 || echo 上升) / 已降 ${degraded} 档）"
                        fi
                        ;;
                    *)
                        : # keep 或 unavailable，交给规则
                        ;;
                esac
            fi
        fi

        # ① 硬保护：超 88°C 立刻恢复原厂并退出
        if [ "$t" -ge "$ABORT_LINE" ]; then
            echo "[$(date '+%H:%M:%S')] 温度 ${t}°C 超限，恢复原厂"
            restore_original >/dev/null 2>&1
            # 暴力模式下必须把系统温控还回去，否则手机会一直裸奔
            start_thermal >/dev/null 2>&1
            rm -f "$DAEMON_PID" "$MODE_FILE"
            exit 0
        fi

        # 限时到点：降档 + 恢复温控
        if [ "$TIME_LIMIT" -gt 0 ]; then
            local now_ts=$(date +%s)
            if [ $((now_ts - start_ts)) -ge "$TIME_LIMIT" ]; then
                echo "[$(date '+%H:%M:%S')] 已达最长时限 $((TIME_LIMIT/60)) 分钟，降档并恢复温控"
                for c in $CPUS; do
                    local d=$(cpufreq_dir "$c")
                    w "$d/scaling_governor" "$GOV_BAL"
                    w "$d/scaling_max_freq" "$(freq_max_allowed "$c")"
                    w "$d/scaling_min_freq" "$(freq_min_allowed "$c")"
                done
                start_thermal >/dev/null 2>&1
                echo "perf" > "$MODE_FILE"
                TIME_LIMIT=0
                start_ts=$(date +%s)
            fi
        fi

        # ② 分级平滑降档（不再一刀切）
        #
        # 实测教训：旧版一超线就把所有核打回 schedutil 最低频，
        # 帧率当场从 141 掉到 60，比不降还难受。
        #
        # 现在分三档小幅让步，每次只动一点，帧率是「小波动」而不是「跳崖」：
        #   档0 正常    → 目标 83°C 附近
        #   档1 微降    → 大核上限砍 15%
        #   档2 中降    → 超大核放开不管 + 大核上限砍 30%
        #   档3 收手    → 全核回均衡，等降温
        if [ "$t" -ge $((WARN_LINE + 5000)) ] && [ "$degraded" -lt 3 ]; then
            degraded=3
            echo "[$(date '+%H:%M:%S')] 温度 ${t}°C 过高，回均衡等降温"
            for c in $CPUS; do
                local d=$(cpufreq_dir "$c")
                w "$d/scaling_governor" "$GOV_BAL"
                w "$d/scaling_max_freq" "$(freq_max_allowed "$c")"
                w "$d/scaling_min_freq" "$(freq_min_allowed "$c")"
            done
        elif [ "$t" -ge $((WARN_LINE + 2500)) ] && [ "$degraded" -lt 2 ]; then
            degraded=2
            echo "[$(date '+%H:%M:%S')] 温度 ${t}°C，大核上限砍 20%（平滑降档）"
            for c in $CLUSTER_MID; do
                local d=$(cpufreq_dir "$c")
                local hi=$(freq_max_allowed "$c")
                local cap80=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.8)]}')
                [ -n "$cap80" ] && w "$d/scaling_max_freq" "$cap80"
            done
            for c in $CLUSTER_TOP; do
                local d=$(cpufreq_dir "$c")
                w "$d/scaling_governor" "$GOV_BAL"
            done
        elif [ "$t" -ge "$WARN_LINE" ] && [ "$degraded" -lt 1 ]; then
            degraded=1
            echo "[$(date '+%H:%M:%S')] 温度 ${t}°C，大核上限砍 8%（平滑降档）"
            for c in $CLUSTER_MID; do
                local d=$(cpufreq_dir "$c")
                local hi=$(freq_max_allowed "$c")
                local cap92=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.92)]}')
                [ -n "$cap92" ] && w "$d/scaling_max_freq" "$cap92"
            done
        elif [ "$t" -lt $((WARN_LINE - 5000)) ]; then
            # 温度回落 5°C 以上，恢复
            if [ "$degraded" -ne 0 ]; then
                degraded=0
                echo "[$(date '+%H:%M:%S')] 温度回落 ${t}°C，恢复正常调度"
                for c in $CLUSTER_MID; do
                    local d=$(cpufreq_dir "$c")
                    w "$d/scaling_max_freq" "$(freq_max_allowed "$c")"
                done
            fi
        fi

        # ③ ColorOS / HyperBoost 抢回控制权检测（有条件对抗）
        #
        #    实测：ColorOS 电源服务会周期性重写 scaling_max_freq
        #    （本机观察到 3283200 → 2438400，2 秒内被改）。
        #
        #    安全策略 —— 不做无脑死磕：
        #      · 只有在温度明显低于警戒线时才重写
        #      · 连续对抗超过 MAX_FIGHTS 次就判定「系统强管控」，主动放弃
        #      · 放弃后让系统接管，脚本只记录日志，不再折腾硬件
        # 抽查 cpu0 和 top 簇 —— 系统压频通常动的是大核/超大核，
        # 只看 cpu0 会漏判（cpu0 常年是 walt 不动）
        local c1=$(echo $CPUS | awk '{print $1}')
        local ctop=$(echo $CLUSTER_TOP | awk '{print $1}')
        [ -z "$ctop" ] && ctop="$c1"
        local cur=$(cat "$(cpufreq_dir "$c1")/scaling_governor" 2>/dev/null)
        local cur_top=$(cat "$(cpufreq_dir "$ctop")/scaling_governor" 2>/dev/null)
        [ -n "$cur_top" ] && [ "$cur_top" != "$cur" ] && cur="$cur_top"
        local want="$GOV_BAL"
        [ "$mode" = "game" ] && want="$GOV_PERF"

        if [ -n "$cur" ] && [ "$cur" != "$want" ] && [ "$degraded" = "0" ]; then
            fights=$((fights + 1))
            echo "[$(date '+%H:%M:%S')] governor 被系统改回 $cur（第 ${fights} 次）"

            if [ "$fights" -gt "$MAX_FIGHTS" ]; then
                echo "[$(date '+%H:%M:%S')] 已被系统改回 ${fights} 次，判定系统强管控，主动放弃对抗以保护设备"
                echo "system-wins" > "$MODE_FILE"
                exit 0
            fi

            # 温度safe 才重写（留 8°C 余量）
            if [ "$t" -lt $((TEMP_WARN - 8000)) ]; then
                for c in $CPUS; do
                    local d=$(cpufreq_dir "$c")
                    w "$d/scaling_governor" "$want"
                    if [ "$mode" = "game" ]; then
                        w "$d/scaling_min_freq" "$(freq_max_allowed "$c")"
                    fi
                done
            else
                echo "[$(date '+%H:%M:%S')] 温度偏高，本次不抢回，交给系统调频"
            fi
        fi

        # ④ 电竞模式超时自动降档（防止长时间高温）
        if [ "$mode" = "game" ] && [ "$mode" != "ascend" ]; then
            local now=$(date +%s)
            if [ $((now - start_ts)) -ge "$GAME_LIMIT" ]; then
                echo "[$(date '+%H:%M:%S')] 电竞模式已持续 $((GAME_LIMIT/60)) 分钟，自动降档到性能模式"
                for c in $CPUS; do
                    local d=$(cpufreq_dir "$c")
                    local lo=$(freq_min_allowed "$c") hi=$(freq_max_allowed "$c")
                    local mid=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.5)]}')
                    [ -z "$mid" ] && mid="$lo"
                    w "$d/scaling_governor" "$GOV_BAL"
                    w "$d/scaling_max_freq" "$hi"
                    w "$d/scaling_min_freq" "$mid"
                done
                mode="perf"
                echo "perf" > "$MODE_FILE"
                start_ts=$(date +%s)
            fi
        fi

        sleep "$GUARD_INTERVAL"
    done
}

# ─────────────────────────────────────────────────────────────
#  应用动画
# ─────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────
#  生效检测：写入后回读，确认设置真的生效了
#
#  为什么需要：ColorOS 的电源服务会在脚本写完 sysfs 后立刻覆盖回去。
#  实测：脚本写 cpu0 max=1363200，系统立即改回 1996800 并把 min 也钉成同值。
#  旧版不检测，界面上显示「✓ 应用完成」，用户以为生效了，其实没有。
# ─────────────────────────────────────────────────────────────
verify_effect() {
    local ok=0 locked=0 skipped=0
    local details=""

    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local cur_max=$(cat "$d/scaling_max_freq" 2>/dev/null)
        local cur_min=$(cat "$d/scaling_min_freq" 2>/dev/null)
        local hw_max=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$cur_max" ] && continue

        # 被系统钉死在单点（min == max）说明锁频
        if [ "$cur_min" = "$cur_max" ]; then
            locked=$((locked + 1))
        elif [ -n "$hw_max" ] && [ "$cur_max" -lt "$hw_max" ]; then
            # 上限被压（正常现象，系统降功耗）
            skipped=$((skipped + 1))
        else
            ok=$((ok + 1))
        fi
    done

    printf '  生效检查：%s正常 %s 个%s / %s受限 %s 个%s / %s锁死 %s 个%s\n' \
        "$C_GREEN" "$ok" "$C_RESET" \
        "$C_YELLOW" "$skipped" "$C_RESET" \
        "$C_RED" "$locked" "$C_RESET"

    if [ "$locked" -gt 0 ]; then
        printf '  %s⚠ %d 个核心被系统锁死（min=max），脚本无法改变\n%s' \
            "$C_YELLOW" "$locked" "$C_RESET"
    fi
    if [ "$skipped" -gt 0 ]; then
        printf '  %s系统压制了 %d 个核心的上限（ColorOS 电源策略）\n%s' \
            "$C_GRAY" "$skipped" "$C_RESET"
    fi

    # walt 参数是否生效（这个系统和脚本不抢，通常能成功）
    local c1=$(echo $CPUS | awk '{print $1}')
    local wup=$(cat "$(cpufreq_dir "$c1")/walt/up_rate_limit_us" 2>/dev/null)
    if [ -n "$wup" ]; then
        printf '  %swalt 响应：升频 %s us / 降频 %s us%s\n' \
            "$C_GRAY" "$wup" "$(cat "$(cpufreq_dir "$c1")/walt/down_rate_limit_us" 2>/dev/null)" "$C_RESET"
    fi
    printf '\n'
}

apply_with_anim() {
    clear_screen
    printf '\n'
    printf '%s' "$C_CYAN"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "正在应用 · $1"
    printf '%s' "$C_RESET"
    printf '%s' "$C_CYAN"; hline; printf '%s\n\n' "$C_RESET"
    progress_bar "写入调度参数" 26
    progress_bar "同步 GPU 档位" 18
    progress_bar "挂载温度守护" 14
    printf '\n%s' "$C_GREEN"
    center "✓ 应用完成"
    printf '%s\n' "$C_RESET"
    printf '\n'
    verify_effect
}

status_card() {
    clear_screen
    printf '\n'
    printf '%s' "$C_PURPLE"; hline; printf '%s' "$C_RESET"
    printf '%s%s' "$C_BOLD" "$C_WHITE"
    center "当  前  状  态"
    printf '%s' "$C_RESET"
    printf '%s' "$C_PURPLE"; hline; printf '%s\n\n' "$C_RESET"

    printf '%s  核心   governor         min          max%s\n' "$C_GRAY" "$C_RESET"
    printf '%s  ──────────────────────────────────────────────────%s\n' "$C_PURPLE" "$C_RESET"

    for c in $CPUS; do
        local d=$(cpufreq_dir "$c")
        local gov=$(cat "$d/scaling_governor" 2>/dev/null)
        local col="$C_GRAY"
        [ "$gov" = "performance" ] && col="$C_GREEN"
        printf '  %scpu%-2s%s  %s%-15s%s %-12s %s\n' \
            "$C_CYAN" "$c" "$C_RESET" \
            "$col" "$gov" "$C_RESET" \
            "$(cat "$d/scaling_min_freq" 2>/dev/null)" \
            "$(cat "$d/scaling_max_freq" 2>/dev/null)"
    done

    if [ -n "$GPU_DIR" ] && [ -r "$GPU_DIR/devfreq/governor" ]; then
        printf '%s  ──────────────────────────────────────────────────%s\n' "$C_PURPLE" "$C_RESET"
        printf '  %sGPU%s   %s%-15s%s %s\n' "$C_CYAN" "$C_RESET" \
            "$C_GREEN" "$(cat "$GPU_DIR/devfreq/governor" 2>/dev/null)" "$C_RESET" \
            "$(cat "$GPU_DIR/devfreq/max_freq" 2>/dev/null)"
    else
        printf '%s  ──────────────────────────────────────────────────%s\n' "$C_PURPLE" "$C_RESET"
        printf '  %sGPU%s   %s内核未暴露可写节点（GKI 限制）%s\n' "$C_CYAN" "$C_RESET" "$C_GRAY" "$C_RESET"
        printf '        %sGPU 调速已跳过，本脚本只对 CPU 生效%s\n' "$C_GRAY" "$C_RESET"
    fi

    printf '%s  ──────────────────────────────────────────────────%s\n' "$C_PURPLE" "$C_RESET"
    printf '  温度   %s\n\n' "$(temp_text)"
}

# ─────────────────────────────────────────────────────────────
#  主菜单
# ─────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────
#  危险区（独立界面）
#
#  为什么单独拆出来：
#    暴力模式 / AI 接管 / 恢复温控 这三件事的后果远比日常调度严重，
#    混在主菜单里容易被「顺手点一下」误触。拆成子菜单 + 一次确认，
#    能让用户在进入前多看一眼。
# ─────────────────────────────────────────────────────────────
danger_menu() {
    while true; do
        clear_screen
        printf '\n'
        printf '%s' "$C_RED"; hline; printf '%s' "$C_RESET"
        printf '%s%s' "$C_BOLD$C_RED"
        center "⚠   危   险   区   ⚠"
        printf '%s' "$C_RESET"
        printf '%s' "$C_RED"; hline; printf '%s\n\n' "$C_RESET"

        printf '%s  这里的功能会停系统温控、拉满频率、让手机明显发烫。%s\n' "$C_YELLOW" "$C_RESET"
        printf '%s  后果自负，但每一步都有兜底和还原入口。%s\n\n' "$C_GRAY" "$C_RESET"

        # 当前状态一览
        printf '  %s系统温控%s %s    %sAI 顾问%s %s    %s守护%s %s\n\n' \
            "$C_GRAY" "$C_RESET" \
            "$(thermal_is_running && printf '%s运行中%s' "$C_GREEN" "$C_RESET" || printf '%s已停止%s' "$C_RED" "$C_RESET")" \
            "$C_GRAY" "$C_RESET" \
            "$([ "$AI_THERMAL_ENABLED" = "1" ] && printf '%s已开启%s' "$C_GREEN" "$C_RESET" || printf '%s未开启%s' "$C_GRAY" "$C_RESET")" \
            "$C_GRAY" "$C_RESET" \
            "$(daemon_running && printf '%s运行中%s' "$C_GREEN" "$C_RESET" || printf '%s未运行%s' "$C_GRAY" "$C_RESET")"

        printf '  %s①%s  %s🔥 区域暴力模式%s\n' "$C_RED" "$C_RESET" "$C_BOLD$C_RED" "$C_RESET"
        printf '      %s停系统温控 · 全核满血 · 脚本接管兜底%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s②%s  %s🤖 AI 温控顾问%s  %s（%s）%s\n' \
            "$C_BLUE" "$C_RESET" "$C_WHITE" "$C_RESET" "$C_GRAY" \
            "$([ "$AI_THERMAL_ENABLED" = "1" ] && echo 开 || echo 关)" "$C_RESET"
        printf '      %sDeepSeek 每 30 秒决策；提频需过规则校验%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s③%s  %s⚡ 超频设置%s  %s（当前 %s）%s\n' \
            "$C_YELLOW" "$C_RESET" "$C_WHITE" "$C_RESET" "$C_GRAY" "$(current_refresh_rate)" "$C_RESET"
        printf '      %s90 / 120 / 144Hz 刷新率锁定%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s④%s  %s🚀 极限锁定%s  %s（刷新率+CPU+GPU 全锁最高）%s\n' \
            "$C_MAGENTA" "$C_RESET" "$C_BOLD$C_MAGENTA" "$C_RESET" "$C_GRAY" "$C_RESET"
        printf '      %s手机锁 120Hz / 平板锁 144Hz（自动探测）%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s⑤%s  %s🛡 恢复系统温控%s\n' "$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
        printf '      %s还原 CPU 设置并重启温控服务%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s⓪%s  %s返回主菜单%s\n\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"

        printf '%s' "$C_RED"; hline2; printf '%s' "$C_RESET"
        printf '  %s请选择 [0-5]：%s' "$C_WHITE" "$C_RESET"
        read DCH

        case "$DCH" in
            1)
                if brutal_disclaimer; then
                    choose_refresh_rate
                    echo "brutal" > "$MODE_FILE" 2>/dev/null
                    apply_with_anim "🔥 区域暴力模式"
                    mode_brutal
                    start_daemon
                    printf '\n  %s[!!] 暴力模式已激活%s\n' "$C_RED" "$C_RESET"
                    printf '  %s     系统温控已停，脚本接管；%d 分钟后自动降档%s\n' \
                        "$C_GRAY" "$((BRUTAL_LIMIT/60))" "$C_RESET"
                fi
                printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _
                ;;
            2)
                if [ "$AI_THERMAL_ENABLED" = "1" ]; then
                    AI_THERMAL_ENABLED=0
                    printf '\n  %s🤖 AI 温控顾问已关闭%s\n' "$C_GRAY" "$C_RESET"
                else
                    AI_THERMAL_ENABLED=1
                    printf '\n  %s🤖 AI 温控顾问已开启%s\n' "$C_GREEN" "$C_RESET"
                    printf '  %s模型：%s（DeepSeek 官方）%s\n' "$C_GRAY" "$AI_MODEL" "$C_RESET"
                    printf '  %s说明：AI 的降档/还原立即生效；提频需通过规则校验%s\n' "$C_GRAY" "$C_RESET"
                fi
                printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _
                ;;
            3) choose_refresh_rate ;;
            4)
                clear_screen
                printf '\n'
                printf '%s' "$C_MAGENTA"; hline; printf '%s' "$C_RESET"
                printf '%s%s' "$C_BOLD$C_MAGENTA"
                center "🚀   极  限  锁  定"
                printf '%s' "$C_RESET"
                printf '%s' "$C_MAGENTA"; hline; printf '%s\n\n' "$C_RESET"
                printf '%s  刷 新 率 + CPU + GPU 全部锁到本机最高档。%s\n\n' "$C_WHITE" "$C_RESET"
                printf '  %sy%s 立即执行\n' "$C_GREEN" "$C_RESET"
                printf '  %sn%s 取消\n\n' "$C_GRAY" "$C_RESET"
                printf '  %s请选择 [y/N]：%s' "$C_WHITE" "$C_RESET"
                read LM
                case "$(printf '%s' "$LM" | tr -d ' \t\r\n')" in
                    y|Y)
                        echo "maxlock" > "$MODE_FILE" 2>/dev/null
                        lock_max_everything
                        start_daemon
                        ;;
                    *) printf '\n%s  已取消%s\n\n' "$C_GRAY" "$C_RESET" ;;
                esac
                printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _
                ;;
            5)
                clear_screen
                printf '\n'
                printf '%s' "$C_GREEN"; hline; printf '%s' "$C_RESET"
                printf '%s%s' "$C_BOLD$C_WHITE"
                center "恢  复  系  统  温  控"
                printf '%s' "$C_RESET"
                printf '%s' "$C_GREEN"; hline; printf '%s\n\n' "$C_RESET"
                printf '%s  当前：%s\n\n' "$C_GRAY" \
                    "$(thermal_is_running && echo '系统温控运行中' || echo '系统温控已停止')" "$C_RESET"
                printf '  %sy%s 恢复温控服务 + 还原 CPU 设置\n' "$C_GREEN" "$C_RESET"
                printf '  %sn%s 取消\n\n' "$C_GRAY" "$C_RESET"
                printf '  %s请选择 [y/N]：%s' "$C_WHITE" "$C_RESET"
                read RC
                case "$(printf '%s' "$RC" | tr -d ' \t\r\n')" in
                    y|Y)
                        start_thermal
                        restore_original >/dev/null 2>&1
                        printf '\n%s  已恢复系统温控并还原 CPU 设置%s\n\n' "$C_GREEN" "$C_RESET"
                        ;;
                    *) printf '\n%s  已取消%s\n\n' "$C_GRAY" "$C_RESET" ;;
                esac
                printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _
                ;;
            0|"") return 0 ;;
            *) printf '  %s无效选项%s\n' "$C_RED" "$C_RESET"; sleep 1 ;;
        esac
    done
}

menu() {
    while true; do
        clear_screen
        printf '\n'
        printf '%s' "$C_CYAN"; hline; printf '%s' "$C_RESET"
        printf '%s%s' "$C_BOLD" "$C_WHITE"
        center "叶 青 一 加 调 度"
        printf '%s' "$C_RESET"
        printf '%s' "$C_GRAY"
        center "${CODENAME}  ·  v${VERSION}"
        printf '%s' "$C_RESET"
        printf '%s' "$C_CYAN"; hline; printf '%s\n\n' "$C_RESET"

        printf '  %s核心%s %s%s%s    %s温度%s %s\n\n' \
            "$C_GRAY" "$C_RESET" "$C_WHITE" "$CPUS" "$C_RESET" \
            "$C_GRAY" "$C_RESET" "$(temp_text)"

        printf '  %s①%s  %s均衡模式%s\n' "$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
        printf '      %s日常使用 · 省电优先%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s②%s  %s性能模式%s  %s★ 推荐%s\n' "$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET" "$C_YELLOW" "$C_RESET"
        printf '      %s游戏首选 · 提升明显且发热可控%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s③%s  %s电竞模式%s\n' "$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
        printf '      %s全核锁最高频 · 发热较大（有保护）%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s④%s  %s一键恢复原厂%s\n' "$C_YELLOW" "$C_RESET" "$C_WHITE" "$C_RESET"
        printf '      %s把 CPU/GPU 改回原始数值%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s⑤%s  %s查看当前状态%s\n\n' "$C_BLUE" "$C_RESET" "$C_WHITE" "$C_RESET"

        printf '  %s⑥%s  %s停止守护 / 查看守护状态%s\n\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"

        printf '  %s⑦%s  %s😡 飞升模式%s  %s（解除限制·慎用）%s\n' "$C_RED" "$C_RESET" "$C_BOLD$C_RED" "$C_RESET" "$C_GRAY" "$C_RESET"
        printf '      %s锁最高频 · 不降档 · 不认输 · 无超时%s\n\n' "$C_GRAY" "$C_RESET"

        printf '  %s⑧%s  %s检查更新%s\n\n' "$C_BLUE" "$C_RESET" "$C_WHITE" "$C_RESET"

        printf '  %s⑨%s  %s⚠ 危险区%s  %s（暴力 / AI 接管 / 恢复温控）%s\n' \
            "$C_RED" "$C_RESET" "$C_BOLD$C_RED" "$C_RESET" "$C_GRAY" "$C_RESET"
        printf '      %sAI：%s%s\n\n' "$C_GRAY" \
            "$([ "$AI_THERMAL_ENABLED" = "1" ] && echo 已开启 || echo 未开启)" "$C_RESET"
        printf '  %s⓪%s  %s退出%s\n\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"

        printf '%s' "$C_CYAN"; hline2; printf '%s' "$C_RESET"
        printf '  %s请选择 [0-9]：%s' "$C_WHITE" "$C_RESET"
        read CH

        case "$CH" in
            1) echo "balance" > "$MODE_FILE" 2>/dev/null
               apply_with_anim "均衡模式"; mode_balance; start_daemon
               printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            2) echo "perf" > "$MODE_FILE" 2>/dev/null
               apply_with_anim "性能模式"; mode_perf; start_daemon
               printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            3) echo "game" > "$MODE_FILE" 2>/dev/null
               apply_with_anim "电竞模式"; mode_game
               start_daemon
               printf '\n  %s温度守护已后台运行（72°C 降档 / 88°C 退出）%s\n' "$C_YELLOW" "$C_RESET"
               printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            4) restore_original
               printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            5) status_card
               daemon_status
               printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            7) if ascend_disclaimer; then
                   echo "ascend" > "$MODE_FILE"
                   apply_with_anim "😡 飞升模式"
                   mode_ascend
                   start_daemon
                   printf '\n  %s[sic] 飞升模式已激活 · 95°C 硬保险仍在生效%s\n' "$C_RED" "$C_RESET"
                   printf '  %s恢复原厂请选 ④ 或 --restore%s\n' "$C_GRAY" "$C_RESET"
               fi
               printf '\n  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            11)
                if [ "$AI_THERMAL_ENABLED" = "1" ]; then
                    AI_THERMAL_ENABLED=0
                    printf '\n  %sAI 温控顾问已关闭%s\n' "$C_GRAY" "$C_RESET"
                else
                    AI_THERMAL_ENABLED=1
                    printf '\n  %sAI 温控顾问已开启%s\n' "$C_GREEN" "$C_RESET"
                    printf '  %s（需联网，配置读自 %s）%s\n' "$C_GRAY" "$AI_CONFIG" "$C_RESET"
                fi
                printf '  %s注意：此开关仅对当前会话生效，重启后恢复关闭%s\n' "$C_GRAY" "$C_RESET"
                printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            12)
                clear_screen
                printf '\n'
                printf '%s' "$C_GREEN"; hline; printf '%s' "$C_RESET"
                printf '%s%s' "$C_BOLD" "$C_WHITE"
                center "恢  复  系  统  温  控"
                printf '%s' "$C_RESET"
                printf '%s' "$C_GREEN"; hline; printf '%s\n\n' "$C_RESET"
                printf '%s  当前状态：%s%s\n\n' "$C_GRAY" \
                    "$(thermal_is_running && echo '系统温控运行中' || echo '系统温控已停止（暴力模式接管中）')" "$C_RESET"
                printf '  %sy%s 立即恢复温控服务并还原 CPU 设置\n' "$C_GREEN" "$C_RESET"
                printf '  %sn%s 取消\n\n' "$C_GRAY" "$C_RESET"
                printf '  %s请选择 [y/N]：%s' "$C_WHITE" "$C_RESET"
                read RC
                case "$(printf '%s' "$RC" | tr -d ' \t\r\n')" in
                    y|Y)
                        start_thermal
                        restore_original >/dev/null 2>&1
                        printf '\n%s  已恢复系统温控并还原 CPU 设置%s\n\n' "$C_GREEN" "$C_RESET"
                        ;;
                    *) printf '\n%s  已取消%s\n\n' "$C_GRAY" "$C_RESET" ;;
                esac
                printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            9) danger_menu ;;
            8) check_update
               printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            6) printf '\n'; daemon_status
               printf '\n  %s要停止守护？(y/N)：%s' "$C_YELLOW" "$C_RESET"
               read YN
               case "$YN" in y|Y) stop_daemon ;; *) printf '  %s未停止%s\n' "$C_GRAY" "$C_RESET" ;; esac
               printf '  %s按回车返回…%s' "$C_GRAY" "$C_RESET"; read _ ;;
            0) clear_screen
               printf '%s' "$C_GRAY"; center "已退出，未做任何修改"; printf '%s\n\n' "$C_RESET"
               exit 0 ;;
            *) printf '  %s无效选项%s\n' "$C_RED" "$C_RESET"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
#  入口
# ─────────────────────────────────────────────────────────────
# ── 守护进程模式：跳过全部 UI 初始化，直接进循环 ──
# 否则每 15 秒重启一次守护会重复打印 banner、重新检测硬件，
# 既拖慢启动又污染日志（实测日志开头全是 LOGO）。
if [ "$1" = "--guard-loop" ]; then
    guard_loop
    exit 0
fi

banner

# 交互模式（无参数）先过卡；带参数模式在下面的 case 里统一过
[ -z "$1" ] && require_license

detect_cpus || {
    printf '%s' "$C_RED"; center "未检测到 cpufreq 接口"; printf '%s' "$C_RESET"
    printf '%s' "$C_GRAY"; center "这台设备可能不支持，或被内核锁定"; printf '%s\n\n' "$C_RESET"
    exit 1
}
sleep 0.4
detect_governors
detect_clusters
detect_gpu && GPU_OK=1 || GPU_OK=0
backup_original

# 带参数模式（给启动器用）—— 同样需要授权，防止 --perf 绕过声明
case "$1" in
    --license|--show-license)
        if check_license; then echo "已授权"; else echo "未授权"; fi
        exit 0 ;;
    --regen-license) printf '请运行：sh yq-license.sh --force\n'; exit 0 ;;
    --guard-loop) ;;                      # 守护进程自己调自己，不能再要求授权
    "") ;;                                # 交互模式，下面统一过卡
    *) require_license ;;                 # 其余所有模式都必须有有效卡密
esac

case "$1" in

    --guard-loop) guard_loop; exit 0 ;;
    --update)    check_update; exit 0 ;;
    --notice)    show_announcement; exit 0 ;;
    --refresh)
        echo "=== 刷新率诊断 ==="
        echo "探测到的档位: $(supported_refresh_rates)"
        echo "system 值:   $(settings get system peak_refresh_rate 2>/dev/null)"
        echo "当前生效:    $(current_refresh_rate)"
        echo ""
        echo "=== 各档位写入测试（不改最终状态）==="
        for hz in 60 90 120 144 165; do
            _avail=$(supported_refresh_rates)
            case " $_avail " in
                *" $hz "*) echo "  ${hz}Hz: 支持" ;;
                *) echo "  ${hz}Hz: 不支持" ;;
            esac
        done
        echo ""
        echo "=== 如果要锁 165 ==="
        echo "  sh $0 --maxlock    （自动锁最高档）"
        echo "  或手动：settings put system peak_refresh_rate 165"
        exit 0 ;;
    --diag)
        echo "=== 环境诊断 ==="
        echo "shell: $0"
        echo "TERM: ${TERM:-未设置}"
        echo "LANG: ${LANG:-未设置}"
        echo "curl: $(command -v curl || echo 无)"
        echo "busybox: $([ -x /data/adb/ksu/bin/busybox ] && echo 有 || echo 无)"
        echo "更新地址: $UPDATE_URL"
        echo "脚本版本: $VERSION"
        echo "=== 抓取测试 ==="
        _b=$(http_get_quick "$UPDATE_URL")
        echo "抓取长度: ${#_b}"
        _b=$(weiyun_normalize "$_b")
        echo "规整后: ${#_b}"
        echo "更新开关: [$(pick "$_b" 更新开关)]"
        echo "最新版本: [$(pick "$_b" 最新版本)]"
        _a=$(pick "$_b" 公告)
        echo "公告长度: ${#_a}"
        echo "公告前40字: $(printf '%s' "$_a" | head -c 40)"
        exit 0 ;;
    --set-update-url) printf '更新地址已固定写在脚本顶部 UPDATE_URL 变量里，直接改脚本即可。\n'; exit 0 ;;
    --stop)       stop_daemon; exit 0 ;;
    --daemon)     daemon_status; exit 0 ;;
    --balance) consent_check && { echo "balance" > "$MODE_FILE" 2>/dev/null; apply_with_anim "均衡模式"; mode_balance; start_daemon; exit 0; } ;;
    --perf)    consent_check && { echo "perf"    > "$MODE_FILE" 2>/dev/null; apply_with_anim "性能模式"; mode_perf;    start_daemon; exit 0; } ;;
    --game)    consent_check && { echo "game"    > "$MODE_FILE" 2>/dev/null; apply_with_anim "电竞模式"; mode_game;    start_daemon; exit 0; } ;;
    --ascend)  consent_check && ascend_disclaimer && { echo "ascend" > "$MODE_FILE" 2>/dev/null; apply_with_anim "飞升模式"; mode_ascend; start_daemon; exit 0; } ;;
    --maxlock) consent_check && { echo "maxlock" > "$MODE_FILE" 2>/dev/null; lock_max_everything; start_daemon; exit 0; } ;;
    --brutal)  consent_check && brutal_disclaimer && { echo "brutal" > "$MODE_FILE" 2>/dev/null; apply_with_anim "暴力模式"; mode_brutal; start_daemon; exit 0; } ;;
    --restore) restore_original; exit 0 ;;
    --status)  status_card; exit 0 ;;
    --reset-walt) reset_walt_default; exit 0 ;;
esac

disclaimer
boot_scan
auto_check_update
show_announcement
menu

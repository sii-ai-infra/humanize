#!/usr/bin/env bash
#
# Stop Hook for RLCR loop
#
# Intercepts Claude's exit attempts and uses Codex to review work.
# If Codex doesn't confirm completion, blocks exit and feeds review back.
#
# State directory: .humanize/rlcr/<timestamp>/
# State file: state.md (current_round, max_iterations, codex config)
# Summary file: round-N-summary.md (Claude's work summary)
# Review prompt: round-N-review-prompt.md (prompt sent to Codex)
# Review result: round-N-review-result.md (Codex's review)
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# DEFAULT_CODEX_MODEL and DEFAULT_CODEX_EFFORT are provided by loop-common.sh (sourced below)
DEFAULT_CODEX_TIMEOUT=5400

# ========================================
# Read Hook Input
# ========================================

HOOK_INPUT=$(cat)

# NOTE: We intentionally do NOT check stop_hook_active here.
# For iterative loops, stop_hook_active will be true when Claude is continuing
# from a previous blocked stop. We WANT to run Codex review each iteration.
# Loop termination is controlled by:
# - No active loop directory (no state.md) -> exit early below
# - Codex outputs MARKER_COMPLETE -> allow exit
# - current_round >= max_iterations -> allow exit

# ========================================
# Find Active Loop
# ========================================

# Source shared loop functions and template loader
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

PROJECT_ROOT="$(resolve_project_root)" || exit 0
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Source portable timeout wrapper for git operations
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Source methodology analysis library
source "$SCRIPT_DIR/lib/methodology-analysis.sh"

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Template directory is set by loop-common.sh via template-loader.sh

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$HOOK_INPUT")

LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID" true)

# ========================================
# Idle-Round Detector (no implementation output)
# ========================================
# A round's only valid outputs are a real change under solution/ or a fresh formal
# measurement.  Design docs, feasibility maths and evidence-only rejections are
# means, not results.  Observed on the three highest-headroom operators: three
# consecutive rounds each ending with "no change to solution/ this round", all
# while the recoverable score sat untouched.
#
# Identity of a round's code state = the git tree object of solution/ plus whether
# anything is dirty underneath it (an uncommitted edit still counts as output).
# Two consecutive rounds with an identical state mean the loop is circling.
#
# This does NOT block or terminate: it appends an escalating instruction to the
# next round's prompt, so the loop's own machinery stays in charge.
solution_state_id() {
    local tree dirty
    tree=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse "HEAD:solution" 2>/dev/null) || tree="none"
    dirty=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain -- solution 2>/dev/null | md5sum | cut -c1-8)
    printf '%s-%s' "$tree" "$dirty"
}

idle_round_streak() {
    local log="$LOOP_DIR/.solution-state-log" now prev streak=0
    now=$(solution_state_id)
    [[ "$now" == "none-"* ]] && { printf '0'; return; }
    printf '%s\n' "$now" >> "$log"
    # 统计末尾有多少条与最后一条相同
    while read -r prev; do
        if [[ "$prev" == "$now" ]]; then streak=$((streak + 1)); else streak=0; fi
    done < "$log"
    printf '%s' "$((streak - 1))"   # 减去本条自身
}

# ========================================
# Noise-Band Detector (deciding on differences smaller than the measurement spread)
# ========================================
# A loop can look busy and still learn nothing: every round produces a candidate
# and a fresh measurement, but the score moves less than the run-to-run spread, and
# the agent adopts/rejects on that movement anyway.  Observed on two operators —
# one cycled "opt: try X" / "docs: reject X" eight times inside an 0.5-point band,
# the other rejected a whole candidate family on a 0.3-point difference.
#
# The band is estimated from the loop's own history rather than hard-coded: take
# the score of every formal report produced since the loop started, and use
# peak-to-trough as the observed spread.  If the last few rounds all sit inside it,
# no adopt/reject decision taken on those differences is supportable.
#
# Like the idle-round detector this only appends guidance to the next prompt; it
# never blocks or terminates.
recent_scores() {
    local dir="$PROJECT_ROOT/reports" f
    [[ -d "$dir" ]] || return 0
    for f in $(ls -t "$dir"/cann_final_eval_*.json 2>/dev/null | head -8); do
        python3 - "$f" 2>/dev/null <<'PYEOF'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for op in d.get("operators") or []:
    cs=[c for c in (op.get("cases") or []) if c.get("status")=="success" and c.get("elapsed_us")]
    if cs and op.get("score") is not None:
        print(f"{op['score']:.4f}"); break
PYEOF
    done
}

append_noise_band_note() {
    local file="$1" scores n
    # `| head` 会在取够行数后关闭管道，上游 recent_scores 收到 SIGPIPE 退出 141；
    # pipefail 把它传给整条管道，set -e 于是杀掉整个 hook——噪声带注入丢失，
    # 其后的回退与结构停滞检测也永远执行不到。用 || true 吸收 SIGPIPE。
    scores=$(recent_scores | head -6 || true)
    n=$(printf '%s\n' "$scores" | grep -c '[0-9]')
    [[ "$n" -ge 5 ]] || return 0
    # recent_scores 按时间倒序（最新在前）。判据要同时满足：
    #   1) 带宽窄        —— 差异小于重复测量的离散度
    #   2) 无净趋势      —— 最新与最旧之差也在带内，即在原地来回而不是在爬
    #   3) 本轮确实动过代码 —— 零产出是另一种病，由 idle-round 检测器负责
    # 只有"一直在改、一直在测、却始终没离开这个带"才是本检测器要说的事。
    local verdict
    verdict=$(printf '%s\n' "$scores" | python3 -c '
import sys
v=[float(x) for x in sys.stdin.read().split() if x]
if len(v) < 5: raise SystemExit(1)
spread = max(v) - min(v)
net = v[0] - v[-1]                  # 最新 - 最旧
if spread > 1.0 or abs(net) >= spread * 0.6: raise SystemExit(1)
print(f"{min(v):.2f} {max(v):.2f} {spread:.2f} {net:+.2f}")
') || return 0
    local lo hi spread net
    read -r lo hi spread net <<< "$verdict"
    local changed
    changed=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain -- solution 2>/dev/null | head -1 || true)
    if [[ -z "$changed" ]] && [[ -n "$BASE_COMMIT" ]]; then
        changed=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" log --oneline -1 \
                  "$BASE_COMMIT..HEAD" -- solution 2>/dev/null)
    fi
    [[ -n "$changed" ]] || return 0
    cat >> "$file" << EOF

## ⛔ 你在噪声带内做取舍

最近 $n 次正式评测的算子分全部落在 **$lo ~ $hi**（带宽 $spread 分），而最新一次相对最早
一次的净变化只有 $net 分——**在原地来回，不是在爬**。这个带宽是本次循环自己的重复测量
给出的离散度，**带内的差异不能作为采纳或否决任何候选的依据**。

若上一轮据此否决了某个方案，那个否决不成立；据此采纳的同样不成立。

本轮必须二选一：

1. **提高分辨率**：对要比较的两个版本各跑 2-3 次正式评测，用重复测量把差异与噪声分开；
   或改用逐 case 的 \`elapsed_us\` 直接对比——它比聚合算子分的噪声小得多。
2. **换量级**：不要再在这个带里微调。跑 \`bash bench/headroom.sh\` 看 device kernel 分支表，
   挑覆盖 case 最多、可回收分最高的那条分支做**结构性**改动，目标是让分数跳出这个带。

任何小于 $spread 分的"提升"都无法与重复测量区分。
EOF
}

# ========================================
# Regression-Without-Rollback Detector
# ========================================
# The fourth failure mode seen tonight: a formal measurement falsifies a change,
# and nothing rolls it back.  Three operators at once —
#     -5.64 分 (nonfinite-gradient fix), unrolled for 2 further rounds
#     -4.93 分 (float tanh path), still in place
#     -0.27 分 (NaN semantics fix), unrolled for 3 further rounds
# Each plan's variant protocol lists "预期收益被实测证伪" as a rollback trigger, but
# nothing checks it, so the loop keeps stacking work on a version already known to
# be worse.
#
# Machine-readable: compare the newest formal score against the best one this loop
# has produced.  Only reports written after the loop started are considered, so a
# previous loop's numbers cannot trigger it.  The threshold is the larger of the
# observed spread and 1.0 point, so ordinary run-to-run wobble never fires it.
loop_scores_with_time() {
    local dir="$PROJECT_ROOT/reports" f start
    [[ -d "$dir" ]] || return 0
    # 循环起点用 state 里的 started_at（ISO8601 UTC）——LOOP_DIR 的 mtime 每轮都在变，
    # 拿它当起点会把本循环自己产出的报告几乎全部滤掉。
    local sf
    sf=$(ls "$LOOP_DIR"/state.md "$LOOP_DIR"/complete-state.md "$LOOP_DIR"/finalize-state.md \
         "$LOOP_DIR"/cancel-state.md 2>/dev/null | head -1)
    start=0
    if [[ -n "$sf" ]]; then
        start=$(grep -m1 '^started_at:' "$sf" 2>/dev/null | awk '{print $2}' \
                | xargs -r -I{} date -u -d {} +%s 2>/dev/null) || start=0
    fi
    [[ -n "$start" ]] || start=0
    for f in $(ls -t "$dir"/cann_final_eval_*.json 2>/dev/null | head -40); do
        [[ $(stat -c %Y "$f" 2>/dev/null || echo 0) -ge "$start" ]] || continue
        python3 - "$f" 2>/dev/null <<'PYEOF'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
for op in d.get("operators") or []:
    cs=[c for c in (op.get("cases") or []) if c.get("status")=="success" and c.get("elapsed_us")]
    if cs and op.get("score") is not None:
        print(f"{op['score']:.4f}"); break
PYEOF
    done
}

append_regression_note() {
    local file="$1" scores verdict best latest drop thr
    scores=$(loop_scores_with_time)          # 最新在前
    [[ $(printf '%s\n' "$scores" | grep -c '[0-9]') -ge 3 ]] || return 0
    verdict=$(printf '%s\n' "$scores" | python3 -c '
import sys
v=[float(x) for x in sys.stdin.read().split() if x]
if len(v) < 3: raise SystemExit(1)
latest, best = v[0], max(v)
spread = max(v) - min(v)
thr = max(spread * 0.5, 1.0)          # 半个观测跨度，且至少 1 分
if best - latest < thr: raise SystemExit(1)
print(f"{best:.2f} {latest:.2f} {best-latest:.2f} {thr:.2f}")
') || return 0
    read -r best latest drop thr <<< "$verdict"
    local recent
    recent=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" log --format='%h %s' -3 \
             -- solution 2>/dev/null | sed 's/^/  - /')
    cat >> "$file" << EOF

## ⛔ 已被实测证伪的改动仍未回滚

本次循环的最好成绩是 **$best**，最新一次正式评测是 **$latest**，**跌了 $drop 分**
（判定阈值 $thr 分，已排除重复测量的正常波动）。

按变体协议，"设计文档中的预期收益被实测证伪"就是回滚触发条件。**在已经变差的版本上
继续叠加改动，只会让后面每一次测量都建立在一个坏基线上**，也无法再区分新改动的好坏。

最近改动 \`solution/\` 的提交：
$recent

本轮第一件事：**回到取得 $best 分的那个版本**。做法二选一——
1. \`git revert\` 掉造成回退的那次提交；或
2. 先 \`cp -r solution candidates/<描述性名字>\` 归档当前实现，再
   \`git checkout <好版本> -- solution\`。

归档时在 \`docs/variants.md\` 记一行：结构、实测分数、放弃原因。**归档不是丢弃**——
若其中某条思路本身合理（只是实现拖慢了主路径），后续可以按正确修法重做。

回滚并复测确认回到 $best 附近之后，再决定是修正当前方向还是换结构。
EOF
}

# ========================================
# Structural-Stall Detector (current structure has stopped paying)
# ========================================
# The variant protocol says to archive the current implementation and try a
# structurally different one once the present structure stops yielding.  Every
# plan mentions that switching is allowed and that candidates/ is where archives
# go, but across seven plans only one carried a trigger condition, and that one
# hung off an acceptance criterion the operator was nowhere near reaching — so it
# could never fire.  The result: five rounds on one operator with the geometric
# speedup going 0.0023 -> 0.0023 -> 0.0011 -> 0.0011 -> 0.0020, and no switch.
#
# The trigger is measurable from the reports the loop already produces: the
# geometric mean of per-case (baseline_perf_us / elapsed_us).  It is a ratio, so
# it is comparable across rounds and immune to the score's aggregation quirks.
loop_speedups() {
    local dir="$PROJECT_ROOT/reports" f start sf sw
    [[ -d "$dir" ]] || return 0
    sf=$(ls "$LOOP_DIR"/state.md "$LOOP_DIR"/complete-state.md "$LOOP_DIR"/finalize-state.md \
         "$LOOP_DIR"/cancel-state.md 2>/dev/null | head -1)
    start=0
    if [[ -n "$sf" ]]; then
        start=$(grep -m1 '^started_at:' "$sf" 2>/dev/null | awk '{print $2}' \
                | xargs -r -I{} date -u -d {} +%s 2>/dev/null) || start=0
    fi
    [[ -n "$start" ]] || start=0
    # 结构切换边界：最近一次归档到 candidates/ 的时刻。切换后只统计新结构的读数，
    # 让新方案至少拿到 3 次正式评测的观察期——否则窗口会跨界混入旧结构的成绩，
    # 刚换就被判停滞，催着再换，形成反复横跳。
    if [[ -d "$PROJECT_ROOT/candidates" ]]; then
        sw=$(find "$PROJECT_ROOT/candidates" -mindepth 1 -maxdepth 1 -type d \
             -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
        if [[ -n "$sw" ]] && [[ "$sw" =~ ^[0-9]+$ ]] && [[ "$sw" -gt "$start" ]]; then
            start="$sw"
        fi
    fi
    for f in $(ls -t "$dir"/cann_final_eval_*.json 2>/dev/null | head -20); do
        [[ $(stat -c %Y "$f" 2>/dev/null || echo 0) -ge "$start" ]] || continue
        python3 - "$f" 2>/dev/null <<'PYEOF'
import json,sys,statistics
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
for op in d.get("operators") or []:
    cs=[c for c in (op.get("cases") or []) if c.get("status")=="success" and c.get("elapsed_us")]
    if not cs: continue
    sp=[(c.get("baseline_perf_us") or 0)/c["elapsed_us"] for c in cs]
    sp=[x for x in sp if x>0]
    if sp: print(f"{statistics.geometric_mean(sp):.6f}")
    break
PYEOF
    done
}

append_structural_stall_note() {
    local file="$1" sps verdict n best latest gain ref
    sps=$(loop_speedups)                     # 最新在前
    [[ $(printf '%s\n' "$sps" | grep -c '[0-9]') -ge 3 ]] || return 0
    verdict=$(printf '%s\n' "$sps" | python3 -c '
import sys
v=[float(x) for x in sys.stdin.read().split() if x]
if len(v) < 3: raise SystemExit(1)
win = v[:3]                                # 滑动窗口：最近 3 次（最新在前）
if any(x <= 0 for x in win): raise SystemExit(1)
latest, ref, best = v[0], win[-1], max(v)
gain = (latest - ref) / ref                # 近 3 次的净提升
if gain >= 0.05: raise SystemExit(1)       # 近窗仍在涨，不算停滞
print(f"{len(v)} {ref:.4f} {latest:.4f} {best:.4f} {gain*100:+.1f}")
') || return 0
    read -r n ref latest best gain <<< "$verdict"
    local branch=""
    if [[ -f "$PROJECT_ROOT/docs/headroom.md" ]]; then
        branch=$(grep -m1 '^> 优先修' "$PROJECT_ROOT/docs/headroom.md" 2>/dev/null | cut -c1-200)
    fi
    cat >> "$file" << EOF

## ⛔ 当前结构已经不再产出：该换结构了

**最近 3 次**正式评测的几何平均加速比：**$ref** → **$latest**（净变化 **$gain%**）。
**当前结构**下共 $n 次正式评测，最好 $best——早期涨过不算数，看的是近三轮。
（读数只从最近一次结构切换起算；新结构不满 3 次正式评测时本提示不会出现。）
按变体协议，"连续多轮提升不足 5%"就是
**换结构**的触发条件——继续在同一结构上调参不会改变量级。

本轮的动作顺序是固定的：

1. **归档**：\`cp -r solution candidates/v<N>-<结构名>\`，在 \`docs/variants.md\`
   记一行——结构、最终几何平均加速比、放弃原因。归档不是丢弃。
2. **选新结构**：读 \`docs/design_recipes/\` 对应算子族的配方，选一个**结构上不同**的
   方案——换切分维度 / 换数据布局 / 是否走 Cube / 融合方式。
   **已在 variants.md 里放弃过的结构不得重试。**
3. **先写设计再动代码**：更新 \`docs/kernel_design_*.md\`（五节齐全、过红线自检）。
4. **阶段门**：先编译过 + 全部可见 case 精度 + \`bash bench/generalize.sh\` 全过
   （此阶段禁止性能调优），再做有读数的优化。

选新结构的依据看 \`bash bench/headroom.sh\` 的 device kernel 分支表——覆盖 case 最多、
可回收分最高的那条分支就是要重写的对象。$branch
EOF
}

append_idle_round_note() {
    local file="$1" streak="$2"
    [[ "$streak" -ge 2 ]] || return 0
    local hard=""
    if [[ "$streak" -ge 4 ]]; then
        hard="

已连续 $streak 轮零产出。若该方案确实实现不出来（编译不过 / 精度过不了），把失败点写进
\`docs/variants.md\`，从 \`candidates/\` 里最好的归档回滚，换一个**结构上不同**的方案——
仍然不许再连着交纯设计。"
    fi
    cat >> "$file" << EOF

## ⛔ 产出节律：本轮必须落地代码

已连续 **$streak** 轮没有对 \`solution/\` 产生任何改动（git 树对象与工作区状态均未变）。

一轮的合格产出**只有两种**：(a) \`solution/\` 有真实代码改动并至少跑过一次 quick；
(b) 一次正式评测的新成绩。设计文档、可行性推算、KernelWiki 调研、证据式否决都**不算**
——它们是手段，不是结果。

**本轮禁止再交设计或否决**：把当前 \`docs/kernel_design_*.md\` 里最优的那个方案实现出来，
并跑一次评测。哪怕它只做到部分 case、哪怕预期收益不高——实测数据比纸面推算值钱，
跑出来才知道推算错在哪。$hard
EOF
}

# If no active loop (or session_id mismatch), allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

# ========================================
# Background-Task Guards
# ========================================
# Delegates to handle_bg_task_short_circuit (hooks/lib/loop-bg-tasks.sh),
# which runs four cohesive guards in order:
#   1. Ambiguous-caller marker guard (no session_id + marker present)
#   2. Cross-session parked-loop guard (foreign session walking in)
#   3. Pending-bg short-circuit (this session has async work in flight)
#   4. Same-session stale-marker cleanup (bg work just finished)
# When any guard short-circuits, it emits the appropriate JSON on stdout
# and `exit 0`s directly; we never return from that call. When no guard
# fires we continue into the normal gate logic below.
handle_bg_task_short_circuit "$LOOP_DIR" "$HOOK_INPUT" "$HOOK_SESSION_ID"

# ========================================
# Detect Loop Phase: Normal or Finalize
# ========================================
# Normal loop: state.md exists
# Finalize Phase: finalize-state.md exists (after Codex COMPLETE, before final completion)

STATE_FILE=$(resolve_active_state_file "$LOOP_DIR")
if [[ -z "$STATE_FILE" ]]; then
    # No state file found, allow exit
    exit 0
fi

IS_FINALIZE_PHASE=false
[[ "$STATE_FILE" == *"/finalize-state.md" ]] && IS_FINALIZE_PHASE=true

IS_METHODOLOGY_ANALYSIS_PHASE=false
[[ "$STATE_FILE" == *"/methodology-analysis-state.md" ]] && IS_METHODOLOGY_ANALYSIS_PHASE=true

# ========================================
# Parse State File (using shared function)
# ========================================

# First extract raw frontmatter to check which fields are actually present
# This prevents silently using defaults for missing critical fields
RAW_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" 2>/dev/null || echo "")

# Check if critical fields are present before parsing (which applies defaults)
RAW_CURRENT_ROUND=$(echo "$RAW_FRONTMATTER" | grep "^current_round:" || true)
RAW_MAX_ITERATIONS=$(echo "$RAW_FRONTMATTER" | grep "^max_iterations:" || true)
RAW_FULL_REVIEW_ROUND=$(echo "$RAW_FRONTMATTER" | grep "^full_review_round:" || true)
RAW_BITLESSON_REQUIRED=$(echo "$RAW_FRONTMATTER" | grep "^bitlesson_required:" || true)
RAW_BITLESSON_FILE=$(echo "$RAW_FRONTMATTER" | grep "^bitlesson_file:" || true)
RAW_BITLESSON_ALLOW_EMPTY_NONE=$(echo "$RAW_FRONTMATTER" | grep "^bitlesson_allow_empty_none:" || true)

# Use tolerant parsing to extract values
# Note: parse_state_file applies defaults for missing current_round/max_iterations
if ! parse_state_file "$STATE_FILE" 2>/dev/null; then
    echo "Warning: parse_state_file returned non-zero, proceeding to schema validation" >&2
fi

# Map STATE_* variables to local names for backward compatibility
PLAN_TRACKED="$STATE_PLAN_TRACKED"
START_BRANCH="$STATE_START_BRANCH"
BASE_BRANCH="${STATE_BASE_BRANCH:-}"
BASE_COMMIT="${STATE_BASE_COMMIT:-}"
PLAN_FILE="$STATE_PLAN_FILE"
CURRENT_ROUND="$STATE_CURRENT_ROUND"
MAX_ITERATIONS="$STATE_MAX_ITERATIONS"
PUSH_EVERY_ROUND="$STATE_PUSH_EVERY_ROUND"
FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"
REVIEW_STARTED="$STATE_REVIEW_STARTED"
CODEX_EXEC_MODEL="${STATE_CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
CODEX_EXEC_PROFILE="${STATE_CODEX_PROFILE:-${DEFAULT_CODEX_PROFILE:-}}"
CODEX_EXEC_EFFORT="${STATE_CODEX_EFFORT:-$DEFAULT_CODEX_EFFORT}"
CODEX_REVIEW_MODEL="$CODEX_EXEC_MODEL"
CODEX_REVIEW_EFFORT="high"
CODEX_TIMEOUT="${STATE_CODEX_TIMEOUT:-${CODEX_TIMEOUT:-$DEFAULT_CODEX_TIMEOUT}}"
ASK_CODEX_QUESTION="${STATE_ASK_CODEX_QUESTION:-false}"
AGENT_TEAMS="${STATE_AGENT_TEAMS:-false}"
PRIVACY_MODE="${STATE_PRIVACY_MODE:-true}"
BITLESSON_REQUIRED="false"
if [[ -n "$RAW_BITLESSON_REQUIRED" ]]; then
    BITLESSON_REQUIRED=$(echo "$RAW_BITLESSON_REQUIRED" | sed 's/^bitlesson_required:[[:space:]]*//' | tr -d ' "')
fi
BITLESSON_FILE_REL=".humanize/bitlesson.md"
if [[ -n "$RAW_BITLESSON_FILE" ]]; then
    BITLESSON_FILE_REL=$(echo "$RAW_BITLESSON_FILE" | sed 's/^bitlesson_file:[[:space:]]*//' | sed 's/^"//; s/"$//')
fi
if [[ -z "$BITLESSON_FILE_REL" ]] || \
   [[ ! "$BITLESSON_FILE_REL" =~ ^[a-zA-Z0-9._/-]+$ ]] || \
   [[ "$BITLESSON_FILE_REL" = /* ]] || \
   [[ "$BITLESSON_FILE_REL" =~ (^|/)\.\.(/|$) ]]; then
    BITLESSON_FILE_REL=".humanize/bitlesson.md"
fi
BITLESSON_FILE="$PROJECT_ROOT/$BITLESSON_FILE_REL"
BITLESSON_ALLOW_EMPTY_NONE="true"
if [[ -n "$RAW_BITLESSON_ALLOW_EMPTY_NONE" ]]; then
    BITLESSON_ALLOW_EMPTY_NONE=$(echo "$RAW_BITLESSON_ALLOW_EMPTY_NONE" | sed 's/^bitlesson_allow_empty_none:[[:space:]]*//' | tr -d ' "')
fi
if [[ "${HUMANIZE_ALLOW_EMPTY_BITLESSON_NONE:-}" == "true" ]]; then
    BITLESSON_ALLOW_EMPTY_NONE="true"
fi
if [[ "$BITLESSON_ALLOW_EMPTY_NONE" != "true" && "$BITLESSON_ALLOW_EMPTY_NONE" != "false" ]]; then
    BITLESSON_ALLOW_EMPTY_NONE="true"
fi
MAINLINE_STALL_COUNT="${STATE_MAINLINE_STALL_COUNT:-0}"
LAST_MAINLINE_VERDICT="${STATE_LAST_MAINLINE_VERDICT:-$MAINLINE_VERDICT_UNKNOWN}"
DRIFT_STATUS="${STATE_DRIFT_STATUS:-$DRIFT_STATUS_NORMAL}"
# Re-validate Codex Model and Effort for YAML safety (in case state.md was manually edited)
# Use same validation patterns as setup-rlcr-loop.sh
if [[ ! "$CODEX_EXEC_MODEL" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    echo "Error: Invalid codex_model in state file: $CODEX_EXEC_MODEL" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi
if [[ -n "$CODEX_EXEC_PROFILE" && ! "$CODEX_EXEC_PROFILE" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    echo "Error: Invalid codex_profile in state file: $CODEX_EXEC_PROFILE" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi
if [[ ! "$CODEX_EXEC_EFFORT" =~ ^(xhigh|high|medium|low)$ ]]; then
    echo "Error: Invalid codex effort in state file: $CODEX_EXEC_EFFORT" >&2
    echo "  Must be one of: xhigh, high, medium, low" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

# Validate critical fields were actually present (not just defaulted)
# This prevents silently treating a truncated state file as round 0
if [[ -z "$RAW_CURRENT_ROUND" ]]; then
    echo "Error: State file missing required field: current_round" >&2
    echo "  State file may be truncated or corrupted" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi
if [[ -z "$RAW_MAX_ITERATIONS" ]]; then
    echo "Error: State file missing required field: max_iterations" >&2
    echo "  State file may be truncated or corrupted" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

# Validate numeric fields
if [[ ! "$CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (current_round not numeric), stopping loop" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (max_iterations not numeric), using default" >&2
    MAX_ITERATIONS=42
fi

if [[ ! "$MAINLINE_STALL_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Warning: Invalid mainline_stall_count '$MAINLINE_STALL_COUNT', defaulting to 0" >&2
    MAINLINE_STALL_COUNT=0
fi
LAST_MAINLINE_VERDICT=$(normalize_mainline_progress_verdict "$LAST_MAINLINE_VERDICT")
DRIFT_STATUS=$(normalize_drift_status "$DRIFT_STATUS")

# ========================================
# Quick-check 0: Schema Validation (v1.1.2+ fields)
# ========================================
# If schema is outdated, terminate loop as unexpected

if [[ -z "$PLAN_TRACKED" || -z "$START_BRANCH" ]]; then
    REASON="RLCR loop state file is missing required fields (plan_tracked or start_branch).

This indicates the loop was started with an older version of humanize.

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.1.2+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.1: Schema Validation (v1.5.0+ fields)
# ========================================
# Validate review_started and base_branch fields for v1.5.0+ state files

if [[ -z "$REVIEW_STARTED" || ( "$REVIEW_STARTED" != "true" && "$REVIEW_STARTED" != "false" ) ]]; then
    REASON="RLCR loop state file is missing or has invalid review_started field.

This indicates the loop was started with an older version of humanize (pre-1.5.0).

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.5.0+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated (missing review_started)" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ -z "$BASE_BRANCH" ]]; then
    REASON="RLCR loop state file is missing base_branch field.

This indicates the loop was started with an older version of humanize (pre-1.5.0).

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.5.0+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated (missing base_branch)" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.2: Schema Warning (v1.5.2+ fields)
# ========================================
# Warn about missing full_review_round field (introduced in v1.5.2)
# This is a non-blocking warning - we continue with default value (5)

if [[ -z "$RAW_FULL_REVIEW_ROUND" ]]; then
    echo "Note: State file missing full_review_round field (introduced in v1.5.2)." >&2
    echo "  Using default value: 5 (Full Alignment Checks at rounds 4, 9, 14, ...)" >&2
    echo "  To use configurable Full Alignment Check intervals, upgrade to humanize v1.5.2+" >&2
    echo "  and restart the RLCR loop with --full-review-round <N> option." >&2
fi

# ========================================
# Quick-check 0.5: Branch Consistency
# ========================================

# Use || GIT_EXIT_CODE=$? to prevent set -e from aborting on non-zero exit
CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_EXIT_CODE=$?
GIT_EXIT_CODE=${GIT_EXIT_CODE:-0}
if [[ $GIT_EXIT_CODE -ne 0 || -z "$CURRENT_BRANCH" ]]; then
    REASON="Git operation failed or timed out.

Cannot verify branch consistency. This may indicate:
- Git is not responding
- Repository is in an invalid state
- Network issues (if remote operations are involved)

Please check git status manually and try again."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git operation failed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ -n "$START_BRANCH" && "$CURRENT_BRANCH" != "$START_BRANCH" ]]; then
    REASON="Git branch changed during RLCR loop.

Started on: $START_BRANCH
Current: $CURRENT_BRANCH

Branch switching is not allowed. Switch back to $START_BRANCH or cancel the loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - branch changed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.6: Plan File Integrity
# ========================================
# Skip this check in Review Phase (review_started=true)
# In review phase, the plan file is no longer needed - only code review matters.
# This is especially important for skip-impl mode where no real plan file exists.

if [[ "$REVIEW_STARTED" == "true" ]]; then
    echo "Review phase: skipping plan file integrity check (plan no longer needed)" >&2
else

BACKUP_PLAN="$LOOP_DIR/plan.md"
FULL_PLAN_PATH="$PROJECT_ROOT/$PLAN_FILE"

# Check backup exists
if [[ ! -f "$BACKUP_PLAN" ]]; then
    REASON="Plan file backup not found in loop directory.

Please copy the plan file to the loop directory:
  cp \"$FULL_PLAN_PATH\" \"$BACKUP_PLAN\"

This backup is required for plan integrity verification."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan backup missing" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check original plan file still matches backup
if [[ ! -f "$FULL_PLAN_PATH" ]]; then
    REASON="Project plan file has been deleted.

Original: $PLAN_FILE
Backup available at: $BACKUP_PLAN

You can restore from backup if needed. Plan file modifications are not allowed during RLCR loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file deleted" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check plan file integrity
# For tracked files: check both git status (uncommitted) AND content diff (committed changes)
# For gitignored files: check content diff only
if [[ "$PLAN_TRACKED" == "true" ]]; then
    # Tracked file: first check git status for uncommitted changes
    PLAN_GIT_STATUS=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null || echo "")
    if [[ -n "$PLAN_GIT_STATUS" ]]; then
        REASON="Plan file has uncommitted modifications.

File: $PLAN_FILE
Status: $PLAN_GIT_STATUS

This RLCR loop was started with --track-plan-file. Plan file modifications are not allowed during the loop."
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified (uncommitted)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# Plan changes are now allowed: plan.md is a symlink to the original, so this diff always passes
if ! diff -q "$FULL_PLAN_PATH" "$BACKUP_PLAN" &>/dev/null; then
    FALLBACK="# Plan File Modified

The plan file \`$PLAN_FILE\` has been modified since the RLCR loop started.

**Modifying plan files is forbidden during an active RLCR loop.**

If you need to change the plan:
1. Cancel the current loop: \`/humanize:cancel-rlcr-loop\`
2. Update the plan file
3. Start a new loop: \`/humanize:start-rlcr-loop $PLAN_FILE\`

Backup available at: \`$BACKUP_PLAN\`"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-modified.md" "$FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "BACKUP_PATH=$BACKUP_PLAN")
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

fi  # End of REVIEW_STARTED != true check for plan file integrity

# ========================================
# Quick Check: Are All Tasks Completed?
# ========================================
# Before running expensive Codex review, check if Claude still has
# incomplete tasks. If yes, block immediately and tell Claude to finish.
# Supports both legacy TodoWrite and new Task system (TaskCreate/TaskUpdate).

TODO_CHECKER="$SCRIPT_DIR/check-todos-from-transcript.py"

if [[ -f "$TODO_CHECKER" ]]; then
    # Pass hook input to the task checker
    TODO_RESULT=$(echo "$HOOK_INPUT" | python3 "$TODO_CHECKER" 2>&1) || TODO_EXIT=$?
    TODO_EXIT=${TODO_EXIT:-0}

    if [[ "$TODO_EXIT" -eq 2 ]]; then
        # Parse error - block and surface the error
        REASON="Task checker encountered a parse error.

Error: $TODO_RESULT

This may indicate an issue with the hook input or transcript format.
Please try again or cancel the loop if this persists."
        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - task checker parse error" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    if [[ "$TODO_EXIT" -eq 1 ]]; then
        # Incomplete tasks found - block immediately without Codex review
        # Extract the incomplete task list from the result
        INCOMPLETE_LIST=$(echo "$TODO_RESULT" | tail -n +2)

        FALLBACK="# Incomplete Tasks

Complete these tasks before exiting:

{{INCOMPLETE_LIST}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/incomplete-todos.md" "$FALLBACK" \
            "INCOMPLETE_LIST=$INCOMPLETE_LIST")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - incomplete tasks detected, please finish all tasks first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Helper: Clean Up Stale index.lock
# ========================================
# git status (and other git commands) temporarily create .git/index.lock
# while refreshing the index. If a git process is killed mid-operation
# (e.g., by a timeout wrapper), the lock file can be left behind,
# causing subsequent git add/commit to fail with:
#   fatal: Unable to create '.git/index.lock': File exists.
# This helper removes the stale lock so Claude's commit won't fail.
cleanup_stale_index_lock() {
    # Resolve the git dir relative to PROJECT_ROOT, not the hook's cwd, so
    # that index.lock cleanup targets the correct repo even when the hook
    # executes from a plugin/cache directory rather than the project root.
    local project_root="${1:-$PROJECT_ROOT}"
    local git_dir
    git_dir=$(git -C "$project_root" rev-parse --git-dir 2>/dev/null) || return 0
    # git rev-parse --git-dir may return a relative path; make it absolute.
    if [[ "$git_dir" != /* ]]; then
        git_dir="$project_root/$git_dir"
    fi
    if [[ -f "$git_dir/index.lock" ]]; then
        echo "Removing stale $git_dir/index.lock" >&2
        rm -f "$git_dir/index.lock"
    fi
}

# ========================================
# Cache Git Status Output
# ========================================
# Cache git status output to avoid calling it multiple times.
# Used by both large file check and git clean check below.
# IMPORTANT: Fail-closed on git failures to prevent bypassing checks.

GIT_STATUS_CACHED=""
GIT_IS_REPO=false

if command -v git &>/dev/null && run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_IS_REPO=true
    # Capture exit code to detect timeout/failure - do NOT use || echo "" which would fail-open
    GIT_STATUS_EXIT=0
    GIT_STATUS_CACHED=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null) || GIT_STATUS_EXIT=$?

    if [[ $GIT_STATUS_EXIT -ne 0 ]]; then
        # Git status failed or timed out - fail-closed by blocking exit
        # The timed-out git status may have left a stale index.lock
        cleanup_stale_index_lock
        FALLBACK="# Git Status Failed

Git status operation failed or timed out (exit code {{GIT_STATUS_EXIT}}).

Cannot verify repository state. Please check git status manually and try again."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-status-failed.md" "$FALLBACK" \
            "GIT_STATUS_EXIT=$GIT_STATUS_EXIT")
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git status failed (exit $GIT_STATUS_EXIT)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# ========================================
# Quick Check: Large File Detection
# ========================================
# Check if any tracked or new files exceed the line limit.
# Large files should be split into smaller modules.

MAX_LINES=2000

if [[ "$GIT_IS_REPO" == "true" ]]; then
    LARGE_FILES=""

    while IFS= read -r line; do
        # Skip empty lines
        if [ -z "$line" ]; then
            continue
        fi

        # Extract filename (skip first 3 chars: "XY ")
        filename="${line#???}"

        # Handle renames: "old -> new" format
        case "$filename" in
            *" -> "*) filename="${filename##* -> }" ;;
        esac

        # Resolve filename relative to PROJECT_ROOT (git status --porcelain
        # returns project-relative paths, but the hook may run from a
        # different working directory).
        filename="$PROJECT_ROOT/$filename"

        # Skip deleted files
        if [ ! -f "$filename" ]; then
            continue
        fi

        # Get file extension and convert to lowercase
        ext="${filename##*.}"
        ext_lower=$(to_lower "$ext")

        # Determine file type based on extension
        case "$ext_lower" in
            py|js|ts|tsx|jsx|java|c|cpp|cc|cxx|h|hpp|cs|go|rs|rb|php|swift|kt|kts|scala|sh|bash|zsh)
                file_type="code"
                ;;
            md|rst|txt|adoc|asciidoc)
                file_type="documentation"
                ;;
            *)
                continue
                ;;
        esac

        # Count lines and trim whitespace (portable across shells)
        line_count=$(wc -l < "$filename" 2>/dev/null | tr -d ' ') || continue

        # Validate line_count is numeric before comparison
        [[ "$line_count" =~ ^[0-9]+$ ]] || continue

        if [ "$line_count" -gt "$MAX_LINES" ]; then
            LARGE_FILES="${LARGE_FILES}
- \`${filename}\`: ${line_count} lines (${file_type} file)"
        fi
    done <<< "$GIT_STATUS_CACHED"

    if [ -n "$LARGE_FILES" ]; then
        FALLBACK="# Large Files Detected

Files exceeding {{MAX_LINES}} lines:

{{LARGE_FILES}}

Split these into smaller modules before continuing."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/large-files.md" "$FALLBACK" \
            "MAX_LINES=$MAX_LINES" \
            "LARGE_FILES=$LARGE_FILES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - large files detected (>${MAX_LINES} lines), please split into smaller modules" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Methodology Analysis Phase Completion Handler
# ========================================
# When in methodology analysis phase, check if the analysis is done.
# If done, rename state to the original exit reason's terminal state.
# If not done, block and ask Claude to complete the analysis.
# All other checks (summary, bitlesson, goal tracker, max iterations) are skipped.
# IMPORTANT: This MUST run before the git-clean check, because methodology
# artifacts (.humanize/rlcr/...) may make the working tree appear dirty
# if .humanize is tracked, which would block exit before reaching this handler.

if [[ "$IS_METHODOLOGY_ANALYSIS_PHASE" == "true" ]]; then
    if complete_methodology_analysis; then
        # Before allowing the terminal state transition, re-verify the
        # working tree is clean. The main git-clean gate below is skipped
        # in the methodology branch, so without this check, tracked edits
        # made during the analysis phase (e.g. post-signoff source
        # modifications) could slip through unreviewed as soon as the
        # completion marker appears.
        #
        # Apply the same .humanize/ untracked exclusion the main gate uses
        # so methodology-artifact writes under .humanize/rlcr/... do not
        # themselves trip the check.
        if [[ "$GIT_IS_REPO" == "true" ]]; then
            HUMANIZE_UNTRACKED_PATTERN='^\?\? \.humanize[-/]'
            GIT_STATUS_FOR_BLOCK=$(echo "$GIT_STATUS_CACHED" | grep -vE "$HUMANIZE_UNTRACKED_PATTERN" || true)
            if [[ -n "$GIT_STATUS_FOR_BLOCK" ]]; then
                cleanup_stale_index_lock
                FALLBACK="# Git Not Clean

Methodology analysis is complete, but the working tree still has uncommitted changes:

{{GIT_ISSUES}}

Please commit all changes before allowing the loop to exit.
{{SPECIAL_NOTES}}"
                REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-not-clean.md" "$FALLBACK" \
                    "GIT_ISSUES=uncommitted changes after methodology analysis" \
                    "SPECIAL_NOTES=")

                jq -n \
                    --arg reason "$REASON" \
                    --arg msg "Loop: Blocked - uncommitted changes detected after methodology analysis, please commit first" \
                    '{
                        "decision": "block",
                        "reason": $reason,
                        "systemMessage": $msg
                    }'
                exit 0
            fi
        fi
        # Analysis complete and tree clean. Now do the terminal rename so the
        # active state file stays in place until this cleanliness gate passes.
        _meth_exit_reason=$(cat "$LOOP_DIR/.methodology-exit-reason" 2>/dev/null | tr -d '[:space:]' || echo "")
        if [[ -n "$_meth_exit_reason" ]]; then
            mv "$LOOP_DIR/methodology-analysis-state.md" "$LOOP_DIR/${_meth_exit_reason}-state.md" 2>/dev/null || true
            rm -f "$LOOP_DIR/.methodology-exit-reason"
            echo "Methodology analysis complete. State preserved as: $LOOP_DIR/${_meth_exit_reason}-state.md" >&2
        fi
        exit 0
    else
        # Analysis not yet complete, block
        block_methodology_analysis_incomplete
        exit 0
    fi
fi

# ========================================
# Quick Check: Git Clean and Pushed?
# ========================================
# Before running expensive Codex review, check if all changes have been
# committed and pushed. This ensures work is properly saved.

# Use cached git status from above
if [[ "$GIT_IS_REPO" == "true" ]]; then
    GIT_ISSUES=""
    SPECIAL_NOTES=""

    if git_has_tracked_humanize_state "$PROJECT_ROOT"; then
        cleanup_stale_index_lock
        REASON=$(git_tracked_humanize_blocked_message)

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - tracked Humanize state detected, remove it from git first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    # Check for uncommitted changes (staged or unstaged) using cached status.
    # Exclude untracked .humanize/ paths and .humanize-* dash-separated legacy
    # variants from the dirty determination because local plugin state under
    # .humanize/ (.humanize/bitlesson.md, config.json, rlcr/) is intentionally
    # untracked.
    HUMANIZE_UNTRACKED_PATTERN='^\?\? \.humanize[-/]'
    GIT_STATUS_FOR_BLOCK=$(echo "$GIT_STATUS_CACHED" | grep -vE "$HUMANIZE_UNTRACKED_PATTERN" || true)
    if [[ -n "$GIT_STATUS_FOR_BLOCK" ]]; then
        GIT_ISSUES="uncommitted changes"

        # Check for special cases in untracked files (use original status for notes)
        UNTRACKED=$(echo "$GIT_STATUS_CACHED" | grep '^??' || true)

        # Check if .humanize/ or .humanize-* dash-separated legacy variants are untracked.
        if echo "$UNTRACKED" | grep -qE "$HUMANIZE_UNTRACKED_PATTERN"; then
            HUMANIZE_LOCAL_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-humanize-local.md" 2>/dev/null)
            if [[ -z "$HUMANIZE_LOCAL_NOTE" ]]; then
                HUMANIZE_LOCAL_NOTE="Note: .humanize/ and .humanize-* directories are intentionally untracked."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$HUMANIZE_LOCAL_NOTE"
        fi

        # Check for other untracked files (potential artifacts)
        OTHER_UNTRACKED=$(echo "$UNTRACKED" | grep -vE "$HUMANIZE_UNTRACKED_PATTERN" || true)
        if [[ -n "$OTHER_UNTRACKED" ]]; then
            UNTRACKED_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-untracked.md" 2>/dev/null)
            if [[ -z "$UNTRACKED_NOTE" ]]; then
                UNTRACKED_NOTE="Review untracked files - add to .gitignore or commit them."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$UNTRACKED_NOTE"
        fi
    fi

    # Block if there are uncommitted changes
    if [[ -n "$GIT_ISSUES" ]]; then
        # Clean up stale index.lock before Claude attempts git add/commit
        cleanup_stale_index_lock
        # Git has uncommitted changes - block and remind Claude to commit
        FALLBACK="# Git Not Clean

Detected: {{GIT_ISSUES}}

Please commit all changes before exiting.
{{SPECIAL_NOTES}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-not-clean.md" "$FALLBACK" \
            "GIT_ISSUES=$GIT_ISSUES" \
            "SPECIAL_NOTES=$SPECIAL_NOTES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - $GIT_ISSUES detected, please commit first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    # ========================================
    # Check Unpushed Commits (only when push_every_round is true)
    # ========================================

    if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
        # Check if local branch is ahead of remote (unpushed commits)
        GIT_AHEAD=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
        if [[ -n "$GIT_AHEAD" ]]; then
            AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
            CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

            FALLBACK="# Unpushed Commits

You have {{AHEAD_COUNT}} unpushed commit(s) on branch {{CURRENT_BRANCH}}.

Please push before exiting."
            REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/unpushed-commits.md" "$FALLBACK" \
                "AHEAD_COUNT=$AHEAD_COUNT" \
                "CURRENT_BRANCH=$CURRENT_BRANCH")

            jq -n \
                --arg reason "$REASON" \
                --arg msg "Loop: Blocked - $AHEAD_COUNT unpushed commit(s) detected, please push first" \
                '{
                    "decision": "block",
                    "reason": $reason,
                    "systemMessage": $msg
                }'
            exit 0
        fi
    fi
fi

# ========================================
# Check Summary File Exists
# ========================================

# In Finalize Phase, expect finalize-summary.md instead of round-N-summary.md
if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
    SUMMARY_FILE="$LOOP_DIR/finalize-summary.md"
    ROUND_CONTRACT_FILE=""
else
    SUMMARY_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-summary.md"
    ROUND_CONTRACT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-contract.md"
fi

if [[ ! -f "$SUMMARY_FILE" ]]; then
    # Summary file doesn't exist - Claude didn't write it
    # Block exit and remind Claude to write summary

    FALLBACK="# Work Summary Missing

Please write your work summary to: {{SUMMARY_FILE}}"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/work-summary-missing.md" "$FALLBACK" \
        "SUMMARY_FILE=$SUMMARY_FILE")

    if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
        SYSTEM_MSG="Loop: Finalize Phase - summary file missing"
    else
        SYSTEM_MSG="Loop: Summary file missing for round $CURRENT_ROUND"
    fi

    jq -n \
        --arg reason "$REASON" \
        --arg msg "$SYSTEM_MSG" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# Check Round Contract Exists
# ========================================

# Only enforce round contract when anti-drift is active (drift_status present in raw state).
# Legacy loops that pre-date the anti-drift feature will not have this field.
RAW_DRIFT_STATUS=$(echo "$RAW_FRONTMATTER" | grep "^drift_status:" || true)
if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ -n "$RAW_DRIFT_STATUS" ]]; then
    if [[ ! -f "$ROUND_CONTRACT_FILE" ]]; then
        FALLBACK="# Round Contract Missing

Before trying to exit, write the current round contract to: {{ROUND_CONTRACT_FILE}}

The round contract must restate:
- The single mainline objective for this round
- The target ACs
- Which side issues are truly blocking
- Which side issues are queued and out of scope
- The success criteria for this round"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/round-contract-missing.md" "$FALLBACK" \
            "ROUND_CONTRACT_FILE=$ROUND_CONTRACT_FILE")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Round contract missing for round $CURRENT_ROUND" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Check BitLesson Delta Section (all non-finalize rounds)
# ========================================

if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ "$BITLESSON_REQUIRED" == "true" ]]; then
    BITLESSON_DELTA_RESULT=$(bash "$PLUGIN_ROOT/scripts/bitlesson-validate-delta.sh" \
        --summary-file "$SUMMARY_FILE" \
        --bitlesson-file "$BITLESSON_FILE" \
        --bitlesson-relpath "$BITLESSON_FILE_REL" \
        --allow-empty-none "$BITLESSON_ALLOW_EMPTY_NONE" \
        --template-dir "$TEMPLATE_DIR" \
        --current-round "$CURRENT_ROUND") || {
        echo "Error: bitlesson-validate-delta.sh failed" >&2
        exit 1
    }
    if [[ -n "$BITLESSON_DELTA_RESULT" ]]; then
        echo "$BITLESSON_DELTA_RESULT"
        exit 0
    fi
fi

# ========================================
# Check Goal Tracker Initialization (Round 0 only, skip in Finalize Phase)
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

# Skip this check in Finalize Phase, Review Phase, or when review_started is already true (skip-impl mode)
# - Finalize Phase: goal tracker was already initialized before COMPLETE
# - Review Phase: later rounds may update only the mutable section, so Round 0 placeholder checks no longer apply
if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ "$REVIEW_STARTED" != "true" ]] && [[ "$CURRENT_ROUND" -eq 0 ]] && [[ -f "$GOAL_TRACKER_FILE" ]]; then
    # Check if goal-tracker.md still contains placeholder text
    # Extract each section and check for generic placeholder pattern within that section
    # This avoids coupling to specific placeholder wording and prevents false positives
    # from stray mentions of placeholder text elsewhere in the file

    HAS_GOAL_PLACEHOLDER=false
    HAS_AC_PLACEHOLDER=false
    HAS_TASKS_PLACEHOLDER=false

    # Extract Ultimate Goal section (### Ultimate Goal to next heading)
    # Use awk to extract lines between start and end patterns, excluding end pattern
    GOAL_SECTION=$(awk '/^### Ultimate Goal/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$GOAL_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_GOAL_PLACEHOLDER=true
    fi

    # Extract Acceptance Criteria section (### Acceptance Criteria to next heading)
    AC_SECTION=$(awk '/^### Acceptance Criteria/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$AC_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_AC_PLACEHOLDER=true
    fi

    # Extract Active Tasks section (#### Active Tasks to next heading or EOF)
    # Active Tasks is a level-4 heading, so match any ## or higher
    TASKS_SECTION=$(awk '/^#### Active Tasks/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$TASKS_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_TASKS_PLACEHOLDER=true
    fi

    # Build list of missing items
    MISSING_ITEMS=""
    if [[ "$HAS_GOAL_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Ultimate Goal**: Still contains placeholder text"
    fi
    if [[ "$HAS_AC_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Acceptance Criteria**: Still contains placeholder text"
    fi
    if [[ "$HAS_TASKS_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Active Tasks**: Still contains placeholder text"
    fi

    if [[ -n "$MISSING_ITEMS" ]]; then
        FALLBACK="# Goal Tracker Not Initialized

Please fill in the Goal Tracker ({{GOAL_TRACKER_FILE}}):
{{MISSING_ITEMS}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-not-initialized.md" "$FALLBACK" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "MISSING_ITEMS=$MISSING_ITEMS")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Goal Tracker not initialized in Round 0" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Check Max Iterations (skip in Finalize Phase - already post-COMPLETE)
# ========================================

NEXT_ROUND=$((CURRENT_ROUND + 1))

# Skip max iterations check in Finalize Phase or Review Phase
# - Finalize Phase: already received COMPLETE from codex
# - Review Phase: must continue until [P?] issues are cleared, regardless of iteration count
if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ "$REVIEW_STARTED" != "true" ]] && [[ $NEXT_ROUND -gt $MAX_ITERATIONS ]]; then
    echo "RLCR loop did not complete, but reached max iterations ($MAX_ITERATIONS). Exiting." >&2
    # Try to enter methodology analysis phase before final exit
    if enter_methodology_analysis_phase "maxiter" "Reached max iterations ($MAX_ITERATIONS) without completion"; then
        exit 0
    fi
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_MAXITER"
    exit 0
fi

# ========================================
# Finalize Phase Completion (skip Codex review)
# ========================================
# If we're in Finalize Phase and all checks have passed, complete the loop
# No Codex review is performed - this is the final step after Codex already confirmed COMPLETE

if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
    echo "Finalize Phase complete. All checks passed." >&2
    # Try to enter methodology analysis phase before final exit
    if enter_methodology_analysis_phase "complete" "All acceptance criteria met and code review passed"; then
        exit 0
    fi
    # Methodology analysis skipped or already done - proceed with normal exit
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    echo "State preserved as: $LOOP_DIR/complete-state.md" >&2
    exit 0
fi

# ========================================
# Docs Path (static default)
# ========================================

DOCS_PATH="docs"

# ========================================
# Build Codex Review Prompt
# ========================================

PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-prompt.md"
REVIEW_RESULT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-result.md"

SUMMARY_CONTENT=$(cat "$SUMMARY_FILE")

# ========================================
# Optional Full Benchmark (every normal round, when configured)
# ========================================

BENCHMARK_CONFIGURED=false
if [[ "$IS_FINALIZE_PHASE" != "true" ]]; then
    BENCHMARK_COMMAND_FILE="$LOOP_DIR/benchmark-command.sh"
    BENCHMARK_TIMEOUT_FILE="$LOOP_DIR/benchmark-timeout"
    BENCHMARK_RESULT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-benchmark.md"
    BENCHMARK_LOG_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-benchmark.log"

    if [[ ! -s "$BENCHMARK_COMMAND_FILE" || ! -s "$BENCHMARK_TIMEOUT_FILE" ]]; then
        # 未配置 per-round benchmark：跳过本环节，保持与该特性引入前一致的行为。
        # 这是可选特性，不是必填项——不能因为没配就把整轮拦下来。
        BENCHMARK_CONFIGURED=false
    else
        BENCHMARK_CONFIGURED=true
    fi
fi

if [[ "$IS_FINALIZE_PHASE" != "true" && "$BENCHMARK_CONFIGURED" == "true" ]]; then

    BENCHMARK_TIMEOUT=$(cat "$BENCHMARK_TIMEOUT_FILE")
    if ! [[ "$BENCHMARK_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$BENCHMARK_TIMEOUT" -lt 1 ]]; then
        jq -n \
            --arg reason "Mandatory full benchmark timeout is invalid. Restart RLCR with a positive --benchmark-timeout." \
            --arg msg "Loop: blocked - invalid full benchmark timeout" \
            '{decision:"block", reason:$reason, systemMessage:$msg}'
        exit 0
    fi

    bash "$PLUGIN_ROOT/scripts/run-round-benchmark.sh" \
        --project-root "$PROJECT_ROOT" \
        --loop-dir "$LOOP_DIR" \
        --round "$CURRENT_ROUND" \
        --command-file "$BENCHMARK_COMMAND_FILE" \
        --timeout "$BENCHMARK_TIMEOUT"

    if [[ ! -s "$BENCHMARK_RESULT_FILE" || ! -f "$BENCHMARK_LOG_FILE" ]]; then
        jq -n \
            --arg reason "The mandatory full benchmark did not produce its result and log artifacts. Fix the benchmark runner before review." \
            --arg msg "Loop: blocked - full benchmark evidence missing" \
            '{decision:"block", reason:$reason, systemMessage:$msg}'
        exit 0
    fi

    BENCHMARK_EVIDENCE=$(cat "$BENCHMARK_RESULT_FILE")
    SUMMARY_CONTENT="${SUMMARY_CONTENT}

## Stop-gate Full Benchmark Evidence

${BENCHMARK_EVIDENCE}

The benchmark was configured for this round. A failed or timed-out run is still
valid recorded evidence, but its impact must be assessed before completion."
fi

# Shared prompt section for Goal Tracker Update Requests (used in both Full Alignment and Regular reviews)
GOAL_TRACKER_SECTION_FALLBACK="## Goal Tracker Updates
If Claude's summary includes a Goal Tracker Update Request section, apply the requested changes to {{GOAL_TRACKER_FILE}}."
GOAL_TRACKER_UPDATE_SECTION=$(load_and_render_safe "$TEMPLATE_DIR" "codex/goal-tracker-update-section.md" "$GOAL_TRACKER_SECTION_FALLBACK" \
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE")

# Determine if this is a Full Alignment Check round (every FULL_REVIEW_ROUND rounds)
# Full Alignment Checks occur at rounds (N-1), (2N-1), (3N-1), etc. where N=FULL_REVIEW_ROUND
# Validate FULL_REVIEW_ROUND is a positive integer (default to 5 if invalid/corrupted)
if ! [[ "$FULL_REVIEW_ROUND" =~ ^[0-9]+$ ]] || [[ "$FULL_REVIEW_ROUND" -lt 2 ]]; then
    echo "Warning: Invalid full_review_round value '$FULL_REVIEW_ROUND', defaulting to 5" >&2
    FULL_REVIEW_ROUND=5
fi
FULL_ALIGNMENT_CHECK=false
if [[ $((CURRENT_ROUND % FULL_REVIEW_ROUND)) -eq $((FULL_REVIEW_ROUND - 1)) ]]; then
    FULL_ALIGNMENT_CHECK=true
fi

# Calculate derived values for templates
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
COMPLETED_ITERATIONS=$((CURRENT_ROUND + 1))
# Clamp previous round indices to 0 minimum to avoid negative file references
# This can happen with --full-review-round 2 where first alignment check is at round 1
PREV_ROUND=$(( CURRENT_ROUND > 0 ? CURRENT_ROUND - 1 : 0 ))
PREV_PREV_ROUND=$(( CURRENT_ROUND > 1 ? CURRENT_ROUND - 2 : 0 ))

# Integral component: accumulated commit history and recent round references
# Validate BASE_COMMIT is an ancestor of HEAD (not just a valid object) before using it in git log
if [[ -n "$BASE_COMMIT" ]] && git -C "$PROJECT_ROOT" merge-base --is-ancestor "$BASE_COMMIT" HEAD 2>/dev/null; then
    COMMIT_HISTORY=$(git -C "$PROJECT_ROOT" log --oneline --no-decorate --reverse "$BASE_COMMIT"..HEAD 2>/dev/null | tail -80)
else
    COMMIT_HISTORY=$(git -C "$PROJECT_ROOT" log --oneline --no-decorate --reverse -30 2>/dev/null)
    # Annotate so Codex knows this is not the full loop history
    [[ -n "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(base commit unavailable, showing recent branch commits)
${COMMIT_HISTORY}"
fi
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

RECENT_ROUND_FILES=""
for (( r = CURRENT_ROUND - 1; r >= 0 && r >= CURRENT_ROUND - 3; r-- )); do
    RECENT_ROUND_FILES+="- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-summary.md
- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-review-result.md
"
done
[[ -z "$RECENT_ROUND_FILES" ]] && RECENT_ROUND_FILES="(first round, no prior history)"

COMMIT_HISTORY_SECTION_FALLBACK="## Development History (Integral Context)
\`\`\`
${COMMIT_HISTORY}
\`\`\`
### Recent Round Files
Read these files before conducting your review to understand the trajectory of work:
${RECENT_ROUND_FILES}"
COMMIT_HISTORY_SECTION=$(load_and_render_safe "$TEMPLATE_DIR" "codex/commit-history-section.md" "$COMMIT_HISTORY_SECTION_FALLBACK" \
    "COMMIT_HISTORY=$COMMIT_HISTORY" \
    "RECENT_ROUND_FILES=$RECENT_ROUND_FILES")

# Build the review prompt
FULL_ALIGNMENT_FALLBACK="# Full Alignment Review (Round {{CURRENT_ROUND}})

Review Claude's work against the plan and goal tracker. Check all goals are being met.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{COMMIT_HISTORY_SECTION}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

REGULAR_REVIEW_FALLBACK="# Code Review (Round {{CURRENT_ROUND}})

Review Claude's work for this round.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{COMMIT_HISTORY_SECTION}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    # Full Alignment Check prompt
    load_and_render_safe "$TEMPLATE_DIR" "codex/full-alignment-review.md" "$FULL_ALIGNMENT_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMMIT_HISTORY_SECTION=$COMMIT_HISTORY_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"

else
    # Regular review prompt with goal alignment section
    load_and_render_safe "$TEMPLATE_DIR" "codex/regular-review.md" "$REGULAR_REVIEW_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "PROMPT_FILE=$PROMPT_FILE" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMMIT_HISTORY_SECTION=$COMMIT_HISTORY_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"
fi

# ========================================
# Shared Setup: Cache Directory and Codex Arguments
# ========================================
# Initialize these before the REVIEW_STARTED guard so they are available in both
# impl phase (codex exec) and review phase (codex review)

# First, check if Codex CLI exists
if ! command -v codex >/dev/null 2>&1; then
    REASON="# Codex CLI Not Found

The 'codex' CLI is not installed or not in PATH.
RLCR loop requires it to perform reviews.

**To fix:**
1. Install Codex CLI: https://github.com/openai/codex
2. Retry the exit

Or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
fi

# Debug log files go to XDG_CACHE_HOME/humanize/<project-path>/<timestamp>/ to avoid polluting project dir
# Respects XDG_CACHE_HOME for testability in restricted environments (falls back to $HOME/.cache)
# This prevents Claude and Codex from reading these debug files during their work
# The project path is sanitized to replace problematic characters with '-'
# LOOP_TIMESTAMP already set above via basename "$LOOP_DIR"
# Sanitize project root path: replace / and other problematic chars with -
# This matches Claude Code's convention (e.g., /home/sihao/github.com/foo -> -home-sihao-github-com-foo)
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR="$CACHE_BASE/humanize/$SANITIZED_PROJECT_PATH/$LOOP_TIMESTAMP"
mkdir -p "$CACHE_DIR"

# portable-timeout.sh already sourced above

# Disable native hooks for nested Codex reviewer calls to prevent Stop-hook recursion.
# Codex has used different hook feature names across releases. Probe each name
# before disabling it so older CLIs that validate feature names still work.
CODEX_DISABLE_HOOKS_ARGS=()
_CODEX_FEATURE_CACHE="$CACHE_DIR/.codex-disable-hooks-features"
if [[ -f "$_CODEX_FEATURE_CACHE" ]]; then
    while IFS= read -r feature_name; do
        case "$feature_name" in
            hooks|plugin_hooks|codex_hooks)
                CODEX_DISABLE_HOOKS_ARGS+=("--disable" "$feature_name")
                ;;
        esac
    done < "$_CODEX_FEATURE_CACHE"
else
    CODEX_HELP_OUTPUT="$(codex --help </dev/null 2>&1 || true)"
    if grep -q -- '--disable' <<< "$CODEX_HELP_OUTPUT"; then
        _CODEX_DISABLE_HOOK_FEATURES=()
        for feature_name in hooks plugin_hooks codex_hooks; do
            if codex --disable "$feature_name" --help </dev/null >/dev/null 2>&1; then
                CODEX_DISABLE_HOOKS_ARGS+=("--disable" "$feature_name")
                _CODEX_DISABLE_HOOK_FEATURES+=("$feature_name")
            fi
        done
        printf '%s\n' ${_CODEX_DISABLE_HOOK_FEATURES[@]+"${_CODEX_DISABLE_HOOK_FEATURES[@]}"} > "$_CODEX_FEATURE_CACHE" 2>/dev/null || true
    else
        : > "$_CODEX_FEATURE_CACHE" 2>/dev/null || true
    fi
fi

# Build command arguments for summary review (codex exec)
CODEX_PROFILE_ARGS=()
if [[ -n "$CODEX_EXEC_PROFILE" ]]; then
    CODEX_PROFILE_ARGS=("-p" "$CODEX_EXEC_PROFILE")
fi
CODEX_EXEC_ARGS=("-m" "$CODEX_EXEC_MODEL")
if [[ -n "$CODEX_EXEC_EFFORT" ]]; then
    CODEX_EXEC_ARGS+=("-c" "model_reasoning_effort=${CODEX_EXEC_EFFORT}")
fi

CODEX_AUTO_FLAG="--full-auto"
if [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "true" ]] || [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "1" ]]; then
    CODEX_AUTO_FLAG="--dangerously-bypass-approvals-and-sandbox"
fi
CODEX_EXEC_ARGS+=("$CODEX_AUTO_FLAG" "-C" "$PROJECT_ROOT")

# Build Codex command arguments for codex review
CODEX_REVIEW_ARGS=("-c" "model=${CODEX_REVIEW_MODEL}" "-c" "review_model=${CODEX_REVIEW_MODEL}")
if [[ -n "$CODEX_REVIEW_EFFORT" ]]; then
    CODEX_REVIEW_ARGS+=("-c" "model_reasoning_effort=${CODEX_REVIEW_EFFORT}")
fi

# ========================================
# Helper Functions for Code Review Phase
# ========================================

# Run code review and save debug files
# Arguments: $1=round_number
# Sets: CODEX_REVIEW_EXIT_CODE, CODEX_REVIEW_LOG_FILE
# Returns: exit code from the configured review CLI
run_codex_code_review() {
    local round="$1"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine review base: prefer BASE_COMMIT (captured at loop start) over BASE_BRANCH
    # Using the fixed commit SHA prevents comparing a branch to itself when working on main,
    # as the branch ref advances with each commit but the captured SHA stays fixed
    local review_base="${BASE_COMMIT:-$BASE_BRANCH}"
    local review_base_type="branch"
    if [[ -n "$BASE_COMMIT" ]]; then
        review_base_type="commit"
    fi

    CODEX_REVIEW_CMD_FILE="$CACHE_DIR/round-${round}-codex-review.cmd"
    CODEX_REVIEW_LOG_FILE="$CACHE_DIR/round-${round}-codex-review.log"
    local prompt_file="$LOOP_DIR/round-${round}-review-prompt.md"

    # Create audit prompt file describing the code review invocation
    local prompt_fallback="# Code Review Phase - Round ${round}

This file documents the code review invocation for audit purposes.
Compatibility note: Codex 0.130.0 rejects [PROMPT] input, including - stdin, when --base is used.
Humanize must not pass prompt input when --base is used; this file is audit-only.
Provider: codex

## Review Configuration
- Base Branch: ${BASE_BRANCH}
- Base Commit: ${BASE_COMMIT:-N/A}
- Review Base (${review_base_type}): ${review_base}
- Review Round: ${round}
- Timestamp: ${timestamp}
"
    load_and_render_safe "$TEMPLATE_DIR" "codex/code-review-phase.md" "$prompt_fallback" \
        "REVIEW_ROUND=$round" \
        "BASE_BRANCH=$BASE_BRANCH" \
        "BASE_COMMIT=${BASE_COMMIT:-N/A}" \
        "REVIEW_BASE=$review_base" \
        "REVIEW_BASE_TYPE=$review_base_type" \
        "TIMESTAMP=$timestamp" > "$prompt_file"

    echo "Code review prompt (audit) saved to: $prompt_file" >&2

    {
        echo "# Code review invocation debug info"
        echo "# Timestamp: $timestamp"
        echo "# Working directory: $PROJECT_ROOT"
        echo "# Base branch: $BASE_BRANCH"
        echo "# Base commit: ${BASE_COMMIT:-N/A}"
        echo "# Review base ($review_base_type): $review_base"
        echo "# Timeout: $CODEX_TIMEOUT seconds"
        echo ""
        echo "codex ${CODEX_DISABLE_HOOKS_ARGS[*]+"${CODEX_DISABLE_HOOKS_ARGS[*]}"} ${CODEX_PROFILE_ARGS[*]} review --base $review_base ${CODEX_REVIEW_ARGS[*]}"
    } > "$CODEX_REVIEW_CMD_FILE"

    echo "Code review command saved to: $CODEX_REVIEW_CMD_FILE" >&2
    echo "Running codex review with timeout ${CODEX_TIMEOUT}s in $PROJECT_ROOT (base: $review_base)..." >&2

    CODEX_REVIEW_EXIT_CODE=0
    (cd "$PROJECT_ROOT" && run_with_timeout "$CODEX_TIMEOUT" codex ${CODEX_DISABLE_HOOKS_ARGS[@]+"${CODEX_DISABLE_HOOKS_ARGS[@]}"} "${CODEX_PROFILE_ARGS[@]}" review --base "$review_base" "${CODEX_REVIEW_ARGS[@]}") \
        > "$CODEX_REVIEW_LOG_FILE" 2>&1 || CODEX_REVIEW_EXIT_CODE=$?

    echo "Code review exit code: $CODEX_REVIEW_EXIT_CODE" >&2
    echo "Code review log saved to: $CODEX_REVIEW_LOG_FILE" >&2

    return "$CODEX_REVIEW_EXIT_CODE"
}

# Note: detect_review_issues() is defined in loop-common.sh and sourced above

# Run code review and handle the result
# Arguments: $1=round_number, $2=success_system_message
# This function consolidates the common pattern of:
#   1. Running codex review (no prompt - uses --base only)
#   2. Checking results and handling outcomes
# On success (no issues), calls enter_finalize_phase and exits
# On issues found, calls continue_review_loop_with_issues and exits
# On failure, calls block_review_failure and exits
#
# Round numbering: After COMPLETE at round N, all review phase files use round N+1
# The caller passes CURRENT_ROUND + 1 as the round_number parameter
run_and_handle_code_review() {
    local round="$1"
    local success_msg="$2"

    echo "Running codex review against base branch: $BASE_BRANCH..." >&2

    # Run codex review using helper function
    # IMPORTANT: Review failure is a blocking error - do NOT skip to finalize
    if ! run_codex_code_review "$round"; then
        block_review_failure "$round" "Codex review command failed" "$CODEX_REVIEW_EXIT_CODE"
    fi

    # Check both stdout and result file for [P0-9] issues (plan requirement)
    # detect_review_issues returns: 0=issues found, 1=no issues, 2=stdout missing (hard error)
    local merged_content=""
    local detect_exit=0
    merged_content=$(detect_review_issues "$round") || detect_exit=$?

    if [[ "$detect_exit" -eq 2 ]]; then
        # Stdout missing/empty is a hard error - block and require retry
        block_review_failure "$round" "Codex review produced no stdout output" "N/A"
    elif [[ "$detect_exit" -eq 0 ]] && [[ -n "$merged_content" ]]; then
        # Issues found - continue review loop
        continue_review_loop_with_issues "$round" "$merged_content"
    else
        # No issues found (exit code 1) - proceed to finalize
        echo "Code review passed with no issues. Proceeding to finalize phase." >&2
        enter_finalize_phase "" "$success_msg"
    fi
}

# Enter finalize phase with appropriate prompt
# Arguments: $1=skip_reason (empty if not skipped), $2=system_message
enter_finalize_phase() {
    local skip_reason="$1"
    local system_msg="$2"

    mv "$STATE_FILE" "$LOOP_DIR/finalize-state.md"
    echo "State file renamed to: $LOOP_DIR/finalize-state.md" >&2

    local finalize_summary_file="$LOOP_DIR/finalize-summary.md"
    local finalize_prompt

    if [[ -n "$skip_reason" ]]; then
        local fallback="# Finalize Phase (Review Skipped)

**Warning**: Code review was skipped due to: {{REVIEW_SKIP_REASON}}

The implementation could not be fully validated. You are now in the **Finalize Phase**.

## Important Notice
Since the code review was skipped, please manually verify your changes before finalizing:
1. Review your code changes for any obvious issues
2. Run any available tests to verify correctness
3. Check for common code quality issues

## Simplification (Optional)
If time permits, use the \`code-simplifier:code-simplifier\` agent via the Task tool to simplify and refactor your code. Focus more on changes between branch from {{BASE_BRANCH}} to {{START_BRANCH}}.

## Constraints
- Must NOT change existing functionality
- Must NOT fail existing tests
- Must NOT introduce new bugs
- Only perform functionality-equivalent code refactoring and simplification

## Before Exiting
1. Complete all todos
2. Commit your changes
3. Write your finalize summary to: {{FINALIZE_SUMMARY_FILE}}"

        finalize_prompt=$(load_and_render_safe "$TEMPLATE_DIR" "claude/finalize-phase-skipped-prompt.md" "$fallback" \
            "FINALIZE_SUMMARY_FILE=$finalize_summary_file" \
            "PLAN_FILE=$PLAN_FILE" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "REVIEW_SKIP_REASON=$skip_reason" \
            "BASE_BRANCH=$BASE_BRANCH" \
            "START_BRANCH=$START_BRANCH")
    else
        local fallback="# Finalize Phase

Codex review has passed. The implementation is complete.

You are now in the **Finalize Phase**. Use the \`code-simplifier:code-simplifier\` agent via the Task tool to simplify and refactor your code.

## Constraints
- Must NOT change existing functionality
- Must NOT fail existing tests
- Must NOT introduce new bugs
- Only perform functionality-equivalent code refactoring and simplification

## Focus
Focus on the code changes made during this RLCR session. Focus more on changes between branch from {{BASE_BRANCH}} to {{START_BRANCH}}.

## Before Exiting
1. Complete all todos
2. Commit your changes
3. Write your finalize summary to: {{FINALIZE_SUMMARY_FILE}}"

        finalize_prompt=$(load_and_render_safe "$TEMPLATE_DIR" "claude/finalize-phase-prompt.md" "$fallback" \
            "FINALIZE_SUMMARY_FILE=$finalize_summary_file" \
            "PLAN_FILE=$PLAN_FILE" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "BASE_BRANCH=$BASE_BRANCH" \
            "START_BRANCH=$START_BRANCH")
    fi

    jq -n \
        --arg reason "$finalize_prompt" \
        --arg msg "$system_msg" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Append task tag routing reminder to follow-up prompts.
# Arguments: $1=prompt_file_path
append_task_tag_routing_note() {
    local prompt_file="$1"

    cat >> "$prompt_file" << 'ROUTING_EOF'

## Task Tag Routing Reminder

Follow the plan's per-task routing tags strictly:
- `coding` task -> Claude executes directly
- `analyze` task -> execute via `/humanize:ask-codex`, then integrate the result
- Keep Goal Tracker Active Tasks columns `Tag` and `Owner` aligned with execution
ROUTING_EOF
}

# Stop the loop when mainline progress has stalled for too many consecutive rounds.
# Arguments: $1=stall_count, $2=last_verdict
stop_for_mainline_drift() {
    local stall_count="$1"
    local last_verdict="$2"

    upsert_state_fields "$STATE_FILE" \
        "${FIELD_MAINLINE_STALL_COUNT}=${stall_count}" \
        "${FIELD_LAST_MAINLINE_VERDICT}=${last_verdict}" \
        "${FIELD_DRIFT_STATUS}=${DRIFT_STATUS_REPLAN_REQUIRED}"

    local fallback="# Mainline Drift Circuit Breaker

The RLCR loop has been stopped because the mainline failed to advance for {{STALL_COUNT}} consecutive implementation rounds.

- Last mainline verdict: {{LAST_VERDICT}}
- Drift status: replan_required

This loop should not continue automatically. Revisit the original plan, recover the round contract, and restart with a narrower mainline objective."
    local reason
    reason=$(load_and_render_safe "$TEMPLATE_DIR" "block/mainline-drift-stop.md" "$fallback" \
        "STALL_COUNT=$stall_count" \
        "LAST_VERDICT=$last_verdict" \
        "PLAN_FILE=$PLAN_FILE")

    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_STOP"

    jq -n \
        --arg reason "$reason" \
        --arg msg "Loop: Stopped - mainline drift circuit breaker triggered" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Block exit when implementation review output omits the required mainline verdict.
# Arguments: $1=review_result_file, $2=review_prompt_file
block_missing_mainline_verdict() {
    local review_result_file="$1"
    local review_prompt_file="$2"

    local fallback="# Mainline Verdict Missing

The implementation review output is missing the required line:

\`Mainline Progress Verdict: ADVANCED / STALLED / REGRESSED\`

Humanize cannot safely update drift state or choose the correct next-round prompt without this verdict.

Retry the exit so Codex reruns the implementation review.

Files:
- Review result: {{REVIEW_RESULT_FILE}}
- Review prompt: {{REVIEW_PROMPT_FILE}}"
    local reason
    reason=$(load_and_render_safe "$TEMPLATE_DIR" "block/mainline-verdict-missing.md" "$fallback" \
        "REVIEW_RESULT_FILE=$review_result_file" \
        "REVIEW_PROMPT_FILE=$review_prompt_file")

    jq -n \
        --arg reason "$reason" \
        --arg msg "Loop: Blocked - implementation review missing Mainline Progress Verdict" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Continue review loop when issues are found
# Arguments: $1=round_number, $2=review_content
continue_review_loop_with_issues() {
    local round="$1"
    local review_content="$2"

    echo "Code review found issues. Continuing review loop..." >&2

    # Update round number in state file
    local temp_file="${STATE_FILE}.tmp.$$"
    sed "s/^current_round: .*/current_round: $round/" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"

    # Build review-fix prompt for Claude
    local next_prompt_file="$LOOP_DIR/round-${round}-prompt.md"
    local next_summary_file="$LOOP_DIR/round-${round}-summary.md"
    if [[ ! -f "$next_summary_file" ]]; then
        cat > "$next_summary_file" << EOF
# Review Round $round Summary

## Work Completed
- [Describe what was implemented in this phase]

## Files Changed
- [List created/modified files]

## Validation
- [List tests/commands run and outcomes]

## Remaining Items
- [List unresolved items, if any]

## BitLesson Delta
- Action: none|add|update
- Lesson ID(s): NONE
- Notes: [what changed and why]
EOF
    fi
    local next_contract_file="$LOOP_DIR/round-${round}-contract.md"

    local fallback="# Code Review Findings

You are in the **Review Phase** of the RLCR loop. Codex has performed a code review and found issues.

## Review Results

{{REVIEW_CONTENT}}

## Instructions

1. Re-anchor on the original plan and current goal tracker before changing code
2. Refresh the round contract at {{ROUND_CONTRACT_FILE}}
3. Address only the issues that are truly blocking the current mainline objective or code-review acceptance
4. Record non-blocking follow-up items as queued, not as the main goal
5. Commit your changes after fixing the issues
6. Write your summary to: {{SUMMARY_FILE}}"

    load_and_render_safe "$TEMPLATE_DIR" "claude/review-phase-prompt.md" "$fallback" \
        "REVIEW_CONTENT=$review_content" \
        "SUMMARY_FILE=$next_summary_file" \
        "BITLESSON_FILE=$BITLESSON_FILE" \
        "PLAN_FILE=$PLAN_FILE" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "ROUND_CONTRACT_FILE=$next_contract_file" \
        "CURRENT_ROUND=$round" > "$next_prompt_file"
    if [[ "$BITLESSON_REQUIRED" == "true" ]] && ! grep -q 'bitlesson-selector' "$next_prompt_file"; then
        cat >> "$next_prompt_file" << EOF

## BitLesson Selection (REQUIRED FOR EACH FIX TASK)

Before implementing each fix task, you MUST:

1. Read @$BITLESSON_FILE
2. Run \`bitlesson-selector\` for each fix task/sub-task to select relevant lesson IDs
3. Follow the selected lesson IDs (or \`NONE\`) during implementation

Reference: @$BITLESSON_FILE
EOF
    fi
    append_idle_round_note "$next_prompt_file" "$(idle_round_streak)"
    append_noise_band_note "$next_prompt_file"
    append_regression_note "$next_prompt_file"
    append_structural_stall_note "$next_prompt_file"
    append_task_tag_routing_note "$next_prompt_file"

    jq -n \
        --arg reason "$(cat "$next_prompt_file")" \
        --arg msg "Loop: Review Phase Round $round - Fix code review issues" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Block exit when codex review fails or produces no output
# This is a hard error - the review phase cannot be skipped
# Arguments: $1=round_number, $2=failure_reason, $3=exit_code (optional)
block_review_failure() {
    local round="$1"
    local failure_reason="$2"
    local exit_code="${3:-unknown}"

    echo "ERROR: Codex review failed. Blocking exit and requiring retry." >&2

    local stderr_content=""
    local stderr_file="$CACHE_DIR/round-${round}-codex-review.log"
    if [[ -f "$stderr_file" ]]; then
        stderr_content=$(tail -50 "$stderr_file" 2>/dev/null || echo "(unable to read stderr)")
    fi

    local fallback="# Codex Review Failed

The code review could not be completed. This is a blocking error that requires retry.

## Error Details

**Reason**: {{FAILURE_REASON}}
**Round**: {{ROUND_NUMBER}}
**Base Branch**: {{BASE_BRANCH}}
**Exit Code**: {{EXIT_CODE}}

## What Happened

The \`codex review\` command failed to produce valid output. This can occur due to:
- Network connectivity issues
- Codex service timeout or unavailability
- Invalid review configuration
- Internal Codex errors

## Required Action

**You must retry the exit.** The review phase cannot be skipped - the loop must continue until code review passes with no \`[P0-9]\` issues found.

Steps to retry:
1. Ensure your changes are committed
2. Write your summary to the expected file
3. Attempt to exit again

If this error persists, consider canceling and restarting the loop: \`/humanize:cancel-rlcr-loop\`

## Debug Information

Stderr (last 50 lines):
\`\`\`
{{STDERR_CONTENT}}
\`\`\`"

    local reason
    reason=$(load_and_render_safe "$TEMPLATE_DIR" "block/codex-review-failed.md" "$fallback" \
        "FAILURE_REASON=$failure_reason" \
        "ROUND_NUMBER=$round" \
        "BASE_BRANCH=$BASE_BRANCH" \
        "EXIT_CODE=$exit_code" \
        "STDERR_CONTENT=$stderr_content" \
        "REVIEW_RESULT_FILE=$LOOP_DIR/round-${round}-review-result.md" \
        "CODEX_CMD_FILE=$CACHE_DIR/round-${round}-codex-review.cmd" \
        "CODEX_LOG_FILE=$CACHE_DIR/round-${round}-codex-review.log")

    jq -n \
        --arg reason "$reason" \
        --arg msg "Loop: Blocked - Codex review failed, retry required" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# ========================================
# Run Codex Review (Implementation Phase Only)
# ========================================
# Skip the summary review when in review phase - review phase uses codex review instead

if [[ "$REVIEW_STARTED" == "true" ]]; then
    echo "In review phase - skipping codex exec summary review, will run codex review instead..." >&2
    # Jump directly to Review Phase section below (after the COMPLETE/STOP handling)
else

echo "Running summary review for round $CURRENT_ROUND via codex..." >&2

CODEX_CMD_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.cmd"
CODEX_STDOUT_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.out"
CODEX_STDERR_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.log"

# Save the command for debugging
CODEX_PROMPT_CONTENT=$(cat "$REVIEW_PROMPT_FILE")
{
    echo "# Codex invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $CODEX_TIMEOUT seconds"
    echo ""
    echo "codex ${CODEX_DISABLE_HOOKS_ARGS[*]+"${CODEX_DISABLE_HOOKS_ARGS[*]}"} ${CODEX_PROFILE_ARGS[*]} exec ${CODEX_EXEC_ARGS[*]} \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$CODEX_PROMPT_CONTENT"
} > "$CODEX_CMD_FILE"

echo "Codex command saved to: $CODEX_CMD_FILE" >&2
echo "Running summary review with timeout ${CODEX_TIMEOUT}s..." >&2

CODEX_EXIT_CODE=0
printf '%s' "$CODEX_PROMPT_CONTENT" | run_with_timeout "$CODEX_TIMEOUT" codex ${CODEX_DISABLE_HOOKS_ARGS[@]+"${CODEX_DISABLE_HOOKS_ARGS[@]}"} "${CODEX_PROFILE_ARGS[@]}" exec "${CODEX_EXEC_ARGS[@]}" - \
    > "$CODEX_STDOUT_FILE" 2> "$CODEX_STDERR_FILE" || CODEX_EXIT_CODE=$?

echo "Codex exit code: $CODEX_EXIT_CODE" >&2
echo "Codex stdout saved to: $CODEX_STDOUT_FILE" >&2
echo "Codex stderr saved to: $CODEX_STDERR_FILE" >&2

# ========================================
# Check Codex Execution Result
# ========================================

# Helper function to print Codex failure and block exit for retry
# Uses JSON output with exit 0 (per Claude Code hooks spec) instead of exit 2
codex_failure_exit() {
    local error_type="$1"
    local details="$2"

    REASON="# Codex Review Failed

**Error Type:** $error_type

$details

**Debug files:**
- Command: $CODEX_CMD_FILE
- Stdout: $CODEX_STDOUT_FILE
- Stderr: $CODEX_STDERR_FILE

Please retry or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
}

# Check 1: Codex exit code indicates failure
if [[ "$CODEX_EXIT_CODE" -ne 0 ]]; then
    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -30 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(unable to read stderr)")
    fi

    codex_failure_exit "Non-zero exit code ($CODEX_EXIT_CODE)" \
"Codex exited with code $CODEX_EXIT_CODE.
This may indicate:
  - Invalid arguments or configuration
  - Authentication failure
  - Network issues
  - Prompt format issues (e.g., multiline handling)

Stderr output (last 30 lines):
$STDERR_CONTENT"
fi

# Check if Codex created the review result file (it should write to workspace)
# If not, check if it wrote to stdout
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    # Codex might have written output to stdout instead
    if [[ -s "$CODEX_STDOUT_FILE" ]]; then
        echo "Codex output found in stdout, copying to review result file..." >&2
        if ! cp "$CODEX_STDOUT_FILE" "$REVIEW_RESULT_FILE" 2>/dev/null; then
            codex_failure_exit "Failed to copy stdout to review result file" \
"Codex wrote output to stdout but copying to review file failed.
Source: $CODEX_STDOUT_FILE
Target: $REVIEW_RESULT_FILE

This may indicate permission issues or disk space problems.
Check if the loop directory is writable."
        fi
    fi
fi

# Check 2: Review result file still doesn't exist
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -30 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(no stderr output)")
    fi

    STDOUT_CONTENT=""
    if [[ -f "$CODEX_STDOUT_FILE" ]]; then
        STDOUT_CONTENT=$(tail -30 "$CODEX_STDOUT_FILE" 2>/dev/null || echo "(no stdout output)")
    fi

    codex_failure_exit "Review result file not created" \
"Expected file: $REVIEW_RESULT_FILE
Codex completed (exit code 0) but did not create the review result file.

This may indicate:
  - Codex did not understand the prompt
  - Codex wrote to wrong path
  - Workspace/permission issues

Stdout (last 30 lines):
$STDOUT_CONTENT

Stderr (last 30 lines):
$STDERR_CONTENT"
fi

# Check 3: Review result file is empty
if [[ ! -s "$REVIEW_RESULT_FILE" ]]; then
    codex_failure_exit "Review result file is empty" \
"File exists but is empty: $REVIEW_RESULT_FILE
Codex created the file but wrote no content.

This may indicate Codex encountered an internal error."
fi

# Read the review result
REVIEW_CONTENT=$(cat "$REVIEW_RESULT_FILE")

# Check if the last non-empty line is exactly "COMPLETE" or "STOP"
# The word must be on its own line to avoid false positives like "CANNOT COMPLETE"
# Use strict matching: only whitespace before/after the word is allowed
LAST_LINE=$(echo "$REVIEW_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

NEXT_MAINLINE_STALL_COUNT="$MAINLINE_STALL_COUNT"
NEXT_LAST_MAINLINE_VERDICT="$LAST_MAINLINE_VERDICT"
NEXT_DRIFT_STATUS="$DRIFT_STATUS"
DRIFT_REPLAN_REQUIRED=false
MAINLINE_DRIFT_STOP=false

if [[ "$REVIEW_STARTED" != "true" ]]; then
    EXTRACTED_MAINLINE_VERDICT=$(extract_mainline_progress_verdict "$REVIEW_CONTENT")

    if [[ "$LAST_LINE_TRIMMED" != "$MARKER_STOP" ]] && [[ "$EXTRACTED_MAINLINE_VERDICT" == "$MAINLINE_VERDICT_UNKNOWN" ]]; then
        echo "Implementation review output is missing Mainline Progress Verdict. Blocking exit for safety." >&2
        block_missing_mainline_verdict "$REVIEW_RESULT_FILE" "$REVIEW_PROMPT_FILE"
    fi

    case "$EXTRACTED_MAINLINE_VERDICT" in
        "$MAINLINE_VERDICT_ADVANCED")
            NEXT_MAINLINE_STALL_COUNT=0
            NEXT_LAST_MAINLINE_VERDICT="$MAINLINE_VERDICT_ADVANCED"
            NEXT_DRIFT_STATUS="$DRIFT_STATUS_NORMAL"
            ;;
        "$MAINLINE_VERDICT_STALLED"|"$MAINLINE_VERDICT_REGRESSED")
            NEXT_MAINLINE_STALL_COUNT=$((MAINLINE_STALL_COUNT + 1))
            NEXT_LAST_MAINLINE_VERDICT="$EXTRACTED_MAINLINE_VERDICT"
            if [[ "$NEXT_MAINLINE_STALL_COUNT" -ge 8 ]]; then
                NEXT_DRIFT_STATUS="$DRIFT_STATUS_REPLAN_REQUIRED"
                DRIFT_REPLAN_REQUIRED=true
            else
                NEXT_DRIFT_STATUS="$DRIFT_STATUS_NORMAL"
            fi
            if [[ "$NEXT_MAINLINE_STALL_COUNT" -gt 10 ]]; then
                MAINLINE_DRIFT_STOP=true
            fi
            ;;
        *)
            :
            ;;
    esac

    if [[ "$LAST_LINE_TRIMMED" == "$MARKER_COMPLETE" ]]; then
        NEXT_MAINLINE_STALL_COUNT=0
        NEXT_LAST_MAINLINE_VERDICT="$MAINLINE_VERDICT_ADVANCED"
        NEXT_DRIFT_STATUS="$DRIFT_STATUS_NORMAL"
        DRIFT_REPLAN_REQUIRED=false
        MAINLINE_DRIFT_STOP=false
    fi
fi

# Handle COMPLETE - enter Review Phase or Finalize Phase

# ========================================
# Completion Cross-Check (guard against a premature terminator)
# ========================================
# "COMPLETE" is the word a reviewer naturally writes to close a document, and the
# hook reads it as "terminate the loop".  Observed twice on the same task: the
# review body prescribed concrete remaining work ("Implement <candidate> as the
# first candidate"), yet the last line said COMPLETE and the loop ended at round 0
# with the solution byte-for-byte unchanged.
#
# Two cross-checks, both best-effort — when a signal cannot be read the terminator
# is honoured unchanged, so nothing here can make a loop un-stoppable:
#
#   1. The review's own `ACs: N/M addressed` line with N < M — the report
#      contradicts itself.  (Deliberately NOT compared against a count parsed from
#      the plan: across seven plans the acceptance sections use different headings,
#      bullet styles and groupings, and the reviewer's denominator legitimately
#      refers to whatever it treats as current scope.  Any such comparison
#      would fire for the wrong reason.)
#   2. No change under solution/ since the loop's base commit.  RLCR exists to
#      change the kernel; declaring every goal met without touching it is not a
#      completion regardless of how the criteria are counted.  This one is read
#      from git, so plan wording cannot affect it.
#
# Repeated blocks are capped at 2 so a stubborn disagreement cannot livelock.
completion_cross_check() {
    [[ "$LAST_LINE_TRIMMED" == "$MARKER_COMPLETE" ]] || return 0
    [[ "$REVIEW_STARTED" == "true" ]] && return 0

    local blocks_file="$LOOP_DIR/.completion-crosscheck-blocks"
    local prior=0
    [[ -s "$blocks_file" ]] && prior=$(tr -dc '0-9' < "$blocks_file" 2>/dev/null)
    [[ -z "$prior" ]] && prior=0
    if [[ "$prior" -ge 2 ]]; then
        echo "completion cross-check: already blocked $prior times; honouring terminator." >&2
        return 0
    fi

    local reason="" acs n m changed
    acs=$(printf '%s' "$REVIEW_CONTENT" | grep -oE 'ACs:[[:space:]]*[0-9]+/[0-9]+' | head -1)
    if [[ -n "$acs" ]]; then
        n=$(printf '%s' "$acs" | grep -oE '[0-9]+/' | tr -d '/')
        m=$(printf '%s' "$acs" | grep -oE '/[0-9]+' | tr -d '/')
        if [[ -n "$n" && -n "$m" && "$n" -lt "$m" ]]; then
            reason="The review says \`$acs\` — $((m - n)) acceptance criteria are still open."
        fi
    fi
    if [[ -z "$reason" && -n "$BASE_COMMIT" ]] && command -v git &>/dev/null; then
        changed=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" diff --name-only \
                  "$BASE_COMMIT" HEAD -- solution 2>/dev/null | head -1)
        if [[ -z "$changed" ]]; then
            reason="Nothing under \`solution/\` has changed since the loop's base commit ($BASE_COMMIT). RLCR exists to change the kernel; a run with no implementation change is not complete."
        fi
    fi
    [[ -z "$reason" ]] && return 0

    echo $((prior + 1)) > "$blocks_file"
    jq -n \
        --arg reason "Completion cross-check blocked the terminator. $reason Continue the work, or restate the completion claim with this discrepancy resolved." \
        --arg msg "Loop: blocked - completion cross-check" \
        '{decision:"block", reason:$reason, systemMessage:$msg}'
    exit 0
}
completion_cross_check

if [[ "$LAST_LINE_TRIMMED" == "$MARKER_COMPLETE" ]]; then
    # In review phase, COMPLETE signal is ignored - only absence of [P0-9] triggers finalize
    if [[ "$REVIEW_STARTED" == "true" ]]; then
        echo "COMPLETE signal ignored in review phase. Codex review determines exit." >&2
        # Fall through to continue with codex review logic below
    else
        # Implementation phase complete - transition to review phase
        # Max iterations check
        if [[ $CURRENT_ROUND -ge $MAX_ITERATIONS ]]; then
            echo "Codex review passed but at max iterations ($MAX_ITERATIONS). Terminating as MAXITER." >&2
            if enter_methodology_analysis_phase "maxiter" "Codex confirmed COMPLETE but at max iterations ($MAX_ITERATIONS)"; then
                exit 0
            fi
            end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_MAXITER"
            exit 0
        fi

        # Initialize skip tracking variables before any skip paths
        REVIEW_SKIPPED=""
        REVIEW_SKIP_REASON=""

        # Check if base_branch is available for code review
        if [[ -z "$BASE_BRANCH" ]]; then
            echo "Warning: No base_branch configured, skipping code review phase." >&2
            REVIEW_SKIPPED="true"
            REVIEW_SKIP_REASON="No base_branch configured for code review"
        else
            echo "Implementation complete. Entering Review Phase..." >&2

            # Update state to indicate review phase has started and clear drift counters.
            upsert_state_fields "$STATE_FILE" \
                "${FIELD_REVIEW_STARTED}=true" \
                "${FIELD_MAINLINE_STALL_COUNT}=0" \
                "${FIELD_LAST_MAINLINE_VERDICT}=${MAINLINE_VERDICT_ADVANCED}" \
                "${FIELD_DRIFT_STATUS}=${DRIFT_STATUS_NORMAL}"
            REVIEW_STARTED="true"

            # Create marker file to validate review phase was properly entered
            # Also record which round build finished for monitor display
            echo "build_finish_round=$CURRENT_ROUND" > "$LOOP_DIR/.review-phase-started"

            # Run code review and handle results (may exit on issues/failure/success)
            # Pass CURRENT_ROUND + 1 so all review phase files use the next round number
            echo "Implementation complete. Running initial code review..." >&2
            run_and_handle_code_review "$((CURRENT_ROUND + 1))" "Loop: Finalize Phase - Simplify and refactor code before completion"
        fi
    fi
fi

fi  # End of implementation phase codex exec block (skipped when review_started is true)

# ========================================
# Review Phase: Run Code Review (when review_started is true)
# ========================================
# When in review phase, we need to run codex review on every exit attempt
# The loop continues until no [P0-9] patterns are found in the review output

if [[ "$REVIEW_STARTED" == "true" && -n "$BASE_BRANCH" ]]; then
    # Validate that review phase was properly entered (marker file must exist)
    # This prevents manual toggle attacks where someone edits state.md directly
    if [[ ! -f "$LOOP_DIR/.review-phase-started" ]]; then
        REASON="Review phase state inconsistency detected.

The state file indicates review_started=true, but no review phase marker exists.
This can happen if the state file was manually edited.

**To fix:**
Reset the state by canceling and restarting the loop.

Use \`/humanize:cancel-rlcr-loop\` to end this loop."
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - invalid review phase state" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi

    echo "Review Phase: Running code review..." >&2

    # Run code review and handle results (may exit on issues/failure/success)
    # Pass CURRENT_ROUND + 1 so all review phase files use the next round number
    run_and_handle_code_review "$((CURRENT_ROUND + 1))" "Loop: Finalize Phase - Code review passed"
fi

if [[ "$MAINLINE_DRIFT_STOP" == "true" ]] && [[ "$LAST_LINE_TRIMMED" != "$MARKER_STOP" ]] && [[ "$LAST_LINE_TRIMMED" != "$MARKER_COMPLETE" ]]; then
    echo "Mainline progress stalled for $NEXT_MAINLINE_STALL_COUNT consecutive rounds. Triggering drift circuit breaker." >&2
    stop_for_mainline_drift "$NEXT_MAINLINE_STALL_COUNT" "$NEXT_LAST_MAINLINE_VERDICT"
fi

# Handle STOP - circuit breaker triggered
if [[ "$LAST_LINE_TRIMMED" == "$MARKER_STOP" ]]; then
    echo "" >&2
    echo "========================================" >&2
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "CIRCUIT BREAKER TRIGGERED" >&2
        echo "========================================" >&2
        echo "Codex detected development stagnation during Full Alignment Check (Round $CURRENT_ROUND)." >&2
        echo "The loop has been stopped to prevent further unproductive iterations." >&2
        echo "" >&2
        echo "Review the historical round files in .humanize/rlcr/$(basename "$LOOP_DIR")/ to understand what went wrong." >&2
        echo "Consider:" >&2
        echo "  - Revisiting the original plan for clarity" >&2
        echo "  - Breaking down the task into smaller pieces" >&2
        echo "  - Manually addressing the blocking issues" >&2
    else
        echo "UNEXPECTED CIRCUIT BREAKER" >&2
        echo "========================================" >&2
        echo "Codex output STOP during a non-alignment round (Round $CURRENT_ROUND)." >&2
        echo "This is unusual - STOP is normally only expected during Full Alignment Checks (every $FULL_REVIEW_ROUND rounds)." >&2
        echo "Honoring the STOP request and terminating the loop." >&2
        echo "" >&2
        echo "Review the review result to understand why Codex requested an early stop:" >&2
        echo "  $REVIEW_RESULT_FILE" >&2
    fi
    echo "========================================" >&2
    # Try to enter methodology analysis phase before final exit
    if enter_methodology_analysis_phase "stop" "Circuit breaker triggered - stagnation detected at round $CURRENT_ROUND"; then
        exit 0
    fi
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_STOP"
    exit 0
fi

# ========================================
# Review Found Issues - Continue Loop
# ========================================

# Update state file for next round
upsert_state_fields "$STATE_FILE" \
    "${FIELD_CURRENT_ROUND}=${NEXT_ROUND}" \
    "${FIELD_MAINLINE_STALL_COUNT}=${NEXT_MAINLINE_STALL_COUNT}" \
    "${FIELD_LAST_MAINLINE_VERDICT}=${NEXT_LAST_MAINLINE_VERDICT}" \
    "${FIELD_DRIFT_STATUS}=${NEXT_DRIFT_STATUS}"

# Create next round prompt
NEXT_PROMPT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-prompt.md"
NEXT_SUMMARY_FILE="$LOOP_DIR/round-${NEXT_ROUND}-summary.md"
if [[ ! -f "$NEXT_SUMMARY_FILE" ]]; then
    cat > "$NEXT_SUMMARY_FILE" << EOF
# Round $NEXT_ROUND Summary

## Work Completed
- [Describe what was implemented in this phase]

## Files Changed
- [List created/modified files]

## Validation
- [List tests/commands run and outcomes]

## Remaining Items
- [List unresolved items, if any]

## BitLesson Delta
- Action: none|add|update
- Lesson ID(s): NONE
- Notes: [what changed and why]
EOF
fi
NEXT_CONTRACT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-contract.md"

# Build the next round prompt from templates
NEXT_ROUND_FALLBACK="# Next Round Instructions

Review the feedback below and address all issues.

Before executing tasks in this round:
1. Read @{{BITLESSON_FILE}}
2. Run \`bitlesson-selector\` for each task/sub-task
3. Follow selected lesson IDs (or \`NONE\`)

## Codex Review
{{REVIEW_CONTENT}}

Reference: {{PLAN_FILE}}, {{GOAL_TRACKER_FILE}}, {{ROUND_CONTRACT_FILE}}, {{BITLESSON_FILE}}"
DRIFT_REPLAN_FALLBACK="# Drift Recovery Required

The mainline has not advanced for {{STALL_COUNT}} consecutive implementation rounds.

Last mainline verdict: {{LAST_MAINLINE_VERDICT}}

Before writing code:
- Re-read @{{PLAN_FILE}}
- Re-read @{{GOAL_TRACKER_FILE}}
- Re-read the recent round summaries and review results
- Rewrite @{{ROUND_CONTRACT_FILE}} with a recovery-focused mainline objective

Do not spend this round clearing queued work. Recover mainline progress first.

## Codex Review
{{REVIEW_CONTENT}}"

if [[ "$DRIFT_REPLAN_REQUIRED" == "true" ]]; then
    load_and_render_safe "$TEMPLATE_DIR" "claude/drift-replan-prompt.md" "$DRIFT_REPLAN_FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "REVIEW_CONTENT=$REVIEW_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "BITLESSON_FILE=$BITLESSON_FILE" \
        "ROUND_CONTRACT_FILE=$NEXT_CONTRACT_FILE" \
        "CURRENT_ROUND=$NEXT_ROUND" \
        "STALL_COUNT=$NEXT_MAINLINE_STALL_COUNT" \
        "LAST_MAINLINE_VERDICT=$NEXT_LAST_MAINLINE_VERDICT" > "$NEXT_PROMPT_FILE"
else
    load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-prompt.md" "$NEXT_ROUND_FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "REVIEW_CONTENT=$REVIEW_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "BITLESSON_FILE=$BITLESSON_FILE" \
        "ROUND_CONTRACT_FILE=$NEXT_CONTRACT_FILE" \
        "CURRENT_ROUND=$NEXT_ROUND" \
        "STALL_COUNT=$NEXT_MAINLINE_STALL_COUNT" \
        "LAST_MAINLINE_VERDICT=$NEXT_LAST_MAINLINE_VERDICT" > "$NEXT_PROMPT_FILE"
fi

if [[ "$DRIFT_REPLAN_REQUIRED" == "true" ]] && [[ "$BITLESSON_REQUIRED" == "true" ]] && ! grep -q 'bitlesson-selector' "$NEXT_PROMPT_FILE"; then
    cat >> "$NEXT_PROMPT_FILE" << EOF

## BitLesson Selection (REQUIRED FOR EACH TASK)

Before executing each task or sub-task, you MUST:

1. Read @$BITLESSON_FILE
2. Run \`bitlesson-selector\` for each task/sub-task to select relevant lesson IDs
3. Follow the selected lesson IDs (or \`NONE\`) during implementation

Reference: @$BITLESSON_FILE
EOF
fi

# 停滞类检测器。此前只挂在 continue_review_loop_with_issues() 上，那条路径仅在
# reviewer 报出问题时才走，因此在正常轮次推进上从未执行——循环可以连续多轮平在
# 噪声带内而收不到任何提示。这里补到主路径上，与 review 分支保持一致。
append_idle_round_note "$NEXT_PROMPT_FILE" "$(idle_round_streak)"
append_noise_band_note "$NEXT_PROMPT_FILE"
append_regression_note "$NEXT_PROMPT_FILE"
append_structural_stall_note "$NEXT_PROMPT_FILE"

if [[ "$AGENT_TEAMS" == "true" ]]; then
    ENFORCEMENT_BLOCK="**Delegation Warning**: Do NOT implement code yourself in Agent Teams mode; delegate all coding tasks to team members."

    TEMP_PROMPT_FILE="${NEXT_PROMPT_FILE}.tmp.$$"
    awk -v enforcement="$ENFORCEMENT_BLOCK" '
        BEGIN { injected = 0 }
        !injected && /^## Original Implementation Plan/ {
            print ""
            print enforcement
            print ""
            injected = 1
        }
        { print }
        END {
            if (!injected) {
                print ""
                print enforcement
                print ""
            }
        }
    ' "$NEXT_PROMPT_FILE" > "$TEMP_PROMPT_FILE"
    mv "$TEMP_PROMPT_FILE" "$NEXT_PROMPT_FILE"
fi

# Check for Open Questions in review content and inject notice if enabled
# Detection: line containing "Open Question" substring with total length < 40 chars
if [[ "$ASK_CODEX_QUESTION" == "true" ]]; then
    HAS_OPEN_QUESTION=false
    while IFS= read -r line; do
        if [[ ${#line} -lt 40 ]] && echo "$line" | grep -q "Open Question"; then
            HAS_OPEN_QUESTION=true
            break
        fi
    done < "$REVIEW_RESULT_FILE"

    if [[ "$HAS_OPEN_QUESTION" == "true" ]]; then
        echo "Detected Open Question(s) in Codex review - injecting AskUserQuestion notice" >&2
        OPEN_QUESTION_NOTICE=$(load_template "$TEMPLATE_DIR" "claude/open-question-notice.md" 2>/dev/null)
        if [[ -z "$OPEN_QUESTION_NOTICE" ]]; then
            OPEN_QUESTION_NOTICE="**IMPORTANT**: Codex has found Open Question(s). You must use \`AskUserQuestion\` to clarify those questions with user first, before proceeding to resolve any other Codex's findings."
        fi
        # Insert notice between "<!-- CODEX's REVIEW RESULT  END  -->" line + "---" line and "## Goal Tracker Reference"
        TEMP_PROMPT_FILE="${NEXT_PROMPT_FILE}.tmp.$$"
        awk -v notice="$OPEN_QUESTION_NOTICE" '
            /<!-- CODEX.*REVIEW RESULT.*END.*-->/ {
                print
                getline
                if (/^---/) {
                    print
                    print ""
                    print notice
                    next
                }
            }
            { print }
        ' "$NEXT_PROMPT_FILE" > "$TEMP_PROMPT_FILE"
        mv "$TEMP_PROMPT_FILE" "$NEXT_PROMPT_FILE"
    fi
fi

# Add special instructions for post-Full Alignment Check rounds
if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    POST_ALIGNMENT=$(load_template "$TEMPLATE_DIR" "claude/post-alignment-action-items.md" 2>/dev/null)
    if [[ -n "$POST_ALIGNMENT" ]]; then
        echo "$POST_ALIGNMENT" >> "$NEXT_PROMPT_FILE"
    fi
fi

# Add footer with commit/summary instructions
FOOTER_FALLBACK="## Before Exiting
Commit your changes and write summary to {{NEXT_SUMMARY_FILE}}"
load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-footer.md" "$FOOTER_FALLBACK" \
    "NEXT_SUMMARY_FILE=$NEXT_SUMMARY_FILE" >> "$NEXT_PROMPT_FILE"
append_task_tag_routing_note "$NEXT_PROMPT_FILE"

# Add push instruction only if push_every_round is true
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
    PUSH_NOTE=$(load_template "$TEMPLATE_DIR" "claude/push-every-round-note.md" 2>/dev/null)
    if [[ -z "$PUSH_NOTE" ]]; then
        PUSH_NOTE="Also push your changes after committing."
    fi
    echo "$PUSH_NOTE" >> "$NEXT_PROMPT_FILE"
fi

# Add goal tracker update request template
GOAL_UPDATE_REQUEST=$(load_template "$TEMPLATE_DIR" "claude/goal-tracker-update-request.md" 2>/dev/null)
if [[ -z "$GOAL_UPDATE_REQUEST" ]]; then
    GOAL_UPDATE_REQUEST="Include a Goal Tracker Update Request section in your summary if needed."
fi
echo "$GOAL_UPDATE_REQUEST" >> "$NEXT_PROMPT_FILE"

# Add agent-teams continuation instructions (only during implementation phase, not review phase)
# Loads both continuation header and shared core template for full team leader guidance
if [[ "$AGENT_TEAMS" == "true" ]] && [[ "$REVIEW_STARTED" != "true" ]]; then
    AGENT_TEAMS_CONTINUE=$(load_template "$TEMPLATE_DIR" "claude/agent-teams-continue.md" 2>/dev/null)
    AGENT_TEAMS_CORE=$(load_template "$TEMPLATE_DIR" "claude/agent-teams-core.md" 2>/dev/null)
    if [[ -n "$AGENT_TEAMS_CONTINUE" ]] && [[ -n "$AGENT_TEAMS_CORE" ]]; then
        echo "" >> "$NEXT_PROMPT_FILE"
        echo "$AGENT_TEAMS_CONTINUE" >> "$NEXT_PROMPT_FILE"
        echo "" >> "$NEXT_PROMPT_FILE"
        echo "$AGENT_TEAMS_CORE" >> "$NEXT_PROMPT_FILE"
    else
        cat >> "$NEXT_PROMPT_FILE" << 'AGENT_TEAMS_FALLBACK_EOF'

## Agent Teams Continuation

Continue using **Agent Teams mode** as the **Team Leader**.
Split remaining work among team members and coordinate their efforts.
Do NOT do implementation work yourself - delegate all coding to team members.
AGENT_TEAMS_FALLBACK_EOF
    fi
fi

# Build system message
SYSTEM_MSG="Loop: Round $NEXT_ROUND/$MAX_ITERATIONS - Codex found issues to address"
if [[ "$DRIFT_REPLAN_REQUIRED" == "true" ]]; then
    SYSTEM_MSG="Loop: Round $NEXT_ROUND/$MAX_ITERATIONS - Mainline drift detected, replan required"
fi

# Block exit and send review feedback
jq -n \
    --arg reason "$(cat "$NEXT_PROMPT_FILE")" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $reason,
        "systemMessage": $msg
    }'

exit 0

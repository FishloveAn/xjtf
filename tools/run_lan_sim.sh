#!/usr/bin/env bash
## run_lan_sim.sh — M2-S5 双实例 headless 联机模拟运行器（Git Bash / WSL bash 均可）
## 用法：bash tools/run_lan_sim.sh
## 流程：轮次 1（main）= B 组核心 + M2 波次/物资/伤害/救援同步 + B8；
##       轮次 2（disconnect）= B7 客户端关窗 → 服务器清理不崩。
## 输出：$LOG_DIR/lan_sim_*.log 四份日志；终端汇总 PASS/FAIL（退出码 0 = 全 PASS）。
## 注意：sleep/seq 非所有 bash 必备，用 bash 内建 read -t / 算术循环替代
set -u

# Godot 4.7.1 可执行路径（可被环境变量 GODOT_BIN 覆盖）
GODOT_BIN="${GODOT_BIN:-/c/Users/668/AppData/Local/CodexTools/Godot/4.7.1/Godot_v4.7.1-stable_win64_console.exe}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT"  # Godot 是 Windows 程序，不认 /c/... 路径，用相对 --path .
LOG_DIR="/tmp/lan_sim"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log 2>/dev/null

wait_sec() { python -c "import time; time.sleep($1)" 2>/dev/null || sleep "$1" 2>/dev/null || read -r -t "$1" < /dev/null; }

run_round() {
	local mode="$1" max="$2"
	echo "=== LAN_SIM: 轮次 $mode ==="
	"$GODOT_BIN" --headless --path . --script tools/debug_lan_sim.gd -- --server "--mode=$mode" > "$LOG_DIR/server_$mode.log" 2>&1 &
	local pid_srv=$!
	wait_sec 2
	"$GODOT_BIN" --headless --path . --script tools/debug_lan_sim.gd -- --client "--mode=$mode" > "$LOG_DIR/client_$mode.log" 2>&1 &
	local pid_cli=$!
	local i
	for ((i = 0; i < max; i++)); do
		kill -0 $pid_srv 2>/dev/null || break
		kill -0 $pid_cli 2>/dev/null || break
		wait_sec 1
	done
	kill $pid_srv $pid_cli 2>/dev/null
	wait $pid_srv 2>/dev/null; echo "  server exit=$?"
	wait $pid_cli 2>/dev/null; echo "  client exit=$?"
}

run_round main 220
wait_sec 3  # 等端口释放
run_round disconnect 150

echo ""
echo "========== 结果汇总 =========="
PASS_TOTAL=$(grep -h "\[SIM\]\[PASS\]" "$LOG_DIR"/*.log | wc -l)
FAIL_TOTAL=$(grep -h "\[SIM\]\[FAIL\]" "$LOG_DIR"/*.log | wc -l)
echo "PASS=$PASS_TOTAL  FAIL=$FAIL_TOTAL"
echo "--- PASS ---"
grep -h "\[SIM\]\[PASS\]" "$LOG_DIR"/*.log
echo "--- FAIL（若有） ---"
grep -h "\[SIM\]\[FAIL\]" "$LOG_DIR"/*.log || echo "（无）"
echo ""
echo "详细日志：$LOG_DIR/server_main.log / client_main.log / server_disconnect.log / client_disconnect.log"

[ "$FAIL_TOTAL" -eq 0 ]

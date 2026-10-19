#!/usr/bin/env python3
# DSM Search Task 的调用间隔边界
#
# 先前观察到「高频连续搜索后设备进入数分钟退化窗口」，但当时验证脚本的任务
# 间隔只有 500ms，已接近压力测试，不能据此把问题单独归因于设备。
#
# 本实验只改一件事：**任务间隔**。其余（参数、stop/clean 顺序、单次调用逻辑）
# 全部保持客户端真实行为，用来确定 DSM Search Task 的安全调用节奏。
#
# 记录：成功率、首次失败出现在第几次、是否进入长失败串、平均耗时、
#       单次任务的 cleanup 状态。
#
# 用法：
#   printf '%s\n' "$PASSWORD" | python3 tools/search_interval_probe.py <间隔秒> <轮数> [关键词]
#
# 凭据只从 stdin 读一行，不进 argv/环境变量/日志/输出。
from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
import os
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent
CORE = CLIENT / "Resources" / "MyNAS" / "bin" / "mynas-core"
STATE = CLIENT / ".build" / "probe-state" / "trust"

# 目标不写死：这是排查工具，谁用谁的 NAS，默认值只是**示例**。
SOURCE_ID = os.environ.get("FF_PROBE_SOURCE", "demo-nas")
ENDPOINT = os.environ.get("FF_PROBE_ENDPOINT", "https://demo-nas.example:5001")
SCOPE = os.environ.get("FF_PROBE_SCOPE", "/示例共享")

INTERVAL = float(sys.argv[1]) if len(sys.argv) > 1 else 0.5
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
KEYWORD = sys.argv[3] if len(sys.argv) > 3 else "odoo"


class Harness:
    """按客户端真实协议驱动核心（与 NASSearchProvider 一致）。"""

    def __init__(self) -> None:
        STATE.mkdir(parents=True, exist_ok=True)
        self.proc = subprocess.Popen(
            [str(CORE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
            env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                 "FF2_TRUST_DIR": str(STATE.resolve())},
        )
        self.pending: dict[str, list[dict]] = {}
        self.lock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            with self.lock:
                self.pending.setdefault(event.get("requestID", ""), []).append(event)

    def send(self, request_id: str, command: str, **fields) -> None:
        message = {"protocolVersion": 1, "requestID": request_id,
                   "sourceID": SOURCE_ID, "queryID": fields.pop("queryID", "none"),
                   "command": command, **fields}
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def wait(self, request_id: str, event: str, timeout: float) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for item in self.pending.get(request_id, []):
                    if item.get("event") == event:
                        return item
            time.sleep(0.05)
        return None

    def close(self) -> None:
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def main() -> int:
    if not CORE.is_file():
        print(f"缺少核心：{CORE}", file=sys.stderr)
        return 1
    password = sys.stdin.readline().rstrip("\n")
    harness = Harness()
    records: list[dict] = []
    try:
        harness.send("r-discover", "discover", mode="live", endpoint=ENDPOINT,
                     scope=SCOPE, trust={"mode": "sourcePin"},
                     requestBudgetMs=30000, queryBudgetMs=30000)
        if not harness.wait("r-discover", "capabilities", timeout=60):
            print("discover 失败")
            return 1
        harness.send("r-login", "login", account = "demo_user", password=password)
        if not harness.wait("r-login", "authState", timeout=60):
            print("登录失败")
            return 1
        print(f"就绪 | 间隔={INTERVAL}s 轮数={ROUNDS} 关键词={KEYWORD!r}")
        print("第次  结果              条数  耗时    清理")
        print("-" * 52)

        for index in range(ROUNDS):
            query_id = f"q-{index}"
            request_id = f"r-{query_id}"
            began = time.monotonic()
            # 范围在 discover 时已绑定，search 只带 query 与预算（客户端真实契约）。
            harness.send(request_id, "search", queryID=query_id,
                         query=KEYWORD, queryBudgetMs=60000)
            done = harness.wait(request_id, "searchReturned", timeout=90)
            elapsed = time.monotonic() - began
            if not done:
                terminal = harness.wait(request_id, "terminal", timeout=2)
                kind = ((terminal or {}).get("error") or {}).get("kind", "noEvent")
                state, published, cleanup = f"FAIL:{kind}", 0, "-"
            else:
                state = done.get("resultState", "?")
                published = done.get("publishedCount", 0)
                cleanup = done.get("cleanupState", "-")
            ok = state == "completed"
            records.append({"index": index + 1, "ok": ok, "state": state,
                            "published": published, "seconds": round(elapsed, 2),
                            "cleanup": cleanup})
            print(f"{index + 1:>4}  {'OK  ' if ok else 'FAIL'} {state:<14} "
                  f"{published:>5}  {elapsed:>5.1f}s  {cleanup}")
            # 关键变量：任务间隔
            time.sleep(INTERVAL)

        ok_count = sum(1 for r in records if r["ok"])
        first_fail = next((r["index"] for r in records if not r["ok"]), None)
        # 最大连续失败串
        longest = current = 0
        for r in records:
            current = current + 1 if not r["ok"] else 0
            longest = max(longest, current)
        successes = [r["seconds"] for r in records if r["ok"]]
        print("-" * 52)
        print(f"间隔 {INTERVAL}s | 成功 {ok_count}/{ROUNDS} = "
              f"{round(ok_count / ROUNDS * 100)}%")
        print(f"  首次失败      : {first_fail if first_fail else '无'}")
        print(f"  最长连续失败  : {longest}")
        if successes:
            print(f"  成功时平均耗时: {round(sum(successes) / len(successes), 2)}s")
        print(f"RESULT {json.dumps({'interval': INTERVAL, 'rounds': ROUNDS,
                                  'keyword': KEYWORD, 'ok': ok_count,
                                  'firstFailAt': first_fail,
                                  'longestFailStreak': longest,
                                  'avgSeconds': round(sum(successes) / len(successes), 2)
                                  if successes else None}, ensure_ascii=False)}")
        return 0
    finally:
        password = "0" * len(password)
        harness.close()


if __name__ == "__main__":
    raise SystemExit(main())
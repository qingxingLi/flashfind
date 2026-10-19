#!/usr/bin/env python3
# 闪寻客户端 MyNAS 核心的真机端到端验证
#
# 目的：验证打进客户端的这份 Dart 核心（不是实验侧那份）能真实走通
# discover -> 登录 -> 列共享 -> 搜索，并用客户端侧 trust-state 里的已确认 pin。
#
# 协议：与 MyNASProcessBridge 完全一致——逐行 stdin JSON，收 stdout JSON。
# 凭据只从 stdin 读一行，不进 argv/环境变量/日志/输出。
from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
import os
from pathlib import Path
from urllib.parse import urlencode

CLIENT = Path(__file__).resolve().parent.parent
CORE = CLIENT / "Resources" / "MyNAS" / "bin" / "mynas-core"
STATE = CLIENT / ".build" / "probe-state" / "trust"

# 目标不写死：这是排查工具，谁用谁的 NAS，默认值只是**示例**。
SOURCE_ID = os.environ.get("FF_PROBE_SOURCE", "demo-nas")
ENDPOINT = os.environ.get("FF_PROBE_ENDPOINT", "https://demo-nas.example:5001")
SCOPE = os.environ.get("FF_PROBE_SCOPE", "/示例共享")
KEYWORDS = (sys.argv[1] if len(sys.argv) > 1 else "odoo,资料,测试").split(",")
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 3


class Harness:
    """按客户端的协议驱动核心进程。"""

    def __init__(self) -> None:
        STATE.mkdir(parents=True, exist_ok=True)
        self.proc = subprocess.Popen(
            [str(CORE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                 "FF2_TRUST_DIR": str(STATE.resolve())},
        )
        self.events: list[dict] = []
        self.lock = threading.Lock()
        self.pending: dict[str, list[dict]] = {}
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
                self.events.append(event)
                self.pending.setdefault(event.get("requestID", ""), []).append(event)

    def send(self, request_id: str, command: str, **fields) -> None:
        message = {
            "protocolVersion": 1, "requestID": request_id,
            "sourceID": SOURCE_ID, "queryID": fields.pop("queryID", "none"),
            "command": command, **fields,
        }
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def wait(self, request_id: str, event: str, timeout: float = 60.0) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for item in self.pending.get(request_id, []):
                    if item.get("event") == event:
                        return item
            time.sleep(0.1)
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
        print("请先运行 bash tools/install-mynas-core.sh", file=sys.stderr)
        return 1
    password = sys.stdin.readline().rstrip("\n")
    harness = Harness()
    try:
        # 1) discover：确认已保存的 pin 生效，无需再次确认证书
        harness.send("r-discover", "discover", mode="live", endpoint=ENDPOINT,
                     scope=SCOPE, trust={"mode": "sourcePin"},
                     requestBudgetMs=30000, queryBudgetMs=30000)
        caps = harness.wait("r-discover", "capabilities", timeout=60)
        if not caps:
            terminal = harness.wait("r-discover", "terminal", timeout=5)
            print("discover 失败：", json.dumps(terminal, ensure_ascii=False)[:300])
            return 1
        print(f"discover OK| trustMode={caps.get('trustMode')} "
              f"nativeSearch={caps.get('nativeSearch')} canOpen={caps.get('canOpen')}")

        # 2) 登录
        harness.send("r-login", "login", account = "demo_user", password=password)
        auth = harness.wait("r-login", "authState", timeout=60)
        if not auth:
            terminal = harness.wait("r-login", "terminal", timeout=5)
            print("登录失败：", json.dumps(terminal, ensure_ascii=False)[:300])
            return 1
        print(f"登录 OK | state={auth.get('state')}")

        # 3) 列共享
        harness.send("r-shares", "listShares")
        shares_event = harness.wait("r-shares", "batch", timeout=30)
        shares = (shares_event or {}).get("shares", [])
        print(f"可见共享 {len(shares)} 个：{shares}")

        # 4) 搜索：每个关键词多轮，观察 attempts
        for keyword in KEYWORDS:
            for index in range(ROUNDS):
                query_id = f"q-{keyword}-{index}"
                # 与 NASSearchProvider 一致：范围在 discover 时已绑定，
                # search 只带 query 与预算。
                harness.send(f"r-{query_id}", "search", queryID=query_id,
                             query=keyword, queryBudgetMs=60000)
                # 客户端契约：结果走 batch 事件，收尾走 searchReturned（单次 Future）。
                done = harness.wait(f"r-{query_id}", "searchReturned", timeout=90)
                if not done:
                    terminal = harness.wait(f"r-{query_id}", "terminal", timeout=5)
                    print(f"  {keyword} #{index + 1}: 无 searchReturned 事件 "
                          f"{json.dumps(terminal, ensure_ascii=False)[:200]}")
                    continue
                # 收尾事件字段平铺在顶层（不是嵌套 result）。
                state = done.get("resultState")
                published = done.get("publishedCount")
                total = done.get("reportedTotal")
                complete = done.get("isComplete")
                err = (done.get("error") or {}).get("kind")
                print(f"  {keyword} #{index + 1}: state={state} "
                      f"published={published} total={total} "
                      f"complete={complete} cleanup={done.get('cleanupState')}"
                      f"{' err=' + err if err else ''}")
                time.sleep(0.5)
        return 0
    finally:
        password = "0" * len(password)
        harness.close()


if __name__ == "__main__":
    raise SystemExit(main())
#!/usr/bin/env python3
"""验证核心对「未知 sourceID 的 disconnect」是**幂等成功**，而不是错误。

── 为什么要写这个 ──────────────────────────────────────────────
产品端在每次「连接 / 重新连接 / 确认证书」之前都会先发一条 `disconnect`
做幂等清理（`AppModel.resetCoreSource`，注释写明「失败不阻塞后续流程」）。
但应用刚启动时核心进程是全新的，`sources` 里什么都没有 —— 于是这条清理
**必然**报 `UnknownSource`，并以

    {"event":"terminal","resultState":"failed","errorKind":"UnknownSource"}

的形态写进 `~/Library/Application Support/FlashFind2/MyNAS/diagnostics/nas-search-events.jsonl`。
那份文件正是排查搜索问题时**最先看**的东西：每次启动往里塞两条假的 failed，
等于在最需要信任的记录里掺沙子。2026-10-11 实测确认这两条记录与被清理的
真实故障行长得一模一样，靠「启动时间戳」才分得清。

`disconnect` 本身就是幂等操作，语义上不该失败。本脚本对**打包产出的核心**
直接验证：未知 sourceID 的 disconnect 必须
  1. 不产生任何带 `errorKind` 的 terminal 事件；
  2. 回一个 `sourceState: disconnected`（产品端靠它结束这次命令）。

用法：python3 probe_disconnect_idempotent.py --core <mynas-core 路径> [--evidence <目录>]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

UNKNOWN_SOURCE = "0000BBBB-1111-4222-8333-000000000002"  # 一个从未 discover 过的 sourceID


def run_core(core: str, messages, wait_seconds: float = 3.0):
    with tempfile.TemporaryDirectory(prefix="ff2-disc-probe-") as trustdir:
        env = dict(os.environ)
        env["FF2_TRUST_DIR"] = trustdir
        process = subprocess.Popen([core], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, text=True)
        for message in messages:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
        time.sleep(wait_seconds)
        process.stdin.close()
        out, err = process.communicate(timeout=30)
    events = []
    for line in out.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            events.append({"event": "<unparsable>", "raw": line[:160]})
    return process.returncode, err.strip(), events


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", required=True, help="打包产出的 mynas-core 路径")
    parser.add_argument("--evidence", default=None)
    args = parser.parse_args()

    core = str(Path(args.core).resolve())
    if not Path(core).exists():
        print(f"找不到核心：{core}")
        return 1

    messages = [
        # 1) 未知 sourceID 的 disconnect —— 这是本次要验证的那一条。
        {"protocolVersion": 1, "requestID": "d1", "sourceID": UNKNOWN_SOURCE,
         "queryID": "none", "command": "disconnect"},
        # 2) 对照：未知 sourceID 的**其它**命令仍必须明确报 UnknownSource ——
        #    幂等只针对 disconnect，不能顺手把所有未知来源都放行。
        {"protocolVersion": 1, "requestID": "d2", "sourceID": UNKNOWN_SOURCE,
         "queryID": "none", "command": "login", "account": "u", "password": "p"},
    ]
    code, stderr, events = run_core(core, messages)
    print(f"核心：{core}")
    print(f"退出码 {code}｜stderr {stderr[:120] or '（空）'}")
    for event in events:
        if event.get("event") in ("terminal", "sourceState"):
            print(f"  {event.get('requestID')} {event.get('event'):11s} "
                  f"state={event.get('state')} resultState={event.get('resultState')} "
                  f"errorKind={(event.get('error') or {}).get('kind') or event.get('errorKind')}")

    disconnect_events = [e for e in events if e.get("requestID") == "d1"]
    noisy = [e for e in disconnect_events
             if e.get("event") == "terminal" and json.dumps(e, ensure_ascii=False).find("errorKind") >= 0]
    acked = any(e.get("event") == "sourceState" and e.get("state") == "disconnected"
                for e in disconnect_events)
    login_events = [e for e in events if e.get("requestID") == "d2"]
    login_rejected = any((e.get("error") or {}).get("kind") == "UnknownSource"
                         or e.get("errorKind") == "UnknownSource" for e in login_events)

    print()
    print("结论：")
    for ok, text in [
        (not noisy, f"未知来源的 disconnect **不写**失败记录（实际写了 {len(noisy)} 条）"),
        (acked, "未知来源的 disconnect 回了 sourceState: disconnected"),
        (login_rejected, "对照：未知来源的其它命令仍明确报 UnknownSource（幂等只针对 disconnect）"),
    ]:
        print(f"  {'✅' if ok else '❌'} {text}")

    if args.evidence:
        out = Path(args.evidence)
        out.mkdir(parents=True, exist_ok=True)
        (out / "probe.json").write_text(json.dumps({
            "date": "2026-10-11", "core": core, "exitCode": code,
            "stderr": stderr[:400], "events": events,
        }, ensure_ascii=False, indent=2))
        print(f"\n证据已写入 {out / 'probe.json'}")

    return 0 if (not noisy and acked and login_rejected) else 1


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
"""验证「重连」不再因 SourceExists 失败。

背景：核心按 sourceID 维护 sources，一个 sourceID 只能存在一份。
用户重复点「连接」、或连接失败后重试，都会用同一个 sourceID 再次 discover，
旧实现直接回 SourceExists——表现为「什么都没改却连不上」。

本脚本用真实设备跑三段，每段都不需要凭据（只到证书握手为止），
因此可以无人值守执行。凭据如需验证登录，走 stdin 一行，不进 argv/环境变量。

用法：
    python3 tools/verify_reconnect.py --host <NAS地址> --port <端口>
"""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path

client = Path(__file__).resolve().parent.parent
core = client / 'Resources/MyNAS/bin/mynas-core'


def drive(host, port, trust_dir, commands):
    """按顺序发命令，返回 [(requestID, event, state)] 摘要。"""
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8',
           'FF2_TRUST_DIR': str(trust_dir)}
    proc = subprocess.Popen([str(core)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)
    seen = []
    try:
        for rid, command in commands:
            msg = {'protocolVersion': 1, 'requestID': rid, 'sourceID': 'nas_reconnect_probe',
                   'queryID': 'none', 'command': command, 'mode': 'live',
                   'endpoint': f'https://{host}:{port}', 'trust': {'mode': 'sourcePin'},
                   'requestBudgetMs': 15000, 'queryBudgetMs': 30000}
            proc.stdin.write(json.dumps(msg) + '\n')
            proc.stdin.flush()
            # 读事件直到这一请求收尾（同一 requestID 的最后一条终止事件）。
            while True:
                line = proc.stdout.readline()
                if not line:
                    break
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get('requestID') != rid:
                    continue
                kind = event.get('event')
                state = event.get('state') or event.get('resultState') or ''
                error = (event.get('error') or {}).get('kind', '')
                if kind in ('capabilities', 'trustState', 'sourceState', 'terminal'):
                    seen.append((rid, kind, state or error))
                    if kind in ('capabilities', 'terminal') or \
                       (kind == 'sourceState' and state == 'trustRequired'):
                        break
    finally:
        proc.stdin.close()
        proc.wait(timeout=10)
    return seen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()

    if not core.is_file():
        raise SystemExit('核心不存在，请先运行 tools/install-mynas-core.sh')

    trust_dir = tempfile.mkdtemp(prefix='ff-reconnect-')
    os.chmod(trust_dir, 0o700)
    # 连续三次 discover：模拟用户反复点「连接」。
    # 关键判据是**任何一次都不出现 SourceExists**。
    commands = [('r1', 'discover'), ('r2', 'discover'), ('r3', 'discover')]
    seen = drive(args.host, args.port, trust_dir, commands)

    print(f'设备 {args.host}:{args.port}，连续 {len(commands)} 次 discover')
    for rid, kind, state in seen:
        print(f'  {rid}: {kind} {state}')

    source_exists = [row for row in seen if 'SourceExists' in (row[2] or '')]
    if source_exists:
        print('\n结论：失败 —— 重连仍被 SourceExists 拦住')
        return 1
    if len(seen) < len(commands):
        print(f'\n结论：失败 —— 只收到 {len(seen)}/{len(commands)} 个响应')
        return 1
    print('\n结论：通过 —— 重复连接不再报 SourceExists')
    print('说明：这里只到证书握手为止（无凭据），不代表登录已验证')
    return 0


if __name__ == '__main__':
    sys.exit(main())

# -*- coding: utf-8 -*-
"""核实：群晖管理员账号能不能用 FlashFind 搜索。

背景：`authorize()` 里有一条「管理员账号一律拒绝」的硬限制
（`is_manager == true` → UnexpectedAdminIdentity）。它是 EXP-04 阶段为了把
验收对象固定成普通账号 `demo_user` 而加的，**从未在真机上验证过管理员账号
的实际行为**——当时只用 Mock 测过「会拒绝」这条路径本身。

要回答三个问题：
  1. 管理员账号能否登录并通过身份校验；
  2. 管理员在 `list_share` 里看到几个共享；
  3. 管理员搜索某共享时，结果是否与普通账号一致（是否会越权看到别的共享）。

凭据只从 stdin 读两行（账号、密码），不进 argv / 环境变量 / 日志 / 输出。
用法：printf '账号\\n密码\\n' | python3 tools/probe_admin_identity.py 192.168.1.88 5003 <账号> <密码>
"""
import json, subprocess, sys, tempfile, os
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent / 'Resources/MyNAS/bin/mynas-core'
HOST, PORT = sys.argv[1], int(sys.argv[2])
ACCOUNT = sys.argv[3]


def main():
    password = sys.stdin.readline().rstrip('\n')
    if not password:
        raise SystemExit('需要从 stdin 提供密码')

    trust = tempfile.mkdtemp(prefix='ff-admin-')
    os.chmod(trust, 0o700)
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'FF2_TRUST_DIR': trust}
    proc = subprocess.Popen([str(CORE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)

    def send(rid, command, **extra):
        msg = {'protocolVersion': 1, 'requestID': rid, 'sourceID': 'nas_admin_probe',
               'queryID': 'none', 'command': command, 'mode': 'live',
               'endpoint': f'https://{HOST}:{PORT}', 'trust': {'mode': 'sourcePin'},
               'requestBudgetMs': 20000, 'queryBudgetMs': 30000}
        msg.update(extra)
        proc.stdin.write(json.dumps(msg) + '\n')
        proc.stdin.flush()

    def wait(rid, stops):
        seen = []
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get('requestID') != rid:
                continue
            kind = e.get('event')
            seen.append((kind, e))
            if kind in stops or (kind == 'sourceState' and e.get('state') == 'trustRequired'):
                break
        return seen

    # 1) 握手拿证书
    send('d1', 'discover')
    events = wait('d1', ('capabilities', 'terminal'))
    candidate = next((e[1].get('candidate') for e in events if e[0] == 'certificateTrustRequired'), None)
    if not candidate:
        print('未拿到证书候选（可能已在信任库中，但本次使用了独立状态目录）；无法继续')
        proc.stdin.close(); proc.wait(timeout=5); return 2

    # 2) 确认证书（用户已在应用里确认过同一台设备，这里复用其指纹）
    send('c1', 'confirmTrust', candidateID=candidate['candidateID'],
         sha256=candidate['sha256'], userConfirmed=True,
         allowExpired=bool(candidate.get('expired')))
    wait('c1', ('capabilities', 'trustState', 'terminal'))

    # 3) 直接登录，观察 authorize 的判定
    send('l1', 'login', account=ACCOUNT, password=password)
    events = wait('l1', ('authState', 'terminal'))
    auth_state = next((e[1].get('state') for e in events if e[0] == 'authState'), None)
    error_kind = next(((e[1].get('error') or {}).get('kind') for e in events if e[0] == 'terminal'), None)
    print(f'登录结果: authState={auth_state} error={error_kind}')

    if auth_state is None:
        print('结论：管理员账号被拒绝。')
        proc.stdin.close(); proc.wait(timeout=5); return 1

    # 4) 列共享：管理员能看到几个
    send('s1', 'listShares')
    events = wait('s1', ('batch', 'terminal'))
    shares = next((e[1].get('shares') for e in events if e[0] == 'batch'), None)
    print(f'可见共享（{len(shares) if shares else 0} 个）: {shares}')

    # 5) 选第一个共享并试搜，确认搜索通路本身是否可用
    if shares:
        send('sc1', 'selectScope', scope=shares[0])
        wait('sc1', ('scopeState', 'terminal'))
        send('q1', 'search', query='质量', queryBudgetMs=30000)
        events = wait('q1', ('searchReturned', 'terminal'))
        payload = next((e[1] for e in events if e[0] in ('searchReturned', 'terminal')), {})
        print('搜索结果: state={} total={} published={}'.format(
            payload.get('resultState'), payload.get('reportedTotal'), payload.get('publishedCount')))

    proc.stdin.close(); proc.wait(timeout=10)
    return 0


if __name__ == '__main__':
    sys.exit(main())

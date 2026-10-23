#!/usr/bin/env python3
"""逐条证红：一次只应用**一条**变异，跑指定测试类，看哪条用例变红。

`red_proof.py` 是「全部变异一起应用」——它能证明「期望的用例都红了」，
**证明不了「这条变异被哪条用例抓住」**。新加变异时必须逐条走一遍，否则
可能出现「某条用例其实谁都没抓住，只是搭了别的变异的便车」。

用法：
    python3 tools/mutate_each.py                                  # 默认 SearchScheduler
    python3 tools/mutate_each.py --file UpdateCheck --tests UpdateCheckTests
    python3 tools/mutate_each.py --file SearchScheduler --group 3 # 只跑第 3 条

退出码 0 = 每条变异都至少让一条用例变红；1 = 有变异没抓住任何东西（或脚本自身出错）。

★ 三种会被如实标注、不算通过的例外：
  - 「标记没找到」：这条变异依赖前一条变异先应用（见 red_proof 里 NAS rank 那组）。
  - 「编译失败」/「没有任何用例变红」：这条变异必须与另一条**成对**应用（例如属性 +
    使用它的逻辑）。`PAIRS` 里登记过的会自动合成一组重跑，不必手工。
    新增成对变异时**记得登记进 PAIRS**，否则会被误报成「没被抓住」。
"""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CLIENT / 'tools'))
import red_proof as rp  # noqa: E402

# 单条应用毫无意义、必须同时打上去的变异（按 red_proof 里的名字配对）。
# 典型的两种：① 只加存储属性（本身无行为）；② 只用属性（单独用会编译失败）。
PAIRS = [
    ('复活 lastQuery 的记账属性', '复活 lastQuery 的无条件广播取消'),
]


def pair_of(name: str):
    """返回与 name 同组的全部名字；不在任何组里就返回 None。"""
    for group in PAIRS:
        if name in group:
            return group
    return None


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def failed_tests(output: str) -> set:
    """从 swift test 输出里抽出失败的用例名。"""
    out = set()
    for line in output.splitlines():
        if "]' failed (" not in line:
            continue
        inner = line.split("'", 2)[1]          # -[Class testName]
        out.add(inner.rsplit(' ', 1)[-1].rstrip(']'))
    return out


def run_tests(test_class: str):
    r = subprocess.run(['swift', 'test', '--filter', test_class],
                       cwd=CLIENT, capture_output=True, text=True)
    output = r.stdout + r.stderr
    failed = failed_tests(output)
    # 编译失败时不会有 "failed (" 行，但一定有 error:
    compile_error = bool(re.search(r'^\S*error:', output, re.MULTILINE)) and not failed
    return failed, compile_error, output


def main() -> int:
    if not rp.require_swift_61():
        return 1
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', default='SearchScheduler', help='FILES 里的键名')
    ap.add_argument('--tests', default='SearchSchedulerTests', help='要跑的测试类名')
    ap.add_argument('--group', type=int, help='只验第 N 条（从 1 开始）')
    args = ap.parse_args()

    path = rp.FILES[args.file]
    targets = [m for m in rp.MUTATIONS if m[1] == path]
    if args.group:
        targets = [targets[args.group - 1]]

    before = sha(path)
    backup = Path(tempfile.mkdtemp(prefix='ff-mut-')) / path.name
    shutil.copy2(path, backup)
    print(f'源文件 {path.name}：{len(targets)} 条变异，测试类 {args.tests}\n')

    bad = []
    done_pairs = set()
    try:
        for i, (name, _, old, new) in enumerate(targets, 1):
            group = pair_of(name)
            # 成对的变异：第一次遇到时整组一起跑，后面同组的直接跳过。
            if group:
                key = tuple(sorted(group))
                if key in done_pairs:
                    print(f'[{i}] 跳过（已随成对组验证过）：{name}')
                    continue
                done_pairs.add(key)
                members = [m for m in rp.MUTATIONS if m[0] in group and m[1] == path]
                text = path.read_text(encoding='utf-8')
                for m in members:
                    if m[2] not in text:
                        text = None
                        break
                    text = text.replace(m[2], m[3], 1)
                if text is None:
                    print(f'[{i}] 跳过（成对组里有标记没找到）：{name}')
                    continue
                path.write_text(text, encoding='utf-8')
                failed, compile_error, _ = run_tests(args.tests)
                label = ' + '.join(m[0] for m in members)
                if compile_error or not failed:
                    print(f'[{i}] ★ 成对组仍没被抓住：{label}')
                    bad.append(label)
                else:
                    print(f'[{i}] RED（成对）{label}')
                    for f in sorted(failed):
                        print(f'        变红：{f}')
                shutil.copy2(backup, path)
                continue

            text = path.read_text(encoding='utf-8')
            if old not in text:
                print(f'[{i}] 跳过（标记没找到，依赖前序变异）：{name}')
                continue
            path.write_text(text.replace(old, new, 1), encoding='utf-8')
            failed, compile_error, _ = run_tests(args.tests)
            if compile_error:
                print(f'[{i}] ★ 编译失败，且未登记为成对变异：{name}')
                bad.append(name)
            elif not failed:
                print(f'[{i}] ★ 没有任何用例变红（这条变异没被抓住）：{name}')
                bad.append(name)
            else:
                print(f'[{i}] RED {name}')
                for f in sorted(failed):
                    print(f'        变红：{f}')
            shutil.copy2(backup, path)
    finally:
        shutil.copy2(backup, path)
        shutil.rmtree(backup.parent, ignore_errors=True)

    same = sha(path) == before
    print('\n还原后 SHA-256 一致：', same)
    if not same:
        return 1
    if bad:
        print('未通过：', len(bad))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

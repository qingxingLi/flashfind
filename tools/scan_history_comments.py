"""历史注释候选扫描：只挑**注释行**里带过程痕迹的。

只读扫描，不改任何文件。用法：python3 tools/scan_history_comments.py [Sources|Tests|MyNASCore]
输出 `文件:行: 原文`，供人工逐条判定：删（过程记录）/ 留（说明为什么）。
"""
import re
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {'.build', 'Resources'}

# 过程痕迹：时间戳、轮次、实验编号、真机取证、内部路径、协作工具、个人开发记录
MARKERS = [
    r'20\d\d-\d\d-\d\d',
    r'EXP[-_]?\d',
    r'trial\d*',
    r'真机',
    r'第[一二三四五六七八九十\d]+轮',
    r'上一[版轮]', r'本轮', r'下一[版轮]',
    r'Codex', r'返工', r'当时', r'以前这里', r'原先', r'后来', r'起重构',
    r'[0-9]{2}-(项目管理|测试与验收|历史归档|发布与运维|任务交付|工作区)',
    r'内部目录', r'工作区/', r'03-开发',
    r'实测', r'取证', r'证据', r'报告编号',
]
PATTERN = re.compile('|'.join(MARKERS))

# 命中但**有意保留**的：清过一轮之后剩下的都是有理由的，别再当残留删掉。
# 每条必须写清理由，否则这条白名单本身就是新的过程记录。
KEEP = {
    # 日期是上游解析器的格式样本，删了就没人知道它认哪种串。
    'MyNASCore/lib/adapters/ugreen.dart': {'上游日期格式样本'},
    # notes 是被 test_adapters 断言的**契约串**：「真机已验证」与验证端口 5005
    # 两个词一个都不能少，删了测试立刻红。
    'MyNASCore/lib/adapters/webdav.dart': {'notes 是被断言的契约串'},
    # 「本轮」是运行时概念（这一次连接 / 这一次扫描），不是开发轮次。
    'Sources/FlashFind2App/AppModel+QuietConnect.swift': {'本轮=本次连接'},
    'Sources/FlashFind2App/NASSourceWizardController.swift': {'本轮=本次连接'},
    'Sources/FlashFind2App/LocalNetworkDiscovery.swift': {'本轮=本次扫描'},
    'Sources/FlashFindCore/SourceConnectIntent.swift': {'本轮=本次连接'},
    # trial 是**被测内容**：正式版不得带 trial 字样，注释在说明这条规矩。
    'Tests/FlashFindCoreTests/AppLayerStructureTests.swift': {'trial 是被测内容'},
    # 「当时」= 写错的那一刻，讲的是「现在看不出来、事后查不到」这条性质。
    'Tests/FlashFindCoreTests/ArchitectureSplitTests.swift': {'当时=出错的当下'},
}

# 上游派生区：注释是归属凭证，一条都不动。
# 真机校准脚本（test_*.dart / probe_*.py）本身就是讲真机的，不在清理范围。
# 这里**不留**已删目录的名字：白名单本身就是残留最容易藏身的地方——
# 目录删了，名字还留在白名单里，扫描就永远绿着，谁也不知道它已经空转。
SKIP_PARTS: set[str] = set()
SKIP_PREFIX = ('upstream_', 'test_', 'probe_', 'run_realnas')


def iter_files(root: Path, exts: tuple[str, ...]):
    for path in sorted(root.rglob('*')):
        if path.suffix not in exts:
            continue
        parts = path.relative_to(CLIENT).parts
        if any(part in SKIP_DIRS | SKIP_PARTS for part in parts):
            continue
        if path.name.startswith(SKIP_PREFIX):
            continue
        yield path


def comment_lines(text: str) -> list[tuple[int, str]]:
    """行号 → 注释原文（含 /// 与 //，以及块注释内部的行）。"""
    out: list[tuple[int, str]] = []
    in_block = False
    for i, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if in_block:
            out.append((i, line.rstrip()))
            if stripped.endswith('*/'):
                in_block = False
            continue
        if stripped.startswith('///') or stripped.startswith('//') or stripped.startswith('*'):
            out.append((i, line.rstrip()))
        elif stripped.startswith('/*'):
            in_block = True
            out.append((i, line.rstrip()))
            if stripped.endswith('*/'):
                in_block = False
    return out


def main() -> int:
    targets = sys.argv[1:] or ['Sources', 'Tests', 'MyNASCore']
    exts = ('.swift', '.dart') if 'MyNASCore' in targets else ('.swift', '.dart')
    total = 0
    for name in targets:
        root = CLIENT / name
        if not root.exists():
            continue
        for path in iter_files(root, exts):
            text = path.read_text(encoding='utf-8')
            hits = [(n, raw) for n, raw in comment_lines(text) if PATTERN.search(raw)]
            if not hits:
                continue
            rel = path.relative_to(CLIENT)
            keep = KEEP.get(rel.as_posix())
            note = f'（{len(hits)} 条，白名单：{"、".join(sorted(keep))}）' if keep else f'（{len(hits)} 条）'
            print(f'\n### {rel}  {note}')
            for n, raw in hits:
                print(f'{n}: {raw.strip()}')
            total += len(hits)
        # 白名单里登记了却一条都没命中的文件：说明那条理由已经过期了。
    stale = [f'{k}：{sorted(v)[0]}' for k, v in KEEP.items() if not (CLIENT / k).exists()]
    if stale:
        print('\n### 白名单已失效（文件不在了，理由该删）')
        for s in stale:
            print(f'  {s}')
    print(f'\n合计 {total} 条')
    return 0


if __name__ == '__main__':
    sys.exit(main())

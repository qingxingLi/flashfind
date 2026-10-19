"""死代码候选扫描：声明之后全仓零引用的 Swift 符号。

只读扫描，不改任何文件。用法：python3 tools/scan_dead_symbols.py
输出「符号 → 声明处 → 引用计数」，供人工逐条判定（残留 0 ≠ 干净）。
"""
import re
import subprocess
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent

SKIP_DIRS = {'.build', 'Resources'}
# Swift 关键字与常见语法噪音，避免把 `func` `if` 之类当符号
KEYWORDS = {
    'func', 'var', 'let', 'class', 'struct', 'enum', 'protocol', 'typealias',
    'extension', 'import', 'init', 'deinit', 'subscript', 'associatedtype',
    'if', 'else', 'for', 'in', 'while', 'guard', 'switch', 'case', 'default',
    'return', 'break', 'continue', 'do', 'try', 'catch', 'throw', 'throws',
    'async', 'await', 'self', 'Self', 'super', 'nil', 'true', 'false',
    'public', 'private', 'internal', 'fileprivate', 'open', 'static', 'final',
    'weak', 'unowned', 'lazy', 'override', 'mutating', 'nonmutating',
    'where', 'as', 'is', 'some', 'any', 'get', 'set', 'willSet', 'didSet',
    'operator', 'indirect', 'required', 'convenience', 'dynamic', 'optional',
    'Int', 'String', 'Bool', 'Double', 'Date', 'UUID', 'URL', 'Data', 'Set',
    'Array', 'Dictionary', 'Optional', 'Result', 'Error', 'Void', 'Any',
}

DECL = re.compile(
    r'^(?P<indent>[ \t]*)(?:@\w+(?:\([^)]*\))?[ \t]*)*'
    r'(?:(?:public|internal|private|fileprivate|open|final|static|override|mutating|lazy|weak|unowned|class|convenience|required|indirect)[ \t]+)*'
    r'(?:func|var|let|class|struct|enum|protocol|typealias)[ \t]+'
    r'(?P<name>[A-Za-z_][A-Za-z0-9_]*)'
)


def swift_files() -> list[Path]:
    out = subprocess.run(
        ['git', 'ls-files', '*.swift'], cwd=CLIENT, capture_output=True, text=True
    )
    if out.returncode == 0 and out.stdout.strip():
        names = [n for n in out.stdout.splitlines()
                 if not any(p in SKIP_DIRS for p in Path(n).parts)]
    else:
        names = []
        for p in CLIENT.rglob('*.swift'):
            if any(d in p.parts for d in SKIP_DIRS):
                continue
            names.append(str(p.relative_to(CLIENT)))
    return [CLIENT / n for n in sorted(names) if (CLIENT / n).exists()]


def main() -> int:
    files = swift_files()
    sources = [f for f in files if 'Sources' in f.parts]
    others = [f for f in files if 'Sources' not in f.parts]
    print(f'扫描 {len(files)} 个受版本控制的 Swift 文件'
          f'（Sources {len(sources)} / 其余 {len(others)}）')

    # 每个文件的「代码行」（去掉注释与字符串里的干扰有限，够用）
    code: dict[Path, list[str]] = {}
    for f in files:
        text = f.read_text(encoding='utf-8')
        lines = []
        for line in text.splitlines():
            s = line.strip()
            if s.startswith('//') or s.startswith('*') or s.startswith('/*'):
                lines.append('')
            else:
                lines.append(line)
        code[f] = lines

    decls: list[tuple[Path, int, str, str]] = []   # file, line, kind-less name, raw
    for f in sources:
        for i, line in enumerate(code[f], start=1):
            m = DECL.match(line)
            if not m:
                continue
            name = m.group('name')
            if name in KEYWORDS or name.startswith('_'):
                continue
            decls.append((f, i, name, line.strip()))

    # 全仓（含测试/工具）引用计数，按整词匹配
    blobs = {f: '\n'.join(code[f]) for f in files}
    word = re.compile(r'\b{}\b'.format('{}'))
    report: list[tuple[int, Path, int, str, str]] = []
    for f, i, name, raw in decls:
        pattern = re.compile(r'\b' + re.escape(name) + r'\b')
        total = 0
        for g, blob in blobs.items():
            total += len(pattern.findall(blob))
        if total <= 1:
            report.append((total, f, i, name, raw))

    report.sort(key=lambda r: (r[0], str(r[1]), r[2]))
    print(f'\n零引用/仅声明处出现的符号：{len(report)} 条')
    for total, f, i, name, raw in report:
        rel = f.relative_to(CLIENT)
        print(f'  [{total}] {rel}:{i}  {name}\n        {raw[:120]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

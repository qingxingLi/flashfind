#!/usr/bin/env python3
"""开源前的两道静态闸口：Secret Logging Audit 与 Privacy Audit。

用法：
    python3 tools/secret_audit.py            # 全量，发现问题就 exit 1
    python3 tools/secret_audit.py --list     # 只列

⚠️ 边界：本脚本只扫 `Sources / MyNASCore / tools`（见 SCAN_DIRS）。
它回答的是「产品与工具代码会不会把秘密写进日志 / 留隐私素材」，
**不是**「整个仓库没有隐私内容」——`Tests / docs / scripts` 不在它的射程里。
全仓按类别枚举残留是 `05-发布与运维/开源发布工具/verify_clean.py` 的活。
拿本脚本的「均通过」当整个仓库干净的依据，会把测试夹具与文档里的
内部路径、内部编号放过去。

查两件事：
1. 秘密会不会进日志：把每个输出点（Swift 的 print/NSLog/os_log/诊断写入，
   Dart 的 print/stderr/stdout）所在的整条语句取出，看里面有没有引用过
   password / token / SID / CSRF / Cookie / Authorization / HMAC 这类东西。
   注意是「引用」而不是「变量名里带这些词」——形如 credentialStore 的标识符本身不是秘密。
2. 隐私素材会不会留在代码里：真实 IP、MAC、域名、用户名、设备/共享名、
   本机绝对路径、内部工作区名称。

命中但确认无害的条目写进 `tools/audit_whitelist.json`（每条要带理由），
不能改代码的地带才允许白名单，理由必须能被人复核。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent

SCAN_DIRS = ['Sources', 'MyNASCore', 'tools']
SKIP_PARTS = {'.build', '.dart_tool', 'MyNAS-resources'}
# 审计脚本自己的关键词表不算「命中」，否则它会永远扫到自己。
SKIP_FILES = {'tools/secret_audit.py', 'tools/audit_whitelist.json'}
SKIP_FILES_LOWER = {name.lower() for name in SKIP_FILES}

# ── 1. 输出点 ────────────────────────────────────────────────────────────
# 必须认词边界：直接 contains("print(") 会被 fingerprint( 命中。
LOG_SINK_NAMES = [
    # Swift / Python / shell
    'print', 'debugPrint', 'dump', 'NSLog', 'os_log', 'Logger', 'NSAlert',
    'standardError.write', 'FileHandle.standardError', 'fputs',
    'diagnostics.append',
    # Dart
    'stderr.writeln', 'stderr.write', 'stdout.write', 'stdout.writeln',
    '_log.d', '_log.i', '_log.w', '_log.e',
]
LOG_SINK_RE = re.compile(r'(?<![A-Za-z0-9_.])(' + '|'.join(
    re.escape(n) + (r'\(' if n != 'NSAlert' else r'\b')
    for n in LOG_SINK_NAMES) + r')')

# 秘密素材。**用词边界**，否则 pin 会咬住 pinned、sid 会咬住 consider。
SECRET_TERMS = [
    'password', 'passwd', 'pwd', 'secret', 'credential',
    'token', 'apikey', 'api_key', 'sessionid', 'session_id', 'sid',
    'csrf', 'x_syno_token', 'cookie', 'authorization', 'bearer',
    'hmac', 'signature', 'otp', 'private_key', 'privatekey', 'accesskey',
]

# 这批是「存凭据这件事」的标识符，不是凭据本体（已经过 universal quantifier 审核）。
SAFE_TERMS = {
    'sourceid', 'source_id', 'traceid', 'trace_id', 'requestid', 'request_id',
    'certificatesha256', 'hascredential', 'credentialaccessallowed',
    'credentialaccount', 'credentialidentity', 'credentialsavefailed',
    'credentialstore', 'credentialssecretstore', 'storedcredentialrequests',
    'pendingcredential', 'credentialmutation', 'credentialprofile',
    'credentialhint', 'keychainhint', 'credentialsource', 'credentialsourceid',
}

# ── 2. 隐私素材 ──────────────────────────────────────────────────────────
IPV4 = re.compile(r'\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
                  r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b')
# 占位与广播这类不是隐私
IP_ALLOW = {'0.0.0.0', '127.0.0.1', '255.255.255.255', '1.2.3.4',
            '192.0.2.1', '10.0.0.1', '239.255.255.250'}
MAC = re.compile(r'\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b')
HOME_PATH = re.compile(r'/(?:Users|home)/[A-Za-z0-9._-]+')
EMAIL = re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')
# 内网/真实域名与内部工作区名：列出即命中，便于逐个复核
# 前面不能是「.」或标识符的一部分：SearchSource.local 这种枚举成员不是域名。
DOMAIN = re.compile(r'(?<![A-Za-z0-9_.-])[a-z0-9][A-Za-z0-9-]*\.'
                    r'(?:local|lan|internal|corp|ts\.net|synology\.me|myDS\.me|myqnapcloud\.com)\b')
WORKSPACE_TERMS = [
    '10-团队知识库', '团队知识库', 'MyNAS-Cardinal验证', 'Cardinal验证',
    '开源准备-', '闪寻-文件搜索', '04-测试与验收', '90-历史归档',
]

TERM_RE = re.compile(r'\b(' + '|'.join(SECRET_TERMS) + r')\b', re.IGNORECASE)
SAFE_RE = re.compile(r'\b(' + '|'.join(sorted(SAFE_TERMS)) + r')\b', re.IGNORECASE)


def strip_comments_and_strings_preserve(text: str) -> str:
    """把注释与字面量之外的内容留下：字面量里出现 PASSWORD 不该算引用秘密。"""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '/' and i + 1 < n and text[i + 1] == '/':
            i = text.find('\n', i)
            if i == -1:
                break
            continue
        if ch == '/' and i + 1 < n and text[i + 1] == '*':
            end = text.find('*/', i + 2)
            i = n if end == -1 else end + 2
            continue
        if ch == '"' and (i == 0 or text[i - 1] != '\\'):
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def statement_at(text: str, start: int) -> str:
    """从输出点起，取到括号配平为止——一行写不完的语句不能只看行尾。"""
    depth = 0
    entered = False
    for i in range(start, len(text)):
        c = text[i]
        if c == '(':
            depth += 1
            entered = True
        elif c == ')':
            depth -= 1
            if entered and depth <= 0:
                return text[start:i + 1]
    return text[start:start + 400]


def scan_files() -> list[Path]:
    files: list[Path] = []
    for rel in SCAN_DIRS:
        base = CLIENT / rel
        if not base.exists():
            continue
        for path in base.rglob('*'):
            if not path.is_file():
                continue
            rel = path.relative_to(CLIENT).as_posix()
            if any(part in SKIP_PARTS for part in path.parts) or rel.lower() in SKIP_FILES_LOWER:
                continue
            if path.suffix.lower() not in {'.swift', '.dart', '.py', '.sh'}:
                continue
            files.append(path)
    return sorted(files)


def code_lines(path: Path) -> list[tuple[int, str]]:
    """返回去掉注释行后的 (行号, 原文)。注释里提到某个 API 不该被当成调用。"""
    result: list[tuple[int, str]] = []
    for number, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('//') or stripped.startswith('*') or stripped.startswith('/*'):
            continue
        result.append((number, line))
    return result


def load_whitelist() -> list[dict]:
    path = CLIENT / 'tools/audit_whitelist.json'
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding='utf-8')).get('entries', [])


def exempt(entry: dict, relfile: str, line: str) -> bool:
    if entry['file'] != relfile:
        return False
    return entry['needle'] in line


def main() -> int:
    list_only = '--list' in sys.argv
    whitelist = load_whitelist()
    findings: list[tuple[str, str, int, str, str]] = []   # kind, file, line, text, why

    for path in scan_files():
        rel = path.relative_to(CLIENT).as_posix()
        lines = code_lines(path)
        raw = '\n'.join(text for _, text in lines)

        # 1. 秘密进日志
        for number, line in lines:
            sink = LOG_SINK_RE.search(line)
            if not sink:
                continue
            start = sink.start()
            statement = strip_comments_and_strings_preserve(statement_at(line, start))
            if SAFE_RE.search(statement) and not TERM_RE.search(statement):
                continue
            hit = TERM_RE.search(statement)
            if hit and not SAFE_RE.fullmatch(hit.group(0)):
                # 命中词本身是安全标识符（如 sourceID 里的 sid?）——不，词边界已保证。
                findings.append(('secret-logging', rel, number, line.strip()[:160], hit.group(0)))

        # 2. 隐私素材
        for number, line in lines:
            hits: list[str] = []
            for ip in IPV4.findall(line):
                if ip not in IP_ALLOW:
                    hits.append(f'IP {ip}')
            for mac in MAC.findall(line):
                hits.append(f'MAC {mac}')
            for home in HOME_PATH.findall(line):
                if '/Users/' in home and home.split('/')[2] not in {'Shared', 'shared'}:
                    hits.append(f'本机路径 {home}')
            for dom in DOMAIN.findall(line):
                hits.append(f'域名 {dom}')
            for term in WORKSPACE_TERMS:
                if term in line:
                    hits.append(f'内部名 {term}')
            if hits:
                findings.append(('privacy', rel, number, line.strip()[:160], '、'.join(hits)))

    unresolved: list[tuple[str, str, int, str, str]] = []
    exempted: list[tuple[str, str, int, str]] = []
    for kind, rel, number, text, why in findings:
        entry = next((e for e in whitelist if exempt(e, rel, text)), None)
        if entry:
            exempted.append((rel, str(number), why, entry['reason']))
        else:
            unresolved.append((kind, rel, number, text, why))

    print(f'扫描文件 {len(scan_files())} 个；原始命中 {len(findings)} 条；'
          f'白名单放行 {len(exempted)} 条；待处理 {len(unresolved)} 条\n')

    for kind, rel, number, text, why in unresolved:
        print(f'[{kind}] {rel}:{number}  ← {why}')
        print(f'    {text}')
    if exempted:
        print('--- 白名单放行（理由已在 audit_whitelist.json 登记）---')
        for rel, number, why, reason in exempted[:40]:
            print(f'    {rel}:{number}  {why}  →  {reason}')
        if len(exempted) > 40:
            print(f'    … 另有 {len(exempted) - 40} 条')

    if list_only:
        return 0
    if unresolved:
        print(f'\n结论：有 {len(unresolved)} 条命中没有结论。修代码，或把无害的一条写进白名单并写明理由。')
        return 1
    print('\n结论：Secret Logging Audit 与 Privacy Audit 均通过（命中项已在白名单逐条登记）。')
    return 0


if __name__ == '__main__':
    sys.exit(main())

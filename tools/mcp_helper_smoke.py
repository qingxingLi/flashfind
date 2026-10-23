#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 10 Gate：对着**最终 .app** 里的 `flashfind-mcp` 做一次真握手。

验的是「用户拿到的那个包」而不是 `.build/` 里的中间产物：
  · `Contents/Helpers/` 只有 flashfind-mcp（开发期工具一个都没跟进来）
  · 二进制里嵌着 `__TEXT,__info_plist`（版本号的唯一来路），且值等于主 Info.plist
  · 真起进程、走 stdio：initialize 回的 `serverInfo.version` 就是发布版本号
  · `tools/list` 正好六个，名字闭集——多一个少一个都说明 `registerAll` 动了
  · stdout 每一行都是合法 JSON-RPC（多一行调试输出就会让客户端连不上）
  · stderr 不超过 3 行（§8.3），且不夹带任何协议内容

用法:
    python3 tools/mcp_helper_smoke.py --app 05-发布与运维/制品/客户端/闪寻.app
    python3 tools/mcp_helper_smoke.py --app <path> --expect-version 1.1.2

退出码 0 = 全部通过；非 0 = 有断言失败（失败项逐条打印）。
"""
import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

HELPER_NAME = 'flashfind-mcp'
EXPECTED_TOOLS = {'list_sources', 'locate', 'locate_many', 'search', 'get_metadata', 'recent'}
MAX_STDERR_LINES = 3


def fail(problems, message):
    problems.append(message)


def check_helpers_directory(app, problems):
    helpers = app / 'Contents' / 'Helpers'
    if not helpers.is_dir():
        fail(problems, 'missing Contents/Helpers')
        return None
    entries = sorted(p.name for p in helpers.iterdir())
    if entries != [HELPER_NAME]:
        fail(problems, 'Contents/Helpers must contain exactly [%r], found %r' % (HELPER_NAME, entries))
    helper = helpers / HELPER_NAME
    if not helper.is_file():
        fail(problems, 'Contents/Helpers/%s is missing' % HELPER_NAME)
        return None
    if not os.access(helper, os.X_OK):
        fail(problems, 'Contents/Helpers/%s is not executable' % HELPER_NAME)
    return helper


def check_embedded_plist(helper, expected, problems):
    """`Bundle.main` 能读到版本的前提是这个 section 真在二进制里。"""
    listing = subprocess.run(['otool', '-l', str(helper)],
                             stdout=subprocess.PIPE).stdout.decode('utf-8', 'replace')
    if 'sectname __info_plist' not in listing:
        fail(problems, 'no __TEXT,__info_plist section (Bundle.main would report 0.0.0-dev)')
        return None
    dump = subprocess.run(['otool', '-s', '__TEXT', '__info_plist', '-X', str(helper)],
                          stdout=subprocess.PIPE).stdout.decode('utf-8', 'replace')
    raw = bytearray()
    for line in dump.splitlines():
        for field in line.split()[1:]:
            raw += bytes.fromhex(field)[::-1]
    end = raw.find(b'</plist>')
    if end >= 0:
        raw = raw[:end + len(b'</plist>')]
    try:
        embedded = plistlib.loads(bytes(raw))
    except Exception as exc:                      # noqa: BLE001 - 失败即证据
        fail(problems, 'embedded plist is unreadable: %r' % (exc,))
        return None
    if embedded.get('CFBundleShortVersionString') != expected:
        fail(problems, 'embedded version %r != expected %r'
             % (embedded.get('CFBundleShortVersionString'), expected))
    if embedded.get('CFBundleExecutable') != HELPER_NAME:
        fail(problems, 'embedded CFBundleExecutable %r != %r'
             % (embedded.get('CFBundleExecutable'), HELPER_NAME))
    return embedded


def handshake(helper, expected, problems):
    env = os.environ.copy()
    # DEBUG 构建才认这个变量；发布二进制忽略它。设一个不存在的路径，避免探针
    # 恰好连到本机正在运行的那份 App 而把结论变得取决于「App 开没开」。
    env['FF_AUTHORITY_SOCKET'] = '/nonexistent/flashfind-smoke.sock'
    proc = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
    stdout_lines, stderr_text = [], ''
    init_result, tools_result = None, None
    try:
        def send(payload):
            proc.stdin.write(json.dumps(payload) + '\n')
            proc.stdin.flush()

        def read_line():
            line = proc.stdout.readline()
            stdout_lines.append(line)
            return json.loads(line) if line.strip() else None

        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
              'params': {'protocolVersion': '2025-06-18', 'capabilities': {},
                         'clientInfo': {'name': 'flashfind-smoke', 'version': '1'}}})
        init = read_line()
        init_result = (init or {}).get('result')
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        tools = read_line()
        tools_result = (tools or {}).get('result')
        proc.stdin.close()
        stderr_text = proc.stderr.read()
        proc.wait(timeout=15)
    except Exception as exc:                      # noqa: BLE001
        fail(problems, 'handshake raised %r' % (exc,))
        try:
            proc.kill()
        except Exception:                         # noqa: BLE001
            pass

    if init_result is None:
        fail(problems, 'initialize produced no result')
        return {}, tools_result
    server_info = init_result.get('serverInfo') or {}
    if server_info.get('name') != 'flashfind':
        fail(problems, 'serverInfo.name %r != "flashfind"' % (server_info.get('name'),))
    if server_info.get('version') != expected:
        fail(problems, 'serverInfo.version %r != %r (Bundle.main fell back?)'
             % (server_info.get('version'), expected))

    lines = [ln for ln in stderr_text.splitlines() if ln.strip()]
    if len(lines) > MAX_STDERR_LINES:
        fail(problems, 'stderr has %d lines (limit %d)' % (len(lines), MAX_STDERR_LINES))

    # stdout 只能有协议：每一行都必须能解析成 JSON 且带 jsonrpc 字段。
    for index, line in enumerate(stdout_lines):
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except Exception:                         # noqa: BLE001
            fail(problems, 'stdout line %d is not JSON: %r' % (index, line[:120]))
            continue
        if 'jsonrpc' not in payload:
            fail(problems, 'stdout line %d is not a JSON-RPC frame: %r' % (index, line[:120]))

    return {'serverInfo': server_info,
            'protocolVersion': init_result.get('protocolVersion'),
            'stderr_lines': lines}, tools_result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, help='最终 .app 路径')
    parser.add_argument('--expect-version', help='期望版本；缺省读 app 的 CFBundleShortVersionString')
    args = parser.parse_args()

    app = Path(args.app).resolve()
    problems = []
    if not app.is_dir():
        print(json.dumps({'status': '失败', 'problems': ['not a directory: ' + str(app)]}, ensure_ascii=False))
        return 2

    info_path = app / 'Contents' / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    expected = args.expect_version or info['CFBundleShortVersionString']
    record = {'app': str(app), 'expected_version': expected, 'bundle_build': info.get('CFBundleVersion')}

    helper = check_helpers_directory(app, problems)
    if helper is not None:
        record['helper'] = {'path': str(helper.relative_to(app)),
                            'bytes': helper.stat().st_size}
        embedded = check_embedded_plist(helper, expected, problems)
        if embedded is not None:
            record['helper']['embedded'] = {
                'identifier': embedded.get('CFBundleIdentifier'),
                'version': embedded.get('CFBundleShortVersionString'),
                'build': embedded.get('CFBundleVersion'),
            }
        session, tools = handshake(helper, expected, problems)
        record['initialize'] = session
        names = sorted(t['name'] for t in (tools or {}).get('tools', [])) if tools else []
        record['tools'] = names
        record['tool_count'] = len(names)
        if set(names) != EXPECTED_TOOLS:
            fail(problems, 'tools/list is %r, expected the closed set %r'
                 % (sorted(names), sorted(EXPECTED_TOOLS)))

    record['status'] = '通过' if not problems else '失败'
    record['problems'] = problems
    print(json.dumps(record, ensure_ascii=False, indent=2))
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())

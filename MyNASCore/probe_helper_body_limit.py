#!/usr/bin/env python3
"""证明原生助手（TrustHTTP）的响应体处理：旧的 256 KB 上限会误杀正常响应，现在按原因分别上报。

── 为什么要写这个 ──────────────────────────────────────────────
2026-10-11 复搜失败时，群晖源（demo-nas.example:5003）的诊断行是：

    errorApi    = SYNO.FileStation.Search
    errorMethod = list
    reportedTotal = null          # 说明挂在**就绪轮询那一次**请求上
    errorDetail = native:ProtocolViolation

`native:` 这个前缀只可能来自 `source_pinned_transport.dart`，也就是**原生助手**
自己报回来的状态。而助手当时只有一处会吐 `ProtocolViolation`：

    guard let data = data, data.count <= 262144,          # ← 256 KB 硬上限
          let object = try? JSONSerialization... else { ProtocolViolation }

它把三件完全不同的事压成了同一个状态：**响应为空 / 超过 256 KB / 不是 JSON**。
于是诊断里只留下「设备返回的内容不符合预期」这一句，无法判断该去查代理、
查设备还是查客户端。

── 这个脚本证明什么 ────────────────────────────────────────────
用一台**本地** HTTPS 服务（现场自签 CA + 叶证书，只在本进程内存与临时目录里）
喂给助手四种响应体，逐条记录它现在怎么报：

  1. 一份**真实形态**的 DSM 分页响应，大小刚过 256 KB
     → 期望 `response`（这正是不带路径的旧上限会误杀的规模）
  2. 20 MB 的 JSON → 期望 `BodyTooLarge` + 字节数
  3. 一个 HTML 登录门户页 → 期望 `NonJSONBody` + 字节数 + looksLikeHTML
  4. 0 字节 → 期望 `EmptyBody`

不碰任何真实设备，不写系统信任库，不改任何全局设置。
用法：python3 probe_helper_body_limit.py --helper <TrustHTTP 路径> [--evidence <目录>]
"""
import argparse
import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

CA_CONFIG = """[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = FlashFind Helper Probe CA
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
"""

LEAF_CONFIG = """[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
"""

# 旧助手里的那个魔数。留在这里是为了在报告里直接做对比。
OLD_BODY_LIMIT = 262144


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} 失败：{result.stderr.strip()[:400]}")
    return result.stdout


def make_certificates(workdir: Path):
    """现场签一套 CA + 叶证书（SAN=IP:127.0.0.1，否则 SecTrustEvaluateWithError 会因主机名不符而失败）。"""
    ca_cnf, leaf_cnf = workdir / "ca.cnf", workdir / "leaf.cnf"
    ca_cnf.write_text(CA_CONFIG)
    leaf_cnf.write_text(LEAF_CONFIG)
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
         "-keyout", str(workdir / "ca.key"), "-out", str(workdir / "ca.crt"),
         "-config", str(ca_cnf)])
    run(["openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(workdir / "leaf.key"), "-out", str(workdir / "leaf.csr"),
         "-config", str(leaf_cnf)])
    run(["openssl", "x509", "-req", "-days", "2",
         "-in", str(workdir / "leaf.csr"), "-CA", str(workdir / "ca.crt"),
         "-CAkey", str(workdir / "ca.key"), "-CAcreateserial",
         "-out", str(workdir / "leaf.crt"), "-extfile", str(leaf_cnf), "-extensions", "v3"])
    return (workdir / "ca.crt").read_text(), str(workdir / "leaf.crt"), str(workdir / "leaf.key")


def dsm_page(rows: int) -> bytes:
    """一份**真实形态**的 DSM `Search.list` 分页响应（含 real_path/owner/perm/time）。

    刻意做成真形状而不是随机填充：这样「大小」这个数字才有意义 ——
    它是设备真的会发出来的量级，不是人为造的字符串。
    """
    folder = "/公司共享文档/年度汇总报告/各部门提交"
    files = [{
        "name": f"第{i:04d}份 质量分析报告 副本.docx",
        "path": f"{folder}/第{i:04d}份 质量分析报告 副本.docx",
        "isdir": False,
        "additional": {
            "real_path": f"/volume1/公司共享文档/年度汇总报告/各部门提交/第{i:04d}份 质量分析报告 副本.docx",
            "size": 102400 + i,
            "owner": {"user": "示例共享", "group": "users", "uid": 1026, "gid": 100},
            "time": {"atime": 1750000000, "crtime": 1740000000, "ctime": 1745000000, "mtime": 1755000000},
            "perm": {"acl": {"append": True, "del": True, "exec": False, "read": True, "write": True},
                     "is_acl_mode": False, "posix": 420},
            "type": "file",
        },
    } for i in range(rows)]
    body = {"success": True,
            "data": {"total": rows, "offset": 0, "finished": False, "files": files}}
    return json.dumps(body, ensure_ascii=False).encode()


def oversized_page(target: int) -> bytes:
    """把行数一步步加上去，直到响应体超过 `target`。"""
    rows = 100
    while True:
        body = dsm_page(rows)
        if len(body) > target:
            return body
        rows += 50


class Payload:
    """服务器按路径返回哪种响应。"""

    def __init__(self):
        self.big = oversized_page(OLD_BODY_LIMIT + 16384)
        self.huge = b'{"success":true,"data":{"pad":"' + b"x" * (20 * 1024 * 1024) + b'"}}'
        self.html = (b"<!DOCTYPE html><html><head><title>\xe7\x99\xbb\xe5\xbd\x95</title></head>"
                     b"<body><form action='/login'>\xe8\xaf\xb7\xe7\x99\xbb\xe5\xbd\x95</form></body></html>")
        self.empty = b""


def serve(payload: Payload, certfile: str, keyfile: str):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            choice = {
                "/webapi/big.cgi": payload.big,
                "/webapi/huge.cgi": payload.huge,
                "/webapi/html.cgi": payload.html,
                "/webapi/empty.cgi": payload.empty,
            }.get(self.path.split("?")[0])
            if choice is None:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(choice)))
            self.end_headers()
            if choice:
                self.wfile.write(choice)

        def log_message(self, *_args):
            pass

    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile, keyfile)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def call_helper(helper: str, endpoint: str, ca_pem: str, path: str):
    payload = json.dumps({
        "sourceID": "probe_local",
        "host": "127.0.0.1",
        "port": int(endpoint.rsplit(":", 1)[1]),
        "endpoint": endpoint,
        "path": path,
        "body": "api=SYNO.FileStation.Search&version=2&method=list&limit=1",
        "requestTimeoutMs": 30000,
        # 只把这次连接的信任锚换成现场签的 CA —— 等价于产品里 approvedCA 的用法，
        # 不触碰系统信任库。
        "approvedCAPem": ca_pem,
    })
    result = subprocess.run([helper], input=payload, capture_output=True, text=True, timeout=90)
    if result.returncode != 0 or not result.stdout:
        return {"state": "<helper 未输出>", "stderr": result.stderr.strip()[:200]}
    parsed = json.loads(result.stdout)
    # 成功时 body 很大，逐字节记进证据没意义；只留形状。
    if parsed.get("state") == "response":
        body = parsed.pop("body", {})
        parsed["bodyKeys"] = sorted(body.keys())
        data = body.get("data") or {}
        parsed["dataKeys"] = sorted(data.keys())
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True, help="打包产出的 TrustHTTP 路径")
    parser.add_argument("--evidence", default=None, help="输出目录（会写入 probe.json）")
    args = parser.parse_args()

    helper = str(Path(args.helper).resolve())
    if not Path(helper).exists():
        print(f"找不到助手：{helper}")
        return 1

    workdir = Path(tempfile.mkdtemp(prefix="ff2-helper-probe-"))
    records = {}
    try:
        ca_pem, certfile, keyfile = make_certificates(workdir)
        payload = Payload()
        httpd, port = serve(payload, certfile, keyfile)
        endpoint = f"https://127.0.0.1:{port}"

        print(f"本地 HTTPS 服务：{endpoint}")
        print(f"助手：{helper}")
        print(f"旧助手的上限：{OLD_BODY_LIMIT} 字节")
        print()

        cases = [
            ("真实规模的 DSM 分页响应（刚过旧上限）", "/webapi/big.cgi", payload.big),
            ("超大 JSON（20 MB）", "/webapi/huge.cgi", payload.huge),
            ("HTML 登录门户页", "/webapi/html.cgi", payload.html),
            ("空响应体", "/webapi/empty.cgi", payload.empty),
        ]
        for title, path, body in cases:
            result = call_helper(helper, endpoint, ca_pem, path)
            records[path] = {"title": title, "sentBodyBytes": len(body), "helper": result}
            verdict = result.get("state")
            extra = ""
            if "bytes" in result and result["bytes"] is not None:
                extra = f"，bytes={result['bytes']}"
            if result.get("looksLikeHTML"):
                extra += "，looksLikeHTML=true"
            exceeded = "（已超过旧上限）" if len(body) > OLD_BODY_LIMIT else ""
            print(f"  {title}")
            print(f"    发送 {len(body)} 字节{exceeded} → 助手报 state={verdict}{extra}")

        httpd.shutdown()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    print("结论：")
    big = records["/webapi/big.cgi"]
    if big["helper"].get("state") == "response":
        print(f"  · 一份 {big['sentBodyBytes']} 字节的**正常** DSM 分页响应现在被正常解析；")
        print(f"    而它已经超过旧上限 {OLD_BODY_LIMIT} 字节 —— 旧实现在这里会报 "
              f"ProtocolViolation，且不告诉你是因为太大。")
    else:
        print(f"  · 意外：{big['sentBodyBytes']} 字节的正常响应未被接受：{big['helper']}")
    for path, key in [("/webapi/huge.cgi", "BodyTooLarge"),
                      ("/webapi/html.cgi", "NonJSONBody"),
                      ("/webapi/empty.cgi", "EmptyBody")]:
        got = records[path]["helper"].get("state")
        mark = "✅" if got == key else "❌"
        print(f"  {mark} {records[path]['title']} → 期望 {key}，实际 {got}")

    if args.evidence:
        out = Path(args.evidence)
        out.mkdir(parents=True, exist_ok=True)
        (out / "probe.json").write_text(json.dumps({
            "date": "2026-10-11",
            "helper": helper,
            "oldBodyLimit": OLD_BODY_LIMIT,
            "records": records,
        }, ensure_ascii=False, indent=2))
        print(f"\n证据已写入 {out / 'probe.json'}")

    unexpected = [p for p, key in [("/webapi/big.cgi", "response"),
                                   ("/webapi/huge.cgi", "BodyTooLarge"),
                                   ("/webapi/html.cgi", "NonJSONBody"),
                                   ("/webapi/empty.cgi", "EmptyBody")]
                  if records[p]["helper"].get("state") != key]
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())

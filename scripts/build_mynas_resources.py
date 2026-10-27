"""Reproducibly compile the frozen MyNAS Dart core and native trust helper into app resources."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess
# 本脚本住在 scripts/ 下，往上两级才是 client/；root 是项目根，所有输出都必须落在它里面。
# root 按**内容**认定（Package.swift + Sources/ + MyNASCore/），不能写死 `client.parents[2]`
# （那是内部布局的层级），也不能要求 `.git` 存在（GitHub 的 Download ZIP 解压出来没有）。
# 与 scripts/build_trial.py 的 `_repo_root` 同一个判据，两边必须保持一致。
client=Path(__file__).resolve().parent.parent
def _repo_root(start):
    markers=('Package.swift','Sources','MyNASCore')
    for cand in [start,*start.parents]:
        if all((cand/m).exists() for m in markers):return cand
    return start
root=_repo_root(client)
a=argparse.ArgumentParser();a.add_argument('--output',required=True);a.add_argument('--temporary-alias',required=True)
a.add_argument('--arch',choices=('arm64','x86_64'),default='arm64',
               help='目标架构。arm64 是本机默认；x86_64 需要一份 x86_64 的 Dart SDK（DART_SDK=…）。')
args=a.parse_args()
out=Path(args.output).resolve();out.relative_to(root)
alias=Path(args.temporary_alias);alias.resolve().relative_to(root)
if not alias.is_symlink():raise SystemExit('temporary alias must resolve inside project')
source=client/'MyNASCore'
def find_dart_sdk():
    # Dart SDK 各人装在不同地方（官方包 / brew / Flutter 自带 / 自定义工具链），
    # 所以不写任何人的本机路径：环境变量 → PATH → 常见位置。
    # 这里缺 SDK 就没法编译核心，必须明确报错，不能悄悄跳过。
    override=os.environ.get('DART_SDK')
    if override:
        p=Path(override)
        if (p/'bin/dart').exists(): return p
        if p.name=='dart' and p.exists(): return p.parent.parent
    found=shutil.which('dart')
    if found:
        p=Path(found).resolve().parent.parent
        if (p/'bin/dart').exists(): return p
    for c in (Path.home()/'flutter/bin/cache/dart-sdk',
              Path('/opt/homebrew/opt/dart-sdk/libexec'),
              Path('/usr/local/opt/dart-sdk/libexec'),
              Path('/usr/lib/dart')):
        if (c/'bin/dart').exists(): return c
    return None
sdk=find_dart_sdk()
if sdk is None:
    raise SystemExit('找不到 Dart SDK：设 DART_SDK=/path/to/dart-sdk，或把 dart 放进 PATH')
arch=args.arch
def _archs(path):
    r=subprocess.run(['lipo','-archs',str(path)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    return r.stdout.split()
# ★ Dart AOT **不支持交叉编译**（实测 3.13.5：`Unsupported target platform macos_x64`），
#   产出的架构恒等于宿主 dart 的架构。所以要 x86_64 产物，SDK 本身必须是 x86_64。
#   混用 SDK 的后果不是编译失败，而是「app 是 x86_64、核心是 arm64」——在 Intel 上
#   表现为能启动、搜索永远失败，比装不上难查得多，所以这里在编译前就拦住。
sdk_archs=_archs(sdk/'bin/dart')
if arch not in sdk_archs:
    raise SystemExit(f'Dart SDK 是 {sdk_archs}，要出 {arch} 必须用 {arch} 的 SDK（DART_SDK=/path/to/sdk）')
swift_target=[] if arch=='arm64' else ['-target','x86_64-apple-macos13']
out.mkdir(parents=True,exist_ok=False)
# 编译缓存必须**不能进 app**，也要能随时删掉重建。
# 之前取 out.parent（= .app/Contents/Resources）时，swiftc 的 .pcm/.swiftmodule 会以
# MyNAS-build-cache/ 一起进包：体积从 7MB 涨到 41MB，且这些是本机编译缓存而非交付物。
# 放在 client/.build 下：构建产物目录，已被版本控制忽略。
cache=client/'.build/mynas-build-cache'
cache.mkdir(parents=True,exist_ok=True)
# ★ 编译日志**不进包**：`dart compile` / `swiftc` 的输出里带构建机的绝对路径
#   （/Users/<用户名>/Documents/…），打进 .app 等于把开发机的目录结构连同项目名
#   一起交给每个拿到安装包的人，不用启动 App 就能读（2026-10-27 审查 F03）。
#   日志留在构建证据目录里：不进 app、也不进版本控制。
logs=client/'.build/mynas-logs'
logs.mkdir(parents=True,exist_ok=True)
for p in ['bin','native','licenses','tmp']: (out/p).mkdir()
env={'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8','CI':'true','DART_SUPPRESS_ANALYTICS':'true','CLANG_MODULE_CACHE_PATH':str(cache),'SWIFT_MODULE_CACHE_PATH':str(cache)}
inputs={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.rglob('*')) if p.is_file()}
record={'task':'mynas resources','version':'0.1','date':'2026-10-09','status':'未执行','inputs':inputs,'steps':[],'architecture':arch}
for name,cmd in [('dart-core',[str(sdk/'bin/dart'),'--disable-dart-dev','compile','exe',str(source/'bin/harness.dart'),'-o',str(out/'bin/mynas-core')]),('native-trust',['/usr/bin/swiftc',*swift_target,str(source/'native/TrustHTTP.swift'),'-o',str(out/'native/TrustHTTP')])]:
 p=subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(logs/(arch+'-'+name+'.log')).write_bytes(p.stdout);record['steps'].append({'name':name,'exitCode':p.returncode})
 (out/'resource-record.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
 if p.returncode:raise SystemExit(name+' failed')
# 产物架构必须与声明一致：一个架构混进另一个，只有「跑起来不对」时才暴露。
record['productArchs']={}
for rel in ('bin/mynas-core','native/TrustHTTP'):
 got=_archs(out/rel);record['productArchs'][rel]=got
 if arch not in got:raise SystemExit(f'{rel} 是 {got}，应为 {arch}')
for name in ['MyNAS-MIT.txt']:shutil.copyfile(source/'licenses'/name,out/'licenses'/name)
for name in ['LICENSE','NOTICES']: 
 if (sdk/name).exists():shutil.copyfile(sdk/name,out/'licenses'/('Dart-'+name))
# 交付前自检：包内只允许运行必需产物 + 构建记录。
# （编译缓存曾被打进 .app：swiftc 的 .pcm/.swiftmodule 让体积从 7MB 涨到 41MB。）
allowed={'bin','native','licenses','tmp'}
root_files={'resource-record.json'}
# ★ 日志**一律**不许出现在包内：不在白名单里就够了，这里再单独卡一次，
#   是因为「日志」和「记录」长得很像（都是构建时生成的文本），容易被顺手加进白名单。
#   它们的区别很硬：记录里只有相对路径与哈希，日志里全是构建机的绝对路径。
packaged_logs=sorted(str(p.relative_to(out)) for p in out.rglob('*.log'))
if packaged_logs:
 raise SystemExit('build log leaked into package (contains build-machine paths): '+', '.join(packaged_logs[:5]))
stray=sorted(str(p.relative_to(out)) for p in out.rglob('*')
              if p.is_file() and p.relative_to(out).parts[0] not in allowed
              and str(p.relative_to(out)) not in root_files)
if stray:
 raise SystemExit('unexpected files in packaged resources: '+', '.join(stray[:10]))
# 双保险：任何编译中间物（.pcm/.swiftmodule/缓存目录）都不允许出现在包内。
leftovers=[str(p) for p in out.rglob('*') if p.suffix in ('.pcm','.swiftmodule') or 'cache' in p.name.lower()]
if leftovers:
 raise SystemExit('build cache leaked into package: '+', '.join(leftovers[:5]))
record['status']='通过'
record['outputHashes']={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [out/'bin/mynas-core',out/'native/TrustHTTP',*list((out/'licenses').glob('*'))]}
(out/'resource-record.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print('MyNAS application resources built')

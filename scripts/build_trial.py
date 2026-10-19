# -*- coding: utf-8 -*-
"""Build/sign/package a real trial app. Never launches or installs it."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, plistlib, re, shutil, subprocess

# 本脚本住在 scripts/ 下，往上两级才是 client/。
# 不要在这里写任何本机绝对路径：仓库要在别人机器上照样能编。
client = Path(__file__).resolve().parent.parent


def _repo_root(start: Path) -> Path:
    """按**内容**认定仓库根：从脚本所在目录往上找第一个同时具备
    `Package.swift` / `Sources/` / `MyNASCore/` 的目录。

    两个坑都不能踩：
    - 不能写死「从 client 上溯固定几级」。那是内部布局
      （<项目根>/03-开发/FlashFind2/client）的层级；公开仓里 client 自己就是仓根，
      上溯固定层级会指向 /Users 之类的无关目录——那时 `--output` / `--scratch`
      无论写什么都会被 `relative_to(project)` 判成「不在项目内」，
      clone 到更浅的目录则直接 IndexError。
    - 不能靠 `.git`。GitHub 的「Download ZIP」解压出来**没有** `.git`，而
      `git clone` 有。用 `.git` 当必要条件就会造出「clone 能编、ZIP 不能编」
      这种开发者永远碰不到、用户一上手就撞上的故障——我们自己只走 clone，
      所以它在 CI 里也不会红。
      判据换成仓库内容：三件标记文件两种拿法里都在，且与 clone 到哪一层无关。
    """
    markers = ('Package.swift', 'Sources', 'MyNASCore')
    for cand in [start, *start.parents]:
        if all((cand / marker).exists() for marker in markers):
            return cand
    return start


project = _repo_root(client)
parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, help='New directory inside project; must not exist')
parser.add_argument('--scratch', help='Swift scratch path inside project (source builds only)')
parser.add_argument('--temporary-alias', help='Short symlink resolving to a project temporary directory (source builds only)')
parser.add_argument('--icon', help='UI-delivered .icns inside project, matching CFBundleIconFile')
parser.add_argument('--release', action='store_true',
                    help='Package a release build: app is named after CFBundleDisplayName '
                         '(no version suffix) and CFBundleShortVersionString must look like 1.2 or 1.2.3')
parser.add_argument('--reuse-mynas-resources',
                    help='复用一份已交付的 Resources/MyNAS（源码未变的重制场景，例如只改 DMG 布局）。'
                         'Dart AOT 重编不保证字节可复现，重编会让 app 本体与已发布包不一致；'
                         '复用则保证 app 内容逐字节不变。来源必须在项目内且自带 resource-record.json。')
parser.add_argument('--app-from-zip',
                    help='只重做安装包：从一份已发布的 -arm64.zip 里取 app，不重新编译。'
                         '理由：Swift 产物不保证字节可复现——实测同源码、同 scratch、同编译器连编两次，'
                         '主二进制仍有 1914 字节差异（LC_UUID 一类）。而「只改 DMG 包装」不该换掉'
                         '用户已经装过的那份二进制：同版本号下出现两个不同的二进制，比不升级更糟。'
                         '此模式下 zip 原样带入，只重做 DMG。')
args = parser.parse_args()
out = Path(args.output).resolve()
scratch = Path(args.scratch).resolve() if args.scratch else None
tmp_alias = Path(args.temporary_alias) if args.temporary_alias else None
icon = Path(args.icon).resolve() if args.icon else None
if icon:
    icon.relative_to(project)
    if not icon.is_file() or icon.suffix != '.icns' or icon.read_bytes()[:4] != b'icns':
        raise SystemExit('A valid project .icns is required')
out.relative_to(project)
if scratch:
    scratch.relative_to(project)
if tmp_alias:
    tmp_alias.resolve().relative_to(project)
    if not tmp_alias.is_symlink():
        raise SystemExit('Temporary alias must be a symlink into the project')
if scratch or tmp_alias:
    if not (scratch and tmp_alias):
        raise SystemExit('--scratch and --temporary-alias go together')
elif not args.app_from_zip:
    raise SystemExit('--scratch and --temporary-alias are required for a source build')
if args.app_from_zip and icon:
    raise SystemExit('--icon is not used with --app-from-zip; the reused app keeps its own icon')
out.mkdir(parents=True, exist_ok=False)
record = {'task': 'PM-CLI-004', 'date': '2026-10-08', 'functional_tests': '包本身未执行安装后完整验收；源码回归见交付记录', 'commands': []}

# 搜索框前导字形（2026-10-15）的文件名**单一来源**：inputs() 的哈希追踪与
# 下面的进包拷贝共用这一份名单。之前两处各写一遍字面量，结果「漏拷」这种改动
# 会被另一处的残留字面量顶替，红证抓不到（2026-10-15 实测）。
SEARCH_GLYPH_NAMES = ('ShanXunGlyph.png', 'ShanXunGlyph@2x.png')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inputs():
    glyph_paths = [client / 'Resources/Brand' / n for n in SEARCH_GLYPH_NAMES]
    paths = list((client / 'Sources').rglob('*')) + list((client / 'MyNASCore').rglob('*')) + [client / 'scripts/build_mynas_resources.py', client / 'Package.swift', client / 'Resources/Packaging/Info.plist', client / 'Resources/Brand/ShanXunMenuIcon.png', client / 'Resources/Brand/ShanXunMenuIcon@2x.png', client / 'Resources/dmg-ds-store', Path(__file__).resolve()] + glyph_paths
    if icon:
        paths.append(icon)
    return {str(p.relative_to(project)): sha(p) for p in sorted(paths) if p.is_file()}

def save():
    (out / 'build-record.json').write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')

def run(command, name, required=True, env=None):
    result = subprocess.run(command, cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '.log')).write_bytes(result.stdout)
    record['commands'].append({'argv': command, 'exit_code': result.returncode, 'log': name + '.log'})
    save()
    if required and result.returncode:
        raise SystemExit(name + ' failed; see log')
    return result


def app_identity(info):
    """从 Info.plist 推交付身份：应用名、归档文件名主干、短版本、构建号。

    正式版与试用版共用这一处——「包名 == Info.plist 版本 == 磁盘版本」只在这里装配。
    """
    version = info['CFBundleShortVersionString']
    build_number = info['CFBundleVersion']
    if args.release:
        # 正式版身份：短版本必须形如 1.0 或 1.0.0，且不得再带 trial 字样——
        # 防的是「改了版本号忘了把 -trial.N 摘掉」，那种包会被当成正式版发出去。
        if not re.fullmatch(r'\d+(\.\d+){1,2}', version) or not build_number.isdecimal():
            raise SystemExit('Unexpected release identity')
        # 应用名不带版本号：`闪寻.app`，与 CFBundleDisplayName 一致。
        # 版本号只落在归档文件名与 Info.plist 里，Finder 里看到的就是干净的名字。
        app_name = info.get('CFBundleDisplayName') or '闪寻'
        return app_name, '%s-%s' % (app_name, version), version, build_number
    if not version.startswith('2.0.0-trial.') or not build_number.isdecimal():
        raise SystemExit('Unexpected trial identity')
    app_name = 'FlashFind-%s-build%s' % (version, build_number)
    return app_name, app_name, version, build_number


def finalize():
    """收口：源文件在交付时没被动过、签名验过、DMG 内容真挂载核对过，才算 complete。"""
    record['final_sources'] = inputs()
    record['sources_unchanged_at_delivery'] = record['sources_before'] == record['final_sources']
    record['complete'] = bool(record['sources_unchanged_at_delivery']
                              and record.get('signature_verified')
                              and record.get('dmg_contents_verified'))
    save()
    print(out)


def package_dmg(app, readme, app_name, file_stem):
    """把 app + 说明文件装成交付 DMG：预置窗口布局、/Applications 快捷方式、交付前挂载自检。

    ── 窗口布局 ────────────────────────────────────────────────────────────
    Finder 打开 DMG 时按卷内 .DS_Store 摆图标：左「闪寻.app」，中「安装前说明.txt」，
    右「Applications」快捷方式；窗口 600×400，图标视图 128pt。

    为什么不在构建时驱动 Finder 自己写：本机实测，Finder 在自动化会话里对 DMG 卷
    只会落下 6148 字节的空壳（offsetTable 512 个槽位全为 0）——APFS 与 HFS+ 都试过，
    `tell window` 与 create-dmg 的 `tell disk` 两种写法都失败：位置能"设置成功"
    （读回正确）却不落盘。所以布局改成一次性程序化生成（ds_store 库，dmgbuild 的依赖）
    并固化成资源，生成与读回见 tools/dmg_layout.py。打包路径对它零依赖：只拷贝 + 自检。
    """
    layout_source = client / 'Resources/dmg-ds-store'
    layout_entries = ('安装前说明.txt', 'Applications', '闪寻.app')
    if not layout_source.is_file():
        raise SystemExit('missing DMG layout resource: ' + str(layout_source))

    # stage 里只有已签名的 app、说明文件与 /Applications 快捷方式；日志留在 DMG 外。
    stage = out / 'dmg-stage'
    stage.mkdir()
    shutil.copytree(app, stage / app.name)
    shutil.copyfile(readme, stage / readme.name)

    # 「应用程序」文件夹快捷方式。没有它，用户打开 DMG 只能看到一个 .app，
    # 还得自己另开一个访达窗口把它拖过去——这是「下下来装不上」最常见的卡点。
    # 软链指向本机 /Applications：Finder 把它画成普通文件夹，把 .app 拖上去
    # 就等于装进了 /Applications。必须是软链——复制只会得到一个空目录，拖不进去。
    applications_link = stage / 'Applications'
    os.symlink('/Applications', applications_link)
    if not applications_link.is_symlink() or os.readlink(applications_link) != '/Applications':
        raise SystemExit('Applications shortcut is not a symlink to /Applications')

    # 预置布局的 Iloc 记录按条目名写死。先拿 stage 的实际条目名对一遍：
    # 对不上就不套用（套了等于给一个不存在的名字设坐标），退回「按名称排列」
    # 并如实记下原因——不假装有布局。
    staged = tuple(sorted(p.name for p in stage.iterdir()))
    if staged != tuple(sorted(layout_entries)):
        record['dmg_layout'] = {'status': 'skipped',
                                'reason': 'staged entries differ from the canned layout',
                                'staged': list(staged), 'layout_targets': sorted(layout_entries)}
    else:
        shutil.copyfile(layout_source, stage / '.DS_Store')
        moved = (stage / '.DS_Store').read_bytes()
        # 空壳的 .DS_Store 里没有任何记录名；这里逐项确认真记录在，免得哪天资源被
        # 截断或覆盖成空壳，包照发、用户却看到一个按名字乱排的窗口。
        problems = [m.decode() for m in (b'.bwspblob', b'.icvpblob') if m not in moved]
        found_iloc = moved.count(b'Ilocblob')
        if found_iloc != len(layout_entries):
            problems.append('Ilocblob x%d, found %d' % (len(layout_entries), found_iloc))
        for name in layout_entries:
            if name.encode('utf-16-be') not in moved:
                problems.append(name + ' (utf-16be)')
        # 窗口尺寸从资源里现读，不在这里再抄一份——抄一份迟早跟资源对不上。
        # bwsp 是以二进制 plist 存在记录里的，字符串 `{{x, y}, {w, h}}` 原样可见。
        bounds = re.search(rb'\{\{-?\d+, -?\d+\}, \{\d+, \d+\}\}', moved)
        if not bounds:
            problems.append('window bounds')
        if problems:
            raise SystemExit('DMG layout resource is unusable: ' + ', '.join(problems))
        record['dmg_layout'] = {'status': 'applied',
                                'resource': str(layout_source.relative_to(project)),
                                'sha256': sha(layout_source), 'bytes': layout_source.stat().st_size,
                                'window_bounds': bounds.group().decode()}

    (out / 'dmg-stage-listing.log').write_text('\n'.join(sorted(
        (p.name + ' -> ' + os.readlink(p)) if p.is_symlink() else p.name
        for p in stage.iterdir())) + '\n', encoding='utf-8')
    record['dmg_stage'] = {p.name: ('symlink -> ' + os.readlink(p)) if p.is_symlink() else 'entry'
                           for p in sorted(stage.iterdir(), key=lambda q: q.name)}

    dmg = out / (file_stem + '-arm64.dmg')
    volname = ('闪寻 ' + version) if args.release else ('FlashFind Trial ' + build_number)
    dmg.unlink(missing_ok=True)
    run(['hdiutil', 'create', '-volname', volname, '-srcfolder', str(stage),
         '-format', 'UDZO', '-ov', str(dmg)], 'dmg')
    run(['hdiutil', 'verify', str(dmg)], 'dmg-verification')
    record['dmg_sha256'] = sha(dmg)

    # 交付前把成品真挂一次：卷名、/Applications 软链、说明文件、布局文件都得在。
    # hdiutil verify 只查镜像完整性，查不出「里面少了什么」——而这次改的正是
    # 「里面有什么」。这是唯一能证明用户挂载后看到什么的检查。
    attached = run(['hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-noautoopen', '-plist'],
                   'dmg-inspect-attach')
    entities = plistlib.loads(attached.stdout).get('system-entities', [])
    mounted = next((e for e in entities if e.get('mount-point')), None)
    if not mounted:
        raise SystemExit('hdiutil attach reported no mount point')
    root = Path(mounted['mount-point'])
    try:
        # 卷名问 diskutil，不问挂载点：同名卷已经挂着时，系统会把新卷挂成
        # 「… 1」，挂载点名字就与卷名不一致了，但卷标本身没变。
        volume = None
        probe = run(['diskutil', 'info', '-plist', mounted['dev-entry']], 'dmg-inspect-volume', required=False)
        if probe.returncode == 0:
            try:
                volume = plistlib.loads(probe.stdout).get('VolumeName')
            except ValueError:
                volume = None
        contents = {p.name: ('symlink -> ' + os.readlink(p)) if p.is_symlink() else 'entry'
                    for p in sorted(root.iterdir(), key=lambda q: q.name) if p.name != '.DS_Store'}
        link_ok = (root / 'Applications').is_symlink() and os.readlink(root / 'Applications') == '/Applications'
        ds_ok = (root / '.DS_Store').is_file()
        record['dmg_contents'] = {'volume': volume, 'entries': contents,
                                  'applications_symlink': link_ok, 'ds_store_in_volume': ds_ok}
        problems = [n for n in (app.name, readme.name) if n not in contents]
        if (volume or root.name) != volname:
            problems.append('volume %r != %r' % (volume, volname))
        if not link_ok:
            problems.append('Applications is not a symlink to /Applications')
        if record['dmg_layout']['status'] == 'applied' and not ds_ok:
            problems.append('layout .DS_Store missing from the volume')
        if problems:
            raise SystemExit('DMG contents check failed: ' + '; '.join(problems))
        record['dmg_contents_verified'] = True
    finally:
        run(['hdiutil', 'detach', str(root), '-force'], 'dmg-inspect-detach', required=False)

    # 收尾删掉 stage：留着的 .app 副本会被 Spotlight 收录，变成 LaunchServices 里
    # 「同 bundle id 的第二个来源」，系统设置就会挑到错的那个（项目记忆：显示名反查坑）。
    shutil.rmtree(stage)
    record['dmg_stage_removed'] = not stage.exists()


def repack_from_zip():
    """只重做安装包：把一份已发布 zip 里的 app 原样搬过来，只重做 DMG。

    Swift 产物不保证字节可复现——实测同源码、同 scratch、同编译器连编两次，
    主二进制仍有 1914 字节差异（LC_UUID 一类）。「只改 DMG 包装」不该换掉用户
    已经装过的那份二进制：同版本号下出现两个不同的二进制，比不升级更糟。
    返回 (app, readme, app_name, file_stem, version, build_number)。
    """
    source_zip = Path(args.app_from_zip).resolve()
    source_zip.relative_to(project)
    if not source_zip.is_file() or source_zip.suffix != '.zip':
        raise SystemExit('--app-from-zip must point at a zip inside the project')
    unpack = out / 'app-from-zip'
    run(['ditto', '-x', '-k', str(source_zip), str(unpack)], 'unpack-app')
    bundles = [p for p in unpack.iterdir() if p.suffix == '.app']
    if len(bundles) != 1:
        raise SystemExit('expected exactly one .app inside ' + str(source_zip))
    source_app = bundles[0]
    if run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(source_app)],
           'source-signature-verification', required=False).returncode:
        raise SystemExit('reused app does not verify; refusing to package it')
    info = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())
    app_name, file_stem, version, build_number = app_identity(info)
    # 名字必须与源包身份一致，否则「只是重做包装」这句话就不成立。
    if source_app.name != app_name + '.app':
        raise SystemExit('reused app is named %s, identity says %s.app' % (source_app.name, app_name))
    app = out / source_app.name
    shutil.copytree(source_app, app)
    record.update(version=version, build=build_number, app=str(app),
                  channel='release' if args.release else 'trial', architecture='arm64', minimum_macos='13.0')
    record['app_source'] = {
        'mode': 'reused-from-zip',
        'zip': str(source_zip.relative_to(project)),
        'zip_sha256': sha(source_zip),
        'reason': 'Swift 产物不保证字节可复现；只改 DMG 包装时不得更换二进制',
        'app_sha256': {str(p.relative_to(app)): sha(p) for p in sorted(app.rglob('*')) if p.is_file()},
    }
    record['signature_verified'] = True
    record['binary_sha256'] = sha(app / 'Contents/MacOS/FlashFind2App')
    record['app_file_count'] = sum(1 for p in app.rglob('*') if p.is_file())
    record['app_bytes'] = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())

    # 已发布的 zip 原样带入：app 没变，zip 就还是那一份。
    # 不重压——实测 ditto 重新压缩同一棵目录并不逐字节复现（027008c0… ≠ 7dbf7b41…），
    # 凭空造一个「同版本、不同哈希」的 zip 只会让账目更乱。
    carried_zip = out / source_zip.name
    shutil.copyfile(source_zip, carried_zip)
    if sha(carried_zip) != sha(source_zip):
        raise SystemExit('carried zip does not match its source')
    record['zip_sha256'] = sha(carried_zip)
    record['zip_note'] = 'carried over unchanged from ' + str(source_zip.relative_to(project))

    # 说明文件属于安装包、不属于 app，按同一套文案重建（内容只由版本号与构建号决定）。
    readme = out / '安装前说明.txt'
    readme.write_text('闪寻 %s（构建 %s）\n正式发布版。\n未Developer ID签名或公证；本包不安装或修改NAS服务。\n'
                      % (version, build_number), encoding='utf-8')
    return app, readme, app_name, file_stem, version, build_number


record['sources_before'] = inputs()
save()

if args.app_from_zip:
    # 只重做安装包：走这里就不编译了，见 repack_from_zip 与 --app-from-zip 的说明。
    app, readme, app_name, file_stem, version, build_number = repack_from_zip()
    package_dmg(app, readme, app_name, file_stem)
    shutil.rmtree(out / 'app-from-zip')
    record['app_extract_removed'] = not (out / 'app-from-zip').exists()
    finalize()
    raise SystemExit(0)

env = os.environ.copy()
env.update(CLANG_MODULE_CACHE_PATH=str(scratch.parent / 'clang-cache'), SWIFT_MODULE_CACHE_PATH=str(scratch.parent / 'swift-cache'))
# 不覆盖 TMPDIR。实测 SwiftPM 在 TMPDIR 被外部改写后解析 target info 失败：
# "Failed to parse target info (malformed(json: \"\", ... Unable to parse empty data))"，
# 与 TMPDIR 的路径内容（中文、符号链接、纯 ASCII）无关，只要改了就必现。
# 编译期临时文件留在系统默认临时目录；构建输入输出仍全部约束在项目内。
record['build_environment'] = {key: env[key] for key in ('CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULE_CACHE_PATH')}
record['tmpdir_kept_default'] = env.get('TMPDIR', '')
run(['swift', 'build', '--package-path', str(client), '--scratch-path', str(scratch), '-c', 'release', '--disable-sandbox'], 'compile', env=env)
record['sources_after'] = inputs()
if record['sources_before'] != record['sources_after']:
    save(); raise SystemExit('Source changed during compile; artifact not packaged')
binary = scratch / 'release/FlashFind2App'
info = plistlib.loads((client / 'Resources/Packaging/Info.plist').read_bytes())
app_name, file_stem, version, build_number = app_identity(info)
app = out / (app_name + '.app')
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True)
(app / 'Contents/Resources').mkdir()
shutil.copyfile(binary, macos / 'FlashFind2App')
(macos / 'FlashFind2App').chmod(0o755)
info = plistlib.loads((client / 'Resources/Packaging/Info.plist').read_bytes())
if info.get('FlashFindUIOnlyPreview'):
    raise SystemExit('Refusing to package UI fixture app as production')
icon_name = info.get('CFBundleIconFile')
if icon_name:
    if not icon or icon_name != icon.name:
        raise SystemExit('CFBundleIconFile must match the supplied .icns')
    shutil.copyfile(icon, app / 'Contents/Resources' / icon_name)
    record['icon'] = {'source': str(icon.relative_to(project)), 'bundle_file': icon_name, 'sha256': sha(icon)}
elif icon:
    raise SystemExit('Supplied icon requires matching CFBundleIconFile')

# 状态栏模板图标（MenuBarExtra 用）。缺失时 App 会退回系统放大镜，
# 但交付包必须带齐——状态栏显示系统符号就是交付缺陷。
menu_icon_1x = client / 'Resources/Brand/ShanXunMenuIcon.png'
menu_icon_2x = client / 'Resources/Brand/ShanXunMenuIcon@2x.png'
for p in (menu_icon_1x, menu_icon_2x):
    if not p.is_file():
        raise SystemExit(f'missing menu bar template icon: {p}')
    shutil.copyfile(p, app / 'Contents/Resources' / p.name)
record['menu_bar_icon'] = {'sha256_1x': sha(menu_icon_1x), 'sha256_2x': sha(menu_icon_2x)}

# 搜索框前导字形：22pt 专用那一套（2026-10-15）。缺失不会报错，
# 只会静默退回系统放大镜——也就是「换图标」白做，所以这里同样硬卡。
search_glyph_record = {}
for name in SEARCH_GLYPH_NAMES:
    p = client / 'Resources/Brand' / name
    if not p.is_file():
        raise SystemExit(f'missing search field template glyph: {p}')
    shutil.copyfile(p, app / 'Contents/Resources' / name)
    search_glyph_record[name] = sha(p)
record['search_field_glyph'] = search_glyph_record

resources_dir = app / 'Contents/Resources/MyNAS'
if args.reuse_mynas_resources:
    # 复用已交付的 MyNAS 资源：只在「app 内容本来就不该变」的重制场景用
    # （例如本次只往 DMG 里加「应用程序」快捷方式）。不走 build_mynas_resources.py
    # 是因为那一步要重编 Dart 核心，而 Dart AOT 产物不保证字节可复现——
    # 重编会把 app 本体改掉，跟「只改包装」的前提直接矛盾。
    # 复用不是盲信：来源必须自带已通过的 resource-record.json，复制后逐字节核对。
    reuse = Path(args.reuse_mynas_resources).resolve()
    if project not in reuse.parents:
        raise SystemExit('reuse source must be inside the project')
    manifest = json.loads((reuse / 'resource-record.json').read_text(encoding='utf-8'))
    if manifest.get('status') != '通过':
        raise SystemExit('reuse source did not pass its own resource check')
    shutil.copytree(reuse, resources_dir)
    run(['diff', '-r', str(reuse), str(resources_dir)], 'mynas-resources')
    record['mynas_resources'] = {
        'mode': 'reused',
        'source': str(reuse.relative_to(project)),
        'source_sha256': {str(p.relative_to(reuse)): sha(p)
                          for p in sorted(reuse.rglob('*')) if p.is_file()},
    }
else:
    run(['python3', str(client / 'scripts/build_mynas_resources.py'), '--output', str(resources_dir),
         '--temporary-alias', str(tmp_alias)], 'mynas-resources')
# 交付前整体自检：.app 里不允许出现编译中间物。
# （MyNAS-build-cache 曾被打进 Resources，体积 7MB → 41MB。）
leaked = [str(p.relative_to(app)) for p in app.rglob('*')
          if p.is_file() and (p.suffix in ('.pcm', '.swiftmodule') or 'build-cache' in p.parts)]
if leaked:
    raise SystemExit('build cache leaked into app: ' + ', '.join(leaked[:5]))
record['app_file_count'] = sum(1 for p in app.rglob('*') if p.is_file())
record['app_bytes'] = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
for component in ('bin/mynas-core', 'native/TrustHTTP'):
    run(['codesign', '--force', '--sign', '-', str(app / 'Contents/Resources/MyNAS' / component)], 'sign-' + Path(component).name)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
record.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'], app=str(app),
              channel='release' if args.release else 'trial', architecture='arm64', minimum_macos='13.0')
run(['codesign', '--force', '--sign', '-', str(app)], 'sign')
verify = run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], 'signature-verification', required=False)
record['signature_verified'] = verify.returncode == 0
record['binary_sha256'] = sha(macos / 'FlashFind2App')
run(['codesign', '-d', '--verbose=4', str(app)], 'signature-details', required=False)
run(['file', str(macos / 'FlashFind2App')], 'architecture')
run(['otool', '-L', str(macos / 'FlashFind2App')], 'linked-libraries')
# An unsigned or unverifiable product is kept for diagnosis, never marked installable.
if verify.returncode:
    save(); raise SystemExit('Signature verification failed; app retained for diagnosis, no installer generated')
readme = out / '安装前说明.txt'
if args.release:
    # 正式版只写版本号：构建号是内部序号，同一个 1.0.1 会为修 bug 重打若干次，
    # 写进交付给用户的说明里只会让人来问「19 是什么意思」。构建号仍在
    # build-record.json 与 Info.plist 里，用于追溯。
    readme.write_text(f'闪寻 {version}\n正式发布版。\n未Developer ID签名或公证；本包不安装或修改NAS服务。\n', encoding='utf-8')
else:
    readme.write_text(f'闪寻 {version} / 客户端 build{build_number}\n真实试用候选，非稳定发布。受测范围及未测项目请阅读PM-CLI-004交付说明。\n未Developer ID签名或公证；本包不安装或修改NAS服务。\n', encoding='utf-8')
zip_path = out / (file_stem + '-arm64.zip')
run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(zip_path)], 'zip')
record['zip_sha256'] = sha(zip_path)

package_dmg(app, readme, app_name, file_stem)
finalize()

# -*- coding: utf-8 -*-
"""DMG 卷内 .DS_Store 的生成与读回。产物是 ../Resources/dmg-ds-store。

为什么需要它 ——
Finder 打开 DMG 时按卷内 .DS_Store 摆图标。本项目试过在打包时驱动 Finder 自己写，
此路不通：本机实测，Finder 在自动化会话里对 DMG 卷只落下 6148 字节的空壳
（offsetTable 512 个槽位全为 0）。APFS 与 HFS+ 都试过，`tell window` 与 create-dmg
的 `tell disk` 两种写法都失败——位置能"设置成功"（读回正确）却不落盘。
于是改成程序化生成一份、固化成资源；打包脚本（build_trial.py）只做「拷贝 + 自检」，
对 ds_store 库零依赖。

依赖：ds-store（dmgbuild 的依赖）。只在**重新生成或读回**时用到，打包路径不用。
      装进隔离环境（别污染系统 python）：
          <venv>/bin/pip install ds-store

用法 ——
    <venv>/bin/python tools/dmg_layout.py --read "/Volumes/闪寻 1.0.0/.DS_Store"
    <venv>/bin/python tools/dmg_layout.py --write Resources/dmg-ds-store

改完坐标后必须实测，别只信 --read 的一行输出：
    1. 把生成的文件塞进一个 DMG 的 stage 目录，hdiutil create 出镜像；
    2. hdiutil detach 之后**再** attach（不卸载直接读，会被 Finder 的内存缓存骗到）；
    3. 对挂在 /Volumes 下的那份 --read，确认坐标落盘了。
"""

import argparse
import sys

try:
    from ds_store import DSStore
except ImportError:  # pragma: no cover - 只在环境没装依赖时走到
    sys.exit('需要 ds-store：<venv>/bin/pip install ds-store（见本文件顶部说明）')

# 窗口：顶左 (300,160)，尺寸 620×500。坐标原点在窗口左上角，y 往下增大。
#
# 高度是量出来的，不是拍的：128pt 图标连标签一个格子约 145 高，窗口内容区还要再
# 让出标题栏 ~52。400 高时说明文件那格会被窗口底边切掉半截（0.1 版实测）。
WINDOW_BOUNDS = '{{300, 160}, {620, 500}}'
ICON_SIZE = 128.0
TEXT_SIZE = 12.0
# 图标落位。左边 app、右边「应用程序」快捷方式——用户横着一拖就装进 /Applications。
# 说明文件压在下排居中，不挡拖拽路径。
POSITIONS = (
    ('闪寻.app', (160, 140)),
    ('Applications', (460, 140)),
    ('安装前说明.txt', (250, 300)),
)

# bwsp = 窗口属性；icvp = 图标视图选项。这两个是「.」条目（卷根）的记录，
# 不是某个文件的记录——写错位置窗口就还是系统默认。
WINDOW_PROPERTIES = {
    'ShowStatusBar': False, 'ShowToolbar': False, 'ShowPathbar': False, 'ShowSidebar': False,
    'ContainerShowSidebar': False, 'SidebarWidth': 0, 'ShowTabView': False,
    'PreviewPaneVisibility': False, 'WindowBounds': WINDOW_BOUNDS,
}
ICON_VIEW_OPTIONS = {
    'viewOptionsVersion': 1, 'backgroundType': 1,
    'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
    'iconSize': ICON_SIZE, 'textSize': TEXT_SIZE, 'arrangeBy': 'none',
    'showIconPreview': True, 'showItemInfo': False, 'labelOnBottom': True,
    'gridSpacing': 100.0, 'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
}


def write(path):
    """生成一份 .DS_Store。Iloc 是**每个文件一条记录**、值是 (x, y) 元组——不是字典。"""
    with DSStore.open(str(path), 'w+') as store:
        store['.']['bwsp'] = WINDOW_PROPERTIES
        store['.']['icvp'] = ICON_VIEW_OPTIONS
        for name, position in POSITIONS:
            store[name]['Iloc'] = position
    return path


def read(path):
    """读回并打印。返回 {'bwsp':…, 'icvp':…, '<entry>': (x, y)}。

    只读打开：挂载出来的 DMG 是只读卷，默认的 r+ 会直接 OSError。
    """
    found = {}
    with DSStore.open(str(path), 'r') as store:
        for record in store:  # 迭代出来的是 DSStoreEntry，不是元组
            code = record.code.decode() if isinstance(record.code, bytes) else record.code
            if code == 'Iloc':
                found[record.filename] = record.value
            elif record.filename == '.' and code in ('bwsp', 'icvp'):
                found[code] = record.value
    return found


def main():
    parser = argparse.ArgumentParser(description='生成或读回 DMG 卷内的 .DS_Store')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--write', metavar='PATH', help='写出一份 .DS_Store')
    group.add_argument('--read', metavar='PATH', help='读回并打印一份 .DS_Store')
    args = parser.parse_args()

    if args.write:
        print('written:', write(args.write))
        return

    found = read(args.read)
    window = found.get('bwsp', {}).get('WindowBounds')
    icons = found.get('icvp', {}).get('iconSize')
    print('%s  窗口=%s 图标=%s' % (args.read, window, icons))
    positions = sorted((k, v) for k, v in found.items() if k not in ('bwsp', 'icvp'))
    for name, position in positions:
        print('  %-22s %s' % (name, tuple(position)))
    # 空壳的判定：一条 Iloc 都读不出来（offsetTable 全是 0）。
    if not positions:
        sys.exit('读不到任何图标位置——这是一份空壳 .DS_Store')
    if window != WINDOW_BOUNDS or icons != ICON_SIZE:
        sys.exit('窗口属性或图标尺寸与预期不符——这份布局不是本工具生成的')


if __name__ == '__main__':
    main()

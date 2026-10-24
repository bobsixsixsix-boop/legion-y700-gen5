#!/usr/bin/env python3
"""按 LAYOUT 重排 ColorOS 启动器（简洁模式 singledesktopitems）的桌面布局。
用法: python arrange.py <输入 launcher.db> <输出 launcher.db>
格式要点（从作者手动合并的文件夹样本学来）：
  - 文件夹 itemType=3，container=-100，有 screen/cellX/cellY，title 为文件夹名
  - 文件夹成员 container=<文件夹 _id>，screen=0，cellX=rank，cellY=0，vCellX=vCellY=-1
  - 桌面项 vCellX/vCellY 是竖屏（6 列）布局里的位置；这里按同样顺序 6 列逐行排
横屏网格 10 列 × 4 行（第 1 屏 0~1 行原本就是空的）。
"""
import sqlite3, sys, time

src, dst = sys.argv[1], sys.argv[2]
COLS, VCOLS = 10, 6

# 包名 -> 位置。'S0:r,c' = 第 1 屏第 r 行第 c 列；'F:工具' = 进文件夹。
LAYOUT = {
    # 第 0 行：常用（示例，按自己装的应用改）
    'com.oplus.camera':           'S0:0,0',   # 相机
    'com.coloros.gallery3d':      'S0:0,1',   # 相册
    'com.android.settings':       'S0:0,2',   # 设置
    'com.coloros.filemanager':    'S0:0,3',   # 文件管理
    'com.y700.switcher':          'S0:0,6',   # 切换到 Linux
    'me.weishu.kernelsu':         'S0:0,7',   # KernelSU
    'com.hons.ringlight':         'S0:0,8',   # 环灯
    # 第 1 行：两个文件夹（FOLDER_POS）
    # 文件夹：工具
    'com.coloros.alarmclock':     'F:工具',
    'com.coloros.calculator':     'F:工具',
    'com.coloros.soundrecorder':  'F:工具',
    'com.coloros.translate':      'F:工具',
    'com.coloros.weather2':       'F:工具',
    'andes.oplus.documentsreader':'F:工具',
    'com.android.email':          'F:工具',
    'com.coloros.ocrscanner':     'F:工具',   # AI 拍一拍
    'com.oplus.wpslauncher':      'F:工具',   # WPS Office PC
    'com.android.contacts/.PeopleActivityAlias': 'F:工具',  # 电话本
    'com.android.contacts/.DialtactsActivityAlias': 'F:工具',  # 拨号
    # 文件夹：OPPO
    'com.heytap.market':          'F:OPPO',
    'com.heytap.themestore':      'F:OPPO',
    'com.oplus.member':           'F:OPPO',
    'com.heytap.health':          'F:OPPO',
    'com.heytap.yoli':            'F:OPPO',
    'com.heytap.music':           'F:OPPO',
    'com.heytap.reader':          'F:OPPO',
    'com.oplus.tips':             'F:OPPO',
    'com.coloros.digitalwellbeing':'F:OPPO',
    'com.coloros.backuprestore':  'F:OPPO',
}
FOLDER_POS = {'工具': 'S0:1,0', 'OPPO': 'S0:1,1'}

import shutil; shutil.copy(src, dst)
c = sqlite3.connect(dst)
now = int(time.time() * 1000)

def key(intent):
    import re
    m = re.search(r'component=([^;]+)', intent or '')
    comp = m.group(1) if m else ''
    pkg = comp.split('/')[0]
    return comp, pkg

# 1) 旧文件夹（itemType=3）：成员放回桌面层级，再删掉文件夹
for (fid,) in c.execute("select _id from singledesktopitems where itemType=3").fetchall():
    c.execute("update singledesktopitems set container=-100 where container=?", (fid,))
    c.execute("delete from singledesktopitems where _id=?", (fid,))

# 2) 建新文件夹
next_id = c.execute("select max(_id) from singledesktopitems").fetchone()[0] + 1
folder_ids = {}
for name, pos in FOLDER_POS.items():
    r, col = map(int, pos.split(':')[1].split(','))
    folder_ids[name] = next_id
    c.execute("""insert into singledesktopitems(_id,title,intent,container,screen,cellX,cellY,vCellX,vCellY,spanX,spanY,itemType,
                 appWidgetId,modified,restored,profileId,rank,options,appWidgetSource,user_id,card_type,card_host_id,card_category,
                 editable_attributes,theme_card_identification,recommendId)
                 values(?,?,NULL,-100,0,?,?,-1,-1,1,1,3,-1,?,0,0,0,0,-1,0,-1,1,-1,0,0,-1)""",
              (next_id, name, col, r, now))
    next_id += 1

# 3) 逐个放置桌面项
placed = {}   # (screen,r,c) -> id
unmatched = []
folder_rank = {n: 0 for n in FOLDER_POS}
for _id, intent in c.execute("select _id,intent from singledesktopitems where container=-100 and itemType=0").fetchall():
    comp, pkg = key(intent)
    pos = LAYOUT.get(comp) or LAYOUT.get(pkg)
    if not pos:
        unmatched.append((_id, comp)); continue
    if pos.startswith('F:'):
        name = pos[2:]; rk = folder_rank[name]; folder_rank[name] += 1
        c.execute("update singledesktopitems set container=?,screen=0,cellX=?,cellY=0,vCellX=-1,vCellY=-1,rank=?,modified=? where _id=?",
                  (folder_ids[name], rk, rk, now, _id))
    else:
        r, col = map(int, pos.split(':')[1].split(','))
        assert (0, r, col) not in placed, f'overlap at {r},{col}'
        placed[(0, r, col)] = _id
        c.execute("update singledesktopitems set container=-100,screen=0,cellX=?,cellY=?,rank=0,modified=? where _id=?", (col, r, now, _id))
for name, fid in folder_ids.items():
    r, col = map(int, FOLDER_POS[name].split(':')[1].split(','))
    assert (0, r, col) not in placed, f'overlap at {r},{col}'
    placed[(0, r, col)] = fid

# 4) 竖屏位置：按横屏行优先顺序，6 列逐行排
order = sorted(placed.items())
for i, ((s, r, col), _id) in enumerate(order):
    c.execute("update singledesktopitems set vCellX=?,vCellY=? where _id=?", (i % VCOLS, i // VCOLS, _id))

# 5) 第 2 屏空了，删掉它
left = c.execute("select count(*) from singledesktopitems where container=-100 and screen=1").fetchone()[0]
if left == 0:
    c.execute("delete from singledesktopscreens where _id=1")
c.commit()

print('unmatched (left where they were):', unmatched)
print('screen1 leftover:', left)
for (s, r, col), _id in order:
    t, it = c.execute("select title,itemType from singledesktopitems where _id=?", (_id,)).fetchone()
    print(f'S{s} r{r} c{col}: id={_id} type={it} {t!r}')
for name, fid in folder_ids.items():
    print(f'folder {name} (id {fid}):', [row[0] for row in c.execute("select _id from singledesktopitems where container=? order by rank", (fid,))])

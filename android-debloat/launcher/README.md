# 安卓桌面（ColorOS 启动器）布局整理

2026-10-12 01:07 完成。为免逐个拖动图标，直接改启动器数据库。

## 文件

| 文件 | 用途 |
|---|---|
| `arrange.py` | 按脚本里的 `LAYOUT` / `FOLDER_POS` 表重排：`python arrange.py <输入db> <输出db>`。改布局只改这两张表。 |
| `launcher.db.bak-20261012` | 动手前的原始库（00:42 拉取，两屏 34 图标无文件夹） |
| `launcher.db.bak2-20261012-0102` | 作者手动合了一个文件夹之后的库（用来学文件夹格式） |
| `launcher.new.db` | 当前装在平板上的库 |
| `layout-*.xml` / `param-*.xml` | 启动器自己的"历史布局"快照（`files/history_layout/Standard/`），只作参考 |
| `home-before.png` / `home-after.png` | 改前改后截图 |

除 `arrange.py` 外，上表的数据库、布局快照和截图都是从设备上导出的数据，不随公开仓库发布；需要时从自己的平板拉取。

## 启动器的存法（ColorOS 17.3.9，`com.android.launcher`，标准模式，横屏 10 列 × 6 行）

- 库：`/data/user_de/0/com.android.launcher/databases/launcher.db`（注意是 `user_de`，不是 `/data/data`），表 `singledesktopitems` + `singledesktopscreens`。journal 模式是 delete，没有 WAL。
- 桌面项：`container=-100`，`screen`，`cellX/cellY`（横屏格子），`vCellX/vCellY`（竖屏 6 列布局里的格子，脚本按同一顺序 6 列逐行排），`itemType=0`。
- 底栏：`container=-101`，`screen`=位置序号。
- **文件夹：`itemType=3`**（不是 Launcher3 的 2），`container=-100`，`intent` 为空，`title` 是文件夹名；成员 `container=<文件夹 _id>`，`screen=0`，`cellX=rank`，`cellY=0`，`vCellX=vCellY=-1`。启动器自动命名的文件夹 title 前带一个 NBSP（如 `"\xa0Education"`）。
- 第 1 屏上面两行原本就是空的，不是卡片占位。

## 替换库的正确姿势（踩过的坑）

`am force-stop com.android.launcher` 之后系统**立刻**重新拉起桌面（它是 Home），如果 `force-stop` 和 `cp` 之间隔了哪怕 1 秒，启动器就已经用旧库加载进内存了——磁盘是新布局、屏幕是旧布局，而且它下一次写库会把旧布局写回去。要在**同一条 su 命令里**不间断地做：
```
am force-stop com.android.launcher && cp new.db launcher.db && rm -f launcher.db-journal launcher.db-wal launcher.db-shm && chown u0_a223:u0_a223 launcher.db && chmod 660 launcher.db && restorecon launcher.db
```
（uid 以 `dumpsys package com.android.launcher | grep userId` 为准。）

用触控注入（`input motionevent`）把图标拖到另一个图标上做文件夹，试了两次都被当成"挪位置"，别再走这条路。

## 回滚

把 `launcher.db.bak-20261012` 按上面的姿势拷回去即可。

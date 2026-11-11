# 台前调度 `y700-stage`（11-08 第一版，11-09 第二版照 vivo 原子工作台）

作者原话：
- 11-08：「我实际用这个平板的时候，发现一个问题，就是我们缺一个台前调度的功能。你去搜一搜，看看有没有开源方案，或者你了解一下什么叫做台前调度，帮我做一个。」
- 11-09，作者看了第一版，觉得完全没照 vivo OriginOS 设计。于是出了设计稿 `design/y700-stage-mockup.html`（提交 `e0906c1`），照 vivo OriginOS「原子工作台」做。作者看了设计稿：「照这个改，要圆角」。

调研见同目录 [`RESEARCH.md`](RESEARCH.md)（开源方案一览、为什么自己写、第一版范围、要作者定的 5 个问题）。作者没另说，第 7 节的 5 个推荐都照做了：真最小化；默认关，用控制中心磁贴开；一组最多 2 个窗口；竖屏暂停。第 2 条「条带常驻、舞台给它让位」第二版改了：舞台为卡片列让出左边 220，但**回到桌面时卡片列收起来**（设计稿里定的，作者「照这个改」等于认了）。

**现状（11-09 02:50）**：
- 第二版的脚本和圆角特效 02:09 装进平板作者的会话。圆角特效已在正在跑的 KWin 里手动加载过一次，D-Bus 接口能调，KWin 没崩。作者 02:33 从控制中心磁贴打开过，装完 shellbar 核对时还开着（脚本最后一句 `strip shown`，体检「开着」）。体检「台前调度」OK。
- **模糊背景层 02:43 随 shellbar 装上**：平板上的 shellbar 源码原来和 git 分叉（平板侧 Claude 11-03/11-04 直接在平板上加了勿扰、键鼠电量，补丁没进 git，踩坑第 20 条）；作者同意后先合进 git（`ea3c7ce`），测试床跑过再装。shellbar 重启后台前调度不会马上重发「开着」（见「有意不做」），所以装完手动发了一次 `setStage true`，日志 `stage on`，读到了作者的壁纸。**画面作者还没看过**。
- **11-09 02:51 作者截图报：模糊有了，左边卡片列被挤没了**（踩坑第 21 条）：背景层被脚本当成了挡板。已修（`e0e9a07`），测试床复现并验证过；作者点头后 03:03 装上（`build 20261109030355`）。装的时候作者正开着全屏的 YOUYOU，卡片列和背景层按规则让开，所以**修复在真会话里还没看到效果**，要作者退出全屏应用后看一眼卡片列在不在。
  03:09 真会话日志 `strip shown`（作者退出全屏后），卡片列回来了。
- **11-09 03:1x 作者又报三件事，已修（`44af433`），测试床复现并验证过，09:35 装上**（作者「装」，见「部署记录」）：
  - 换组时底下的 Dock 闪一下又收回去（踩坑第 22 条）：shellbar 新加 `holdDock(ms)`，飞行期间不把「没有窗口露着」当回桌面。
  - 屏幕键盘弹起再收起，Chrome、Claude 停在半屏高（踩坑第 23 条）：工作区一变就重新摆舞台。
  - Telegram 被键盘顶起来但下半截还压在键盘底下（同第 23 条）：窗口最矮高过槽位时底边对齐槽位底边、往上伸。
  - 装上后拿装着的版本跑 `stagestrip.sh` `SBBED_OK`；**真手指还没试**（「要作者在真机上做的」第 14–16 条）。
- **11-09 上午作者报：开着台前调度很费电**，平板 6–8 W，CPU 合计 25–27 %，卡片列里收起的应用（Chrome、wiliwili）都在后台画（踩坑第 24 条）。根因是卡片用的活缩略图：KWin 会一直按 120 Hz 催它的窗口出帧，窗口最小化了也一样。已改：卡片只拍一张静止图，活缩略图只开 0.6 秒，拍完就放掉。测试床里收起的动画应用 3 秒内旧版画了 180 帧，新版 0 帧。**10:37 装上**（作者「装吧，装上」，`build 20261109103741`，见「部署记录」）。作者 10:18 已经把台前调度关了，所以是关着加载的。**11:05–11:08 真机自测对照过**（作者「请你自行测试」，`stage-power-ab.sh`）：开着 1.30 W、关着 1.45 W，一样（亮度 800，静止画面）；收进卡片的动画测试应用 3 分钟 0 帧，wiliwili、KWin 都接近 0（改之前 9 %、8.7 % 一个核）。数见「部署记录」。
- **11-10 作者报：连点卡片切不过去，要等动画播完**（「手指连续点的话，它就不能够连续的切换应用，必须得等这个画动画播放完以后才能切换……我感觉动画打断是现在触摸逻辑UI的核心中的核心」，踩坑第 26 条）。三处都改了：飞行时的覆盖窗吃掉了点击（加 `outputOnly`）；飞行中途来了新操作要先落地再飞（改成从副本当前位置接着飞，`interrupt()` / `retake()`）；正在淡出的旧卡还接点击，快速点同一处会切过去又切回来（淡出时 `enabled: false`）。测试床加了 `retarget`、`slow-retarget` 两步，`stage.sh` `TSBED_OK`。**04:46 装上**（作者「装吧」，`build 20261110044654`，见「部署记录」），装着的版本测试床复查 `TSBED_OK`。**作者真手指试过**（第 19 条：两张卡来回快点、同一张卡连点、飞到一半再点）：「试过了，顺」。
- **11-10 作者报：键盘弹起再收起，左边的卡片上下又出黑边**（「左边那几个小卡片，它本来是渲染的挺好的……但是键盘切出来再弹回去，它就又出现黑边了」，踩坑第 27 条）。根因：键盘占了工作区，KWin 把卡片列里那些最小化着的窗口也压矮，键盘收起后不还；脚本以前只重摆舞台上那一组。卡片重拍时拍到压矮的窗口，放进按舞台比例画的卡里，上下露出底色。已改（`7dc25d9`）：卡片列里的窗口也一直摆在自己那组的槽位上（`placeRest()`），换了工作区把槽位再告诉它一次，卡里的窗口变了大小就重拍。顺带，从没上过舞台的窗口、从一对里拆出去的窗口，卡片上也不再有黑边。测试床 `stagestrip.sh` 加了 `cards` 一步和两处断言：旧脚本 5 条 FAIL，新脚本 `SBBED_OK`；`stage.sh` `TSBED_OK`（收进卡片的动画应用仍是 3 秒 0 帧）。**11-10 05:39 装上平板了**（build `20261110053904`，见「部署记录」）。真会话的日志里，键盘收起后卡片列里的 Dolphin、Telegram、Chrome 都回到了整槽位；**作者 11-10 真机试过：「没黑边了」**（「要作者在真机上做的」第 20 条；回来那一下闪不闪，作者没提）。
- **11-10 晚作者报：从文件管理器拖文件到 Telegram 拖不过去，普通桌面也没法让两个应用同时在一个屏幕上**（「我打开了一个文件管理器，我想拖一个文件到 Telegram 上发送，呃，拖不过去。然后顺带我发现了我们的正常的桌面模式也是无法让2个软件同时在一个屏幕上，这有点问题」）。真会话日志里只有 20:51–20:52 卡片列出入几次、20:52:15 作者关掉了台前调度，看不出当时 Telegram 在卡片列里还是和 Dolphin 并成了一组。20:58–21:06 在 ts-bed 里用真的 Dolphin 和 GTK 测试窗口分情况试了（剧本和探针在 `research/dnd-20261110/`，不随公开仓库发布）：
  - **并成一组以后能拖**：把目标的卡拖到舞台右半边并组，GTK 测试源拖到目标、Dolphin 的文件拖到目标，目标都收到了文件。台前调度本身不挡拖放（飞行覆盖层不飞的时候停在屏外，卡片列只有左边 220 宽）。
  - **拖到左边卡片上不行**：卡片列是 KWin 的内部窗口，收不到应用的拖放，松手就是拖放失败（踩坑第 28 条）。台前调度也不会因为拖着东西停在卡片上就把那组叫上舞台。
  - **Dolphin 自己的毛病**（台前调度关着、两个窗口并排也一样）：手指要先按住约 0.7 秒再动才拖得出来，直接拖拖不出来；按住时 Dolphin 有时会进「选择模式」（顶上一条浅绿色的横条），进了以后再长按拖就拖不动，要点横条上的「退出选择模式」。同一次连拖三次只成了一次。这是 Dolphin 的触摸逻辑，不是台前调度的。
  - **普通桌面（台前调度关着）其实能并排**：手指按住窗口标题栏拖到屏幕左边缘或右边缘，KWin 自带的「半屏贴边」把它摆成半屏；两个窗口各贴一边以后文件拖得过去。只在测试床试过，真会话里有状态栏、Dock 和边缘手势，没试；而且这个办法藏得深，作者不知道很正常。
  - 等作者定下一步，候选：台前调度里「拖着文件停在卡片上，那组就上舞台」（照苹果台前调度；卡片收不到拖放，要另找路，见踩坑第 28 条）；普通桌面照 vivo 做分屏（新界面，先出设计稿）。
- 测试床里全部通过：ts-bed 的 `stage.sh` `TSBED_OK`（带圆角特效），sb-bed 的 `stageback.sh` 在合并后的构建上 `SBBED_OK`，`stagestrip.sh`（脚本和 shellbar 一起，11-09 加了换组、键盘、高窗口三步，11-10 加了卡片一步）修复版 `SBBED_OK`。
- **还没有真手指验收**，清单在本文末「要作者在真机上做的」。

## 它做什么（大白话）

打开后：
- **舞台**：正在用的那一组窗口浮在右边，四角 20 的圆角，离左边 220、离上下右各留一点空（上 12、右 16、下 16）。一个窗口就占满舞台；两个窗口左右并排，中间留 12。
- **左边的卡片列**：最近用过的另外几组，最多 4 张卡，最新的在最上面。卡片是这组窗口的实时画面，按舞台的比例缩小，宽 172；两个窗口的组是两小张（83 + 6 + 83）。整张卡带透视，右边略矮（0.9），朝列的中间收，像一摞斜放的卡片。每个窗口画面的左下角压着它的应用图标，不写名字。
- **背景**（shellbar 的背景层，11-09 02:43 装上）：壁纸模糊后略压暗，铺在所有窗口下面；状态栏的黑底变透明，时间和图标直接浮在模糊壁纸上。

操作：

| 动作 | 结果 |
|---|---|
| 点卡片 | 舞台上那组飞回卡片列，点中的那组从卡片飞上舞台（500 ms，曲线是 vivo 的主曲线） |
| 按住卡片 | 卡片缩到 0.97（200 ms） |
| 把一张单窗口的卡拖上舞台 | 和舞台上的窗口并成一组。手指下面跟着一张卡，舞台上出现一张深色的「落点卡」，写着会发生什么（「X 放左边 / 右边」「换下 X」），会被挤走或换下的窗口压 40 % 黑。松手在左半放左边，在右半放右边；舞台上已经有两个窗口时，松手那一侧的窗口被换下来，单独成组进卡片列 |
| 把一张两窗口的卡拖上舞台 | 和点它一样，换组（落点卡写「换上这一组」） |
| 长按卡片 0.5 秒 | 卡片放大到 1.05，右边弹出深色菜单：两窗口组有「拆开」和「关闭」，单窗口组只有「关闭」。点别处收起 |
| 开一个新应用 | 新应用自成一组上台，旧组进卡片列 |
| 点舞台上某个窗口的最小化按钮 | 只有它下台，单独成一组；另一个占满舞台 |
| 底边快划回桌面、控制中心「显示桌面」 | 舞台清空，露出桌面，**卡片列滑出左边收起**；组不拆 |
| 在桌面上从 Dock、桌面图标、多任务卡片点开某组里的窗口 | 那一组整组回到舞台，卡片列滑回来 |
| 多任务卡片、Dock、通知、应用自己抢焦点，激活了卡片列里某组的窗口 | 切到那一组。刚换下去的那组在 1 秒内又抢焦点，不理它 |
| 关掉组里最后一个窗口 | 舞台空出来，露出桌面，卡片列收起 |
| 转竖屏 | 暂停：卡片列藏起来，舞台上的窗口最大化成整屏，圆角去掉；转回横屏恢复原来的布局 |
| 游戏、串流（Steam 游戏、gamescope、LIVI、Moonlight）、全屏窗口在前台 | 卡片列藏起来；这些窗口不缩放、不最小化、不进组，也不加圆角 |
| 屏幕键盘、控制中心、通知中心开着 | 卡片列藏起来（KWin 的内部窗口画在所有窗口上面，不藏就会盖住它们）；背景层留着 |
| 停靠的屏幕键盘弹起 / 收起（11-09） | 舞台按键盘上面剩下的高度重新摆；收起后回到原来的大小。应用最矮也高过剩下的高度（Telegram 689）时，窗口底边贴着键盘顶，往上伸到状态栏底下 |
| 换组（点卡、拖卡）的 0.5 秒里 | 底下的 Dock 不出来（11-09 以前会闪一下） |
| 把舞台上的窗口最大化，或者拖到盖住卡片列的位置 | 卡片列让开，最大化的窗口是方角；窗口退回来，卡片列和圆角再回来 |
| 关掉台前调度 | 舞台上的窗口回到打开前的大小和最大化状态，圆角去掉。别的组照旧最小化着，下次点开时也还原成打开前的样子 |

## 怎么开、怎么关

- **平时**：从顶边右半下拉控制中心。右栏第 6 行有三个磁贴：刷新率、性能浮层、**台前调度**。点一下打开，磁贴变蓝；再点一下关掉。帘子不会收起，因为这是开关，不是动作。
- **底下发生了什么**：
  - 磁贴跑 `kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active true|false`；
  - 然后调全局快捷键 `y700-stage-on` 或 `y700-stage-off`（`busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-stage-on`）。
- **跨重新登录**：脚本每次加载时读 `Active`。开着重登，登录后还是开着，但组不保存（见「有意不做」），所有窗口各自成组重新开始。
- **命令行**（user 的会话总线上）：同上两条命令。快捷键没有默认按键，KDE 设置里能看到「Y700: Stage Manager on / off」。
- **卸载**：root 跑 `sh /usr/local/src/y700-stage/install.sh --remove`。它卸掉脚本和圆角特效，删掉脚本目录、特效的 `.so`、apt 钩子、`/usr/local/share/y700-stage/`，删掉 kwinrc 里的四个键（`Plugins/y700-stageEnabled`、`Plugins/y700_stagecornersEnabled`、`BuildId`、`Active`）。磁贴留着，点了只写 `Active`，什么都不会发生。shellbar 的背景层不用卸：没人调 `setStage(true)` 它就不出来。

## 文件

| 文件 | 平板上 | 作用 |
|---|---|---|
| `linux/stage/y700-stage/metadata.json` | `~user/.local/share/kwin/scripts/y700-stage/` | 声明式 KWin 脚本包。Id `y700-stage`，`EnabledByDefault=false`，入口 `ui/main.qml` |
| `linux/stage/y700-stage/contents/ui/main.qml` | 同上 `contents/ui/` | 永远不变的入口：一个 `Loader`，按 kwinrc 的 `BuildId` 加载 `../build-<BuildId>/ui/Stage.qml`。没有 `BuildId` 时（ts-bed 直接拿仓库目录）加载同目录的 `Stage.qml`。为什么这样做见踩坑第 2 条 |
| `linux/stage/y700-stage/contents/ui/Stage.qml` | `contents/build-<id>/ui/` | 全部逻辑：组和账本、摆窗口、换组、并组、拆组、防抢回、卡片列的显示规则、飞行层和落点卡、长按菜单、开关快捷键；告诉 shellbar 开关背景层（`setStage`）、告诉圆角特效哪些窗口在台上（`setWindows`） |
| `linux/stage/y700-stage/contents/ui/Card.qml` | 同上 | 一张卡片：透视的画面（一个或左右两个，各自圆角 10），4 倍超采样去锯齿，左下角压应用图标；按下、长按放大、拖动时的缩放和透明；点按、长按、拖动交给 `Stage.qml`。画面是静止图（11-09 改：活缩略图只开 0.6 秒，拍完放掉，见「实现要点 · 卡片的画面是静止图」、踩坑第 24 条；11-10 加：卡里的窗口变了大小就重拍，踩坑第 27 条） |
| `linux/stage/kwin-corners/`（`CMakeLists.txt`、`metadata.json`、`main.cpp`、`stagecorners.h`、`stagecorners.cpp`） | 编成 `/usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_stagecorners.so` | KWin C++ 特效 `y700_stagecorners`：给脚本点名的窗口设 KWin 6.6 自带的 `Window::setBorderRadius(20)`。见「实现要点 · 圆角」 |
| `linux/stage/y700-stagecorners-rebuild` | `/usr/local/libexec/y700-stagecorners-rebuild`，apt 钩子 `/etc/apt/apt.conf.d/99y700-stagecorners` | 每次 apt/dpkg 跑完调一次：`kwin-wayland` 版本变了就重编特效（版本戳 `/usr/local/share/y700-stage/stagecorners.kwin-version`）。没变只花一次 `dpkg-query`。从不让 apt 失败，日志 `journalctl -t y700-stagecorners` |
| `linux/stage/install.sh` | 源码镜像 `/usr/local/src/y700-stage/`，root 跑 | 安装：先 `unloadScript`；有 `kwin-dev` 就编圆角特效（`ldd -r` 查出未解析符号就不装），装 `.so`、写版本戳和 kwinrc `y700_stagecornersEnabled=true`、装 apt 钩子；再拷脚本到 user 的脚本目录，每次新建 `contents/build-<时间戳>/`，写 kwinrc 的 `Plugins/y700-stageEnabled=true` 和 `BuildId`，`reconfigure`。然后等 `isScriptLoaded`，查日志里这个构建目录有没有 QML 报错，打印 `INSTALL_OK build <id>` 或 `INSTALL_FAIL`。**不动 `Active`**。没有 `kwin-dev` 时只装脚本（方角），**不替作者 apt install**。`--remove` 全撤 |
| `linux/stage/stage-power-ab.sh`、`stage-power-ab.py`（11-09 新） | 不装，测的时候拷到平板 | 真机开关对照：`.sh` 在作者的桌面会话里起两个测试窗口，开 1 分钟、关 1 分钟、再开 1 分钟，记电池功耗、CPU、动画测试应用的帧数和每个进程的 CPU，跑完全部还原；`.py` 在 Windows 或平板上出每段的汇总。见「测试」 |
| `linux/stage/design/y700-stage-mockup.html` | 不装 | 第二版的可交互设计稿（11-09，作者拍板的那份），用浏览器直接打开 |
| `linux/stage/RESEARCH.md`、`research/`（后者不随公开仓库发布） | 不装 | 调研和第一版设计稿（11-08） |
| `linux/stage/research/dnd-20261110/`（不随公开仓库发布） | 不装，跑测试时拷到平板 | 11-10 晚拖文件的排查：ts-bed 剧本（台前调度里拖到卡片上、并组后拖过去；探针和 Dolphin 连拖；普通桌面半屏贴边）、拖放测试窗口 `dropapp.py`、内部窗口拖放探针 `probe/`。一次性的排查工具，结论在「现状」和踩坑第 28 条；以后真做「拖到卡片上」时照它写正式剧本 |
| `linux/dock/y700-shellbar/qml/Backdrop.qml`（新）、`qml/Main.qml`、`qml/StatusBar.qml`、`src/main.cpp`、`src/shell.cpp`、`src/shell.h` | shellbar（背景层 11-09 02:43、`holdDock` 09:35 装上） | 背景层：全屏、层级 `LayerBottom`（壁纸之上、所有窗口之下）的模糊壁纸；`Shell.setStage(b)`（D-Bus `fyi.y700.Shellbar.setStage`）开关它，打开时读一次壁纸路径；开着时状态栏黑底透明。见「实现要点 · 背景层」。11-09 加 `Shell.holdDock(ms)`（D-Bus `fyi.y700.Shellbar.holdDock`，最多 3000）和 `Main.qml` 的 `heldUntil`：换组飞行时 Dock 不出来，见「实现要点 · 换组」 |
| `linux/gesture/tests/ts-bed.sh` | 不装，跑测试时拷到平板 | 无头测试 KWin（多任务卡片的测试台）。第一版加了 `TSBED_SCRIPTS`、`TSBED_KWINRC`、`shortcut 名字`；第二版加 `TSBED_PLUGINS=目录`：把一棵 Qt 插件树（特效的 `build/bin`）拷进测试台、经 `QT_PLUGIN_PATH` 先于系统插件找到，用来试还没装的特效。起不来时报 `effect not up within 20 s`。11-09 以前多半是 yuv709 垫片的死锁，那时的办法是重跑；修复版 11-09 已装，再出现就先查栈（踩坑第 17 条） |
| `linux/gesture/tests/ts-scenarios/stage.sh` | 同上 | 台前调度的 ts-bed 剧本，覆盖哪些见「测试」 |
| `linux/dock/tests/stageback.sh`（新） | 不装，跑测试时拷到平板 | 背景层的 sb-bed 剧本 |
| `linux/dock/tests/stagestrip.sh`（11-09 新） | `/usr/local/src/y700-dock/tests/` | 台前调度脚本和 shellbar 在同一个测试 KWin 里一起跑的 sb-bed 剧本（踩坑第 21 条之后写的，第 22、23 条之后加了换组、键盘、高窗口三步，第 27 条之后加了卡片一步）。`SB_STAGE=<y700-stage 目录>` 测候选脚本，不给就用装着的 |
| `linux/dock/tests/sb-bed.sh` | 同上 | dock 的测试台；11-09 放行 `SB_STAGE` 给 `stagestrip.sh`，并把 `kbzone.py` 拷进测试台 |
| `linux/dock/tests/kbzone.py`（11-09 新） | 同上 | 测试台里的「键盘占位条」：GTK4 层壳窗口贴底、高 H、`exclusive zone` = H，像停靠的屏幕键盘那样让工作区变小，进程被杀就撤。要 `LD_PRELOAD=libgtk4-layer-shell.so.0`。类名不是 `y700-osk`，台前调度不把它当挡板 |
| `linux/gesture/tests/ts-app.py` | `/usr/local/src/y700-gesture/tests/` | 测试应用（多任务卡片的）；11-09 加 `--min-height H`（最矮 H，像 Telegram 的 689），`stagestrip.sh` 的 tall 一步用；11-09 加 `--frames FILE`：每帧改一下字（像一直在动的网页），每秒把累计画了多少帧写进 FILE，`stage.sh` 的 still 一步用 |
| `linux/dock/tests/stagetile.sh` | `/usr/local/src/y700-dock/tests/` | 控制中心磁贴的 sb-bed 剧本（测试台里跑真的控制中心和装着的 y700-stage） |
| `linux/controlpanel/y700-control-center/qml/Main.qml`、`src/backend.cpp`、`qml/icons/stage.svg` | 控制中心 | 第一版加的「台前调度」磁贴，第二版没动 |
| `tools/y700-checklist.py`、`tools/y700-checklist-selftest.py` | `/usr/local/bin/y700-checklist` | 体检项「台前调度」（含圆角特效核对）和自测 S43a–p，见「体检」 |

## 实现要点

**为什么是 KWin 脚本**：要同时拿到窗口缩略图（`K.WindowThumbnail`）、能摆窗口（写 `frameGeometry`），还要能画常驻的卡片列。只有跑在 KWin 进程里的脚本三样都能做。它不是新的常驻进程（项目约定新的常驻进程用 Rust，这里不适用）。思路借了 HyprKwin 的 stage 布局，代码是自己写的，没拷它的（所以不带它的 GPL；包里写 MIT）。圆角是脚本做不到的（脚本碰不到窗口的渲染），所以另配一个很小的 C++ 特效。

**数字从哪来**：圆角、卡片尺寸、透视、曲线、时长都照设计稿，设计稿的数字是从 vivo Pad 6 Pro 的 OriginOS 6 ROM（原子工作台）里挖的，只抄名字和数字，没拷位图和代码；`originos-v6/` 里的东西不进仓库。

**状态**（都在 `Stage.qml` 根上）：
- `groups`：组的列表，最近用过的在前面，舞台上那组也在里面。每组 `{id, wins: [1 或 2 个窗口], focus}`，`focus` 是组里最后用的那个窗口。
- `staged`：舞台上那组。`null` 表示舞台空着、露出桌面，这时卡片列收起。
- `ledger`：账本，`internalId → {g: 进舞台前的几何, max: 是否最大化}`。打开台前调度时、新窗口被收进来时记一笔。关掉时按它还原。
- `later`：关掉时还最小化着的窗口。最小化的窗口写几何不生效（踩坑第 3 条），等它下次被点开再还原。
- `quiet`：脚本自己在最小化、摆放、激活窗口时大于 0。这时 `minimizedChanged`、`windowActivated` 不当成用户的动作。
- `rev`：每次变动加一，卡片绑定它刷新。卡片列表是一个 `ListModel`，就地 `move` / `insert` / `remove`，这样 `ListView` 的重排动画能动起来。

**收哪些窗口**（`manageable()`）：
- 收：普通窗口，能最小化、能缩放、能移动，不是 transient、modal、skipTaskbar、special，不是固定尺寸，不是全屏，在平板自己的屏（`DSI*`）上。
- 不收：受保护的（`guarded()`，和多任务卡片 `stack.js` 同一套：类名或 desktop 文件名命中 `steam_app_`、`steam_proton`、`gamescope`、`livi`、`dev.f-io.livi`、`moonlight`）。
- 对话框跟着主窗口走，因为它们根本不进组，就浮在上面。

**布局**（平板横屏逻辑 1600×1002，缩放 1.9；`Stage.qml` 顶上的常量）：
- 工作区用 `clientArea(MaximizeArea)` 算。11-08 在作者的桌面会话里读到的是 `0,28 1600×974.1`，状态栏占顶上 28。
- 舞台 `stageRect()` = 工作区 x + 220、y + 12，宽 − 236（左 220、右 16），高 − 28（上 12、下 16）。作者的屏上是 220,40 1364×946；测试床（没有状态栏，工作区整屏）是 220,12 1364×974。
- 两个窗口：各 `round((1364 − 12) / 2)` = 676，中间 12，右边那个从 x 908 起。
- 卡片列是一个 220 宽的内部窗口（`strip`），透明。卡片 x 32、宽 172，间距 16，最多 4 张，整列竖着以舞台中线（`midY()`）居中。
- 卡片的画面按舞台的比例：一个窗口 172 × (172 × 舞台高 / 舞台宽)；两个窗口每张 83 × (83 × 舞台高 / 676)，中间 6。作者的屏上单张约 119.3 高、两张约 116.2；测试床是 122.8 和 119.6。
- 透视（`trapezoid()` + `quadMatrix()`）：卡片的右边缩成左边的 0.9，朝列的中线收，中线上面的卡往下斜、下面的往上斜。用 `Matrix4x4` 的投影矩阵把整张卡映射到这个梯形。
- 每个画面圆角 10（`OpacityMask`，和多任务卡片 `StackCard.qml` 同一种写法），底色 `#111`：窗口比例和舞台不一样时露出黑边。11-10 起卡片列里的窗口也摆在槽位上（下面「卡片列里的窗口也摆进槽位」），平时看不到；还会露的情况见「有意不做」。
- 应用图标 30，带软阴影（向下 3、半径 6、35 % 黑），压在每个画面透视后的左下角，往外 5。
- 摆放时先 `setMaximize(false, false)` 再写 `frameGeometry`。
- **工作区变了就重摆**（11-09，`updateStrip()`）：停靠的屏幕键盘（`y700-osk`）是层壳窗口，带 `exclusive zone`（作者屏上 389 高），它一出来工作区从 `0,28 1600×974` 变成 `0,28 1600×585`，收起再变回来；屏幕本身没变，`screensChanged` 不来。KWin 自己会把没最大化的窗口压进变小的工作区，但收起后不还。所以每次算卡片列时比一下工作区（`sameRect()`），变了（开着、舞台有组、没在飞、没在等转屏重摆、不是竖屏）就 `place(staged)`，日志 `state area`（`Debug=true` 时）。舞台在作者屏上从 220,40 1364×946 变成 220,40 1364×557。
- **太高的窗口底边对齐**（11-09，`fit()`）：槽位比窗口的最矮高度（`minSize.height` 加上标题栏，`frameGeometry` 减 `clientGeometry`）还矮时，窗口照最矮高度摆，**底边对齐槽位底边**、往上伸。Telegram 最矮 689，键盘上面的槽位只有 557：以前顶边对齐，KWin 按最矮高度往下伸，输入框压在键盘底下；现在输入框贴着键盘顶，代价是窗口顶上伸出屏外：测试床里最矮 689 的测试应用带 36 高的标题栏，共 725，底边在 597，顶边就在 y −128，顶上 128 在屏外、再往下 28 在状态栏底下（见「有意不做」）。Telegram 要是自己画标题栏，伸出去的少 36。卡片列仍按舞台中线居中，键盘弹起时它本来就藏着。
- **卡片列里的窗口也摆进槽位**（11-10，`placeRest()`；为什么见踩坑第 27 条）：卡片的画面按舞台的比例画，所以卡里每个窗口都得是它那一组的槽位大小，不然卡上露底色。
  - 什么时候跑：`updateStrip()` 每次算完工作区都调一遍；卡片列里的窗口（最小化着的）几何一变，也马上再跑一遍（`hook()` 的 `geo` 里 `Qt.callLater(root.placeRest)`）。关着、竖屏、等转屏重摆（`relayout`）时不跑；正在飞行时等飞完（副本在空中照着窗口现在的样子画）。
  - 摆谁：不在舞台上的每一组里，最小化着、不是全屏的窗口。槽位照 `fit(w, slot(i, 这组几个窗口))` 算，和上舞台时一样（一对是左右各一半，太高的窗口底边对齐）。不在槽位上、或者还最大化着，就 `setMaximize(false, false)` 再写 `frameGeometry`，日志 `rest: <类名> #n <原来的几何>/<最大化状态> -> <槽位>`。
  - 最小化的窗口回话很晚：它只在收到帧回调时才按新大小画，而帧回调只在它那张卡拍照时才有。所以脚本记着问过谁（`asked[id]` = 槽位、问的时候窗口的样子、问了几次）：窗口还没变样就不重复问；变了样但还不是槽位就再问，同一个槽位、同一个工作区最多 3 次，不肯接受的应用保持它自己的大小，不会死循环。
  - **换了工作区，再告诉一次**（`stale`）：工作区一变（`askedArea`），账本清空；新工作区里第一遍完整跑的时候，对已经站在槽位上的窗口，先要一个矮 1 px 的矩形、紧接着再要槽位，日志 `rest: <类名> told again <槽位>`。这样 KWin 一定会再发一次 configure，而且带的是最后要的那个大小（槽位）。不做这一步，窗口手里可能还捏着一个过期的「压矮」configure，卡片列回来、它第一次画的时候先画成压矮的，卡片上闪一下黑边再变回来。只在每个新工作区做一次，平时窗口进卡片列不做（多一次 configure 没必要）。
  - 上了舞台的窗口（`place()`）从账本里删掉，下次回到卡片列重新算。关掉台前调度时照旧按几何账还原（账是打开时就给所有窗口记的），所以打开时就被摆进槽位的窗口，关掉后还是原来的大小和最大化状态。
  - 键盘弹起时，卡片列里的窗口也跟着摆进键盘上面的矮槽位（那时卡片列藏着，看不到），收起后摆回来。

**去锯齿**：透视的斜边直接画会有台阶。卡片的画面先画进一个 4 倍大的离屏层（`layer.textureSize` × 4、`layer.mipmap`、`layer.smooth`），再缩下来，斜边就平滑了（测试床截图放大 3 倍看过）。没用 `layer.samples`（MSAA），原因见踩坑第 17 条。

**卡片的画面是静止图**（11-09，`Card.qml`；为什么见踩坑第 24 条）：
- `K.WindowThumbnail` 只要还存在，KWin 就给它的窗口开离屏渲染：按屏幕刷新率（平板 120 Hz）给窗口发帧回调。跟缩略图看不看得见、窗口是不是最小化都无关。一直在动的应用收到回调就画下一帧。
- 所以每张卡只在「拍照」时有活缩略图。条件是 `shooting`：没拍过（`!shot`）、卡片列显示着（`stage.shown`）、卡片画着（`opacity > 0`，飞行时被副本顶替的卡是 0）。
- 拍照时：每个窗口一个 `Loader` 建缩略图，上面的 `ShaderEffectSource`（`hideSource`）跟着抄（`live: shooting`）。
- 拍完（`shotMs` = 600 ms 后 `shot = true`）：`ShaderEffectSource` 停住，留着最后一张。缩略图再留 100 ms（`linger`）才销毁，免得抄到它消失的那一帧。
- 为什么要卡片列显示着才拍：KWin 只在合成一帧屏幕时（`preFrameRender`）往缩略图里填画面。卡片列停在 x −32000、卡片透明（QML 不处理透明子树）时，抄到的是空的。
- 重拍：卡里的窗口变了（`wins`），或卡片变高变矮（停靠键盘占了工作区，舞台变矮，卡片跟着变），或卡里某个窗口变了大小（11-10，`sizes`：各窗口宽高拼成的字符串）。都等卡片列下次显示时拍，不拿旧图拉伸。
- 拍照至少拍到最后一次变大小之后半秒（11-10，`sizedAt`）：最小化的窗口要等这张卡的活缩略图带来帧回调，才按 `placeRest()` 要的大小画，所以对的大小往往出现在拍照中途、甚至刚拍完。定时器每 600 ms 响一次，离最后一次变大小不足 500 ms 就再等一拍，保证抄下来的最后一帧是定下来的那个大小。不会变成一直拍：窗口不再变大小，下一拍就结束；`placeRest()` 对同一个槽位最多问 3 次。
- 每次拍照都新建缩略图，不复用：放掉过窗口的缩略图，节点还指着 KWin 已经删掉的纹理。
- 飞行的副本和拖动的卡（`Stage.qml`）还是活缩略图，只在飞行（约 0.5 秒）和拖动时存在。
- 超采样层内容不变就不重画；画面静止后，它只在重排、按下缩放时重画。

**动效**（时长都乘 `k`，见下一段；曲线是 vivo 的三次贝塞尔，常量在 `Stage.qml` 顶上）：

| 什么 | 时长 | 曲线 |
|---|---|---|
| 点卡飞行（舞台 ↔ 卡片，`flyAnim`） | 500 ms | 主曲线 `cMain` [0.45, 0.85, 0.28, 1] |
| 卡片列滑出 / 滑回（桌面时收起） | 300 ms | `cMain` |
| 按下缩到 0.97 | 200 ms | `cDown` [0.25, 0.45, 0.30, 1] |
| 被拖走的卡缩到 0.973、透明 0.4 | 300 ms | `cDrag` [0.4, 0, 0.6, 1] |
| 松手回 1、长按放大到 1.05 | 250 ms | `cUp` [0.25, 0.45, 0.35, 1] |
| 卡片重排、整列重新居中 | 350 ms | `cReord` [0.25, 0.1, 0.25, 1] |
| 关掉的组的卡缩小淡出 | 400 ms | `cStd` [0.33, 0, 0.67, 1] |
| 落点卡、被挤走窗口的 40 % 黑 | 250 ms | `cDim` [0.28, 0.4, 0.2, 1] |
| 菜单弹出：从左上角 0.3 → 1.02 → 1，同时淡入 | 250 + 150 ms | `cMenuIn` [0.37, 0.75, 0.46, 1]，回弹 `cStd` |
| 菜单收起：缩到 0.3 并淡出 | 200 ms | `cMenuOut` [0.3, 0, 0.5, 1] |
| 背景层淡入淡出（shellbar） | 300 ms | `cStd` |

**动画速度跟系统走**：
- 所有时长都乘 `k`，`k = Kirigami.Units.longDuration / 200`。KDE 设置里调动画速度，这里跟着变。
- 减弱动画（`longDuration` 为 0）时点卡直接换组，不飞。
- `DebugSpeed`（kwinrc `[Script-y700-stage]`）只给测试床用：测试床没有 KDE 的平台主题，Kirigami 读不到系统设置，就用它固定一个倍数。剧本用 10 倍慢速拍飞行中间那一帧。

**换组**（`switchTo()`、`swap()`）：
- 顺序是：新组的窗口先取消最小化、摆好、激活，再把旧组最小化。焦点从旧窗口直接到新窗口，中间不会漏到桌面或第三个窗口。
- 点卡时有飞行动画（`tapCard()` → `flyHold` → `flyAnim` → `land()`）：
  - 全屏透明的「覆盖窗」（`fly`，点击穿过它落到卡片列和舞台上：靠的是 `outputOnly` 属性，不是 `Qt.WindowTransparentForInput`，见踩坑第 26 条）里放带圆角和阴影的缩略图副本：舞台上的窗口从原位飞到卡片列最上面那张卡的位置，点中的卡从卡位飞到舞台，圆角从 10 过渡到 20。
  - 覆盖窗先画出第一帧，50 ms 后（`flyHold`）旧组才最小化，所以画面上不会闪一下桌面。
  - 旧组最小化、新组要到落地才取消最小化，中间约 0.5 秒没有一个窗口露着，shellbar 会当成回到了桌面、把 Dock 升上来（11-09 踩坑第 22 条）。所以飞行一开始（有窗口要收的时候）先经 D-Bus 调 `fyi.y700.Shellbar.holdDock(holdMs)`，`holdMs` = 50 + 500 × `k` + 400（平时 950 ms）。参数必须是 `int` 属性，见踩坑第 22 条。shellbar 旧版没有这个方法时调用静默失败，照旧闪。
  - 飞完 `land()` 才真正换组。覆盖窗在真窗口画出一帧后（`flyPark`，60 ms）才撤。
  - **飞行可以打断**（11-10，踩坑第 26 条）：飞行中途再点卡、开始拖卡、松手放卡、新开窗口、别处激活了窗口，都走 `retake(fn)`：
    - 先 `interrupt()`：记下每个副本此刻的位置（`lerpRect(from, to, fly.p)`，存进 `carry`），停掉计时器，把这次飞行落地时要做的事（`flyApply`，换组本身）立刻做掉。`flying` 保持为真，覆盖窗不撤。
    - 再做新操作（`fn`）。它的 `flight()` 看到 `carry`：已经在空中的副本从当前位置起飞，不跳回起点也不先跳到终点。拖卡松手的那张例外（`copies()` 的 `keep`），从手指下起飞。
    - 新操作没带上的副本（比如连点时被挤到第二张卡的那组）飞到它那组在新顺序里的卡位（舞台那组飞回舞台的槽位，`o.stay`），日志 `flight taken on mid-way: N copies, M carried on`。被挤出卡片列（第 5 组以后）的组，副本直接不画。
    - `interrupt()` 里换组会把新组的窗口取消最小化，可它们的副本还在空中，所以同一个 JS 回合里马上再收起来（`early`），屏幕上不会有一帧露出真窗口。真窗口要等新的这次飞行落地才出来。
    - 这一回合要收的窗口里，有在打断前就真露着的（不只是 `early` 那种），照常等 `flyHold` 的 50 ms 让副本先画一帧；这 50 ms 里空中的副本停着不动。全是 `early` 就直接 `flyAnim.restart()`，不停。
    - 新操作什么都没飞（开始拖卡：拖动本身不飞；点的那张卡已经不在了；抢回被拒），`retake` 补一次「接着飞」：副本飞到各组现在的位置，落地时舞台那组的窗口要是还收着就 `switchTo(st, "landed")` 放出来。
- 点中的卡在飞行时透明（`flyHidden`，副本替它画）。

**拖卡并组**（`dragStart()` / `dragMove()` / `dragEnd()`、`aimAt()`）：
- 手指移动超过 16 px 才算拖动（`DragHandler.dragThreshold`）。
- 拖动时覆盖窗里有一张跟着手指的卡（`ghostCopy`）。舞台上的落点卡：深色（`rgba(34,36,42,0.86)`、1 px 白 14 % 边、阴影 30/10/30 %、圆角 20），中间是 50 的应用图标和一行字：舞台空着「打开 X」、拖的是一对「换上这一组」、舞台一个窗口「X 放左边/右边」、舞台已有一对「换下 X」。会被挤走或换下的窗口压 40 % 黑。名字取窗口标题「文档 - 应用」最后一段（`appName()`，和多任务卡片一样），只画在屏幕上，不进日志。
- 松手在卡片列里就什么都不做；落点卡淡出（`dropFade`，300 ms）后覆盖窗才撤。

**长按菜单**：深色 `#282828`，圆角 18，阴影 39 %；在卡片右边 10、和卡片顶对齐；每行 48 高、从顶上 6 开始，按下的高亮是白 15 %、圆角 12、左右各缩 6；「拆开」和「关闭」之间一条 4 px 的白 5 % 分隔。字和图标白 90 %。菜单开着时那张卡放大到 1.05。

**圆角**（`kwin-corners/`，特效 `y700_stagecorners`）：
- KWin 6.6 的 `Window` 有公开的 `setBorderRadius()`，场景里的窗口容器按它裁剪表面和装饰（阴影是兄弟节点，不裁）。所以圆角不写着色器。台前调度单用时特效不挂绘制回调，`isActive()` 是 false，不进绘制链；只有分屏的底色开着时为真（见下面「分屏那部分」）。
- 脚本每次布局变了调 `corners()`：经 D-Bus `org.y700.StageCorners.setWindows(s)`（`org.kde.KWin` 上的 `/org/y700/StageCorners`）把台上窗口的 `internalId` 用空格连起来发过去；关着、竖屏、舞台空着时发空串。特效只在集合变了时记一行日志 `y700-stagecorners: N window(s) rounded`。
- **分屏那部分**（11-10，`linux/split`，脚本 `y700-split`；**编过、测试床过，没装**，正在跑的还是旧特效）：同一个特效多了三个方法。
  - `setSplitWindows(s)`：分屏的两个窗口，格式同 `setWindows`，圆角 10。同时在两张单上的窗口用台前调度的 20。
  - `setSplitChrome(s)`：工作区 `"x y w h"`，空串 = 关。特效在两个分屏窗口里叠在下面那个的位置画 #242424，它下面的窗口在这块里不画，6 px 缝和圆角处露出底色；叠在上面的 Dock、横幅、菜单照常盖在上面。开着时分屏窗口不画阴影；最下面那个按「有变换」画，否则 `WorkspaceScene::paintSimpleScreen`（6.6）会把它的绘制区裁到它自己的范围。只有这时 `isActive()` 为真。
  - `touchPoint()`：手指按着时回 `"x y"`，没按着时回空串。KWin 只告诉脚本窗口在哪，`Workspace.cursorPos` 是指针的，触摸不动它（ts-bed 11-10）；分屏拖标题栏期间每 8 ms 问一次。
  - 换上新特效后台前调度的 ts-bed `stage.sh` 照样 `TSBED_OK`。详情见 `linux/split/README.md`「实现要点 · 圆角特效」。
- 台前调度开着时，卡片列内部窗口的标题是 `y700-stage strip on`，关着是 `y700-stage strip`（11-10 为分屏加的，`Stage.qml`）。分屏脚本和多任务卡片的 ▾ 看它让开：台前调度的一组两个本来就是并排的。
- 最大化（整屏）和全屏的窗口保持 KWin 自己的半径（方角），看 `maximizedChanged` / `fullScreenChanged`。
- KWin 自己的半径（装饰给的，客户端装饰的窗口是空的）每个窗口记一份，离台、清空、特效卸载时还回去。`updateDecorationBorderRadius()` 是 protected 的，特效调不了，所以握着窗口期间 KWin 改的半径（装饰换了）都记成「它自己的」，再把 20 放回去（`m_setting` 区分是不是自己设的）。
- 脚本 `start()` 时调一次 `loadEffect("y700_stagecorners")`：kwinrc 里虽然开着，但 KWin 运行中 `reconfigure` 不会加载新装的特效（11-09 实测），登录时才按 kwinrc 加载。
- 特效插件的 IID 里带 KWin 的版本号，KWin 一升级旧的 `.so` 就加载不了（不会崩，只是不加载），所以要重编：apt 钩子自动做，新的下次登录生效。`install.sh` 和钩子都先 `LD_BIND_NOW=1 ldd -r` 查未解析符号，有就不装（插件是懒绑定的，未解析的符号第一次被调到时会把整个 kwin_wayland 带崩）。

**背景层**（shellbar，`qml/Backdrop.qml`；11-09 02:43 装上）：
- 为什么在 shellbar 里：脚本的内部窗口画在所有窗口上面，没法垫在舞台窗口下面；KWin 的模糊（blur-behind）也不跟 QML 的透明度一起淡入淡出。shellbar 本来就是层壳（layer-shell）客户端，加一个 `LayerBottom` 全屏层最省事。
- 脚本在卡片列显示时（或只是被键盘、控制中心挡着时）调 `fyi.y700.Shellbar.setStage(true)`，其余时候 `false`（`tellShell()`，只在变了时发）。shellbar 没在跑、或是旧版没有这个方法时，这个调用静默失败，什么都不发生。
- `setStage(true)` 时读一次壁纸：在 `~/.config/plasma-org.kde.plasma.desktop-appletsrc` 里找第一个以 `[Wallpaper][org.kde.image][General]` 结尾、带 `Image=` 的段；`file:` 地址转本地路径（中文文件名照样认，作者的就是）；是目录就当壁纸包，取 `contents/images` 里最大的那个文件。找不到就用兜底的深蓝灰 `#2a3346`，日志 `stage on (no wallpaper found)`。
- 画法：图片按设备像素的 1/4 解码，高斯模糊（deviation 10、半径 24、49 个采样，`cached`，只算一次），再放大 4 × 1.1 倍（多出的 1.1 把模糊的暗边推到屏外），上面压 `30/255` 的黑。淡入淡出 300 ms，淡完才把窗口藏掉。
- 它接收触摸（点卡片列的空白处不会点到桌面图标），从不接键盘。
- 开着时状态栏的黑底透明（和在桌面上一样），字和图标留着。

**卡片列什么时候藏**（`updateStrip()`，有事件才算，100 ms 防抖，不轮询），按顺序：
1. 关着；
2. 竖屏；
3. 舞台空着（桌面）——第二版新加，滑出左边；
4. 活动窗口是全屏或受保护的；
5. 舞台上的窗口盖进了卡片列（摆放后 1 秒内不算，因为几何是异步落地的）；
6. 有「挡路的」窗口：输入法、`y700-osk`、`y700-control-center`、高过 200 的 `y700-shellbar`（就是通知中心）。

每次显隐日志记一行 `strip shown` 或 `strip hidden (原因)`。第 6 种藏的时候背景层留着（键盘、帘子本来就盖在上面）。

**最小化的三种来源**（`onMinimized()`、`settle()`、`regroup()`）。舞台上某个窗口被最小化、又不是脚本自己做的，要分清是谁做的：
1. **用户点了那个窗口的最小化按钮**：它是当前活动窗口。KWin 先把焦点交出去，再发 `minimizedChanged`，所以要看「当前活动的」或者「50 ms 内刚才活动的」是不是它（`curActive` / `prevActive`）。是的话起 300 ms 计时（`burst`）：
   - 300 ms 后整组都最小化了，算回桌面或显示桌面，舞台清空，组不拆；
   - 只下去一部分，下去的单独成组，剩下的占满舞台。
   - 这个计时器只在最小化事件来的时候才起，平时不醒。
2. **多任务卡片选中一个应用**：它的 `finishOpen` 会把别的窗口都最小化，包括舞台上的另一个。这时被最小化的窗口不是活动窗口，`regroup()` 把它放回来，一对还在。
3. **`minimizeAll`**（回桌面手势、显示桌面）：先收别的，最后收活动窗口。所以先来的那个看起来像第 2 种，`regroup()` 里一看整组都下去了，就当成舞台清空。

**防抢回**：换组后 1 秒内，刚下台的那组又激活了（有的应用被最小化时会自己抢回焦点），就把它再最小化回去，焦点还给舞台，日志记一行 `grab-back refused (<类名>)`。

**应用自己恢复最大化**：有的应用被摆好后，会按它自己记的状态再最大化一次。摆放后 2 秒内来的最大化，就再摆一次，每个窗口只补一次（`refitted`）。2 秒以后的最大化算用户自己点的，卡片列让开（`covered`）。

**内部窗口**：卡片列、覆盖窗、菜单是三个 QML `Window`（KWin 的内部窗口）。
- 都是无边框、不抢焦点、`BypassWindowManagerHint`，底色透明。
- 不用时不隐藏，而是停在 x = -32000。这样没有 KWin 的开窗、关窗动画，也不用每次重新映射。卡片列滑出去的动画在窗口里面做（`column.x`），滑完才停到屏外。
- 显示的先后决定叠放：卡片列最下，覆盖窗在它上面，菜单最上（踩坑第 11 条）。

**日志**（`journalctl --user -b | grep -E 'y700-stage|stagecorners'`）：
- 平时只记这几种：`loaded, on|off`、`on, N windows`、`off, restored N, M when shown`、`strip shown|hidden (…)`、`grab-back refused (类名)`；特效 `y700-stagecorners: N window(s) rounded`；shellbar `stage on|off`。**不记窗口标题**，标题可能有隐私。
- `Debug=true`（kwinrc `[Script-y700-stage]`，只在测试床里开）时，每次变动多一行 `state <动作> staged=<标题> strip=<标题,…>`。剧本就靠这一行判断状态。**真会话别开**，标题会进日志。

**功耗**：
- 没有周期定时器。所有计时器都是事件来了才起的单次计时器（300 ms、100 ms、1.1 s、50/60 ms，卡片拍照的 600 ms 和 100 ms）。
- 关着时，每个窗口事件进来就返回。
- 开着时，卡片是静止图，不再催收起的窗口出帧。只有拍照那 0.6 秒、飞行和拖动时，相关的窗口按屏幕刷新率画。
- 超采样层内容不变就不重画。圆角特效不进绘制链；背景层的模糊只算一次（`cached`）。
- 11-09 以前这里写的是「卡片列里都是最小化的窗口，它们不出新帧，缩略图就是静止的」。这是错的：活缩略图让它们一直以 120 Hz 画，见踩坑第 24 条。
- 改成静止图后的真机功耗还没量，见「没验证的」。

## 踩坑（根因）

1. **`Window` 写在 `Item` 里永远不显示**：QML 会自动给它设 `transientParent`（父项所在的窗口）。KWin 脚本的根不是窗口，这个父窗口不存在，窗口就一直不映射。三个 `Window` 都写死 `transientParent: null`。
2. **改了 QML，KWin 还在跑旧代码**：KWin 按 URL 缓存脚本的 QML，整个进程活着就一直用缓存。原地换文件要重新登录才生效（小样里实测：原地改了再 reload，还是旧版）。所以入口 `main.qml` 永远不变，只是一个 `Loader`；`install.sh` 每次把正文放进新的 `build-<时间戳>/`，URL 是新的，`unloadScript` + `reconfigure` 就加载新版，不用重登。旧的 build 目录 `install.sh` 每次整个重建时删掉。（特效不一样：装了新的 `.so`，正在跑的 KWin 还映射着旧的，要重新登录，体检「KWin 用的库」会提示。）
3. **最小化的窗口写几何不生效**：KWin 不给最小化的窗口套几何。所以换组时一定先取消最小化，再摆放。关掉台前调度时，还最小化着的窗口记进 `later`，等它被点开那一刻再还原。（11-10 补充，见第 27 条：准确地说是「不马上生效」。KWin 会把请求记下并发 configure，但窗口要等下一次帧回调才按新大小画，最小化的窗口平时没有帧回调。换组和关掉时的做法不用改。）
4. **内部窗口画在所有窗口上面，全屏应用也一样**：所以卡片列有一套「什么时候藏」的规则，游戏、全屏、键盘、控制中心、通知中心都要它让开。也因为这个，背景层没法用内部窗口做，放在 shellbar 里。
5. **多任务卡片把我们的卡片列算成一个应用**：它的模型收所有窗口。脚本在 `windowAdded` 里认出自己的窗口（标题以 `y700-stage ` 开头、没有 `resourceClass`），给它设 `skipSwitcher`、`skipTaskbar`、`skipPager`。
6. **用户点最小化时，焦点已经先交出去了**：KWin 先把焦点给下一个窗口，再发 `minimizedChanged`。这时 `activeWindow` 已经不是被最小化的那个，单看它会把「用户自己最小化」错当成「被别人最小化」。所以一直跟着记最近两个活动窗口和时间。
7. **多任务卡片的 `finishOpen` 会拆散一对**：它「只让选中的应用回来」，把别的都最小化，舞台上的另一半也被收了。脚本把这种情况认出来放回去（实现要点「最小化的三种来源」第 2 种）。剧本 `switcher` 一步测的就是它。
8. **`maximizedChanged` 是异步的**：状态要等客户端回话才变。脚本自己调的 `setMaximize` 晚一点也会到这里，这时 `quiet` 早就归零了。所以「是不是用户点的」只能按时间判断（摆放后 2 秒内），竖屏时一律不管（那时只可能是脚本自己最大化的）。
9. **卸载后重新加载再打开，KWin 崩了**（ts-bed 11-08）：`workspace.stackingOrder` 里还留着已经关掉、正在播关闭动画的窗口；重载之后，里面也包括上一个实例已经销毁的内部窗口，读它的 `minSize` 就是空指针。`start()` 只取同时在 `workspace.windows` 里的、活着的窗口。
10. **卸载后，每次最小化都报 `TypeError … of null`**（ts-bed 11-08）：`w.minimizedChanged.connect(箭头函数)` 挂在窗口上的连接，比脚本自己的对象活得久，卸载后还往已经销毁的根对象里调。现在每个连接的函数都存进 `hooked`，`Component.onDestruction` 里逐个 `disconnect`。
11. **卡片列盖在覆盖窗上面，飞行的缩略图被挡住一半**（ts-bed 11-08）：QML 完成对象的顺序是从后往前，KWin 按显示的先后叠放内部窗口。三个窗口都是 `visible: false`，`Component.onCompleted` 里用 `Qt.callLater` 按卡片列、覆盖窗、菜单的顺序显示。
12. **小样里有一张缩略图一直是空的**：先建一个空的 `WindowThumbnail`、过后再填 `wId`，没最小化的窗口那张一直是空的（最小化的反而有画面）。根因没深究。正式代码里卡片、飞行层、拖动的卡都在创建时就给 `wId`，测试床截图里都有画面。
13. **KWin 的最小化特效（squash）不会和飞行动画叠在一起**：特效是加载着的，但它要窗口的「图标位置」，平板上所有窗口的 `iconGeometry` 都是 0×0（11-08 在作者的桌面会话里读的），所以它不播。以后哪天有任务栏开始发布图标位置，squash 就会叠上来，要重新看。
14. **sb-bed 判断磁贴「亮没亮」**：一开始按「蓝不蓝」判断，结果关着的磁贴也读成蓝的。测试应用本身是蓝色的，关着的磁贴是白色 12 % 叠在它的模糊上。改成量「离强调色 `#2e6bf6` 多远」：亮着 0，关着 34。
15. **（操作）ssh 带 `< /dev/null` 又从管道喂 tar**：`< /dev/null` 把管道的 stdin 顶掉了，远端 tar 报「不像是一个 tar 归档文件」。往远端灌 tar 时不加这个重定向。
16. **`id: gc` 让整个 Stage.qml 加载失败**（ts-bed 11-09）：`ID illegally masks global JavaScript property`——`gc` 是 JS 的全局函数 `gc()`。拖动的卡改名 `ghostCopy`。QML 的 id 别用 `gc`、`print`、`console` 这类全局名。
17. **测试 KWin 启动时偶尔卡死，起初错怪了 `layer.samples`**（ts-bed 11-09，约 3 次里 1 次）：卡片先试的是 MSAA（`layer.samples`），赶上测试 KWin 起不来（`effect not up within 20 s`），就以为是它，改成超采样。后来再卡死时 gdb 看了栈：是 `/etc/ld.so.preload` 里的 yuv709 垫片（`/usr/local/lib/y700-yuv709.so`，源码 `linux/video/yuv709-shim.c`）在第一次导入 dmabuf 时，在 `dl_iterate_phdr` 的回调（`find_gallium`）里调 `dlopen(RTLD_NOLOAD)` / `dlsym`。`dl_iterate_phdr` 握着加载器的锁，另一个线程（这里是加载 QML 插件的 QQmlThread）正在 `dlopen`，两边互等（ABBA 死锁）。只在 KWin 刚启动、第一次导入 dmabuf 那一刻可能撞上；正在跑的 KWin 已经过了那一刻，所以真会话里只有登录时可能中招。测试床的对策是重跑。**已修（11-09，视频部分）**：`yuv709-shim.c` 的回调里只抄路径，等 `dl_iterate_phdr` 返回再 `dlopen` / `dlsym`。回归测试是 `linux/video/test-yuv709-loader-lock.sh`，旧版 30 次全卡死，新版 200 次全过；拿候选版跑这里的台前调度剧本 12 次，12 次全是 `TSBED_OK`，一次都没卡（详见开发日志（未公开）「视频硬解」里「11-09 修：加载器死锁」）。**11-09 03:03 已装到平板**（作者说「装吧」，`INSTALL_OK 01e4e354526683b6`）。ts-bed 每次都起一个新的测试 KWin，从此用的直接就是新版；作者的桌面会话里正在跑的 KWin 要到下次登录才换。以后再卡在 `effect not up within 20 s`，先用 gdb 看栈再说，别当成这条直接重跑。MSAA 本身没再试过。
18. **慢速剧本点卡点空**（ts-bed 11-09）：`DebugSpeed 10` 下，重新加载后卡片列滑进来要 3 秒（300 ms × 10），先点就点在还没到位的卡上。剧本里先等 3.5 秒再点。
19. **ts-bed 里特效找不到**：测试台用 `env -i` 起，`QT_PLUGIN_PATH` 是空的，只认系统插件目录，没装的特效加载不了。加了 `TSBED_PLUGINS`（见「文件」）。测试台里不用写 kwinrc：脚本 `start()` 自己 `loadEffect`。
20. **平板上的 shellbar 源码和 git 分叉了**（11-09 装之前比 hash 发现）：`/usr/local/src/y700-shellbar/` 里 `install.sh`、`qml/Banners.qml`、`qml/StatusBar.qml`、`src/shell.cpp`、`src/shell.h`、`src/status.cpp`、`src/status.h` 和 git 的任何一版都对不上，另外多了 `y700-dnd-toggle.desktop` 和 `kbd-dnd-mouse-20261104.patch`。是平板侧 Claude 11-03/11-04 直接在平板上改的（勿扰月牙、fn+F6 勿扰、妙控键盘/鼠标电量；补丁名里的 dnd 是 do not disturb，即勿扰，早先这里误写成「拖放」），装着的二进制是 11-04 21:10 用它编的；反过来它又缺 git 里 10-31 的修复（`44b085d` 审计 D2 那版 `shell.cpp`，它是照二进制重写的另一版）。**教训：装任何东西前先比镜像和上一次提交的 hash**，对不上就停。**已解决（11-09）**：逐文件找到补丁的底（除 `shell.{h,cpp}` 外都是 `3850ac5`），三方合并进 git（`ea3c7ce`，`shell.cpp` 用 git 的 D2 修复），测试床跑过横幅、勿扰、背景层后装上，见「部署记录」和开发日志（未公开）「Dock 与状态栏」开头 11-09 那条。
21. **背景层一出来，卡片列就被藏起来**（11-09 02:51 作者真机截图，背景层装上 8 分钟后）：截图里舞台窗口、模糊壁纸、透明状态栏都对，左边卡片列没了。日志每次 `strip shown` 后紧跟 `strip hidden (blocker)`。根因：`blocker()` 把 `y700-shellbar` 高于 200 px 的窗口都算挡板（第一版为「盖在应用上面的大窗口」写的，注释写的是通知页，其实通知中心是控制中心的窗口；shellbar 里真盖在上面的大窗口是全部应用页），全屏的背景层也中了：它一出来卡片列就藏，藏了背景层照样开着（挡板时背景层不撤），所以停在「有模糊、没卡片」。修法（`e0e9a07`）：shellbar 的大窗口只有在叠放顺序里压在舞台窗口上面才算（`overStage()`；KWin 按层叠放，背景层在 Bottom 层，在所有应用下面，全部应用页在 Top 层，在上面；`stagestrip.sh` 实测从下往上是 背景层 2、两个应用 3 和 4、状态栏 5）。**为什么测试床没抓到**：ts-bed 的 `stage.sh` 里没有 shellbar，sb-bed 的 `stageback.sh` 里没有台前调度脚本、是剧本手动 `setStage`，两边各测一半。**教训：两个程序之间新加了联动，要有一个剧本让它们在同一个测试 KWin 里一起跑**，于是写了 `stagestrip.sh`：拿装着的旧脚本跑它 FAIL（复现了），修复版 `SBBED_OK`。
22. **换组时 Dock 闪一下**（11-09 03:1x 作者报）：shellbar 的 `Main.qml` 用任务模型数「露着的窗口」，0 个就是 `onDesktop`，Dock 升上来。台前调度换组时，旧组在飞行开头 50 ms（`flyHold`）就最小化了，新组要到 500 ms 后落地（`land()` → `switchTo()` / `merge()`）才取消最小化，中间整整半秒一个窗口都没露着，Dock 就升上来又收回去（测试床里量到 Dock 窗口映射了 744 ms）。修法（`44af433`）：shellbar 加 D-Bus 方法 `holdDock(ms)`，台前调度在飞行开头调；这段时间里「0 个窗口露着」不改 `onDesktop`，有窗口露着照常算，到点（`heldTimer`）再算一次。**故意不提前解除**：落地时再发一个 D-Bus「解除」，可能比 Wayland 那边的取消最小化先到，又闪一下；等到点更稳。另一个坑：**KWin 脚本 `DBusCall` 的参数直接给 JS 数字，发出去是 `double`（D-Bus 签名 `d`）**，`holdDock(int)` 根本匹配不上，shellbar 日志里没有 `hold dock`，Dock 照闪；参数改成 QML 的 `readonly property int holdMs` 才是 `int`。**教训**：脚本往 C++ 服务发 D-Bus，参数要用带类型的 QML 属性，测试里要看对面真的收到（日志里有 `hold dock 950 ms`）。
23. **键盘收起后窗口停在半屏高；Telegram 被顶起来但下半截还在键盘底下**（11-09 03:1x 作者报，Chrome、Claude、Telegram）：停靠的屏幕键盘有 `exclusive zone`（389 高），工作区从 974 高变成 585 高，KWin 自己把没最大化的舞台窗口压进剩下的地方（贴着工作区，不留舞台的上下空），收起后不还；脚本以前只在 `screensChanged` / `virtualScreenGeometryChanged`（屏幕变了）时重摆，键盘进出屏幕没变，所以窗口一直停在 585 高。Telegram 最矮 689，比键盘上面的地方还高，KWin 只能让它往下伸进键盘底下，正好压住输入框。修法（`44af433`）：工作区一变就重摆（实现要点「布局」），太高的窗口底边对齐（`fit()`）。测试床里没有真键盘，用 `kbzone.py` 占一条同样高的底边。旧脚本复现了全部：键盘弹起时 Kate 是 `220,28+1364x585`（不是槽位 `220,40+1364x557`），收起后 `220,417+1364x585`（没回到 `220,40+1364x946`，还往下挪了）；最矮 689 的 Tall 是 `220,28+1364x725`，底边 753，伸进键盘 140；收起后也还是 725 高。
24. **开着台前调度时，卡片列里的应用都在后台画，平板 6–8 W**（11-09 上午作者报，CPU 合计 25–27 %，收起的 Chrome、wiliwili 照样吃 CPU）。
    - 根因：卡片用的是活的 `K.WindowThumbnail`。查了 KWin 6.6 源码：`WindowThumbnailSource` 构造时调 `refOffscreenRendering()`，析构时才放掉；`Window::refOffscreenRendering` 起一个定时器，按 1'000'000 / 刷新率 微秒给看不见的窗口发帧回调。
    - 所以只要缩略图存在，它的窗口就按屏幕刷新率（平板 120 Hz）收到帧回调，跟看不看得见、是不是最小化都无关。一直在动的应用（网页、视频、动画）收到回调就画下一帧，于是收起的应用都在后台以 120 Hz 画。
    - 以前「功耗」一段写的「最小化的窗口不出新帧，缩略图就是静止的」是想当然，没查源码也没量。
    - 修法：卡片只拍一张静止图（实现要点「卡片的画面是静止图」）。
    - 测试床复现：Blue 换成 `ts-app.py --frames`，每帧改字。GTK 在 Wayland 上每次提交后，要等到帧回调才画下一帧。Blue 收进卡片后数 3 秒：装着的旧版 180 帧（测试台 60 Hz，一个回调一帧），新版 0 帧。
    - 第一版只在卡里的窗口变了时重拍，`stagestrip.sh` 的 `k4-kbd` 里 Blue 的卡被压扁：键盘让卡片变矮，静止图被拉伸。加了「卡片变高变矮就重拍」。
    - 真机（11-09 11:05–11:08，`stage-power-ab.sh`）：开着 1.30 W、关着 1.45 W，一样；收进卡片的动画测试应用 3 分钟 0 帧，KWin 0.03 %、wiliwili 约 0 %（一个核）。
    - **教训**：KWin 的缩略图不是截图，存在多久，它的窗口就被催着画多久。以后用 `WindowThumbnail` 先问它活多久。多任务卡片的缩略图只在卡片视图开着时存在，关掉就销毁，不受影响。
    - KWin 没有接口能查哪些窗口在离屏渲染，体检查不了，回归靠 `stage.sh` 的 still 一步。
25. **（操作）装完复查时测试床 FAIL，still 一步又是 180 帧**（11-09 10:38）：复查是在平板镜像 `/usr/local/src/y700-gesture/tests/` 里跑的 `ts-bed.sh`。那份是多任务卡片部分早先放进去的旧版（`9d866b0c1d60`），没有 `TSBED_SCRIPTS`，台前调度脚本根本没加载进测试台。Blue 一直开着，没收进卡片，当然在画。拿仓库版（`9a75e43dfd01`）跑同一份装着的脚本：`TSBED_OK`，0 帧。**教训**：测试台的 FAIL 先看被测的东西加载了没有（日志里有没有 `y700-stage: loaded`），再怀疑代码。ts-bed 一律用仓库里的那份。镜像里那份属于多任务卡片，这里没动它。
26. **连点卡片只有第一下管用，要等动画播完才能再切**（11-10 作者报，原话见「现状」）：
    - 根因一：飞行时全屏的覆盖窗（`fly`）把点击全吃了。它设了 `Qt.WindowTransparentForInput`，本意是不接收输入。但 KWin 6.6 判断内部窗口（脚本的 QML `Window`）点不点得中，`InternalWindow::hitTest` 只看两样：窗口的输入掩码，和窗口对象上 `outputOnly` 属性是不是真。`WindowTransparentForInput` 只在 `hasPopupGrab()` 里用到。所以飞行的约 0.6 秒（`flyHold` 50 + `flyAnim` 500 + `flyPark` 60 ms），和松手后落点卡淡出的 0.3 秒（`dropFade`），点卡片列都点在覆盖窗上，什么都不发生。
    - 修法一：覆盖窗加 `property bool outputOnly: true`。QML 里声明的属性，`QObject::property("outputOnly")` 读得到。
    - 根因二：就算点得到，以前飞行中途来了新操作是先 `land()`，副本一下跳到终点，再从终点飞下一次，看着一跳一跳。
    - 修法二：飞行可以打断，从副本当前位置接着飞（实现要点「换组」里的「飞行可以打断」）。
    - 根因三（测试床 `slow-retarget` 抓到的）：卡片离开卡片列（上舞台、组关了）时，`ListView` 的 `remove` 过渡让它缩小淡出 400 ms × `k`。这段时间里它还在原处，还接点击；顶替它的新卡就在同一个位置。`TapHandler` 按下时只拿被动抓取（passive grab），不挡下面的，所以两张卡的 `onTapped` 都触发：先切到新卡那组，紧接着又切回旧卡那组。真手指快速点同一张卡（一张卡时尤其）就会碰上。
    - 修法三：`remove` 过渡第一步 `PropertyAction { property: "enabled"; value: false }`，淡出的卡不再接输入。
    - 测试床：`stage.sh` 的 `retarget` 一步（0.25 s、0.1 s 间隔连点三下）、`slow-retarget` 一步（10 倍慢速，转向前后各拍一张）。两步都用 `ntaps`、`lasttap` 数「一次点击只切一次」：修法三之前 `slow-retarget` 是切了 3 次（日志三行 `state tap`），之后 2 次。
    - **教训**：KWin 脚本里的 QML `Window` 要点击穿透，用 `outputOnly`，别信 `Qt.WindowTransparentForInput`。仓库里别的覆盖层（shellbar 的背景层、Dock 等）是 layer-shell 客户端，不走这条路，不受影响；多任务卡片的窗口本来就要接收输入。
    - 测试脚本自己的坑：剧本里 `tap … &` 之后要 `wait $!`（或者记下 pid），裸的 `wait` 会连测试应用一起等，测试应用不会退出，跑到 `ts-bed.sh` 超时（`TSBED_FAIL (rc 124)`）。11-10 第一次跑就撞上了。
27. **键盘弹起再收起，卡片上下出黑边**（11-10 作者报，原话见「现状」；sb-bed 复现）：
    - 现象：卡片本来画得好好的，停靠键盘出来再收回去以后，左边的卡片上下各多一条黑边（底色 `#111`），画面被压成中间一条。
    - 根因：键盘（`exclusive zone` 389）一出来，工作区从 `0,28 1600×974` 变成 `0,28 1600×585`。KWin 把所有没最大化的窗口压进小工作区，**最小化着的也压**，键盘收起后不还。第 23 条只重摆了舞台上那一组（`place(staged)`），卡片列里的窗口就留在压矮的大小上。键盘收起、卡片变回原来的高度要重拍，拍到的是 1364×585 的窗口，放进按 1364×946 比例画的卡里，上下露底。旧脚本在测试床里：键盘收起后卡片窗口是 `220,417+1364x585`。
    - 同一类的另外两种（一直有，以前记在「有意不做」里）：从没上过舞台的窗口还最大化着（1600 宽，比槽位宽 236）；从一对里拆出去的窗口还是半宽。
    - 修法：卡片列里的窗口也摆进槽位（实现要点「卡片列里的窗口也摆进槽位」），卡里的窗口变了大小就重拍。
    - 第一版修法还会闪一下，原因有两层：
      - 最小化的窗口懒：它只在帧回调时才按新大小画，帧回调只在它的卡拍照时才有。键盘期间卡片列藏着，它什么都不画。
      - 过期的 configure：KWin 的 `XdgSurfaceWindow::moveResizeInternal` 在「要的大小」等于「窗口现在的大小」时不发新 configure。键盘弹起时 KWin 要它压矮（发了 configure，窗口没画），键盘收起时脚本要它回槽位，可槽位正是它现在的大小，KWin 不再发。窗口手里最后一个 configure 还是「压矮」。卡片列一回来，它第一帧就画成压矮的，脚本看到再问一次，它才变回来。测试床日志：`cc hide` 之后才出现 `rest: ts-live #1 220,40,1364,557/0 -> 220,40,1364,946`。
    - 第二版加「再告诉一次」：新工作区里第一遍，对已经在槽位上的窗口先要矮 1 px、同一回合里再要槽位。KWin 排一次 configure，发的时候带最后要的大小（`sendRoleConfigure` 用 `moveResizeGeometry()`），盖掉过期的那个。测试床：卡片列回来后 0 次再问，窗口全程 1364×946。
    - 自己挖的坑：「再告诉一次」起初每次窗口进卡片列都做，ts-bed 日志里一串 `told again`，每次换组多一次没用的 configure。加了 `stale`，只在换了工作区后做一次。
    - 测试床：`stagestrip.sh` 的 `on`、`kbd` 两步加了卡片窗口在槽位上的断言，新加 `cards` 一步（见「测试」）。旧脚本 5 条 FAIL。
    - **教训**：KWin 压窗口不分最小化没最小化，工作区变了以后所有窗口都要自己摆回去。给最小化的窗口改大小，要想到它很晚才回话、回的可能是旧话；判断「摆好了没有」别只看 `frameGeometry` 当下的值。
28. **卡片列收不到应用的拖放**（11-10 晚，作者拖文件到 Telegram 拖不过去，原话见「现状」）：
    - 现象：从别的应用拖文件到左边的卡片上，松手什么都没发生，源应用那边是拖放失败。
    - 根因：卡片列（和飞行覆盖层）是 KWin 脚本开的内部窗口（QML `Window`），不是 Wayland 客户端，没有 `wl_surface`，KWin 不把客户端的拖放交给它。探针实测（`research/dnd-20261110/probe/`，一个和卡片列同样标志、铺在 x 0..220 的 `Window`，里面一个 `DropArea`）：点它有 `dndprobe tapped`，拖东西过去一次 `entered` 都没有，GTK 测试源报 `drag-failed error`。
    - 所以「拖到卡片上就叫那组上舞台」不能在 `Card.qml` 里加 `DropArea` 了事，要找一个能收拖放的 Wayland 客户端表面放在卡片列那里（比如 shellbar 的背景层），再告诉脚本拖到了哪张卡。KWin 会不会把拖放交给内部窗口底下的那个表面，没试。

## 测试

**ts-bed 剧本 `ts-scenarios/stage.sh`**（无头测试 KWin，不碰作者的会话，屏幕上什么都不出现；约 1 分钟）。在平板上，root：

```
# 仓库里的 linux/gesture、linux/stage 拷到 /tmp/y700st/（scp -O -r），去掉 CRLF
cd /tmp/y700st/stage/kwin-corners && cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build   # 编特效（要 kwin-dev）
cd /tmp/y700st/gesture
sh taskswitcher/install.sh --build /tmp/y700st/build          # 只组装多任务卡片，打印 BUILD_OK
TSBED_SCRIPTS=/tmp/y700st/stage/y700-stage TSBED_KWINRC='[Script-y700-stage]\nDebug=true' \
    TSBED_PLUGINS=/tmp/y700st/stage/kwin-corners/build/bin \
    sh tests/ts-bed.sh /tmp/y700st/build tests/ts-scenarios/stage.sh /tmp/y700st/out-stage
```

打印 `TSBED_OK` 或 `TSBED_FAIL`，日志和截图在输出目录。打印 `effect not up within 20 s`：11-09 以前是 yuv709 垫片的死锁，重跑就行；修复版装上以后不该再出现，再出现就先用 gdb 看测试 KWin 的栈（踩坑第 17 条）。特效装好以后可以不带 `TSBED_PLUGINS`（测试台认系统插件目录）。测试台里没有状态栏，舞台是 220,12 1364×974，一对是 676 + 12 + 676；卡片两张单窗口时在 y 368–491、507–630，一张时在 438–561（一对 439–559）。按顺序测这些：
- `on`：开之前一个普通窗口、一个最大化窗口；打开后最大化的那个上台（220,12 1364×974），卡片列出来，特效 `1 window(s) rounded`。
- `new`：新窗口上台，旧的最小化进卡片列。
- `still`（11-09，踩坑第 24 条）：Blue 是一直在动的测试应用（`ts-app.py --frames`），收进卡片 1.5 秒后数 3 秒，最多 6 帧（实测 0）；总帧数要过 30，说明计数真在走。日志 `tsbed still: Blue drew N frames in 3 s as a card`。装着的旧版在这一步 FAIL（180 帧）。截图 `02b-still`：Blue 的卡上是拍下的那一帧，不是黑的。
- `tap`：点卡换组，截飞行中的一帧；刚下台的那组 1 秒内抢焦点被拒（`grab-back refused`）。
- `retarget`（11-10，踩坑第 26 条）：0.25 s、0.1 s 间隔连点三下（Green、Red、再 Green），每一下都生效：日志两次 `flight taken on mid-way: 3 copies, 1 carried on`，`state tap` 依次是 Red、Green，最后 Green 在台上、Red 和 Blue 收着。截图 `03b-retarget`（第三下之后 50 ms，副本在半路）、`03c-retarget-end`。最后再点一下 Blue，回到下面几步开头的状态。
- `merge`：拖卡到右半成一对（220,12 676×974 和 908,12 676×974），截拖动中落点卡那一帧，特效 `2 window(s) rounded`；`split`：最小化一个就拆开；`merge-left`：拖到左半。
- `burst`：两个同时最小化，舞台清空、一对不散、`strip hidden (desktop)`；激活那一对里的一个（等于在 Dock、桌面图标点它），整对回来、`strip shown`。
- `switcher`：从多任务卡片里选一对里的一个，一对还在（踩坑第 7 条）。
- `guarded`：游戏窗口出来卡片列藏，游戏退了卡片列回来。
- `portrait` / `landscape`：竖屏两个窗口都最大化成 1002×1600、卡片列藏；转回横屏恢复 676 + 676。
- `close-last`：关掉舞台上唯一的窗口，舞台空，`strip hidden (desktop)`。
- `menu`：激活卡片里的组；长按一对的卡出菜单（截图），「拆开」；点卡换组；再长按另一张，「关闭」。
- `off`：关掉，按账本还原：普通窗口回到 200,100 800×600，最大化的回到最大化（还最小化着的那两个，点开时才还原），特效 `0 window(s) rounded`。
- `slow-flight`：卸载后带 `Active=true` 重新加载（踩坑第 9、10 条就是这一步抓到的），10 倍慢速，等卡片列滑进来，拍飞行中间那一帧。
- `slow-retarget`（11-10）：还是 10 倍慢速，点唯一那张卡，飞到一半（2.2 s）再点那张卡（现在是正飞过去的那组），两组副本就地掉头飞回去：日志 `flight taken on mid-way: 2 copies, 0 carried on`，最后回到点之前的状态；整步只切 2 次（第二下点在第一下的卡正在淡出的地方，踩坑第 26 条根因三）。截图 `17a-before-turn`、`17b-after-turn` 两张的副本应该在差不多同一个地方、都不在两头（以前是先跳到终点），17b 里刚点的那组在变大、另一组在缩回卡位；`17c-turned-end` 是飞回去以后。

**sb-bed 剧本 `linux/dock/tests/stageback.sh`**（背景层，约 30 秒，不动屏幕，不点任何东西）。root：

```
# 候选的 shellbar 装进临时前缀（QML 从前缀里读），dock 的测试台文件和剧本拷到平板
cmake -S <镜像>/y700-shellbar -B build -DCMAKE_INSTALL_PREFIX=/tmp/y700st2/prefix && cmake --build build && cmake --install build
chmod -R a+rX /tmp/y700st2/prefix
cd <dock>/tests && SB_BAR=/tmp/y700st2/prefix/bin/y700-shellbar sh ./sb-bed.sh stageback.sh /tmp/y700st2/out-back
```

剧本往测试台的配置里写一份 `plasma-org.kde.plasma.desktop-appletsrc`，`Image=` 是带中文文件名的 `file://` 地址（作者的壁纸也是中文名）。
- `before`：一个小窗口在测试台壁纸上，状态栏黑底（截图 `b0-before`）。
- `on`：`setStage true`：shellbar 日志 `stage on`、没有 `no wallpaper found`；窗口列表里有 `y700-shellbar/@0,0+1600x1002`（背景层，层壳窗口没有标题）；截图 `b1-on` 是模糊压暗的壁纸，状态栏黑底没了、字还在。
- `off`：`setStage false`：`stage off`，背景层的窗口没了（`b2-off`）。
- `nowall`：删掉 appletsrc 再开：`stage on (no wallpaper found)`，截图 `b3-nowall` 是兜底的深蓝灰。

**sb-bed 剧本 `linux/dock/tests/stagestrip.sh`**（11-09，台前调度脚本和 shellbar 在同一个测试 KWin 里一起跑，约 60 秒，不动屏幕；只在测试台自己的卡片列上点一下，作者用着平板时也能跑）。root：

```
# 候选脚本：仓库的 linux/stage/y700-stage 拷到平板，chmod -R a+rX（测试台用 user 跑）
cd /usr/local/src/y700-dock/tests && SB_STAGE=/tmp/y700st4/stage/y700-stage sh ./sb-bed.sh stagestrip.sh /tmp/y700st4/out-strip
# 不给 SB_STAGE：测装着的那份（按作者 kwinrc 的 BuildId）
# 候选 shellbar：SB_BAR=<前缀>/bin/y700-shellbar（编法见上面 stageback.sh）
# 平板镜像里的 ts-app.py 还没有 --min-height 时：GESTURE_SRC=<放了新 tests/ts-app.py 和 tests/ftouch 的目录>
```

脚本靠测试台 kwinrc 里的 `Active=true` 加载即开，关的时候和磁贴一样写 `Active=false` 再调 `y700-stage-off` 快捷键。shellbar 用装着的（要测候选 shellbar 就加 `SB_BAR`）。测试台有状态栏，工作区和作者屏上一样是 `0,28 1600×974`，舞台 220,40 1364×946。
- `on`：两个应用，脚本加载就开：一个上舞台，另一个成一张卡。日志 `loaded, on`、`strip shown`，**不能有** `strip hidden (blocker)`；shellbar `stage on`、读到壁纸；叠放顺序（从下往上）背景层 < 两个应用 < 状态栏。截图 `k1-on`：卡片在模糊壁纸上。11-10 加：Kate（从没上过舞台、成了卡的那个）也要在槽位 `220,40+1364x946` 上，卡片上没有黑边；旧脚本这里是 `0,28+1600x974`（还最大化着），FAIL。
- `cc`：控制中心盖上来还是挡板：`strip hidden (blocker)`，背景层不撤（`k2-cc`）；控制中心收起，`strip shown`。
- `swap`（踩坑第 22 条）：剧本先往测试 KWin 里加载一段小脚本，Dock 窗口（`y700-shellbar`、y 大于 800）每次映射、撤掉都记一行 `sbbed dock mapped|unmapped <毫秒>`；然后单指点卡片列上 Kate 那张卡（118,513）。要 `state tap staged=Kate strip=Blue`，**不能有** `sbbed dock mapped`（`k3-swap`）。旧 shellbar 在这一步 FAIL（Dock 映射了 744 ms）。
- `kbd`（踩坑第 23 条）：起 `kbzone.py 389`，工作区要变（`0,28 1600×585`），Kate 要正好在键盘上面的槽位 `220,40+1364x557`（`k4-kbd`）；杀掉占位条，Kate 回到 `220,40+1364x946`。11-10 加（踩坑第 27 条）：卡片里的 Blue 也要回到 `220,40+1364x946`（截图 `k4b-kbd-gone`）；旧脚本是 `220,417+1364x585`，FAIL。
- `tall`（同上）：再开一个最矮 689 的应用 Tall（`ts-app.py --min-height 689`）。占位条在时，Tall 底边要在槽位底 597、高不低于 689（实测 `220,-128+1364x725`，`k5-tall`）；占位条撤了回到槽位。
- `cards`（11-10，踩坑第 27 条）：照平板上真键盘的样子走一遍，也就是**键盘在的时候卡片列藏着**。占位条不是挡板，所以先让控制中心盖上来当挡板（`strip hidden (blocker)`），再起占位条、杀占位条，最后收起控制中心。这时有三张卡：Live（`ts-app.py --frames`，一直在动的应用，最小化后只在卡片拍照时才画）、Tall、Blue；Kate 在舞台上。查三件事：
  - 卡片列回来以后，日志里**不能再有** `y700-stage: rest: `（输出 `cards: 0 requests to the column's windows once it was back`）。有就说明某个窗口先画了一帧压矮的，卡片上会闪一下黑边。
  - 三张卡的窗口都在整槽位 `220,40+1364x946`（截图 `k7-cards`：没有黑边）。旧脚本三条都 FAIL（Live、Blue 是 `220,417+1364x585`，Tall 是 `220,28+1364x725`）。
  - Live 拍完以后 3 秒内画的帧数不超过 6（实测 0），总帧数大于 30（证明它确实在动）：多拍的那几拍没有变成一直拍。
- `off`：`off, restored`、shellbar `stage off`，1.5 秒后背景层窗口没了（`k6-off`：窗口还原成最大化，状态栏回到黑条）。
- 全部应用页（shellbar 里真正盖在应用上的大窗口）这条路没走到：要点 dock 上的按钮，而点错位置会在真用户会话里启动应用（`sb-bed.sh` 头注释），所以只用叠放顺序间接证明它在上面。

**sb-bed 剧本 `linux/dock/tests/stagetile.sh`**（控制中心磁贴，第一版写的，第二版没动；里面跑真的控制中心，约 50 秒，不动屏幕；每点一下平板真振一下，所以熄屏时跑）。root：

```
cd /usr/local/src/y700-dock/tests && sh ./sb-bed.sh stagetile.sh /root/sb-stagetile
# 测候选的控制中心：SB_CC=<编出来的 y700-control-center> sh ./sb-bed.sh stagetile.sh /root/sb-stagetile
```

测试台的 KWin 跑**已装的** y700-stage（从作者的 kwinrc 读 `BuildId`）。没装就报 FAIL，什么都不点。
- s0：截图确认第 6 行三个磁贴在 x 1204–1307、1322–1425、1440–1543，台前调度的图标和四个字的标题都画出来了，关着是暗的。**认不出就一下都不点**：测试台里的控制中心动的是真系统，旁边的刷新率和性能浮层是真开关。
- s1：点开，测试台的 kwinrc `Active=true`，脚本日志 `on, 1 windows`，帘子没收，6 秒后磁贴还亮着（说明状态读回来了，不只是乐观值）。
- s2：再点，`Active=false`，`off, restored`，6 秒后磁贴暗了。
- 两次都不能出 `台前调度失败` 的提示。

**真机开关对照 `linux/stage/stage-power-ab.sh`**（11-09，踩坑第 24 条之后写的；在**作者真会话**里跑，屏幕会自己亮、冒出两个测试窗口、台前调度自己开关，约 4 分钟。跑之前跟作者说一声）。条件：熄屏（没人在用）、用电池、台前调度开着，不满足就不跑。root，在平板上：

```
# 仓库的 linux/stage/stage-power-ab.sh 拷到平板（scp -O），镜像里的 ts-app.py 要有 --frames
systemd-run --unit=y700-stagepw-$(date +%H%M) --collect bash /tmp/y700st8/stage-power-ab.sh /tmp/y700st8/run
# 跑的时候别 ssh（状态页可以看）；跑完 tar czf 拷回来（tar 保留 mtime，.py 拿它算每段多长）
tools/venv/Scripts/python.exe -X utf8 -I -B linux/stage/stage-power-ab.py <拷回来的 run 目录>
```

- 准备：先等 15 秒（发起它的那次 ssh 会拉起 root 的用户管理器，断开约 10 秒后才散），记下当前的活动窗口（只记 id 和应用类名）、亮度、自动亮度、屏幕状态；停自动亮度，亮屏，亮度定在 800（和 `linux/video/chrome-video-power-ab.sh` 一样）。
- 起 Anim（`ts-app.py --frames`，每帧都改字），3 秒后再起 Quiet（静止的灰窗口）：Quiet 上台，Anim 和作者原来台上的应用都进卡片列。
- 三段：`on1` 开着、`off`（和磁贴一样写 `Active=false` 再调 `y700-stage-off`）、`on2` 再开。每段 6 个 10 秒块，每块是一次 `y700-powersample`（电池 W、CPU 忙、面板刷新率分布），加上 Anim 这 10 秒画了几帧、亮度、屏幕状态，块前块后各一份 `/proc/*/stat`。换开关后等 8 秒，记 Anim 这 8 秒画的帧（开的那次应该只有拍照那 0.6 秒的几十帧）。
- 每块之后看触摸屏中断（NVT-ts）变没变：变了就是有人摸了，立刻停下还原，屏幕留亮。熄了屏也停。
- 还原：开关回到开着；原来的活动窗口回到台上；杀掉两个测试窗口；亮度、自动亮度、熄屏都恢复。输出目录：`log`（准备和还原）、`chunks`（每块一行）、`stage-lines`（这段时间台前调度自己的日志，不开 Debug 时没有窗口标题）、`ps.N.a/b`、`anim.frames`。
- **看不见其他测试的虚拟输入**：vtouch、uinput 不走 NVT-ts，不会触发停止（11-09 第一段就被同时在跑的串流测试撞了）。看 `stage-lines`：某段里出现 `strip hidden (fullscreen/guarded)` 之类，这段作废。

**结果**：
- 11-08：`stage.sh` `TSBED_OK`，0 个 QML 报错；`stagetile.sh` 候选构建和装上后各 `SBBED_OK`；相邻两行的 `acttile.sh` 也 `SBBED_OK`。量到的数：亮着离强调色 0，关着 34；台前调度标题 61 px 宽，性能浮层关着时的标题 62 px 宽。
- 11-09：`stage.sh`（第二版 + 特效）`TSBED_OK`，0 个 QML 报错，19 张截图逐张看过：卡片的透视斜边放大 3 倍是平滑的；菜单、落点卡、飞行中间一帧都对。`stageback.sh`（候选 shellbar）`SBBED_OK`，4 张截图看过。`stagetile.sh` 没重跑（磁贴没动）。
- 11-09 合并平板侧补丁后（`ea3c7ce`，候选装在 `/tmp/y700st3/prefix`）：`stageback.sh`、`dnd.sh`（勿扰，新写的）、`curtain.sh`、`look.sh` 全 `SBBED_OK`；合并前的构建跑 `dnd.sh` 按预期失败 4 条（说明剧本真测到了勿扰）。
- 11-09 修卡片列（踩坑第 21 条）：`stagestrip.sh` 拿装着的旧脚本（build `20261109020906`）FAIL：`strip hidden (blocker)`，复现；修复版 `SBBED_OK`，3 张截图看过（旧版 `k1-on` 没有卡片，新版有）。`stage.sh` 用修复版 `TSBED_OK`，19 张截图，0 个 QML 报错。
- 11-09 修 Dock 闪弹和键盘（踩坑第 22、23 条，`44af433`；候选脚本在平板 `/tmp/y700st4/cand/stage/y700-stage`，候选 shellbar 在 `/tmp/y700st4/sbprefix`）：
  - 旧脚本 + 旧 shellbar 跑新的 `stagestrip.sh`：swap 一步 Dock 映射了 744 ms（另一次 749 ms），kbd、tall 两步 4 条 FAIL（坐标见踩坑第 23 条），都复现了。
  - 第一次修好后 Dock 还闪：shellbar 日志里没有 `hold dock`（`double` 参数，踩坑第 22 条）；改成 `int` 属性后 `hold dock 950 ms`。
  - 修复版脚本 + 候选 shellbar：`stagestrip.sh` `SBBED_OK`，新加的三张截图看过（`k3-swap` 换好了组、底下没有 Dock，`k4-kbd` 舞台窗口在占位条上面、`k5-tall` 高窗口底边贴着占位条）；候选 shellbar 跑 `look.sh`、`dock-gone.sh` 也 `SBBED_OK`（Dock 平时的显隐没被 `holdDock` 带坏）。修复版脚本跑 ts-bed 的 `stage.sh` `TSBED_OK`，0 个 QML 报错。
- 11-09 卡片改静止图（踩坑第 24 条；候选在平板 `/tmp/y700st6/`）：
  - 装着的旧脚本（build `20261109093526`）跑新的 `stage.sh`：still 一步 FAIL，Blue 3 秒画了 180 帧。
  - 候选 `TSBED_OK`，0 帧，0 个 QML 报错。截图和旧版逐张比过：单张、一对、长按菜单旁那张卡都有画面，和活缩略图看着一样。
  - `stagestrip.sh`（`SB_STAGE` 指候选）`SBBED_OK`。第一版候选在 `k4-kbd` 里 Blue 的卡被压扁；加了变形重拍后不压扁了（窗口比例不同，左右露一点 `#111` 黑边，和以前活缩略图一样）。最终版再跑 `stage.sh`：`TSBED_OK`，0 帧。
- 11-09 11:05–11:08 真机开关对照（`stage-power-ab.sh`，装着的 build `20261109103741`）：`off` 1.45 W、`on2` 1.30 W，CPU 忙 4.5 % 和 4.0 %（8 个核合计），Anim 三段 18 块全是 0 帧。`on1` 被同时在跑的另一项测试撞了，作废。数和每个进程的 CPU 见「部署记录」。

**体检**（`y700-checklist`「台前调度」，`check_stage`）：
- 没装（`~user/.local/share/kwin/scripts/y700-stage` 不在）就不出这一项。
- 装了的话，按顺序查：
  1. `isScriptLoaded` 不是 true → WARN；
  2. `BuildId` 不是数字，或者 `contents/build-<id>/ui/Stage.qml` 不在 → WARN；
  3. 这次开机日志里有这个脚本的 QML 报错 → WARN，带条数；
  4. kwinrc 的 `Active` 和脚本日志最后一句（`loaded, on|off`、`on, …`、`off, …`）对不上 → WARN「kwinrc 记的是「开/关」，脚本最后一句是「…」」。可能刚好在点磁贴，所以隔 1.5 秒再读一次，还对不上才报；
  5. 没有加载记录 → WARN。
- 都对：OK「台前调度就绪（y700-stage 已加载，开着/关着，和控制中心的开关一致）」。
- 圆角特效（11-09 加）：有版本戳（`/usr/local/share/y700-stage/stagecorners.kwin-version`）、又和现在的 `kwin-wayland` 对不上 → WARN「圆角特效是为 KWin X 编的，现在是 Y：自动重编没成功，舞台窗口是方角」；台前调度开着、特效却没加载 → WARN。关着时特效本来就不加载，不报；没有版本戳（这台没编过）不出这一条。
- 自测 `tools/y700-checklist-selftest.py` S43a–p，0 失败。

## 部署记录

**11-08（第一版，屏灭、没人用时装的）**
- **23:37 脚本**：源码镜像 `/usr/local/src/y700-stage/`（`install.sh` `3826831d2545`、`Stage.qml` `bd8f4d0c2ff2`、`Card.qml` `ee954f49dd56`、`main.qml` `7f1a58f8feaa`）。`sh install.sh` → `INSTALL_OK build 20261108233700`，日志 `y700-stage: loaded, off`，`Active` 没写（等于关）。
- **23:40 控制中心**：先备份到 `/root/backup/cc-stage-1108-234022/`；新的 `qml/Main.qml`（`f007727c1238`）、`qml/icons/stage.svg`（`be21b680eaa2`）、`src/backend.cpp`（`0a499c5e8f78`）放进镜像 `/usr/local/src/y700-control-center/`，编过再跑 `install.sh` → `INSTALL_OK`；服务 active，没有 QML 报错，装着的二进制 `6551ca89a293`。装之前核对过镜像和上一次提交只差一行注释。
- **23:42**：`stagetile.sh`（`d111c03d9fe4`）放进 `/usr/local/src/y700-dock/tests/`。
- **23:46 体检**：`/usr/local/bin/y700-checklist` 换成 `41fccce5f944`，旧版备份 `/root/backup/cl-stage-1108-234620/`。实跑「OK 台前调度就绪（…关着…）」。另外两条 WARN 和这里无关（`tb323fu-kernel-fetch.service` 失败；熄屏省电没生效那段是我在跑测试床）。

**11-09（第二版，凌晨 2 点，屏灭、没人用、没在测量时装的）**
- **02:08 核对**：镜像 `/usr/local/src/y700-stage/` 的 5 个文件和提交 `e0906c1` 一致，才覆盖。
- **02:09 脚本 + 圆角特效**：镜像里放进 `install.sh` `319d37a9047e`、`y700-stagecorners-rebuild` `11b9c56eae9a`、`Stage.qml` `87b8466c7282`、`Card.qml` `7f7d029e9b9d`、`main.qml` `7f1a58f8feaa`（没变）、`kwin-corners/`（`stagecorners.cpp` `b978f15df3e6`），两边 hash 比过。`sh install.sh` → `corners effect installed`、`INSTALL_OK build 20261109020906`，日志 `y700-stage: loaded, off`。装上的：`y700_stagecorners.so`、版本戳 `4:6.6.6-0ubuntu0.1`、apt 钩子、kwinrc `y700_stagecornersEnabled=true`。cmake 那两行 `fatal: 不是 Git 仓库` 是 KDE 的 cmake 模块想读 git 版本，无害。
- **02:10 手动加载特效**：`reconfigure` 没加载它（运行中的 KWin 不加载新装的特效），`busctl … loadEffect s y700_stagecorners` → `isEffectLoaded` true，`/org/y700/StageCorners` 的 `setWindows` 能调。KWin 还是原来那个进程（跑了 1 天 10 小时），没崩。
- **02:13 体检**：`/usr/local/bin/y700-checklist` 换成 `da3789d1485f`（提交 `8949fec`），旧版备份 `/root/backup/cl-corners-1109-021315/`。实跑「OK 台前调度就绪（…关着…）」，唯一的 WARN 还是无关的 `tb323fu-kernel-fetch.service`。
- **02:2x shellbar 先没装**：装之前比 hash 发现平板镜像和 git 分叉（踩坑第 20 条），停下来问作者。作者：「合并后装背景层」。
- **02:43 shellbar（背景层 + 合进来的勿扰、键鼠电量，提交 `ea3c7ce`）**：旧镜像、旧二进制（11-04 21:10 那份）、旧 QML 备份在 `/root/backup/sb-merge-1109-024209/`，补丁文件 `kbd-dnd-mouse-20261104.patch` 也挪进那里；镜像 24 个文件和 git 逐个比过 sha256；`install.sh --no-start` 后单独重启服务（主服务进程换了，没有重启循环）。新二进制 `ac76a36c12ea`、`Backdrop.qml` `5b35a4574658`、`StatusBar.qml` `9bcbadc55c6e`。起来后日志只有 `notifications: serving …`，没有 QML 报错；D-Bus 上 `setStage`、`toggleDoNotDisturb` 都在。真会话里 `setStage` 开关一次，`stage on`（中文名的壁纸读到了，没有 `no wallpaper found`）。
- **02:4x 补发一次「开着」**：这时才看到作者 02:33 已经打开了台前调度（脚本最后一句 `strip shown`）。新 shellbar 不知道（台前调度只在换组时重发，见「有意不做」），手动 `setStage true`，日志 `stage on`。
- **体检**：「状态栏与 dock 就绪」OK，「台前调度就绪（…开着…）」OK，唯一的 WARN 还是无关的 `tb323fu-kernel-fetch.service`。
- **03:01 卡片列修复进镜像（还没重新加载）**：作者截图报卡片列没了（踩坑第 21 条），修好、测试床过了以后，镜像 `/usr/local/src/y700-stage/` 先和提交 `9277101` 逐个比过 hash（11 个文件全对），再把 `y700-stage/contents/ui/Stage.qml` 换成 `57e1c22cb2db`（提交 `e0e9a07`），旧的备份在 `/root/backup/stage-strip-1109-030102/`。测试剧本 `stagestrip.sh` `4aaae56fb440` 和 `sb-bed.sh` `d9b733f71bc1` 放进 `/usr/local/src/y700-dock/tests/`（旧 `sb-bed.sh` 也备份在同一个目录）。**`install.sh` 没跑**：它会卸载再重新加载脚本，作者正在用，要先问。
- **03:03 装卡片列修复**（作者：「现在装」）：状态页没在测量。`sh /usr/local/src/y700-stage/install.sh` → `corners effect installed`、`INSTALL_OK build 20261109030355`；日志 `loaded, on`、`on, 4 windows`，没有 QML 报错。这时作者开着全屏的 YOUYOU（03:02:26 从 dock 启动），活动窗口全屏就是「fullscreen/guarded」：卡片列不出、背景层不开，所以日志里没有 `strip shown`，shellbar 也没收到新的开关（03:02:19 回桌面时已经 `stage off`），都对。旧脚本卸载时 `Component.onDestruction` 发的 `setStage false` 没在 shellbar 日志里出现，因为它那时已经是关的（`setStage` 不变不记）。
- **03:04 体检**：「台前调度就绪（…开着…）」OK，「状态栏与 dock 就绪」OK。新的 WARN「KWin 还映射着 2 个被升级替换掉的库（`y700-yuv709.so`、`y700_stagecorners.so`）」：圆角特效是这次重编重装的（源码没变），yuv709 垫片是视频部分 03:03:46 装的修复版（不是这里装的），两个都是下次登录才换成新的，预期内。另一条 WARN 还是无关的 `tb323fu-kernel-fetch.service`。
- **09:34 Dock 闪弹和键盘修复进镜像**（作者回「装」）：状态页没在测量、熄屏、没有 ssh。`44af433` 的 8 个文件拷到 `/tmp/y700st5/`，脚本逐个核对：旧的都和 `54bc0a1` 一样、新的都和 `44af433` 一样，才动手。旧文件按原路径备份在 `/root/backup/stage-dock-kbd-1109-093450/`。镜像里现在是：`y700-shellbar/src/shell.h` `6128cf1d17a8`、`src/shell.cpp` `a3b13f796324`、`qml/Main.qml` `125a40bb1beb`，`y700-stage/y700-stage/contents/ui/Stage.qml` `7a2b8c886ff7`，`y700-dock/tests/stagestrip.sh` `f242ad647ce2`、`sb-bed.sh` `86dffcc3f37c`、`kbzone.py` `6581d7b4a67c`（新），`y700-gesture/tests/ts-app.py` `3ed519580a99`。
- **09:35 shellbar**：旧二进制 `ac76a36c12ea` 和旧 QML 目录也备份进同一个目录；`sh install.sh --no-start` → `INSTALL_OK_NOT_STARTED`，新二进制 `8c63905462f5`。再看一次状态页（还是熄屏），09:35:10 单独 `systemctl --user restart y700-shellbar`：active、`NRestarts=0`，日志只有通知服务和性能小组件那几行，没有 QML 报错；D-Bus 上 `holdDock` 是 `i`。
- **09:35 脚本**：`sh install.sh` → `corners effect installed`、`INSTALL_OK build 20261109093526`；日志 `loaded, on`、`on, 4 windows`、`strip shown`、`1 window(s) rounded`。装着的 `Stage.qml` `7a2b8c886ff7`。shellbar 日志随即 `stage on`：新加载的脚本 `sentStage` 是空的，加载就发，所以这次不用手动补发。
- **09:36 体检**：「台前调度就绪（…开着…）」OK，「状态栏与 dock 就绪」OK。WARN 三条都和这里无关或预期内：KWin 还映射着被换掉的 `y700-yuv709.so`、`y700_stagecorners.so`（下次登录换）；`tb323fu-kernel-fetch.service` 失败；「熄屏省电开着但没生效」（02:33 以后系统域一次没进）——跑了 `y700-whoawake 20`：平板上的 Claude 桌面版渲染进程 283 ms/s、GPU 进程 242 ms/s，KWin 50 ms/s，`gpu-irq` 471 次/s，是 Claude 在熄屏后还在画（开发日志（未公开）「熄屏省电开着却没生效」里见过的那种），不是台前调度。Claude 是作者的程序，没动。
- **09:37 测试床复查**：不给 `SB_STAGE`、`SB_BAR`，拿装着的脚本和 shellbar 跑 `stagestrip.sh` → `SBBED_OK`：swap 一步测试台 shellbar 日志 `hold dock 950 ms`、没有 Dock 映射；kbd 一步 Kate `220,40+1364x557`，收起后 `220,40+1364x946`；tall 一步 Tall `220,-128+1364x725`，收起后回槽位。
- **10:37 卡片静止图**（`336af38`，踩坑第 24 条；作者「装吧，装上」）：
  - 状态页没在测量，熄屏，没有别的 ssh。
  - 提交版的 `Card.qml`、`ts-app.py`、`stage.sh` 从 git 取出，传到 `/tmp/y700st7/`。
  - 镜像核对：`Card.qml` `7f7d029e9b9d`、`ts-app.py` `3ed519580a99`，都是改之前那版，才动手。
  - 旧文件按原路径备份在 `/root/backup/stage-still-1109-103728/`。
  - 镜像里现在是 `y700-stage/y700-stage/contents/ui/Card.qml` `a63626d49e6d`、`y700-gesture/tests/ts-app.py` `7c49695f4646`，外加 `y700-gesture/tests/ts-scenarios/stage.sh` `d15a0e918d4e`（新放的）。放完比过 sha256。
- **10:37 重新加载**：`sh install.sh` → `corners effect installed`、`INSTALL_OK build 20261109103741`，日志 `loaded, off`，没有 QML 报错。装着的 `Card.qml` 是 `a63626d49e6d`。作者 10:18:40 已经从磁贴关掉了台前调度（日志 `off, restored 1, 3 when shown`，kwinrc `Active=false`），所以是关着加载的，没拆散什么。
- **10:38 体检**：「台前调度就绪（…关着…）」OK，「状态栏与 dock 就绪」OK。三条 WARN 都和这次无关：
  - KWin 还映射着被换掉的 `y700-yuv709.so`、`y700_stagecorners.so`，下次登录换；
  - `tb323fu-kernel-fetch.service` 失败；
  - 「熄屏省电开着但没生效」，09:36 查过，是平板上的 Claude 桌面版熄屏还在画。
- **10:38–10:42 测试床复查**：
  - 第一次在镜像的 `tests/` 里跑 ts-bed，FAIL（180 帧）：那份 `ts-bed.sh` 是旧版，没加载台前调度，见踩坑第 25 条。
  - 拿仓库版 `ts-bed.sh` 跑装着的脚本（`TSBED_SCRIPTS=/usr/local/src/y700-stage/y700-stage`）：`TSBED_OK`，still 一步 0 帧，0 个 QML 报错。
  - `stagestrip.sh`（不给 `SB_STAGE`，日志 `the installed script, build 20261109103741`）：`SBBED_OK`。
- **11:04–11:09 真机开关对照**（作者先说「现在量」，又说「请你自行测试」；踩坑第 24 条）：
  - 先前 10:5x 约作者自己点磁贴那次：我 40 秒就停了记录，没看日志里两段齐没齐，只量到「开着」半分钟，屏幕 10:56 也熄了，不算数（数据留在平板 `/tmp/y700st7/pw-aborted-1056/`）。所以改成自己跑。
  - 跑之前看过：熄屏、电池放电 90 %、台前调度开着、状态页没在测量。台上是 wiliwili，卡片列里是 Telegram、Claude、Chrome。
  - `systemd-run --unit=y700-stageself-1104`（脚本就是后来提交的 `stage-power-ab.sh`，只差头注释），11:04:46 起，11:08:43 还原完。跑的时候没 ssh。
  - 还原核对：开关回到开着，wiliwili 回到台上，两个测试窗口都没了，自动亮度起来了（亮度 3599，之前 3431，是自动亮度又调了），屏幕关回去了，没人摸过屏幕。
  - **结果**（亮度 800、静止画面；面板刷新率三段都大多在 30 Hz）：

    | 段 | 电池功耗（6 块） | CPU 忙（8 核合计） | Anim 帧数 |
    |---|---|---|---|
    | `off` 11:06:26–11:07:27 | 1.45 W（1.32、2.08、1.54、1.20、1.25、1.33） | 4.5 % | 0 |
    | `on2` 11:07:35–11:08:36 | 1.30 W（1.30、1.27、1.30、1.36、1.29、1.28） | 4.0 % | 0 |

  - 每个进程（一个核的百分比，开关两段差不多）：Chrome 13.5–13.8 %、平板上的 Claude 9.0–9.5 %，收起了也在跑，开关都一样，是它们自己的定时器，不是台前调度催的。KWin 0.03 %，wiliwili 0.00–0.02 %，Anim 进程 0.03 %。改之前开着时：Chrome 19 %、wiliwili 9 %、KWin 8.7 %，CPU 合计 25–27 %，作者看到 6–8 W（那次亮度和操作没控制，只能当参照）。
  - Anim 换开关后 8 秒的帧：关的时候 0 帧；再开的时候 42 帧，就是卡片拍照那 0.6 秒，之后 0。
  - `on1` 作废：同一时段（11:05:29–11:05:57）另一项测试在平板上全屏开了串流窗口，还用 vtouch 点、用 uinput 按键。台前调度日志 11:05:32 `strip hidden (fullscreen/guarded)`、11:05:42 `strip shown`，第 1 块 9.45 W（最高 14.66 W）。后两块没被撞，1.56、1.60 W。脚本只认真手指，看不见虚拟输入，已写进「测试」。
  - 数据在平板 `/tmp/y700st8/run/`（`run.tgz`），本机拷回来分析过。

**11-10（连点打断，`a69f3b6`，踩坑第 26 条；作者「装吧」）**
- **04:46 进镜像**：状态页 `measure=stopped`。提交版的 `Stage.qml`、`stage.sh` 传到 `/tmp/y700st9/`。镜像核对：`Stage.qml` `7a2b8c886ff7`、`ts-scenarios/stage.sh` `d15a0e918d4e`，都是改之前那版，才动手。旧的备份在 `/root/backup/stage-retarget-1110-044639/`，换上后 `Stage.qml` `8933ef8f3c99`、`stage.sh` `240a5617e92a`（和提交一致）。
- **04:46 重新加载**：`sh /usr/local/src/y700-stage/install.sh` → `corners effect installed`、`INSTALL_OK build 20261110044654`；日志 `loaded, on`、`on, 2 windows`、`strip shown`、`1 window(s) rounded`，没有 QML 报错。安装脚本打了两行「不是 Git 仓库」，是它在镜像里取提交号，没取到，不影响。
- **04:47 体检**：「台前调度就绪（y700-stage 已加载，开着，和控制中心的开关一致）」OK。两条 WARN 和这次无关：KWin 还映射着被换掉的 `y700-yuv709.so`、`y700_stagecorners.so`（圆角特效每次装都重编，源码没变，下次登录换）；「熄屏省电开着但没生效」（00:35–04:20 熄屏那段系统域没进，那段时间平板上没有台前调度的测试床单元在跑，没追）。
- **04:48 测试床复查**：`TSBED_SCRIPTS=/usr/local/src/y700-stage/y700-stage`，仓库版 `ts-bed.sh` 跑 `stage.sh` → `TSBED_OK`：retarget 两次 `3 copies, 1 carried on`，slow-retarget 一次 `2 copies, 0 carried on`、只切 2 次，still 一步 0 帧。
- **作者真手指验收**（第 19 条）：「试过了，顺」。

**11-10（键盘后卡片黑边，`7dc25d9`，踩坑第 27 条；作者「装吧」）**
- **05:38 进镜像**：状态页 05:37 六个测量单元全 `stopped`、`ssh_sessions=0`、`dpms=On`。提交版的 `Stage.qml`、`Card.qml`、`stagestrip.sh` 传到 `/tmp/y700st10/inst/`。镜像核对：`Stage.qml` `8933ef8f3c99`、`Card.qml` `a63626d49e6d`、`y700-dock/tests/stagestrip.sh` `f242ad647ce2`，都是改之前那版，才动手。旧的备份在 `/root/backup/stage-cards-1110-053835/`，换上后 `766ea8a00269`、`348023e2782e`、`8156f91fd878`（和提交一致）。
- **05:39 重新加载**：先跟作者说了一声。`sh /usr/local/src/y700-stage/install.sh` → `corners effect installed`、`INSTALL_OK build 20261110053904`；日志 `loaded, on`、`on, 4 windows`、`1 window(s) rounded`，没有 QML 报错；装着的 `build-20261110053904/ui/` 里两个文件的 hash 和提交一致。重新加载时屏幕键盘正弹着（之前最后一行是 05:38:51 `strip hidden (blocker)`）。
- **真会话日志**（05:39:05–05:39:56，之后到 05:44 没有新行；只留时间和 `y700-stage:` 后面的部分）：

  ```
  05:39:05 on, 4 windows
  05:39:05 rest: org.kde.dolphin #1 220,28,1364,585/0 -> 220,40,1364,558
  05:39:05 rest: org.telegram.desktop #1 220,28,1364,703/0 -> 220,-91,1364,689
  05:39:05 rest: google-chrome #1 220,28,1364,586/0 -> 220,40,1364,558
  05:39:05 rest: org.telegram.desktop #2 220,-91,1364,703/0 -> 220,-91,1364,689
  05:39:37 rest: org.kde.dolphin #1 220,40,1364,557/0 -> 220,40,1364,946.1052631578948
  05:39:37 rest: org.telegram.desktop #1 220,-91,1364,703/0 -> 220,40,1364,946.1052631578948
  05:39:37 rest: google-chrome #1 220,28,1364,586/0 -> 220,40,1364,946.1052631578948
  05:39:37 strip shown
  05:39:55 rest: org.telegram.desktop #2 220,28,1364,703/0 -> 220,40,1364,946.1052631578948
  05:39:55 rest: org.kde.dolphin #2 220,28,1364,585/0 -> 220,40,1364,946.1052631578948
  05:39:56 rest: org.kde.dolphin #1 220,40,1364,946/0 -> 220,40,1364,558
  05:39:56 rest: org.telegram.desktop #1 220,40,1364,946/0 -> 220,-90.99999999999989,1364,688.9999999999999
  05:39:56 rest: google-chrome #1 220,40,1364,946/0 -> 220,40,1364,558
  05:39:56 strip hidden (blocker)
  ```

  读法：加载时（键盘弹着）三个真应用都被 KWin 压在 `220,28`、高 585/703/586，就是作者看到黑边的那种状态。05:39:37 键盘收起，三个都被要回整槽位，然后卡片列才出来；05:39:56 它们已经站在 `220,40,1364,946`。05:39:55 键盘又弹起，KWin 先压、脚本按旧工作区多要了一轮（`#2`），下一秒才要矮槽位。没出现 `told again`：收起那次三个窗口都不在整槽位上，走的是普通请求。要的高度带小数（946.105…）是槽位算出来没取整，以前摆舞台上的窗口也这样，窗口实际站在 946。这几条写进了「没验证的」。
- **05:39–05:42 测试床复查（装着的版本）**：sb-bed 跑镜像里的 `stagestrip.sh`（不带 `SB_STAGE`）→ `the installed script, build 20261110053904`、`cards: 0 requests to the column's windows once it was back`、三张卡的窗口都在 `220,40+1364x946`、`Live drew 0 frames in 3 s as a card (201 in all)`、`done (FAIL=0)`、`SBBED_OK`。ts-bed（`TSBED_SCRIPTS=/usr/local/src/y700-stage/y700-stage`，仓库版 `ts-bed.sh`）跑 `stage.sh` → `TSBED_OK`，still 一步 `Blue drew 0 frames in 3 s as a card (364 in all)`。
- **05:42 体检**：「台前调度就绪（y700-stage 已加载，开着，和控制中心的开关一致）」OK，「状态栏与 dock 就绪」OK。两条 WARN 和上一次一样、和这次无关：KWin 还映射着被换掉的 `y700-yuv709.so`、`y700_stagecorners.so`（下次登录换）；「熄屏省电开着但没生效」（这次报的是 00:38–05:20 熄屏那段，没追）。
- **作者真手指验收**（第 20 条）：「没黑边了」。回来那一下闪不闪、试的是哪几个应用，作者没提，没追问。
- **平板上的临时文件**：`/tmp/y700st/`、`/tmp/y700st2/`、`/tmp/y700st3/`、`/tmp/y700st4/`、`/tmp/y700st5/`、`/tmp/y700st6/`、`/tmp/y700st7/`、`/tmp/y700st8/`、`/tmp/y700st9/`、`/tmp/y700st10/`（候选 shellbar、候选脚本、测试输出，重启就没）。

## 待办

- [x] **开关对照量一次功耗**（踩坑第 24 条）：11-09 11:05–11:08 用 `stage-power-ab.sh` 自己量了，开着 1.30 W、关着 1.45 W，收起的动画应用 0 帧（见「部署记录」）。以后改了卡片或缩略图，照「测试 · 真机开关对照」再跑一次。
- [x] **装上卡片静止图**（踩坑第 24 条）：11-09 10:37 装上（见「部署记录」）。下面是当时的装法，以后再装照这个。要动的只有台前调度脚本（`Card.qml`，重新加载），外加测试文件。装法（root，在平板上；先看状态页没在测量，先跟作者说一声、确认没在用平板；装和重新加载分两步）：
  1. 比镜像：`/usr/local/src/y700-stage/y700-stage/contents/ui/Card.qml` 要是 `7f7d029e9b9d`（`9277101` 那版，11-09 改之前核对过），`/usr/local/src/y700-gesture/tests/ts-app.py` 要是 `3ed519580a99`。对不上就停。
  2. 旧的备份到 `/root/backup/stage-still-1109-<时间>/`，放进新的 `Card.qml`；`ts-app.py` 放进 `/usr/local/src/y700-gesture/tests/`，`stage.sh` 放进同一处的 `ts-scenarios/`。放完比 sha256。
  3. `sh /usr/local/src/y700-stage/install.sh`：`INSTALL_OK build <新 id>`，日志 `loaded, on`（作者开着时）、`strip shown`，没有 QML 报错。重新加载时背景层和圆角先撤一下；当前窗口上舞台，其他应用各成一张卡，原来的一对会拆开。
  4. 体检；拿装着的版本跑 ts-bed 的 `stage.sh`，`TSBED_OK`、still 一步 0 帧左右。**`ts-bed.sh` 要用仓库里的**（拷到 `/tmp` 下的那份），别用平板镜像 `/usr/local/src/y700-gesture/tests/` 里的：那份是旧版，不认 `TSBED_SCRIPTS`，台前调度根本不加载（踩坑第 25 条）。`TSBED_SCRIPTS=/usr/local/src/y700-stage/y700-stage`。
  5. 写「部署记录」，划掉这条，提交。
- [x] **装上 Dock 闪弹和键盘修复**（`44af433`，踩坑第 22、23 条）：11-09 09:35 装上（见「部署记录」）。第 5 步没用上：先重启 shellbar、后重新加载脚本，新加载的脚本自己发了 `setStage true`。下面是当时的装法，以后再装照这个。要动两样：shellbar（重启服务）、台前调度脚本（重新加载）。装法（root，在平板上；先看状态页没在测量，先跟作者说一声、确认没在用平板；装和重启分两步）：
  1. 比镜像：`/usr/local/src/y700-shellbar/` 的 `src/shell.h`、`src/shell.cpp`、`qml/Main.qml` 和 `/usr/local/src/y700-stage/y700-stage/contents/ui/Stage.qml` 要和上一次提交 `54bc0a1` 一致（11-09 修的时候核对过：`Stage.qml` `57e1c22cb2db`、`shell.cpp` `302fb5ac3097`、`shell.h` `f79dbfb49408`、`Main.qml` `3518f2002afe`）。对不上就停。
  2. 旧的备份到 `/root/backup/stage-dock-kbd-1109-<时间>/`，再把 `44af433` 的这四个文件放进镜像；测试用的 `stagestrip.sh`、`sb-bed.sh`、`kbzone.py` 放进 `/usr/local/src/y700-dock/tests/`，`ts-app.py` 放进 `/usr/local/src/y700-gesture/tests/`。放完比 sha256。
  3. `sh /usr/local/src/y700-shellbar/install.sh --no-start`，看到装好；再单独 `systemctl --user restart y700-shellbar`（user）。日志没有 QML 报错，D-Bus 上有 `holdDock`。
  4. `sh /usr/local/src/y700-stage/install.sh`：`INSTALL_OK build <新 id>`、日志 `loaded, on`（作者开着时）。重新加载时背景层和圆角先撤一下，当前窗口上舞台，其他应用各成一张卡，原来的一对会拆开。
  5. 台前调度开着的话手动补发一次 `setStage true`（shellbar 重启后不会马上收到，见「有意不做」），日志 `stage on`。
  6. 体检；再拿装着的版本跑一遍 `stagestrip.sh`（不给 `SB_STAGE`、`SB_BAR`），`SBBED_OK`。
  7. 写「部署记录」，划掉这条，提交。
- [x] **背景层上线**：11-09 02:43 装上（先把平板镜像里的勿扰、键鼠电量合进 git，`ea3c7ce`；见「部署记录」）。开发日志（未公开）「Magic 键鼠」一节那条「待合」也划掉了。
- [x] **装上卡片列修复**：11-09 03:03 装上（见「部署记录」）。下面是当时的装法，以后再装照这个：镜像已换（见「部署记录」11-09 03:01）。在平板上 root `sh /usr/local/src/y700-stage/install.sh`，看到 `INSTALL_OK build <新 id>` 和日志 `loaded, on`、`strip shown` 后面**没有** `strip hidden (blocker)`，再跑体检。重新加载时：背景层和圆角先撤一下；当前窗口上舞台，其他应用各成一张卡，原来拼成一对的会拆开。圆角特效会重编重装一遍（源码没变，正在跑的 KWin 继续用已加载的那份）。装上后划掉这条。
- [x] **装上连点打断**（11-10，踩坑第 26 条）：11-10 04:46 装上（见「部署记录」）。下面是当时的装法，以后再装照这个。只动台前调度脚本的 `Stage.qml`（重新加载），外加测试剧本。装法（root，在平板上；先看状态页没在测量，先跟作者说一声、确认没在用平板；装和重新加载分两步）：
  1. 比镜像：`/usr/local/src/y700-stage/y700-stage/contents/ui/Stage.qml` 要是 `7a2b8c886ff7`（`44af433` 那版，11-10 改之前核对过；`Card.qml` `a63626d49e6d` 不动），`/usr/local/src/y700-gesture/tests/ts-scenarios/stage.sh` 要是 `d15a0e918d4e`。对不上就停。
  2. 旧的备份到 `/root/backup/stage-retarget-1110-<时间>/`，放进新的 `Stage.qml` 和 `stage.sh`，放完比 sha256。
  3. `sh /usr/local/src/y700-stage/install.sh`：`INSTALL_OK build <新 id>`，日志 `loaded, on`（作者开着时）、`strip shown`，没有 QML 报错。重新加载时背景层和圆角先撤一下；当前窗口上舞台，其他应用各成一张卡，原来的一对会拆开。
  4. 体检；拿装着的版本跑 ts-bed 的 `stage.sh`（`TSBED_SCRIPTS=/usr/local/src/y700-stage/y700-stage`，`ts-bed.sh` 用仓库里拷到 `/tmp` 的那份，踩坑第 25 条），`TSBED_OK`。
  5. 写「部署记录」，划掉这条，请作者做「要作者在真机上做的」第 19 条，提交。
- [x] **圆角边上的描边**：11-10 作者定「不用管」，挪到「有意不做」。
- [x] ~~yuv709 垫片的加载器死锁（踩坑第 17 条）~~：11-09 修好、测过，03:03 作者点头后装上（见踩坑 17）；回滚见开发日志（未公开）「视频硬解」里「11-09 修：加载器死锁」。

## 有意不做

- **打断后不保留速度**（11-10）：中途改目标时副本从当前位置起飞，但重新走一整条 `500 ms × k` 的缓动曲线，从静止加速，没有弹簧，也不接着原来的速度。连点得快的时候，每一下都是一次新的 0.5 秒。要接住速度得把 `cMain` 换成弹簧（自己积分），每帧多算一遍所有副本，先不做。
- **打断时有真露着的窗口要收，空中的副本停 50 ms**（`flyHold`）：让副本先盖住窗口一帧再收，不然会闪一下窗口。只发生在打断的那一刻舞台上还有真窗口的时候（比如落地后 60 ms 的 `flyPark` 里又点了），连点时一般全是 `early`，不停。
- **别处激活的组，副本在空中的话直接出现在舞台上**：从 Dock、多任务卡片切到一组，而这组的副本正在飞，`flyOut` 只飞下台的那组，没有 `o.stay`，这组的副本不画，窗口直接出来。少见，不值得为它再算一条路线。
- **飞行中被挤出卡片列的组，副本直接消失**：第 5 组以后不显示，没有地方可飞。新开窗口时卡片列满 4 张才会碰到。
- **拖卡松手后马上又点，那张平的副本会一下变成带透视的**：松手那一下的副本是平的（`flat`），被打断后按普通副本算透视。副本还小（刚离开手指）的时候，右边会一下矮 10 %；已经长到接近舞台大小时透视本来就没了，看不出来。只在松手后 0.5 秒内又点卡才会碰到。
- **关掉台前调度（`stop()`）还是先落地**：关掉时所有窗口要回原样，没有「接着飞」的去处。
- **圆角外面那圈 Breeze 描边不处理**（11-10 作者定「不用管」）：Breeze 给服务端装饰的窗口画的那圈 1 px 描边（深色主题里是浅色线）属于阴影，阴影不被圆角裁，所以圆角外面可能还能看到一圈接近方角的细线（测试床截图里能看出来）。当时给的另外两种办法没做：舞台上的窗口去掉标题栏（`setNoBorder`）；全局关掉 Breeze 的描边（`breezerc` `OutlineIntensity=OutlineOff`）。
- **新卡不从上方滑入**：卡片列表只有重排（350 ms）和关掉时的缩小淡出（400 ms），新出现的卡直接出现。
- **卡片上剩下的黑边**（11-10 改写；以前这条是「从没上过舞台的窗口有黑边」，现在卡片列里的窗口都摆进槽位了，见踩坑第 27 条）。还会露出 `#111` 底色的情况：
  - 不肯变成槽位大小的应用：有固定大小、固定比例或最小尺寸比槽位大的。脚本问 3 次就不再问，卡片上按它自己的比例画。
  - 全屏的窗口不摆（它在卡片里是屏幕的比例，1600×1002 对 1364×946，上下各约 6 px 的边）。
  - 还没变成槽位大小的窗口头一次拍照的头几帧（刚打开台前调度时没上舞台的那些、后台新开的窗口）：它要等拍照带来的帧回调才按槽位大小画，中间可能看到一下旧比例。测试床截图里没抓到过。
  - 不做「裁切填满」：`WindowThumbnail` 没有这种模式，自己裁要多一层离屏渲染；把窗口摆对比裁画面干净。
- **打开台前调度时，没上舞台的窗口也被取消最大化、摆进槽位**（11-10，同上）：以前它们留着原来的大小，上舞台时才摆。关掉时照几何账还原，结果一样；区别只在开着的时候，别的工具（多任务卡片的缩略图、`kscreen-doctor` 之类）看到的是槽位大小。
- **shellbar 在台前调度开着时重启，背景层要等下次换组才回来**：`Stage.qml` 的 `tellShell` 记着上次发过的值（`sentStage`），只在换组（`changed()`）时清掉重发；shellbar 那边 `setStage` 不导出属性，脚本也不监视 shellbar 的进程。所以 shellbar 重启后，在下一次点卡、新开窗口、回桌面之前，背景层不在、状态栏是黑条。shellbar 平时不重启（只有装新版、崩了被 systemd 拉起时），不值得多一路监视。11-09 装 shellbar 时撞上过一次，手动补发了（见「部署记录」）。要更快跟上，可以在 `activated` 里也清 `sentStage`。
- **背景层只读第一个桌面容器的壁纸、只在打开时读一次**：壁纸换了要关掉再开（或者下次回到舞台时）才跟上；不监视文件。多屏、每屏不同壁纸、幻灯片壁纸都不管。
- **不用 MSAA**：超采样已经够平滑，见踩坑第 17 条。
- **卡片上的画面不跟着应用更新**（11-09，踩坑第 24 条）：只在收进卡片列后（或卡片变了形状后）拍一张。应用在后台变了（来了新消息、视频播到哪了），卡上还是收起时那一帧，点回来才看到新的。要实时更新，就得让应用一直在后台画，那正是要省掉的电。
- **拍照没赶上，卡片是黑的**：KWin 只在合成屏幕帧时往缩略图里填画面。要是那 0.6 秒里一帧都没填上（熄屏时有应用自己开了新窗口；窗口还没画出第一帧），卡片就停在 `#111` 底色上，直到卡里的窗口变了或卡片变了形状。测试床里没见过。要补得在拍完后读像素看是不是全黑，多一次 GPU 回读，先不做。
- **体检不查离屏渲染**：KWin 没有接口能问哪些窗口在离屏渲染。回归靠测试床 `stage.sh` 的 still 一步数帧。
- **换组后 1 秒内回桌面，Dock 要晚一点出来**（11-09，踩坑第 22 条）：`holdDock` 的 950 ms 里「0 个窗口露着」都不算回桌面，到点才算。所以点完卡马上底边快划回桌面，Dock 最多晚不到 1 秒出来。不在落地时提前解除，理由见踩坑第 22 条。
- **太高的窗口只是底边对齐，不跟着光标**（11-09，`fit()`）：Telegram 这种最矮高过键盘上面空间的应用，输入框贴着键盘顶，顶上（标题栏、聊天标题）伸出屏外。要看顶上就收起键盘。跟着输入光标挪窗口要知道光标在哪（输入法协议里有，脚本拿不到），不值。
- **浮动键盘什么都不变**：浮动的屏幕键盘没有 `exclusive zone`，工作区不变，舞台不重摆，键盘可能盖住输入框；拖开它就行。
- **键盘弹起时卡片列不跟着矮的舞台重新排**：卡片列按舞台中线居中，舞台变矮时它算到新中线去，但键盘本来就是挡板，那时卡片列藏着，看不到。
- **测试床的占位条不是真键盘**：`kbzone.py` 只做了 `exclusive zone`，类名不是 `y700-osk`，台前调度不把它当挡板（卡片列不藏）。「卡片列藏 + 工作区变」的组合 11-10 起在 `stagestrip.sh` 的 `cards` 一步里用控制中心当挡板拼出来了；但两件事的先后是剧本定的（先藏、再变、再变回、再出来），真键盘收起时哪个先到没量过，见「没验证的」。
- **几何账不分横竖屏**：设计稿第一版写的是两份。但竖屏是暂停，窗口最大化，转回横屏时按舞台重新摆，账本里只需要「进舞台前」那一份，关掉时还原用。
- **外接显示器不管**：只收平板自己屏上的窗口，外屏上的窗口照原样。外屏没有触摸，多任务卡片也不管外屏。
- **组不跨重新登录保存**：重登以后窗口的 id 全变了，对不上号。
- **一组最多 2 个窗口**：1364 宽分三份每份只有 450，太窄（作者选的推荐）。
- **「关闭」不二次确认**：和窗口的 ×、多任务卡片上划一样，没保存的程序自己会问。只是关窗口，不像多任务卡片那样连程序一起退。
- **不做从 Dock 长按拖应用上舞台、拉出卡片列的边缘手势、多任务卡片里按组显示、甩窗半屏**：理由见 `RESEARCH.md` 第 6 节。
- **点卡片拿不到 GPU 触摸加速**：加速只认屏幕边缘起手（「多任务卡片」一节的触摸 boost），点卡不是从边缘起手。换组那 500 ms 的帧时间没测。不够顺再让加速规则也认左边 220 px。
- **快捷键 `y700-home-minimize` 会拆散一对**：它只最小化当前窗口，按规则就是「用户最小化了一个」。G9 主页键双击现在是开多任务卡片，不走它，平时碰不到。
- **防抢回可能误伤**：换组后 1 秒内，用户真想切回刚下台的那组（比如很快地在多任务卡片里点它），会被拒一次，要再点一次。
- **没装时点磁贴只写 `Active`**：调一个不存在的快捷键，busctl 也是静默成功，磁贴照样变亮，什么都不发生。体检在没装时不出这一项。
- **性能浮层那块磁贴变窄了**：从 163 宽变成 104 宽。「浮层·帧数功耗」是最长的标题，估计约 98 px（没实测这个状态），放得下但很紧。
- （第一版的「dock 和条带可能叠在一起」不存在了：dock 只在桌面上出来，第二版桌面上卡片列是收起的。第一版的「飞行时缩略图没有圆角」也改了：飞行的副本带圆角和阴影。）

## 周期性义务

- [ ] `kwin-wayland` 升级后：圆角特效由 apt 钩子自动重编（`journalctl -t y700-stagecorners` 看结果），**重新登录一次**新的才加载；体检「台前调度」那行会报版本对不上或开着没加载。钩子没编成（比如 `kwin-dev` 没跟着升级，它会记一行「kwin-dev does not match」）就手动 `sh /usr/local/src/y700-stage/install.sh`；`kwin-dev` 要作者点头再装。
- [ ] `kwin-wayland`、`plasma-mobile` 或 Qt 升级后：先跑体检看「台前调度」那行，再按上面「测试」跑一遍 `stage.sh`（不动屏幕）。脚本用到的 KWin 接口（`stackingOrder`、`clientArea`、`WindowThumbnail`、`ShortcutHandler`、`minimizedChanged`、`maximizedChanged`、`setMaximize`、`frameGeometry`，特效的 `setBorderRadius`、`findWindow`）都在里面测。不过就先关掉磁贴（或 `install.sh --remove`），再对照上游改。
- [ ] 新加用 `K.WindowThumbnail` 的地方（台前调度、多任务卡片、shellbar 都算）：先想清楚它存在多久，常驻的界面里只能短暂存在（踩坑第 24 条）；台前调度里的跑 `stage.sh`，still 一步要 0 帧左右。
- [ ] 改了 `Stage.qml`、`Card.qml` 或 `kwin-corners/`：先跑 `stage.sh`，改了交互就加或改剧本的步骤；过了再 `sh /usr/local/src/y700-stage/install.sh`（脚本不用重登；特效第二次装要重登）。装之前先比镜像和上一次提交的 hash。看到 `INSTALL_OK` 后跑体检。
- [ ] 改了 shellbar 的 `Backdrop.qml`、`StatusBar.qml`、`setStage`、`holdDock`，或者 `Main.qml` 的 `recompute()`（`onDesktop` 怎么算）：跑 `stageback.sh` 和 `stagestrip.sh`，再跑 `look.sh`、`dock-gone.sh`（Dock 平时的显隐）。
- [ ] 改了 `Stage.qml` 里和 shellbar 联动的地方（`blocker()`、`overStage()`、`tellShell()`、`holdCall` / `holdMs`、飞行的时长），或者 shellbar 新加了大窗口、改了哪个窗口在哪一层（`src/main.cpp` 的 `layer(...)`）：跑 `stagestrip.sh`（`SB_STAGE` 指向候选脚本）。
- [ ] 屏幕键盘 `y700-osk` 改了停靠时的高度或 `exclusive zone`：`stagestrip.sh` 里 `kbzone.py 389` 的 389 跟着改，再跑一遍。
- [ ] 改了控制中心拇指栏第 6 行、`Tile.qml` 或测试台之后：熄屏时跑 `stagetile.sh`，再跑 `acttile.sh`（第 7、8 行的坐标在里面）。
- [ ] 多任务卡片的 `finishOpen` 或 `minimizeAll` 改了（`linux/gesture/taskswitcher/ui/TaskSwitcher.qml`）：跑 `stage.sh`，`switcher` 和 `burst` 两步靠的就是它们现在的顺序（踩坑第 7 条、实现要点第 3 种）。
- [ ] 受保护窗口名单改了（多任务卡片 `stack.js` 的 `guarded()`）：`Stage.qml` 的 `guarded()` 照着改，两边要一样。
- [ ] 有东西开始给窗口发布图标位置（`iconGeometry` 不再是 0×0）：看 squash 最小化特效会不会和飞行叠上（踩坑第 13 条）。

## 没验证的

- **真手指**：点卡、拖卡、长按，只用测试床的假手指测过。
- **连点、打断在真机上**（11-10）：作者真手指试过「顺」（第 19 条）。没单独试过的：拖卡松手后马上点另一张卡、飞行中新开窗口或从 Dock 切组时的打断，只在测试床和代码里走过。
- **真应用**：Chrome、Claude、Telegram、Dolphin 在 676 宽下好不好用；应用自己恢复最大化的补摆（`refit`）只在测试应用上见过。
- **圆角在真应用上**：客户端自己画装饰的应用（GTK、Chrome）的阴影会不会被裁、圆角外面有没有方角的影子（Breeze 描边那圈线 11-10 作者定不管）。
- **从 Dock、桌面图标点一个卡片列里的应用、或者在多任务卡片里点卡片列里那组的应用** → 切到那组（`activated`）：测试床里用脚本激活窗口模拟的，没走 Dock。
- **真正的回桌面手势和控制中心「显示桌面」**：测试床里是用脚本同时最小化两个窗口模拟的。
- **真机转屏**：只在测试床里用 `kscreen-doctor` 转过。
- **背景层在真会话里**：11-09 装上，日志确认读到了壁纸，**画面没看过**（真会话不截图）；作者的壁纸 4K 级 PNG 解码 + 模糊要多久、第一次打开会不会晚一下出来，没量。
- **全部应用页盖在舞台上时卡片列让不让**：测试床里没打开过全部应用页（见「测试」`stagestrip.sh` 最后一条），只量了叠放顺序。
- **帧时间和功耗**：换组的帧时间、超采样层的开销没测。开着时的功耗：11-09 作者报改之前 6–8 W（踩坑第 24 条）；改成静止图后真机自测对照过（开 1.30 W、关 1.45 W，见「部署记录」11:04）。那次是亮度 800、静止画面、Quiet 在台上，没量作者自己用着时（视频在台上、频繁换组）的功耗。
- **拍照没赶上的黑卡**（「有意不做」）：熄屏时有应用自己开新窗口的情况没试过。
- **真机上卡片的静止图**：拍下来的画面在作者屏上对不对、键盘收起后卡片有没有重拍，都只在测试床里看过。
- **键盘收起后卡片的黑边**（11-10 修的，`7dc25d9`，05:39 装上了；作者当天真机试过「没黑边了」，下面几条细的没单独验）：
  - 真机上只看了日志（一次收起、一次弹起，原文在「部署记录」）：键盘弹着的时候，卡片列里的 Dolphin、Telegram、Chrome 确实被 KWin 压进了键盘上方的工作区（都在 `220,28`，高 585、703、586），根因在真应用上对得上；键盘收起后三个都回到了 `220,40,1364,946`。卡片上实际画出来的样子我没看（真屏没截图），作者看过说没黑边，是哪几个应用的卡片没问；日志里没见过 Claude 和 wiliwili（那时不在卡片列里）。不听的应用问 3 次后保持原样，卡片上还会有边。
  - Chrome 最小化着的时候不马上听：键盘弹着时要它去矮槽位，32 秒后还是原来的大小（多半是踩坑第 27 条说的，没人要它画它就不提交）；键盘收起后要它回整槽位，19 秒内到了，哪一刻到的日志里看不出。Telegram 在矮槽位里站成 703 高，不是要的 689；那时卡片列被键盘挡着，看不到。
  - 真键盘收起时的先后：看到的那一次，日志里先是摆槽位的请求、后是 `strip shown`，在同一秒，和测试床一样是工作区先变回、卡片列后出来。只有一个样本。要是哪次反过来，卡片会先按矮舞台拍一张、再变高重拍，能看到约半秒卡片从矮变高的活画面（不是黑边）。
  - 真键盘弹起时多问了一轮：KWin 先把卡片列里的窗口压矮，几何变化的钩子就按旧工作区又要了一次整槽位（日志里的 `#2`），不到 1 秒后工作区变了才要矮槽位。两轮都在卡片列被挡着的时候，看不到，没改；测试床里没出现过（那里工作区先变）。
  - 卡片多拍的那几拍（每拍 0.6 秒活缩略图）对功耗的影响没在真机量。测试床里收进卡片的动画应用拍完后 3 秒 0 帧。
  - 打开台前调度那一下，所有没上舞台的窗口都被取消最大化摆进槽位：应用多的时候会不会卡一下，没量。
- **真的屏幕键盘**（11-09 修的）：测试床里用 `kbzone.py` 代替，`y700-osk` 本身没进过测试床；真键盘弹起时 KWin 先压窗口、脚本再重摆，中间会不会跳一下没看过。真应用（Chrome、Claude、Telegram）重摆后自己会不会再改大小、Telegram 伸出屏外的那截是不是标题栏，都没看过。
- **真会话里换组时 Dock 不闪**：只在测试床里量过（Dock 窗口没映射）。

## 要作者在真机上做的

1. 下拉控制中心，点「台前调度」：磁贴变蓝，帘子不收。收起帘子后，当前应用在右边舞台、四角是圆的，其他应用都收起来，左边出透视的卡片列。
   - 背景是你的壁纸模糊压暗（不是桌面图标），顶上状态栏变透明、字还在。11-09 装背景层时台前调度已经开着，要是现在看到的是黑条状态栏，先关掉再开一次（或点一下卡）再看。
2. 点几张卡来回换：飞行动画顺不顺、有没有闪、卡片的斜边有没有锯齿、图标位置对不对。
3. 把一张单窗口的卡分别拖到舞台左半、右半：落点卡上的字对不对，松手后两个窗口各占一半、中间有缝。左右手各试一遍。
4. 长按一张两窗口的卡：卡片放大、出「拆开」「关闭」；点「拆开」变两张卡。长按单窗口的卡只有「关闭」，点别处菜单收起。
5. 点舞台上一个窗口标题栏的最小化：只它下台，另一个占满。
6. 底边快划回桌面：舞台清空、卡片列滑走；在 Dock 上点刚才那组的应用：那一组整组回来，卡片列滑回来。
7. 底边上划停住出多任务卡片：点舞台上的一个应用，一对还在；点卡片列里的一个应用，切到它那组。
8. 开一个新应用：新应用上台。
9. 开一个 Steam 游戏、LIVI：卡片列让开，游戏没被缩放、是方角；退出后卡片列回来。
10. 弹出屏幕键盘、打开通知中心：卡片列藏起来，关掉后回来。
11. 转竖屏：卡片列藏、窗口整屏方角；转回横屏：刚才的布局和圆角回来。
12. ~~看看圆角外面有没有一圈方角的细线，告诉我要哪种处理。~~ **11-10 作者定「不用管」**（见「有意不做」）。
13. 左右边缘返回手势在开着时还正常。
14. （11-09 修了以后）点卡、拖卡换组：底下的 Dock 不再闪出来。
15. 在 Chrome 或 Claude 里点输入框弹出停靠的键盘：窗口缩到键盘上面；收起键盘：窗口回到原来的高度，不再停在半屏。
16. 在 Telegram 里点输入框：输入框贴着键盘顶、整条能看到（顶上的标题会伸出屏外）；收起键盘回原样。
17. 再点磁贴关掉：舞台上的窗口回到打开前的大小、方角；收起的那些点开时也回到原样。
18. （11-09 改了以后）卡片列里的应用不再在后台画：卡片上是收起那一刻的画面，不会动，点回来才更新。功耗我 11-09 11:05 自己开关对照量过了（开 1.30 W、关 1.45 W）；作者日常用的时候看一眼状态页，开着台前调度不该再到 6–8 W，CPU 不该再到 25 %。
19. ~~（11-10 改了以后）~~ **11-10 作者试过：「试过了，顺」。** 在卡片列上快速连点：两张卡来回点、同一张卡连点两下，每一下都马上切过去，不用等动画播完；飞到一半再点，窗口从半路直接掉头，不先跳到终点。拖卡松手后马上点另一张卡也试一下。
20. ~~（11-10 改了，05:39 装上了）~~ **11-10 作者试过：「没黑边了」。** 开着台前调度、左边有两三张卡的时候，在舞台上的应用里点输入框弹出停靠键盘，再收起：左边的卡片回来时上下没有黑边，画面和键盘弹出前一样满。留意卡片回来的那一下有没有闪（先矮后高，或者先有黑边再没有）。再看一眼：刚打开台前调度时，一直没点开过的那些应用的卡片也没有黑边。哪个应用的卡片还有边，告诉我是哪个。

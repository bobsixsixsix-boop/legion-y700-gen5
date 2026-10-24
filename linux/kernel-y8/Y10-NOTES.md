# 内核 y10 = y9 + 上游 t51 的 0131/0132 + 1043 `allow_system_off`（树外补丁，2026-10-16）

> 2026-10-16 03:0x 改动：y10 同时收进上游 kernel-t51 新增的两个补丁（README「上游 t51」一节）：**0131** drm/msm/dpu 只在 CRTC 缺 DSPP 时才为色彩管理强制 modeset（夜间色温开关不再黑屏一下），**0132** battmgr 暴露快充电流上限 `constant_charge_current[_max]`（helper 0.4.2 的「旁路保持 9 V」依赖它；**别写 0**，固件会把 PD 合同掉到 5 V）。两者原件与 y700 版放在 `t51/`：0131 原样能打上；0132 的 `sm8350_bat_prop_map` hunk 与树里 y3 的 battmgr I×V 补丁撞上下文，`t51/0132-*.patch` 是在「HEAD(0130) → 0132」与「HEAD → y 栈」三方合并后重生成的同内容补丁，原件留作 `*.upstream`。series 顺序：…1041, 1042, **0131, 0132**, 1043（放在 y9 的栈顶 1042 之后，这样 y9 树上的进度检测恰好只打这三个）。另外把此前 `kbuild-y10.sh` 里 CMDLINE 加 `allow_system_off=0` 的写法改掉了——与下文「有意不做·不改 cmdline」一致（之前脚本与本文互相矛盾：脚本断言必须有、本文说必须没有）。

> 写给下一个接盘者。背景与裁决在 [linux/power/cx-collapse/RESEARCH.md](../power/cx-collapse/RESEARCH.md) §3.3（flag 方案）、实验用法在 [PROTOCOL.md](../power/cx-collapse/PROTOCOL.md) §6 与 §3 E3。
> 本机（Win11）只有上游源码副本、没有工具链、没碰平板：补丁用 `git apply --check` 对"v7.3-rc4 + 0106 + 0118"验证过能打上、对纯 v7.3-rc4 和"只有 0106"被拒（即它确实依赖 0118 的上下文）。**没有编译过**（已过时：10-16 03:13 编译、03:27 keep，60/60 PASS；y12 继承本栈，见 README「内核 y10/y12」），第一次 `kbuild-y10.sh` 若报编译错，先看 §"未验证"。
> 2026-10-16 独立审阅（重新从 GitHub 拉 v7.3-rc4 源码、重建 rc4+0106+0118 树、逐行核对 core.c/params.c/rpmh-rsc.c/dt_idle_genpd.c 的引用）：补丁逻辑与行号均成立；审阅改了三处——ops 补 `.flags = KERNEL_PARAM_OPS_FL_NOARG`（裸 cmdline token 等于 `=1`，与 0118 的 bool 一致；此前会被 parse_one 以 -EINVAL 拒掉）、提交信息补写 `core.c:966-969` 同一检查里 7.3 新加的 `genpd->stay_on` 为何已被清（provider sync_state）及无屏障的顺序论证、`dev_pm_genpd_rpm_always_on` 的行号 992-994 → 993-995。补丁用 `git format-patch` 重生成（+97/−2），三种树状态重新验证。

## 文件

| 文件 | 作用 |
|---|---|
| `1043-cpuidle-psci-domain-allow_system_off.patch` | 补丁本体（git format-patch 格式，`git apply` 直接吃；提交信息写了为什么、改了什么、怎么切、怎么验证） |
| `kbuild-y10.sh` | 由 `kbuild-y9.sh` 派生：`NAME=-tb323fu-t49-y10`、`OUT=/usr/local/src/y700-kernel-y10`、`MODS=/usr/local/src/y700-mods-y10`、series = y9 的 10 个 + `/root/t51-patches/{0131,0132}-*.patch` + `/root/y8-patches/1043-*.patch`（13 个）；**CMDLINE 与 y9 完全相同**（脚本见到 `allow_system_off` 字样直接退出）；打完补丁后 grep 断言 0131（dpu_crtc 新注释在、msm_atomic 的 FIXME 循环没了）、0132（`qcom_battmgr_set_charge_current_limit`、`BATT_CHG_CTRL_LIM_MAX` 映射）、1043 真在树里、默认 N、RT 保护、0106/0118 原样、没用 genpd 锁；配置检查多两条（`ARM_PSCI_CPUIDLE_DOMAIN=y`、`PREEMPT_RT` 不得为 y）；镜像里断言参数名字符串 `cpuidle_psci_domain.allow_system_off` 与报告格式串在 |
| `t51/0131-drm-msm-dpu-*.patch` | 上游 kernel-t51 原件（sha256 前 16 位 `f4094c5ae87118e0`），对 y9 树 `git apply --check` 通过 |
| `t51/0132-power-supply-qcom_battmgr-*.patch` / `*.upstream` | y700 rebase 版（内容与原件相同、只调上下文）/ 上游原件（`851c1884bc15b107`，对 y9 树 hunk @452 失败） |
| `y10-selfcheck.sh [TREE]` | 不编译、不执行：对补丁文件做 grep 断言（默认 N、0644、RT early return、0106 的行没被删、没碰 fragment/CMDLINE、只改一个文件、上下文来自 0118 后的文件）；TREE 存在时再对源码树断言，并用 git 判断"已打上（reverse-check）"或"能干净打上" |
| `y10-verify.sh` | 首次启动后跑（root）：y9 的全部回归项 + 1043 项（见下"怎么验证"）；默认做一次零风险的写 1 / 写 0 切换测试，`Y10_NO_TOGGLE=1` 跳过；`allow_cluster_off` 不是 N 时拒绝做切换 |

## 补丁做了什么（`drivers/cpuidle/cpuidle-psci-domain.c`，+97/−2，只此一文件）

- 新模块参数 `allow_system_off`（`static bool`，**默认 N**），`module_param_cb(..., 0644)` → `/sys/module/cpuidle_psci_domain/parameters/allow_system_off`（驱动是内建的，模块名 `cpuidle_psci_domain`，与 0118 的 `allow_cluster_off` 同目录）。ops 带 `KERNEL_PARAM_OPS_FL_NOARG`（与 `param_ops_bool` 相同）：cmdline 上裸写 `cpuidle_psci_domain.allow_system_off` 等于 `=1`。
- `psci_pd_init()`：0106 的 `of_machine_is_compatible("lenovo,baldur") && of_node_name_eq(np, "power-domain-system")` 判定**原样保留**，probe 时照旧 `pd->flags |= GENPD_FLAG_RPM_ALWAYS_ON`，另外把这个 genpd 记进 `psci_system_pd` 并调一次 `psci_system_pd_apply()`（cmdline 若给了 `allow_system_off=1` 在这里生效；我们不给）。域注册成功后（`pm_genpd_init` + `of_genpd_add_provider_simple` 都过了）打一行 dmesg。
- `allow_system_off_set()`：`param_set_bool` 后调 `psci_system_pd_apply()`——写 1 清掉系统域的 `GENPD_FLAG_RPM_ALWAYS_ON`（= 上游行为，`genpd_power_off()` 在 `core.c:966-969` 不再早退，运行时可进 ss3）、写 0 置回（= 0106）；值变了就打一行 dmesg。
- `psci_system_pd_apply()` 开头 `if (IS_ENABLED(CONFIG_PREEMPT_RT)) return;`——RT 给所有 CPU 域设的 flag 不动；此时参数只是被记下，报告行仍说 "in system suspend only"。
- 错误路径与 `psci_pd_remove()` 清掉指针。
- **不加锁**（提交信息有完整论证）：genpd 锁没导出；`pm_genpd_init` 之后只有这里写该域的 `flags`；参数写入被 `kernel_param` 锁串行化；单 bit RMW 对 `unsigned int` 的纯读不会撕裂；写者所在 CPU 的域链必为 on，系统域不可能正在下电中途；清掉 flag 后"下一次最后一个簇下电"即生效——`genpd_power_off(system)` 过 966-969 的检查、`apps_rsc` 设备算 suspended（`rpmh_rsc_pd_attach` 只 `devm_pm_runtime_enable` 不 get）、`pm_domain_cpu_gov` 裁决、`_genpd_power_off` 走 PRE_OFF → `rpmh_flush` → `psci_pd_power_off`。966-969 同一检查里还有 7.3 新加的 `genpd->stay_on`（`pm_genpd_init(…, is_off=false)` 置 true）：各 PSCI 域的 provider 设备（`genpd_provider_bus_type`，`GENPD_SYNC_STATE_SIMPLE`）的 sync_state 在启动时把它清掉并试一次下电，`fw_devlink.sync_state=timeout` 保证最迟 late_initcall_sync；y9 上簇域 Rejected > 0 就是它已清的证据，系统域走同一条路。顺序：系统域要下电必先经过写者 CPU 自己进 idle 时拿的 CPU 域/簇域/系统域自旋锁，所以 flag 的新值不需要显式屏障就排在任何可能据此裁决的下电尝试之前。
- s2idle 两种设置都一样：`genpd_sync_power_off()`（`core.c:1404-1410`）只看 `GENPD_FLAG_ALWAYS_ON`。

## 默认、切换、验证（dmesg / sysfs 长什么样）

| 场景 | 看到什么 |
|---|---|
| 开机（默认 N） | `dmesg`: `CPUidle PSCI: power-domain-system: allow_system_off=N, system domain state in system suspend only (lenovo,baldur quirk, boot)`，且仍有 `CPUidle PSCI: Initialized CPU PM domain topology using OSI mode`；`cat …/allow_system_off` → `N`；`stat -c %a` → `644`；`/sys/kernel/debug/pm_genpd/power-domain-system/idle_states` 第 2 行 Usage 0 Rejected 0（与 y9/0106 相同；只有 s2idle 会让 Usage 动） |
| `echo 1 > …/allow_system_off` | `dmesg` 多一行 `… allow_system_off=Y, system domain state in runtime idle too (parameter written)`；`cat` → `Y`。**只要 `allow_cluster_off` 还是 N，别的什么都不会变**（簇不下电，系统域到不了）——这就是 `y10-verify.sh` 切换测试零风险的理由 |
| `echo 0` | `… allow_system_off=N, system domain state in system suspend only (parameter written)` |
| 真正放开（E3，`cx-exp.sh`） | `aco=1` + `aso=1` 后 `power-domain-system` Usage 增长、`qcom_stats/apss` Count 增长；cxsd/aosd/ddr 看 E3a/b/c 分级。`cx-exp.sh` 的 EXIT trap 把两者写回 0；复位后两者也都是 N（1043 默认 N，0118 靠 cmdline） |
| PREEMPT_RT 内核（不是我们的配置） | 写 1 后 `cat` 显示 Y，但报告行仍是 "in system suspend only"，flag 没动 |

## 打补丁顺序与上下文

- 1043 只改 `drivers/cpuidle/cpuidle-psci-domain.c`，而上游 **0106**（baldur 系统域 `RPM_ALWAYS_ON`）与 **0118**（`allow_cluster_off`）也改它。1043 的五个 hunk 的上下文取自**0118 打过之后**的文件：`@@ -37` 接在 0118 的 `MODULE_PARM_DESC(allow_cluster_off, …)` 后面，`@@ -94` 把 0106 的 `of_node_name_eq(np, "power-domain-system"))` 行改写成带 `{` 的块，`@@ -114`/`-122` 在 `psci_pd_init` 尾部与错误路径，`@@ -138` 在 `psci_pd_remove`。所以它**只能在 0106 和 0118 之后**打（本机树 t47 起就含 0001-0130，天然满足）；对纯 v7.3-rc4 或只有 0106 的树 `git apply --check` 被拒（已验证）。
- 与我们自己的 1041（ath12k）、1042（memlat）无交集；`kbuild-y10.sh` 的 series 顺序：0540, 0620, 0621, 0622, 1030, 1031, 1032, 1033, 1041, 1042, **0131, 0132（t51）**, **1043**。series 检测照旧"最新能反向打上的补丁 = 树的进度"，1043 打上后 `git apply --reverse --check` 通过（已验证）。
- 升级基底时的地雷（RESEARCH §2.7）：linux-next 的 `pm_genpd_init(pd, pd_gov, use_osi)` 让"always-on 域初始为 off"返回 -EINVAL，0106 与 1043 都要改写。

## 上机步骤（照 y9 的流程）

```sh
# Win11 侧：先 scp 再 bash（PowerShell 内联引号会坏；Windows 上写的文件要确认是 LF）
scp linux/kernel-y8/1043-cpuidle-psci-domain-allow_system_off.patch root@<tablet>:/root/y8-patches/
scp linux/kernel-y8/t51/0131-*.patch linux/kernel-y8/t51/0132-*.patch root@<tablet>:/root/t51-patches/   # 不是 *.upstream
scp linux/kernel-y8/kbuild-y10.sh linux/kernel-y8/y10-selfcheck.sh linux/kernel-y8/y10-verify.sh root@<tablet>:/root/
ssh root@<tablet> 'bash /root/y10-selfcheck.sh'            # 期望：补丁层全 PASS；树层 "1043 not applied yet" + "applies cleanly" PASS
ssh root@<tablet> 'bash /root/kbuild-y10.sh; tail -3 /root/y700-kernel-y10.log'   # 约 16 分钟，末行 KFULL_OK
ssh root@<tablet> 'bash /root/y10-selfcheck.sh'            # 现在树层应报 "1043 is in the tree" 且 reverse-check PASS
# 安装为试用内核（与 y8/y9 相同：tb323fu-ctl kernel install-local … --trial），作者重启；起不来再重启一次自动回 y9
ssh root@<tablet> 'bash /root/y10-verify.sh'               # 期望 ALL PASS（含切换测试）；任何 FAIL → kernel rollback
```

通过后：`kernel keep`，然后才是 PROTOCOL §3 的 E0 → E1 → … → E3（E3 才第一次真正把 `aso=1` 与 `aco=1` 同时打开，走 `cx-exp.sh`）。

## 有意不做（及原因）

- **不改 cmdline**：RESEARCH §3.3 第 (3) 条写"CMDLINE 加 `cpuidle_psci_domain.allow_system_off=0`"，这里不采用——默认 N 已在 C 里，是真正的 fail-safe；加 cmdline 片段反而让人以为旋钮依赖 cmdline（0118 的 `allow_cluster_off=0` 仍靠 cmdline，那是上游的选择，不动）。`kbuild-y10.sh` 对 CMDLINE 里出现 `allow_system_off` 直接报错。
- **不采用 -EBUSY 版**（PROTOCOL 原 §6）：会在每次最后一个簇下电时先 PRE_OFF→`rpmh_flush` 再被拒、Rejected++，不是 0106 基线，A/B 会掺混杂变量。
- **不采用草稿的"无 `power-domains` 属性的根域"判定**（早先的草稿 `y10-1043-…diff` 用它取代 `of_machine_is_compatible`）：等价于把 0106 从 baldur 专属改成所有 OSI 机器，且对 baldur-kexec 配置片段（无该参数）意味着默认放开 ss3；要求保留 0106 的判定与 probe 行为。草稿里被复用的：`psci_system_pd` 指针、`psci_system_pd_apply()`、`module_param_cb` 结构；被改掉的：默认值 true→N、新增 RT 早退、新增 dmesg 报告行、新增错误路径/remove 清指针、`WRITE_ONCE`。
- **不用 `dev_pm_genpd_rpm_always_on()`**（`core.c:752-766`，带 genpd 锁的现成接口）：它是按设备设 `rpm_always_on`，`genpd_power_off()` 在 `core.c:992-994` 同样在 governor 和 PRE_OFF 之前返回，效果等价；但要拿到挂在系统域上的消费者设备（只有 `apps_rsc`，归 rpmh-rsc.c 管），得改第二个驱动或按节点查设备，而且那不是 0106 的做法。
- **不做 y11（Oryon DC ZVA 勘误移植）**：RESEARCH §3.2 规定要 E2 阳性才做；本轮没有证据，不预做。
- **不改 `cx-exp.sh`/`y700-flightrec.py`**：它们读写的路径 `/sys/module/cpuidle_psci_domain/parameters/allow_system_off` 与 1043 一致，`aso=0` 时系统域 Usage/Rejected 恒 0 的判据与 PROTOCOL §6 新写法一致，无需改。

## 未验证（上机前要知道）

1. **没编译过**（已过时：10-16 03:13 编译、03:27 keep，60/60 PASS；y12 继承本栈，见 README「内核 y10/y12」）。代码只用了该文件已有的头文件（`moduleparam.h`、`pm_domain.h`、`kernel.h` 的 `IS_ENABLED`/`READ_ONCE`/`WRITE_ONCE`、`pr_info`）；`param_set_bool`/`param_get_bool`/`module_param_cb` 的签名对照了 v7.3-rc4 的 `include/linux/moduleparam.h`。括号/花括号配平检查过。若编译器报 `psci_system_pd_report` 未使用之类，不会——它在 init 与 set 两处都用。
2. 开机报告行出现的前提是 `pm_genpd_init` 成功且机器是 `lenovo,baldur`——若 dmesg 没有这一行而拓扑行有，说明 DT 根 compatible 变了或节点名不是 `power-domain-system`，0106 同样不会生效，要查 DT。
3. `y10-verify.sh` 的 `qcom_stats apss Count 0` 一项假定开机后没做过 s2idle；平时不做 s2idle，若做过则该项 FAIL 属预期。
4. 切换测试假设 `pr_info` 同步落 dmesg（是），计数用 `grep -cF` 做前后差，重复运行 verify 不受影响。

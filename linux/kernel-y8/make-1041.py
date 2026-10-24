#!/usr/bin/env python3
"""make-1041.py: apply the ath12k station power-save fix to the kernel tree and print the diff
(run on the tablet in /usr/local/src/linux-t47; linux/kernel-y8/1041-*.patch is its output).

Why: mac80211 reports a power-save change (BSS_CHANGED_PS, vif->cfg.ps) through the vif-level
callback vif_cfg_changed; ath12k only looks for it in its link-level bss_info_changed, which never
sees it. So the firmware stays in the mode set at vdev creation - power save DISABLED (CAM) - whatever
`iw ... power_save` says. Measured 2026-10-15 on the TB323FU (WCN7860): Wi-Fi associated and idle
cost 0.19 W of the 0.55 W screen-off total; rfkill off dropped it to 0.36 W. (An upstream fix for this
was posted and withdrawn over a throughput complaint in 2025; this is a minimal local version.)"""
import re, sys

P = "drivers/net/wireless/ath/ath12k/mac.c"
s = open(P).read()
# MODULE_VERSION shows up as /sys/module/ath12k/version when loaded: y700-checklist uses it to see
# that the running module is this build (ath12k has no srcversion)
VERSION = 'MODULE_VERSION("y700-1041");\n'
if "ath12k_mac_vif_cfg_ps" in s:
    if VERSION not in s:
        open(P, "a").write("\n" + VERSION); print("version tag added")
    else:
        print("already applied")
    sys.exit(0)
s = s.rstrip("\n") + "\n\n" + VERSION

# 1. forward declaration before vif_cfg_changed (setup_ps is defined after it)
anchor = "void ath12k_mac_op_vif_cfg_changed(struct ieee80211_hw *hw,\n\t\t\t\t   struct ieee80211_vif *vif,\n\t\t\t\t   u64 changed)\n{"
assert s.count(anchor) == 1, "vif_cfg_changed anchor"
decl = ("static void ath12k_mac_vif_setup_ps(struct ath12k_link_vif *arvif);\n\n"
        "/* BSS_CHANGED_PS arrives here (vif-level cfg), not in bss_info_changed: apply it to every link */\n"
        "static void ath12k_mac_vif_cfg_ps(struct ieee80211_hw *hw, struct ieee80211_vif *vif)\n"
        "{\n"
        "\tstruct ath12k_vif *ahvif = ath12k_vif_to_ahvif(vif);\n"
        "\tunsigned long links = ahvif->links_map;\n"
        "\tstruct ath12k_link_vif *arvif;\n"
        "\tu8 link_id;\n"
        "\n"
        "\tlockdep_assert_wiphy(hw->wiphy);\n"
        "\n"
        "\tif (vif->type != NL80211_IFTYPE_STATION)\n"
        "\t\treturn;\n"
        "\n"
        "\tahvif->ps = vif->cfg.ps;\n"
        "\tfor_each_set_bit(link_id, &links, IEEE80211_MLD_MAX_NUM_LINKS) {\n"
        "\t\tarvif = wiphy_dereference(hw->wiphy, ahvif->link[link_id]);\n"
        "\t\tif (!arvif || !arvif->ar || !arvif->ar->ab->hw_params->supports_sta_ps)\n"
        "\t\t\tcontinue;\n"
        "\t\tath12k_mac_vif_setup_ps(arvif);\n"
        "\t}\n"
        "}\n\n")
s = s.replace(anchor, decl + anchor, 1)

# 2. call it at the end of vif_cfg_changed (after the BSS_CHANGED_ASSOC block, so a fresh association
#    gets its PS mode right after ath12k_bss_assoc)
end = "\t\t\t} else {\n\t\t\t\tath12k_bss_disassoc(ar, arvif);\n\t\t\t}\n\t\t}\n\t}\n}\nEXPORT_SYMBOL(ath12k_mac_op_vif_cfg_changed);"
assert s.count(end) == 1, "vif_cfg_changed end anchor"
s = s.replace(end, end.replace("\t}\n}\nEXPORT_SYMBOL", "\t}\n\n\tif (changed & BSS_CHANGED_PS)\n\t\tath12k_mac_vif_cfg_ps(hw, vif);\n}\nEXPORT_SYMBOL"), 1)

open(P, "w").write(s)
print("applied")

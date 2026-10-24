#!/usr/bin/env python3
# Test-only, applied after txdbg-patch.py to the same COPY of ath12k: the driver stops offering mac80211 TX 802.3
# encapsulation offload, so every vif (AP and station) hands native-wifi frames to the hardware and EAPOL takes the
# plain TCL path - no TO_FW exception with HTT metadata, where the firmware drops the AP's 1/4s in the bad state.
# RX decap offload stays. Usage: noenc-patch.py <copy>/ath12k
import sys, pathlib
D = pathlib.Path(sys.argv[1])


def edit(rel, old, new):
    p = D / rel
    s = p.read_text()
    n = s.count(old)
    assert n == 1, f"{rel}: anchor found {n}x, want 1: {old[:70]!r}"
    p.write_text(s.replace(old, new))


edit("mac.c", 'MODULE_VERSION("y700-1041-txdbg");', 'MODULE_VERSION("y700-1041-txdbg-noenc");')
edit("mac.c", """	if (test_bit(WMI_TLV_SERVICE_ETH_OFFLOAD, ar->wmi->wmi_ab->svc_map)) {
		ieee80211_hw_set(hw, SUPPORTS_TX_ENCAP_OFFLOAD);
		ieee80211_hw_set(hw, SUPPORTS_RX_DECAP_OFFLOAD);
	}
""", """	if (test_bit(WMI_TLV_SERVICE_ETH_OFFLOAD, ar->wmi->wmi_ab->svc_map))
		ieee80211_hw_set(hw, SUPPORTS_RX_DECAP_OFFLOAD);
""")
print("noenc patch applied to", D)

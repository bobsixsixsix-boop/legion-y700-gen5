#!/usr/bin/env python3
# Test-only instrumentation of a COPY of ath12k (never the kernel tree): pr_info for every AP-vdev data TX
# descriptor, every AP-vdev TX completion (raw WBM words), HTT FW completion status, peer create/map/assign,
# vdev create, TX attach and bank profiles. Usage: txdbg-patch.py <copy>/ath12k
import sys, re, pathlib
D = pathlib.Path(sys.argv[1])

def edit(rel, old, new, count=1):
    p = D / rel
    s = p.read_text()
    n = s.count(old)
    assert n == count, f"{rel}: anchor found {n}x, want {count}: {old[:70]!r}"
    p.write_text(s.replace(old, new))

# version string, so modinfo tells the test module apart
edit("mac.c", 'MODULE_VERSION("y700-1041");', 'MODULE_VERSION("y700-1041-txdbg");')

edit("mac.c", """	dp_link_vif->pdev_idx = ar->pdev_idx;
""", """	dp_link_vif->pdev_idx = ar->pdev_idx;
	pr_info("y700dbg: vdev create %u type %u sub %u link %u addr %pM bssid %pM pdev %u lmac %u encap %u offl %x\\n",
		arvif->vdev_id, ahvif->vdev_type, ahvif->vdev_subtype, arvif->link_id, vif->addr,
		arvif->bssid, ar->pdev_idx, ar->lmac_id, ahvif->dp_vif.tx_encap_type, vif->offload_flags);
""")

edit("dp.c", """	dp_link_vif->bank_id = bank_id;
""", """	dp_link_vif->bank_id = bank_id;
	pr_info("y700dbg: tx attach vdev %u link %u pdev_id %u meta %08x bank %d search %u/%u ast %u/%u\\n",
		arvif->vdev_id, link_id, ar->pdev->pdev_id, dp_link_vif->tcl_metadata, bank_id,
		dp_link_vif->hal_addr_search_flags, dp_link_vif->search_type, dp_link_vif->ast_hash,
		dp_link_vif->ast_idx);
""")

edit("dp.c", """	if (configure_register)
		ath12k_hal_tx_configure_bank_register(ab,
						      bank_config, bank_id);
""", """	if (configure_register)
		ath12k_hal_tx_configure_bank_register(ab,
						      bank_config, bank_id);
	pr_info("y700dbg: bank %d config %08x users %u written %d\\n", bank_id, bank_config,
		dp->bank_profiles[bank_id].num_users, configure_register);
""")

edit("dp_peer.c", """	ath12k_dbg(ab, ATH12K_DBG_DP_HTT, "htt peer map vdev %d peer %pM id %d\\n",
		   vdev_id, mac_addr, peer_id);
""", """	ath12k_dbg(ab, ATH12K_DBG_DP_HTT, "htt peer map vdev %d peer %pM id %d\\n",
		   vdev_id, mac_addr, peer_id);
	pr_info("y700dbg: htt peer map vdev %u %pM id %u ast %u hw %u\\n", vdev_id, mac_addr, peer_id,
		ast_hash, hw_peer_id);
""")

edit("dp_peer.c", """void ath12k_dp_link_peer_unmap_event(struct ath12k_base *ab, u16 peer_id)
{
	struct ath12k_dp_link_peer *peer;
	struct ath12k_dp *dp = ath12k_ab_to_dp(ab);
""", """void ath12k_dp_link_peer_unmap_event(struct ath12k_base *ab, u16 peer_id)
{
	struct ath12k_dp_link_peer *peer;
	struct ath12k_dp *dp = ath12k_ab_to_dp(ab);

	pr_info("y700dbg: htt peer unmap id %u\\n", peer_id);
""")

edit("dp_peer.c", """	rcu_assign_pointer(dp_hw->dp_peers[peerid_index], dp_peer);

	spin_unlock_bh(&dp_hw->peer_lock);
""", """	rcu_assign_pointer(dp_hw->dp_peers[peerid_index], dp_peer);
	pr_info("y700dbg: dp peer assign vdev %u %pM sta %d id %u idx %u link %u hw_link %u\\n", vdev_id,
		addr, !!sta, peer->peer_id, peerid_index, peer->link_id, hw_link_id);

	spin_unlock_bh(&dp_hw->peer_lock);
""")

edit("peer.c", """	peer->pdev_idx = ar->pdev_idx;
	peer->sta = sta;
""", """	peer->pdev_idx = ar->pdev_idx;
	peer->sta = sta;
	pr_info("y700dbg: peer create vdev %u %pM id %u ast %u hw %u sta %d iftype %u\\n", arg->vdev_id,
		arg->peer_addr, peer->peer_id, peer->ast_hash, peer->hw_peer_id, !!sta, vif->type);
""")

# TX descriptor, after it went into the TCL ring (ti is still intact there)
edit("wifi7/dp_tx.c", """	ath12k_dbg_dump(ab, ATH12K_DBG_DP_TX, NULL, "dp tx msdu: ",
			skb->data, skb->len);
""", """	ath12k_dbg_dump(ab, ATH12K_DBG_DP_TX, NULL, "dp tx msdu: ",
			skb->data, skb->len);
	if (ahvif->vdev_type == WMI_VDEV_TYPE_AP)
		pr_info("y700tx: p %04x len %u da %pM vdev %u meta %04x bank %d encap %u enc %u f0 %08x f1 %08x as %u st %u ast %u/%u ring %u rbm %u desc %08x type %u ext %d htt %d diff %d offl %x tid %u lmac %u ovr %d q %u\\n",
			be16_to_cpu(skb->protocol), skb->len,
			eth ? eth->h_dest : ((struct ieee80211_hdr *)skb->data)->addr1,
			ti.vdev_id, ti.meta_data_flags, ti.bank_id, ti.encap_type, ti.encrypt_type, ti.flags0,
			ti.flags1, ti.addr_search_flags, ti.search_type, ti.bss_ast_hash, ti.bss_ast_idx,
			ti.ring_id, ti.rbm_id, ti.desc_id, ti.type, msdu_ext_desc, add_htt_metadata,
			is_diff_encap, ahvif->vif->offload_flags, ti.tid, ti.lmac_id, ti.lookup_override,
			skb_get_queue_mapping(skb));
""")

edit("wifi7/dp_tx.c", """fail_remove_tx_buf:
	ath12k_dp_tx_release_txbuf(dp, tx_desc, pool_id);
""", """fail_remove_tx_buf:
	ath12k_dp_tx_release_txbuf(dp, tx_desc, pool_id);
	if (ahvif->vdev_type == WMI_VDEV_TYPE_AP)
		pr_info("y700tx: fail %d p %04x len %u\\n", ret, be16_to_cpu(skb->protocol), skb->len);
""")

# every completion of an AP-vdev frame: release source, TQM reason, the raw 8 words
edit("wifi7/dp_tx.c", """		ath12k_dp_tx_release_txbuf(dp, tx_desc, tx_desc->pool_id);
		if (ts.buf_rel_source == HAL_WBM_REL_SRC_MODULE_FW) {
""", """		{
			struct ath12k_skb_cb *y_cb = desc_params.skb ? ATH12K_SKB_CB(desc_params.skb) : NULL;
			const __le32 *w = (const __le32 *)tx_status;

			if (y_cb && y_cb->vif &&
			    ath12k_vif_to_ahvif(y_cb->vif)->vdev_type == WMI_VDEV_TYPE_AP)
				pr_info("y700cmp: ring %d desc %08x src %u rel %u p %04x len %u w %08x %08x %08x %08x %08x %08x %08x %08x\\n",
					ring_id, tx_desc->desc_id, buf_rel_source, rel_status,
					be16_to_cpu(desc_params.skb->protocol), desc_params.skb->len,
					le32_to_cpu(w[0]), le32_to_cpu(w[1]), le32_to_cpu(w[2]),
					le32_to_cpu(w[3]), le32_to_cpu(w[4]), le32_to_cpu(w[5]),
					le32_to_cpu(w[6]), le32_to_cpu(w[7]));
		}
		ath12k_dp_tx_release_txbuf(dp, tx_desc, tx_desc->pool_id);
		if (ts.buf_rel_source == HAL_WBM_REL_SRC_MODULE_FW) {
""")

edit("wifi7/dp_tx.c", """	dp->device_stats.fw_tx_status[wbm_status]++;
""", """	dp->device_stats.fw_tx_status[wbm_status]++;
	{
		struct ath12k_skb_cb *y_cb = ATH12K_SKB_CB(desc_params->skb);

		if (y_cb->vif && ath12k_vif_to_ahvif(y_cb->vif)->vdev_type == WMI_VDEV_TYPE_AP)
			pr_info("y700htt: wbm %u p %04x len %u i0 %08x i1 %08x i2 %08x i3 %08x i4 %08x\\n", wbm_status,
				be16_to_cpu(desc_params->skb->protocol), desc_params->skb->len,
				le32_to_cpu(status_desc->info0), le32_to_cpu(status_desc->info1),
				le32_to_cpu(status_desc->info2), le32_to_cpu(status_desc->info3),
				le32_to_cpu(status_desc->info4));
	}
""")
# every WMI command and event: id, length, the first 48 bytes after the WMI header (key installs, management
# frames: id and length only - no key material, no neighbours' frames in the log)
edit("wmi.c", """	cmd_hdr->cmd_id = le32_encode_bits(cmd_id, WMI_CMD_HDR_CMD_ID);

	memset(skb_cb, 0, sizeof(*skb_cb));
""", """	cmd_hdr->cmd_id = le32_encode_bits(cmd_id, WMI_CMD_HDR_CMD_ID);
	{
		u32 y_n = skb->len - sizeof(*cmd_hdr);

		if (cmd_id == WMI_VDEV_INSTALL_KEY_CMDID || cmd_id == WMI_MGMT_TX_SEND_CMDID)
			y_n = 0;
		pr_info("y700wmi: > %05x len %u %*ph\\n", cmd_id, skb->len, (int)min_t(u32, y_n, 48),
			skb->data + sizeof(*cmd_hdr));
	}

	memset(skb_cb, 0, sizeof(*skb_cb));
""")

edit("wmi.c", """	id = le32_get_bits(cmd_hdr->cmd_id, WMI_CMD_HDR_CMD_ID);

	switch (id) {
		/* Process all the WMI events here */
""", """	id = le32_get_bits(cmd_hdr->cmd_id, WMI_CMD_HDR_CMD_ID);
	pr_info("y700wmi: < %05x len %u %*ph\\n", id, skb->len,
		(int)min_t(u32, id == WMI_MGMT_RX_EVENTID ? 0 : skb->len, 48), skb->data);

	switch (id) {
		/* Process all the WMI events here */
""")

# every HTT target-to-host message: type, length, the first 32 bytes
edit("dp_htt.c", """	type = le32_get_bits(resp->version_msg.version, HTT_T2H_MSG_TYPE);

	ath12k_dbg(ab, ATH12K_DBG_DP_HTT, "dp_htt rx msg type :0x%0x\\n", type);
""", """	type = le32_get_bits(resp->version_msg.version, HTT_T2H_MSG_TYPE);

	ath12k_dbg(ab, ATH12K_DBG_DP_HTT, "dp_htt rx msg type :0x%0x\\n", type);
	pr_info("y700htc: type %02x len %u %*ph\\n", type, skb->len, (int)min_t(u32, skb->len, 32), skb->data);
""")
print("txdbg patch applied to", D)

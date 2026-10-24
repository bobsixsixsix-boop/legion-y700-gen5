#!/bin/bash
# Build the test-only instrumented ath12k from a copy of the y12 tree's driver (the tree itself is not touched).
# Output: /root/ath12k-txdbg/ath/ath12k/{ath12k.ko,wifi7/ath12k_wifi7.ko}; log /root/ath12k-txdbg/build.log
set -e
SRC=/usr/local/src/linux-t47; W=/root/ath12k-txdbg
rm -rf $W; mkdir -p $W; exec >$W/build.log 2>&1; set -x
cp -a $SRC/drivers/net/wireless/ath $W/ath
find $W/ath -name '*.o' -o -name '*.ko' -o -name '*.mod*' -o -name '.*.cmd' -o -name 'modules.order' -o -name 'Module.symvers' | xargs rm -f
python3 /root/txdbg-patch.py $W/ath/ath12k
# EXTRA=/root/noenc-patch.py: a second test-only patch on top (still "txdbg" in the version, so restore finds it)
[ -z "$EXTRA" ] || python3 "$EXTRA" $W/ath/ath12k
M="make -C $SRC LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
$M M=$W/ath/ath12k KBUILD_MODPOST_WARN=1 modules
for k in $W/ath/ath12k/ath12k.ko $W/ath/ath12k/wifi7/ath12k_wifi7.ko; do modinfo -F vermagic $k; modinfo -F version $k; done
[ "$(modinfo -F vermagic $W/ath/ath12k/ath12k.ko)" = "$(modinfo -F vermagic /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko)" ]
# clang 18 keeps the BTI landing pads (clang 21 dropped them -> Oops-BTI): every function entry must start with bti
/opt/llvm-18/bin/llvm-objdump -d --no-show-raw-insn $W/ath/ath12k/wifi7/ath12k_wifi7.ko | grep -A1 "<ath12k_wifi7_dp_tx>:" | head -2
echo TXDBG_BUILD_OK

#!/bin/bash
exec > /root/y700-kernel-build18.log 2>&1
set -ex
cd /opt
if [ ! -x /opt/llvm-18/bin/clang ]; then
	curl -fsSL -o /opt/llvm18.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.3/clang+llvm-18.1.3-aarch64-linux-gnu.tar.xz
	mkdir -p /opt/llvm-18 && tar -xJf /opt/llvm18.tar.xz -C /opt/llvm-18 --strip-components=1 && rm -f /opt/llvm18.tar.xz
fi
/opt/llvm-18/bin/clang --version | head -1
cd /usr/local/src/linux-t47
cp /tmp/config-t47 .config 2>/dev/null || curl -fsSL -o .config https://github.com/joonhoekim/tb323fu-linux/releases/download/kernel-t47/config-tb323fu-t47
cp .config /root/config-t47.release
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
$M olddefconfig
diff <(grep -v "^#" /root/config-t47.release | sort) <(grep -v "^#" .config | sort) || true
$M clean M=drivers/net/wireless/ath/ath12k || true
$M modules_prepare
$M M=drivers/net/wireless/ath/ath12k KBUILD_MODPOST_WARN=1 modules
for k in drivers/net/wireless/ath/ath12k/ath12k.ko drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7.ko; do modinfo -F vermagic $k; done
/opt/llvm-18/bin/llvm-objdump -d --no-show-raw-insn drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7.ko | grep -A2 "<ath12k_wifi7_hal_ce_get_desc_size>:" | head -3
echo BUILD18_OK

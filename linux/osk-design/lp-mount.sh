#!/bin/bash
# read-only mount of single-extent LP partitions from the live super partition
DEV=/dev/sda7; modprobe erofs 2>/dev/null
for name in my_stock_a my_product_a system_ext_a product_a; do
  read off size < <(python3 - "$name" <<'PY'
import struct, sys
name=sys.argv[1]; f=open('/dev/sda7','rb'); f.seek(4096*3); h=f.read(256)
hsize=struct.unpack('<I',h[8:12])[0]; ts=struct.unpack('<I',h[44:48])[0]
d=lambda o: struct.unpack('<III',h[o:o+12]); parts,exts=d(80),d(92)
f.seek(4096*3+hsize); t=f.read(ts)
tb=lambda dd: [t[dd[0]+i*dd[2]:dd[0]+(i+1)*dd[2]] for i in range(dd[1])]
P,E=tb(parts),tb(exts)
for e in P:
    if e[:36].split(b'\0')[0].decode()==name:
        a,fx,nx,gi=struct.unpack('<IIII',e[36:52]); ns,tt,td,ts_=struct.unpack('<QIQI',E[fx][:24]); print(td*512, ns*512)
PY
)
  mkdir -p /mnt/lp/$name
  mountpoint -q /mnt/lp/$name && { echo "$name already mounted"; continue; }
  L=$(losetup -r -f --show -o $off --sizelimit $size $DEV) || continue
  fs=$(blkid -o value -s TYPE $L); echo "$name -> $L fs=$fs off=$off size=$size"
  mount -o ro $L /mnt/lp/$name 2>&1 | head -1
done
echo "== IME apks"
find /mnt/lp -iname "*.apk" 2>/dev/null | grep -iE "input|sogou|baidu|ime|keyboard|iflytek|xunfei" | head -20
echo "== all app dirs count"; find /mnt/lp -maxdepth 3 -type d \( -name app -o -name priv-app \) | while read d; do echo "$d: $(ls $d | wc -l)"; done

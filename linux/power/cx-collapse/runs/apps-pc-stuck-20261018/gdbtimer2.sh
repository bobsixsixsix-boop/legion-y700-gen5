#!/bin/bash
# 2026-10-18: name plasmashell's ~130/s timer receiver: at one QEvent::Timer delivery call metaObject()->className()
# on it and on its parent chain (QObject d_ptr at +8, QObjectData parent at +16); unwindonsignal keeps a failed call
# from leaving plasmashell in a broken frame; breakpoint deleted and gdb detaches either way
export LC_ALL=C
P=$(pgrep -x plasmashell | head -1)
cat > /tmp/gdbtimer2.cmd <<'EOF'
set debuginfod enabled off
set pagination off
set print thread-events off
set unwindonsignal on
set $hit = 0
break QCoreApplication::notifyInternal2 if *(unsigned short *)($x1 + 8) == 1
commands
silent
set $hit = 1
end
continue
delete
if $hit == 1
  set $o = $x0
  set $i = 0
  while $o != 0 && $i < 14
    set $mo = ((void *(*)(void *)) (**(void ***)$o))($o)
    printf "level %d obj %p class %s\n", $i, $o, ((const char *(*)(void *)) 'QMetaObject::className() const')($mo)
    set $o = *(void **)(*(void **)((char *)$o + 8) + 16)
    set $i = $i + 1
  end
end
detach
EOF
timeout -s INT 12 gdb -p $P -batch -nx -x /tmp/gdbtimer2.cmd 2>&1 | grep -v -E '^\[New LWP|^Reading symbols|^\(No debugging|Download failed|^warning: (Could not|Unable)|libthread_db' | cut -c1-200
echo "plasmashell state after: $(awk '{print $3}' /proc/$P/stat) pid $(pgrep -x plasmashell)"

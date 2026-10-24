#!/bin/bash
# Summarise one apjoin run made with the txdbg module: per session the setup lines, the EAPOL descriptors and their
# completions, and histograms of completion paths. Usage: txdbg-sum.sh /root/aptest2/join-HHMMSS
O=$1
grep '^s[0-9]' "$O/run.log" | grep -E 'channel|settle'
for k in $(ls "$O"/k*.log | sed 's/.*k\([0-9]*\)\.log/\1/' | sort -n); do
    L=$O/k$k.log
    echo "===== s$k: $(grep "^s$k Y700" "$O/run.log" | cut -d' ' -f3-)"
    grep -E 'y700dbg: (vdev create|tx attach|bank|peer create|htt peer (un)?map|dp peer assign)' "$L" | sed -E 's/^.*y700dbg: //' | head -20
    echo "-- EAPOL TX (first 4) / completions (first 6):"
    grep 'y700tx: p 888e' "$L" | head -4 | sed -E 's/^([0-9:.]+) .*y700tx: /\1 /'
    grep -E 'y700(cmp|htt): .*p 888e' "$L" | head -6 | sed -E 's/^([0-9:.]+) .*(y700(cmp|htt)): /\1 \2 /'
    echo "-- tx count by proto:"; grep -o 'y700tx: p [0-9a-f]*' "$L" | sort | uniq -c | tr '\n' ' '; echo
    echo "-- tx fails:"; grep -c 'y700tx: fail' "$L"
    echo "-- completion src/rel:"; grep -o 'y700cmp: .*src [0-9]* rel [0-9]*' "$L" | sed -E 's/.*(src [0-9]+ rel [0-9]+)/\1/' | sort | uniq -c | tr '\n' ' '; echo
    echo "-- htt wbm status:"; grep -o 'y700htt: wbm [0-9]* p [0-9a-f]*' "$L" | sed 's/y700htt: //' | sort | uniq -c | tr '\n' ' '; echo
    echo "-- distinct tx desc fields (vdev meta bank encap enc as st ast ext htt diff):"
    grep 'y700tx: p' "$L" | sed -E 's/.* (vdev [0-9]+ meta [0-9a-f]+ bank -?[0-9]+ encap [0-9]+ enc [0-9]+) f0 ([0-9a-f]+) f1 [0-9a-f]+ (as [0-9]+ st [0-9]+ ast [0-9\/]+).* (ext [0-9] htt [0-9] diff [0-9]).*/\1 f0 \2 \3 \4/' | sort | uniq -c
done

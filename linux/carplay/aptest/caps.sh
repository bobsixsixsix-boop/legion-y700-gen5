#!/bin/bash
# Per txdbg session: good/bad (M2 seen or not) and the capability field of each WMI PEER_ASSOC sent for the PC
# (bytes 29-30 of the logged payload = peer_caps, from the station's association request).
# PC_MAC= the station's MAC (default: the placeholder used throughout aptest/).
PC_MAC=${PC_MAC:-02:00:00:00:00:20}
PAT="y700wmi: > 06005 len 336 f4 00 65 00 $(echo "$PC_MAC" | tr 'A-F:' 'a-f ')"
for d in /root/aptest2/join-*; do
    [ -f "$d/run.log" ] || continue
    for k in $(ls "$d"/k*.log 2>/dev/null | sed 's/.*k\([0-9]*\)\.log/\1/' | sort -n); do
        l=$(grep "^s$k Y700" "$d/run.log") || continue
        m2=$(echo "$l" | sed -E 's/.* M2 ([0-9]+) .*/\1/'); as=$(echo "$l" | sed -E 's/.* assoc ([0-9]+) .*/\1/')
        [ "$as" = 0 ] && continue
        st=ok; [ "$m2" = 0 ] && st=BAD
        caps=$(grep "$PAT" "$d/k$k.log" |
            awk '{ for (i = 1; i <= NF; i++) if ($i == "06005") { print $(i+32) $(i+31) } }' | sort | uniq -c | tr '\n' ' ')
        echo "$(basename $d) s$k $st assoc $as caps: $caps"
    done
done

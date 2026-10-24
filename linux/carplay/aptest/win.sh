#!/bin/bash
# win.sh FILE FROM TO [extra grep -v pattern]: lines of a mactrace.txt between two HH:MM:SS times, minus the
# chatty WMI reorder-queue / peer-param commands
F=$1; A=$2; B=$3; X=${4:-'^$'}
awk -v a="$A" -v b="$B" '$1 >= a && $1 <= b' "$F" | grep -vE '> 06013|> 06004' | grep -vE "$X" | cut -c1-190

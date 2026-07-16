#!/bin/bash
# t6-forensics.sh <corrupt.img> <044.out.bad>
# For each file the test flagged, pull its INODE_ITEM (disk i_size) and any
# EXTENT_DATA items straight from the on-disk fs tree. If disk size > 0 with
# zero EXTENT_DATA items, the ordered-extent invariant was violated ON DISK.
set -u
IMG=$1; BAD=$2
BTRFS=/home/prozak/uml-smoke/btrfs-progs-v7/btrfs
DUMP=$(mktemp); trap "rm -f $DUMP" EXIT
$BTRFS inspect-internal dump-tree -t 5 "$IMG" > $DUMP 2>/dev/null
echo "== superblock generation: $($BTRFS inspect-internal dump-super "$IMG" 2>/dev/null | awk '/^generation/{print $2}')"
for name in $(grep -oE 'corrupt file [^ ]+' "$BAD" | awk -F/ '{print $NF}' | head -8); do
  # find objectid via DIR_ITEM/INODE_REF name match
  ino=$(grep -B2 "name: $name$" $DUMP | grep -oE 'key \([0-9]+ INODE_REF' | grep -oE '[0-9]+' | head -1)
  [ -z "$ino" ] && { echo "file $name: no INODE_REF found (name not in tree?)"; continue; }
  size=$(awk -v k="($ino INODE_ITEM 0)" 'index($0,k){f=1} f&&/size/{print $2; exit}' $DUMP)
  gen=$(awk -v k="($ino INODE_ITEM 0)" 'index($0,k){f=1} f&&/generation/{print $2; exit}' $DUMP)
  ext=$(grep -cE "key \($ino EXTENT_DATA " $DUMP)
  echo "file $name ino=$ino disk_size=$size inode_gen=$gen extent_data_items=$ext"
done
echo "== healthy neighbor sample:"
for name in 1 2 500; do
  ino=$(grep -B2 "name: $name$" $DUMP | grep -oE 'key \([0-9]+ INODE_REF' | grep -oE '[0-9]+' | head -1)
  [ -z "$ino" ] && { echo "file $name: absent (never committed — fine)"; continue; }
  size=$(awk -v k="($ino INODE_ITEM 0)" 'index($0,k){f=1} f&&/size/{print $2; exit}' $DUMP)
  ext=$(grep -cE "key \($ino EXTENT_DATA " $DUMP)
  echo "file $name ino=$ino disk_size=$size extent_data_items=$ext"
done

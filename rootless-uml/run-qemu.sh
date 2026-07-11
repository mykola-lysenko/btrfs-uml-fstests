#!/bin/bash
# run-qemu.sh — native rootless qemu wrapper (no docker). Args pass through.
Q=$HOME/uml-smoke/qemu-native/root
exec env LD_LIBRARY_PATH=$Q/usr/lib/x86_64-linux-gnu:$Q/lib/x86_64-linux-gnu \
  $Q/usr/bin/qemu-system-x86_64 \
  -L $Q/usr/share/qemu -L $Q/usr/share/seabios -L $Q/usr/share/ipxe/qemu \
  "$@"

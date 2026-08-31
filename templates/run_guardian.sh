#!/bin/zsh
set -eu

install_root=${0:A:h}
case "$(/usr/bin/uname -m)" in
  arm64|x86_64) ;;
  *) exit 78 ;;
esac

exec "${install_root}/venv/bin/python" "${install_root}/guardian.py" --daemon

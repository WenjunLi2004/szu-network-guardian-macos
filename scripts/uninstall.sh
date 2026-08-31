#!/bin/zsh
set -eu

user_home=${HOME:?}
install_root="${user_home}/Library/Application Support/SZUNetworkGuardian"
app_target="${user_home}/Applications/SZU Network Guardian.app"
guardian_plist="${user_home}/Library/LaunchAgents/com.wenjun.szu-network-guardian.plist"
menu_plist="${user_home}/Library/LaunchAgents/com.wenjun.szu-network-guardian.menu.plist"
domain="gui/$(/usr/bin/id -u)"
purge=false

if [[ "${1:-}" == "--purge" ]]; then
  purge=true
elif [[ -n "${1:-}" ]]; then
  echo "用法：$0 [--purge]" >&2
  exit 64
fi

/bin/launchctl bootout "${domain}/com.wenjun.szu-network-guardian.menu" 2>/dev/null || true
/bin/launchctl bootout "${domain}/com.wenjun.szu-network-guardian" 2>/dev/null || true
/bin/rm -f -- "${guardian_plist}" "${menu_plist}"
/bin/rm -rf -- "${app_target}"

if [[ "${purge}" == true ]]; then
  expected_root="${user_home}/Library/Application Support/SZUNetworkGuardian"
  if [[ "${install_root}" != "${expected_root}" || "${install_root}" == "/" ]]; then
    echo "拒绝清理异常安装路径。" >&2
    exit 78
  fi
  if [[ -x "${install_root}/keychain" ]]; then
    "${install_root}/keychain" delete com.wenjun.szu-network-guardian.username || true
    "${install_root}/keychain" delete com.wenjun.szu-network-guardian.password || true
  fi
  /bin/rm -rf -- "${install_root}"
  echo "已彻底卸载，并删除本项目的 Keychain 凭据和本地日志。"
else
  echo "已卸载程序；Keychain 凭据、配置和日志仍保留。使用 --purge 可一并清理。"
fi

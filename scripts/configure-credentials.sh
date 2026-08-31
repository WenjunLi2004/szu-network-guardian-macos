#!/bin/zsh
set -eu

user_home=${HOME:?}
install_root="${user_home}/Library/Application Support/SZUNetworkGuardian"
keychain_helper="${install_root}/keychain"

if [[ ! -x "${keychain_helper}" ]]; then
  echo "Keychain helper 尚未安装，请先运行 install.sh。" >&2
  exit 69
fi

read -r "campus_username?校园网账号："
read -rs "campus_password?统一身份认证密码："
echo
if [[ -z "${campus_username}" || -z "${campus_password}" ]]; then
  echo "账号和密码不能为空。" >&2
  exit 64
fi

printf '%s' "${campus_password}" | "${keychain_helper}" set com.wenjun.szu-network-guardian.password
printf '%s' "${campus_username}" | "${keychain_helper}" set com.wenjun.szu-network-guardian.username
campus_username=""
campus_password=""

pid_path="${install_root}/guardian.pid"
if [[ -f "${pid_path}" ]]; then
  guardian_pid=$(/bin/cat "${pid_path}" 2>/dev/null || true)
  if [[ "${guardian_pid}" == <-> ]]; then
    /bin/kill -USR1 "${guardian_pid}" 2>/dev/null || true
  fi
fi
echo "凭据已写入当前用户的 macOS Keychain。"

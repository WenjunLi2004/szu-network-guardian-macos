#!/bin/zsh
set -eu

repo_root=${0:A:h:h}
user_home=${HOME:?}
install_root="${user_home}/Library/Application Support/SZUNetworkGuardian"
app_target="${user_home}/Applications/SZU Network Guardian.app"
launch_agents="${user_home}/Library/LaunchAgents"
guardian_plist="${launch_agents}/com.wenjun.szu-network-guardian.plist"
menu_plist="${launch_agents}/com.wenjun.szu-network-guardian.menu.plist"
domain="gui/$(/usr/bin/id -u)"
python_bin=${PYTHON_BIN:-}
reconfigure=false

if [[ -z "${python_bin}" ]]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    if [[ -x "${candidate}" ]] && "${candidate}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
      python_bin="${candidate}"
      break
    fi
  done
fi
if [[ -z "${python_bin}" || ! -x "${python_bin}" ]]; then
  echo "未找到 Python 3.10+；请先通过 Homebrew 或 python.org 安装。" >&2
  exit 69
fi

if [[ "${1:-}" == "--reconfigure" ]]; then
  reconfigure=true
elif [[ -n "${1:-}" ]]; then
  echo "用法：$0 [--reconfigure]" >&2
  exit 64
fi

"${repo_root}/scripts/build.sh"

# Stop the loaded jobs before replacing their executable files. launchd can
# temporarily reject bootstrap if a running image is overwritten first.
/bin/launchctl bootout "${domain}/com.wenjun.szu-network-guardian" 2>/dev/null || true
/bin/launchctl bootout "${domain}/com.wenjun.szu-network-guardian.menu" 2>/dev/null || true

/bin/mkdir -p "${install_root}/logs" "${user_home}/Applications" "${launch_agents}"
/bin/chmod 700 "${install_root}" "${install_root}/logs"
/usr/bin/ditto "${repo_root}/build/SZU Network Guardian.app" "${app_target}"
/bin/cp "${repo_root}/Sources/guardian.py" "${install_root}/guardian.py"
/bin/cp "${repo_root}/build/keychain" "${install_root}/keychain"
/bin/cp "${repo_root}/templates/run_guardian.sh" "${install_root}/run_guardian.sh"
/bin/chmod 700 "${install_root}/keychain" "${install_root}/run_guardian.sh"

if [[ ! -f "${install_root}/config.json" ]]; then
  /bin/cp "${repo_root}/templates/config.json" "${install_root}/config.json"
fi
/bin/chmod 600 "${install_root}/config.json"

"${python_bin}" -m venv "${install_root}/venv"
"${install_root}/venv/bin/python" -m pip install --disable-pip-version-check -q \
  --no-index --find-links "${repo_root}/build/wheels" -r "${repo_root}/requirements.txt"

escaped_root=$(printf '%s' "${install_root}" | /usr/bin/sed 's/[\\&|]/\\&/g')
escaped_app=$(printf '%s' "${app_target}/Contents/MacOS/SZUNetworkGuardianMenu" | /usr/bin/sed 's/[\\&|]/\\&/g')
/usr/bin/sed "s|__INSTALL_ROOT__|${escaped_root}|g" "${repo_root}/templates/guardian.plist" > "${guardian_plist}"
/usr/bin/sed -e "s|__INSTALL_ROOT__|${escaped_root}|g" -e "s|__APP_EXECUTABLE__|${escaped_app}|g" \
  "${repo_root}/templates/menu.plist" > "${menu_plist}"
/bin/chmod 600 "${guardian_plist}" "${menu_plist}"
/usr/bin/plutil -lint "${guardian_plist}" "${menu_plist}"

if [[ "${reconfigure}" == true ]] || \
   ! "${install_root}/keychain" get com.wenjun.szu-network-guardian.username >/dev/null 2>&1 || \
   ! "${install_root}/keychain" get com.wenjun.szu-network-guardian.password >/dev/null 2>&1; then
  "${repo_root}/scripts/configure-credentials.sh"
else
  echo "已保留 Keychain 中的现有凭据。"
fi

/bin/launchctl enable "${domain}/com.wenjun.szu-network-guardian"
/bin/launchctl enable "${domain}/com.wenjun.szu-network-guardian.menu"

bootstrap_job() {
  local plist_path=$1
  local attempt
  local bootstrap_error=""
  for attempt in {1..15}; do
    if bootstrap_error=$(/bin/launchctl bootstrap "${domain}" "${plist_path}" 2>&1); then
      return 0
    fi
    /bin/sleep 1
  done
  echo "LaunchAgent 加载失败：${plist_path}" >&2
  echo "${bootstrap_error}" >&2
  return 1
}

bootstrap_job "${guardian_plist}"
bootstrap_job "${menu_plist}"

echo "安装完成。菜单栏程序和后台守护已启动。"

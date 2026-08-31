#!/bin/zsh
set -eu

repo_root=${0:A:h:h}
build_root="${repo_root}/build"
build_venv="${repo_root}/.venv-build"
app_bundle="${build_root}/SZU Network Guardian.app"
python_bin=${PYTHON_BIN:-}
export MACOSX_DEPLOYMENT_TARGET=13.0
machine_arch=$(/usr/bin/uname -m)
swift_target="${machine_arch}-apple-macosx13.0"

if [[ -z "${python_bin}" ]]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    if [[ -x "${candidate}" ]] && "${candidate}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
      python_bin="${candidate}"
      break
    fi
  done
fi

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  echo "此项目只能在 macOS 上构建。" >&2
  exit 78
fi
if (( $(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1) < 13 )); then
  echo "需要 macOS 13 或更高版本。" >&2
  exit 78
fi
if [[ -z "${python_bin}" || ! -x "${python_bin}" ]]; then
  echo "未找到 Python 3.10+；请先通过 Homebrew 或 python.org 安装。" >&2
  exit 69
fi
if ! "${python_bin}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "检测到的 Python 版本低于 3.10：${python_bin}" >&2
  echo "可使用 PYTHON_BIN=/path/to/python3 指定现代 Python。" >&2
  exit 69
fi

/bin/rm -rf -- "${build_root}" "${build_venv}"
/bin/mkdir -p "${app_bundle}/Contents/MacOS" "${build_root}/wheels"
"${python_bin}" -m venv "${build_venv}"
"${build_venv}/bin/python" -m pip download --disable-pip-version-check -q \
  -d "${build_root}/wheels" -r "${repo_root}/requirements.txt"
"${build_venv}/bin/python" -m pip install --disable-pip-version-check -q \
  --no-index --find-links "${build_root}/wheels" -r "${repo_root}/requirements.txt"
"${build_venv}/bin/python" -m unittest discover -s "${repo_root}/Tests" -v

/usr/bin/xcrun swiftc -D TESTING -parse-as-library \
  -target "${swift_target}" \
  "${repo_root}/Sources/MenuBarApp.swift" \
  "${repo_root}/Tests/MenuDraftHarness.swift" \
  -framework SwiftUI -framework AppKit \
  -o "${build_root}/menu-draft-test"
"${build_root}/menu-draft-test"

/usr/bin/xcrun swiftc -O \
  -target "${swift_target}" \
  "${repo_root}/Sources/keychain.swift" \
  -framework Security \
  -o "${build_root}/keychain"
/usr/bin/xcrun swiftc -parse-as-library -O \
  -target "${swift_target}" \
  "${repo_root}/Sources/MenuBarApp.swift" \
  -framework SwiftUI -framework AppKit \
  -o "${app_bundle}/Contents/MacOS/SZUNetworkGuardianMenu"
/bin/cp "${repo_root}/templates/Info.plist" "${app_bundle}/Contents/Info.plist"
/bin/chmod 755 "${build_root}/keychain" "${app_bundle}/Contents/MacOS/SZUNetworkGuardianMenu"
/usr/bin/codesign --force --sign - "${build_root}/keychain"
/usr/bin/codesign --force --deep --sign - "${app_bundle}"
/usr/bin/codesign --verify --deep --strict "${app_bundle}"

echo "构建完成：${app_bundle}"
echo "架构：${machine_arch}，最低系统：macOS 13.0"

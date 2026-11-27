#!/usr/bin/env bash
# 界面文案的本地化工具。String Catalog 在 Assets/Localization/Localizable.xcstrings（源语言 en，另有 zh-Hans）。
#
#   scripts/l10n.sh sync           从代码抽取文案并更新 String Catalog（新文案需补翻译，见 LocalizationCatalogTests）
#   scripts/l10n.sh check          同上但只检查：String Catalog 与代码不一致时失败（CI 用）
#   scripts/l10n.sh compile <dir>  把 String Catalog 编译成 <dir>/<lang>.lproj（打包、开发运行用）
#
# 文案由编译器抽取（-emit-localized-strings），和 Xcode 的做法一致：SwiftUI 的 LocalizedStringKey、
# String(localized:) 都算，String 变量不算。App 运行时从 Bundle.main 查表，所以 .lproj 要放在
# .app/Contents/Resources（打包）或可执行文件旁边（开发运行）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"   # 物理路径，和编译器写进 .stringsdata 的一致
CATALOG="${ROOT_DIR}/Assets/Localization/Localizable.xcstrings"

log() {
    printf '[l10n] %s\n' "$*" >&2
}

# 重新编译本仓库的源文件，把每个文件的 .stringsdata 写进 $1。
# 增量构建只给重编的文件出 .stringsdata，所以先 touch 一遍本仓库的源文件（依赖库不受影响）。
extract() {
    local out_dir="$1"
    find "${ROOT_DIR}/Sources" -name '*.swift' -exec touch {} +
    log "building with string extraction"
    (cd "${ROOT_DIR}" && swift build --product agent-inbox \
        -Xswiftc -emit-localized-strings \
        -Xswiftc -emit-localized-strings-path -Xswiftc "${out_dir}" >&2)
}

# 用 $1 目录里属于本仓库 Sources/ 的 .stringsdata 更新 $2（文件名须是 Localizable.xcstrings，按表名匹配）。
sync_into() {
    local strings_dir="$1" catalog="$2"
    local args=()
    local file
    for file in "${strings_dir}"/*.stringsdata; do
        [[ -e "${file}" ]] || continue
        # 依赖库也会输出 .stringsdata；只认 source 指向本仓库 Sources/ 的。
        if grep -qF "\"source\": \"${ROOT_DIR}/Sources/" "${file}"; then
            args+=(--stringsdata "${file}")
        fi
    done
    if [[ ${#args[@]} -eq 0 ]]; then
        log "no .stringsdata found for ${ROOT_DIR}/Sources"
        exit 1
    fi
    xcrun xcstringstool sync "${catalog}" "${args[@]}"
}

command="${1:-}"
case "${command}" in
    sync)
        work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-inbox-l10n.XXXXXX")"
        trap 'rm -rf "${work_dir}"' EXIT
        extract "${work_dir}/stringsdata"
        sync_into "${work_dir}/stringsdata" "${CATALOG}"
        log "updated ${CATALOG#"${ROOT_DIR}/"}; translate new entries and delete stale ones"
        ;;
    check)
        work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-inbox-l10n.XXXXXX")"
        trap 'rm -rf "${work_dir}"' EXIT
        extract "${work_dir}/stringsdata"
        mkdir -p "${work_dir}/catalog"
        cp "${CATALOG}" "${work_dir}/catalog/Localizable.xcstrings"
        sync_into "${work_dir}/stringsdata" "${work_dir}/catalog/Localizable.xcstrings"
        if ! cmp -s "${CATALOG}" "${work_dir}/catalog/Localizable.xcstrings"; then
            diff -u "${CATALOG}" "${work_dir}/catalog/Localizable.xcstrings" >&2 || true
            log "String Catalog is out of date: run scripts/l10n.sh sync, then translate the new entries"
            exit 1
        fi
        log "String Catalog matches the code"
        ;;
    compile)
        out_dir="${2:?usage: scripts/l10n.sh compile <dir>}"
        mkdir -p "${out_dir}"
        xcrun xcstringstool compile "${CATALOG}" --output-directory "${out_dir}" >/dev/null
        log "compiled $(find "${out_dir}" -maxdepth 1 -name '*.lproj' | wc -l | tr -d ' ') localizations into ${out_dir}"
        ;;
    *)
        echo "usage: scripts/l10n.sh sync | check | compile <dir>" >&2
        exit 64
        ;;
esac

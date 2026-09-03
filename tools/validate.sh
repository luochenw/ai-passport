#!/usr/bin/env bash
set -euo pipefail

mode="${1:---all}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 [--all|--static|--firmware]" >&2
}

run_static_checks() {
    local actionlint_bin
    local test_dir

    python3 tools/check_repo.py

    actionlint_bin="${ACTIONLINT_BIN:-}"
    if [[ -z "${actionlint_bin}" ]]; then
        actionlint_bin="$(command -v actionlint || true)"
    fi
    if [[ -z "${actionlint_bin}" || ! -x "${actionlint_bin}" ]]; then
        actionlint_bin="$(./tools/install-actionlint.sh)"
    fi
    "${actionlint_bin}" -color .github/workflows/*.yml

    test_dir="$(mktemp -d /tmp/ai-passport-host-tests.XXXXXX)"
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -Imain \
        tests/test_ui_pixel_math.c main/ui_pixel_math.c \
        -o "${test_dir}/test_ui_pixel_math"
    "${test_dir}/test_ui_pixel_math"

    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -Imain \
        tests/test_walkie_codec.c main/walkie_codec.c \
        -o "${test_dir}/test_walkie_codec"
    "${test_dir}/test_walkie_codec"

    if command -v go >/dev/null 2>&1; then
        (cd services && go test ./...)
    else
        echo "跳过 services 的 go test:本机没有 go"
    fi

    # 注:这里曾经有一个 dashboard_parse 的 JSON 解析回归测试。面板数据的获取
    # 和解析在架构转向后整体搬到了 Mac 端(DashboardApp.swift),设备不再联网,
    # 那份 C 解析代码和它的测试一起删掉了。顺带解掉了 IDF_PATH 依赖 ——
    # static 这一档跑在没装 ESP-IDF 的 CI 机器上,那个变量在 set -u 下是
    # "unbound variable",会让整档直接失败。

    # Mac 端的按键枚举必须跟固件头文件逐个对上。写错了不会有任何编译错误或
    # 运行时报错,只表现为"按下去做的事不对",要拿着实机一个键一个键试才能
    # 发现 —— 实测踩过一次(下键和确定键互换)。esp_err.h 只用到一个类型名,
    # 给个最小桩就够,不需要拉整个 ESP-IDF。
    mkdir -p "${test_dir}/stub"
    printf '#pragma once\ntypedef int esp_err_t;\n' > "${test_dir}/stub/esp_err.h"
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror \
        -Icomponents/bsp/include -I"${test_dir}/stub" \
        tests/test_button_enum_sync.c -o "${test_dir}/test_button_enum_sync"
    "${test_dir}/test_button_enum_sync"
    # 远程应用商店的逻辑(装 → 上首屏 → 商店不再列出 → 卸载)。这条链路的
    # 失败模式全是**静默**的:装了但清单没推出去、卸了设备首屏还留着、装到
    # 第 9 个被悄悄丢掉 —— 真机上要一步步试才能发现。swiftc 只在 macOS 上有,
    # Linux 的 CI 跳过这一项(那边的 static 档仍然跑其余全部检查)。
    if command -v swiftc >/dev/null 2>&1; then
        # CodexApp + Protocol 也编进来:平台边界(本端跑不了的应用怎么表现)
        # 是这次三端改造的核心行为,而它的失败模式同样是静默的 —— 设备上
        # 点进去一片空白、或者"正在读取…"永远挂着。
        swiftc -o "${test_dir}/test_remote_apps" \
            tests/test_remote_apps.swift \
            mac-relay/FoloCodexRelay/Shared/Framework/RemoteApps.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Codex/CodexApp.swift \
            mac-relay/FoloCodexRelay/Shared/Framework/Protocol.swift \
            mac-relay/FoloCodexRelay/Shared/Framework/AppOverlay.swift
        # ⚠ 用隔离的 HOME 跑:配置层在 macOS 上会写 ~/.folotoy/<name>.json,
        # 拿真实家目录跑测试会污染(甚至覆盖)用户自己的配置。
        HOME="${test_dir}" "${test_dir}/test_remote_apps"

        swiftc -o "${test_dir}/test_walkie_protocol" \
            tests/test_walkie_protocol.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Walkie/WalkieProtocol.swift
        "${test_dir}/test_walkie_protocol"

        swiftc -o "${test_dir}/test_walkie_client" \
            tests/test_walkie_client.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Walkie/WalkieClient.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Walkie/WalkieProtocol.swift
        HOME="${test_dir}" "${test_dir}/test_walkie_client"

        swiftc -o "${test_dir}/test_meal_client" \
            tests/test_meal_client.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Meal/MealClient.swift \
            mac-relay/FoloCodexRelay/Shared/Apps/Meal/MealProtocol.swift \
            mac-relay/FoloCodexRelay/Shared/Framework/AppConfigStore.swift
        HOME="${test_dir}" "${test_dir}/test_meal_client"
    else
        echo "跳过 test_remote_apps:本机没有 swiftc"
    fi

    python3 tests/test_verify_firmware.py
    rm -rf "${test_dir}"
    echo "Host tests: PASS"
}

run_firmware_checks() (
    local validation_build_dir

    if ! command -v idf.py >/dev/null 2>&1; then
        echo "ERROR: idf.py is not available; activate ESP-IDF 5.5.3 first." >&2
        return 1
    fi

    validation_build_dir="$(mktemp -d /tmp/ai-passport-firmware.XXXXXX)"
    trap 'case "${validation_build_dir}" in /tmp/ai-passport-firmware.*) rm -rf -- "${validation_build_dir}" ;; esac' EXIT

    SDKCONFIG_DEFAULTS="${repo_root}/sdkconfig.defaults" \
        idf.py -B "${validation_build_dir}" \
        -D "SDKCONFIG=${validation_build_dir}/sdkconfig" build
    idf.py -B "${validation_build_dir}" size
    idf.py -B "${validation_build_dir}" merge-bin \
        -o "${validation_build_dir}/FoloToy-AI-Passport-full.bin"
    python3 tools/verify_firmware.py "${validation_build_dir}"
    mkdir -p "${repo_root}/build"
    install -m 0644 \
        "${validation_build_dir}/FoloToy-AI-Passport-full.bin" \
        "${repo_root}/build/FoloToy-AI-Passport-full.bin"
    mkdir -p "${repo_root}/mac-relay/AppCatalog"
    install -m 0644 \
        "${validation_build_dir}/FoloToy-AI-Passport.bin" \
        "${repo_root}/mac-relay/AppCatalog/current-firmware.bin"
    echo "Firmware build: PASS"
)

cd "${repo_root}"
case "${mode}" in
    --all)
        run_static_checks
        run_firmware_checks
        ;;
    --static)
        run_static_checks
        ;;
    --firmware)
        run_firmware_checks
        ;;
    *)
        usage
        exit 2
        ;;
esac

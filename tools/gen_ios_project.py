#!/usr/bin/env python3
"""生成 iOS 版的 .xcodeproj。

为什么是生成而不是手工建:手工在 Xcode 里点出来的 .xcodeproj 是个几千行、
UUID 全随机的文件,没法 review、没法在 diff 里看出改了什么,加一个源文件
还得所有人重新点一遍。这个脚本按文件名算出稳定的 UUID,所以同样的输入永远
生成同样的工程文件,加文件只要重跑一次。

真机装机必须走 .xcodeproj:自动签名(申请证书、创建描述文件、注册设备)
是 Xcode 构建系统的一部分,命令行手工 codesign 那条路要自己拼 entitlements、
自己嵌描述文件,又长又脆。模拟器/CI 那条路不需要签名,继续用 build-ios.sh。
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REL = "mac-relay"
# 递归扫描:源码按「框架 / 能力 / 每个应用一个文件夹」分层放。
# 加一个应用 = 新建一个文件夹,这个脚本不用改。
SRC_DIR = "FoloCodexRelay/Shared"
PROJ = os.path.join(ROOT, REL, "FoloCodexRelay.xcodeproj")
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.folotoy.codexrelay")


def ptt_entitlements():
    """要不要把 Push to Talk / 推送的 entitlement 编进工程。

    **默认不编**,因为免费的个人开发者 team 拿不到这两项能力,Xcode 会直接
    拒绝生成描述文件:

        Personal development teams, including "...", do not support the
        Push to Talk and Push Notifications capabilities.

    而这个 target 是整个仓库唯一的 iOS target —— 一旦签名失败,BLE 中继、
    配置页、固件页**全都装不上**,不只是对讲机。用免费账号的人会看到一堆
    描述文件报错,而完全猜不到根因是对讲机的后台唤醒能力。

    关掉之后对讲机照常能用:SystemPushToTalk 初始化失败会退回前台模式
    (SystemPushToTalk.swift:49/53),WalkieClient 每处使用都用
    systemPTTAvailable?() 守着。代价只是 iOS 上收不到后台来话唤醒。

    有付费账号、并且已经向 Apple 申请到 PTT 授权的话:

        WALKIE_PTT=1 ./install-ios.sh
    """
    if os.environ.get("WALKIE_PTT", "").lower() in ("1", "true", "yes"):
        return '\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = "FoloCodexRelay/FoloCodexRelay.entitlements";'
    return ""


def uid(*parts):
    """稳定的 24 位十六进制 ID。pbxproj 要求 12 字节。"""
    h = hashlib.md5("|".join(parts).encode()).hexdigest()
    return h[:24].upper()


def main():
    src_abs = os.path.join(ROOT, REL, SRC_DIR)
    if not os.path.isdir(src_abs):
        sys.exit(f"找不到源码目录: {src_abs}")
    # ⚠ 递归 —— 源码是分层放的(Framework/ Capabilities/ Apps/<应用>/),
    # 不是平铺。用 os.listdir 只会扫到零个文件,生成一个能打开但编不过的
    # 工程:Xcode 不报"少了文件",只报几百条"cannot find X in scope"。
    #
    # pbxproj 里用**相对 SRC_DIR 的路径**当 file ref 的 path(带斜杠),
    # 它相对所在 group 的 path 解析,所以不需要为每层建 PBXGroup。
    sources = sorted(
        os.path.relpath(os.path.join(dirpath, f), src_abs)
        for dirpath, _dirs, files in os.walk(src_abs)
        for f in files if f.endswith(".swift")
    )
    if not sources:
        sys.exit(f"{SRC_DIR} 下一个 .swift 都没有")

    file_refs, build_files, src_children, phase_files = [], [], [], []
    for name in sources:
        fref = uid("fileref", name)
        bfile = uid("buildfile", name)
        file_refs.append(
            f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = {name}; '
            f'sourceTree = "<group>"; }};'
        )
        build_files.append(
            f'\t\t{bfile} /* {name} in Sources */ = {{isa = PBXBuildFile; '
            f'fileRef = {fref} /* {name} */; }};'
        )
        src_children.append(f'\t\t\t\t{fref} /* {name} */,')
        phase_files.append(f'\t\t\t\t{bfile} /* {name} in Sources */,')

    ptt = ptt_entitlements()

    if not ptt:

        print("  Push to Talk entitlement: 关(免费账号装不上带这个的 app)")

        print("    要开:WALKIE_PTT=1,需要付费 team + Apple 的 PTT 授权")


    ids = {k: uid(k) for k in (
        "project", "target", "product", "maingroup", "sharedgroup",
        "productgroup", "sourcesphase", "frameworksphase", "resourcesphase",
        "projconflist", "targetconflist", "projdebug", "projrelease",
        "configphase",
        "targetdebug", "targetrelease", "catalogref", "catalogbuild",
        "manifestsref", "manifestsbuild",
    )}

    # 应用自己的配置必须在签名前写进 bundle。install-ios.sh 默认打开该开关；
    # helper 只复制 server 和无敏感性的鉴权提示位，token 始终不会进入应用产物。
    config_script = (
        'python3 \\"${SRCROOT}/../tools/update_firmware_catalog.py\\" --check '
        '--firmware \\"${SRCROOT}/AppCatalog/current-firmware.bin\\" '
        '--catalog \\"${SRCROOT}/AppCatalog/catalog.json\\"\\n'
        'bundle_dir=\\"${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}\\"\\n'
        'rm -f \\"${bundle_dir}/meal.json\\" \\"${bundle_dir}/walkie.json\\"\\n'
        'if [ \\"${FOLO_BUNDLE_CONFIG:-0}\\" = 1 ]; then\\n'
        '  python3 \\"${SRCROOT}/bundle-app-configs.py\\" \\"${bundle_dir}\\"\\n'
        'else\\n'
        '  echo \\"\\u5e94\\u7528\\u670d\\u52a1\\u5730\\u5740\\u672a\\u6253\\u5305\\"\\n'
        'fi'
    )

    text = f'''// !$*UTF8*$!
// 由 tools/gen_ios_project.py 生成,不要手工编辑 —— 重跑脚本即可。
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
		{ids["catalogbuild"]} /* AppCatalog in Resources */ = {{isa = PBXBuildFile; fileRef = {ids["catalogref"]} /* AppCatalog */; }};
		{ids["manifestsbuild"]} /* AppManifests in Resources */ = {{isa = PBXBuildFile; fileRef = {ids["manifestsref"]} /* AppManifests */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
		{ids["product"]} /* FoloCodexRelay.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FoloCodexRelay.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{ids["catalogref"]} /* AppCatalog */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = AppCatalog; path = AppCatalog; sourceTree = "<group>"; }};
		{ids["manifestsref"]} /* AppManifests */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = AppManifests; path = AppManifests; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
		{ids["maingroup"]} = {{
			isa = PBXGroup;
			children = (
				{ids["sharedgroup"]} /* Shared */,
				{ids["catalogref"]} /* AppCatalog */,
				{ids["manifestsref"]} /* AppManifests */,
				{ids["productgroup"]} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids["sharedgroup"]} /* Shared */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(src_children)}
			);
			path = {SRC_DIR};
			sourceTree = "<group>";
		}};
		{ids["productgroup"]} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids["product"]} /* FoloCodexRelay.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids["target"]} /* FoloCodexRelay */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids["targetconflist"]};
			buildPhases = (
				{ids["sourcesphase"]},
				{ids["frameworksphase"]},
				{ids["resourcesphase"]},
				{ids["configphase"]},
			);
			buildRules = ();
			dependencies = ();
			name = FoloCodexRelay;
			productName = FoloCodexRelay;
			productReference = {ids["product"]} /* FoloCodexRelay.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXShellScriptBuildPhase section */
		{ids["configphase"]} /* 打包应用配置 */ = {{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = ();
			inputPaths = (
				"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",
			);
			name = "\u6253\u5305\u5e94\u7528\u914d\u7f6e";
			outputPaths = ();
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "{config_script}";
		}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXProject section */
		{ids["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{ids["target"]} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {ids["projconflist"]};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base);
			mainGroup = {ids["maingroup"]};
			productRefGroup = {ids["productgroup"]} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids["target"]} /* FoloCodexRelay */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids["resourcesphase"]} = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids["catalogbuild"]} /* AppCatalog in Resources */,
				{ids["manifestsbuild"]} /* AppManifests in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids["sourcesphase"]} = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(phase_files)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		{ids["frameworksphase"]} = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = ();
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids["projdebug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{ids["projrelease"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{ids["targetdebug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = "";
				APS_ENVIRONMENT = development;
				CODE_SIGN_STYLE = Automatic;{ptt}
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "FoloCodexRelay/Info-iOS.plist";
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{ids["targetrelease"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = "";
				APS_ENVIRONMENT = production;
				CODE_SIGN_STYLE = Automatic;{ptt}
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "FoloCodexRelay/Info-iOS.plist";
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids["projconflist"]} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids["projdebug"]} /* Debug */,
				{ids["projrelease"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids["targetconflist"]} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids["targetdebug"]} /* Debug */,
				{ids["targetrelease"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids["project"]} /* Project object */;
}}
'''

    os.makedirs(PROJ, exist_ok=True)
    out = os.path.join(PROJ, "project.pbxproj")
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"生成完成: {out}")
    print(f"  {len(sources)} 个源文件(只有 Shared/ 及其子目录,macOS/ 不参与 iOS 构建)")
    print(f"  Bundle ID: {BUNDLE_ID}")
    print("  DEVELOPMENT_TEAM 不写入工程;真机构建时由 install-ios.sh 临时传入")


if __name__ == "__main__":
    main()

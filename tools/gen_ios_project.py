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


def _flag(name):
    return os.environ.get(name, "").lower() in ("1", "true", "yes")


def entitlements_line():
    """要不要把需要付费开发者账号的 entitlement 编进工程,编哪几项。

    Push to Talk / 推送、NFC 标签读写,这几项**都**要求付费 Apple Developer
    Program(PTT 还额外要 Apple 的授权)。免费个人 team 申请其中任何一项,
    Xcode 都会直接拒绝生成描述文件:

        Personal development teams, including "...", do not support the
        Push to Talk and Push Notifications capabilities.

    同样的失败模式对 NFC 也成立。而这个 target 是整个仓库唯一的 iOS
    target —— 一旦签名失败,BLE 中继、配置页、固件页**全都装不上**,不只是
    出问题的那一个功能。

    ⚠ 每一项单独开关、**默认全关**,不能绑在一起申请:免费账号的人可能只
    想用 NFC、完全不碰对讲机的后台唤醒(反之亦然)。所以 entitlements 文件
    不是手工维护的静态内容,而是这个函数按开关**动态生成**再写盘 ——
    这样才能做到"只申请打开的那几项",不会因为文件里躺着一条没打开的 PTT
    声明,就把只想要 NFC 的构建也拖进签名失败。

    关掉 PTT 之后对讲机照常能用:SystemPushToTalk 初始化失败会退回前台模式
    (SystemPushToTalk.swift:49/53),WalkieClient 每处使用都用
    systemPTTAvailable?() 守着,代价只是 iOS 上收不到后台来话唤醒。
    关掉 NFC 之后 NFCTagIO.isSupported 返回 false,读写页面会提示"此设备
    不支持 NFC",不影响其它功能。

    有付费账号:

        WALKIE_PTT=1 ./install-ios.sh   # 还需要已向 Apple 申请到的 PTT 授权
        NFC_TAG=1    ./install-ios.sh
    """
    want_ptt = _flag("WALKIE_PTT")
    want_nfc = _flag("NFC_TAG")

    entries = []
    if want_ptt:
        entries.append("\t<key>aps-environment</key>\n\t<string>$(APS_ENVIRONMENT)</string>")
        entries.append("\t<key>com.apple.developer.push-to-talk</key>\n\t<true/>")
    if want_nfc:
        entries.append(
            "\t<key>com.apple.developer.nfc.readersession.formats</key>\n"
            "\t<array>\n\t\t<string>NDEF</string>\n\t</array>"
        )

    print("  Push to Talk entitlement: " + ("开" if want_ptt else "关(免费账号装不上带这个的 app)"))
    if not want_ptt:
        print("    要开:WALKIE_PTT=1,需要付费 team + Apple 的 PTT 授权")
    print("  NFC 标签读写 entitlement: " + ("开" if want_nfc else "关(免费账号装不上带这个的 app)"))
    if not want_nfc:
        print("    要开:NFC_TAG=1,需要付费 team")

    ent_path = os.path.join(ROOT, REL, "FoloCodexRelay", "FoloCodexRelay.entitlements")
    if not entries:
        return ""

    body = "\n".join(entries)
    text = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        "<plist version=\"1.0\">\n<dict>\n" + body + "\n</dict>\n</plist>\n"
    )
    with open(ent_path, "w", encoding="utf-8") as f:
        f.write(text)
    return '\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = "FoloCodexRelay/FoloCodexRelay.entitlements";'


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

    sign_entitlements = entitlements_line()


    ids = {k: uid(k) for k in (
        "project", "target", "product", "maingroup", "sharedgroup",
        "productgroup", "sourcesphase", "frameworksphase", "resourcesphase",
        "projconflist", "targetconflist", "projdebug", "projrelease",
        "configphase",
        "targetdebug", "targetrelease", "catalogref", "catalogbuild",
        "manifestsref", "manifestsbuild",
    )}

    # 应用自己的配置随构建打进 bundle。
    #
    # ⚠ 必须是构建阶段,不能构建完再拷:产物是签过名的,事后往里塞文件
    # 会让签名失效,装机时报 "invalid code signature"。
    #
    # 用 /bin/sh 写,不用 compgen(那是 bash 内建,Xcode 的脚本阶段默认 sh)。
    config_script = (
        'rm -f \\"${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}/meal.json\\"\\n'
        'for f in \\"$HOME\\"/.folotoy/*.json; do\\n'
        '  [ -e \\"$f\\" ] || continue\\n'
        '  cp \\"$f\\" \\"${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}/\\"\\n'
        '  echo \\"\\u5df2\\u6253\\u5305: $(basename \\"$f\\")\\"\\n'
        'done'
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
				CODE_SIGN_STYLE = Automatic;{sign_entitlements}
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "FoloCodexRelay/Info-iOS.plist";
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.folotoy.codexrelay;
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
				CODE_SIGN_STYLE = Automatic;{sign_entitlements}
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "FoloCodexRelay/Info-iOS.plist";
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.folotoy.codexrelay;
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
    print("  DEVELOPMENT_TEAM 不写入工程;真机构建时由 install-ios.sh 临时传入")


if __name__ == "__main__":
    main()

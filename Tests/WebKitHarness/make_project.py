#!/usr/bin/env python3
"""Generate a separate, unsigned iOS XCTest project from the exact checkout script source."""

import argparse
import hashlib
import plistlib
import shutil
from pathlib import Path
from xml.sax.saxutils import quoteattr


def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def generate(app_source, output, simulator_swift_libraries=None):
    harness = Path(__file__).resolve().parent
    source = app_source / "Y3Client" / "LegacySiteSupport.swift"
    if not source.is_file():
        raise SystemExit("App source must contain Y3Client/LegacySiteSupport.swift")
    launch_environment = ""
    if simulator_swift_libraries is not None:
        simulator_swift_libraries = simulator_swift_libraries.resolve()
        if not (simulator_swift_libraries / "libswiftWebKit.dylib").is_file():
            raise SystemExit("The selected simulator Swift directory must contain libswiftWebKit.dylib")
        launch_environment = (
            '<EnvironmentVariables><EnvironmentVariable key="DYLD_FALLBACK_LIBRARY_PATH" value='
            + quoteattr(str(simulator_swift_libraries))
            + ' isEnabled="YES"/></EnvironmentVariables>'
        )
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Harness output must be an empty directory")
    sources = output / "Sources"
    sources.mkdir()
    for filename in ["HarnessApp.swift", "WebKitRuntimeTests.swift"]:
        shutil.copyfile(harness / filename, sources / filename)
    shutil.copyfile(source, sources / "LegacySiteSupport.swift")
    shutil.copyfile(app_source / "Y3Client" / "ReportPresentation.swift", sources / "ReportPresentation.swift")
    info = {
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSRequiresIPhoneOS": True,
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoadsInWebContent": True},
        "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    }
    (sources / "Info.plist").write_bytes(plistlib.dumps(info))

    objects = {}

    def add(name, body):
        objects[identifier(name)] = body
        return identifier(name)

    def q(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

    def refs(names):
        return "(" + ",".join(identifier(name) for name in names) + ",)"

    for name, path, filetype in [
        ("appSource", "HarnessApp.swift", "sourcecode.swift"),
        ("legacySource", "LegacySiteSupport.swift", "sourcecode.swift"),
        ("reportSource", "ReportPresentation.swift", "sourcecode.swift"),
        ("testSource", "WebKitRuntimeTests.swift", "sourcecode.swift"),
        ("info", "Info.plist", "text.plist.xml"),
    ]:
        add(name, f'isa=PBXFileReference;lastKnownFileType={filetype};path={q(path)};sourceTree="<group>";')
    for name, path, filetype in [("appProduct", "WKRuntimeHarness.app", "wrapper.application"),
                                  ("testProduct", "WKRuntimeTests.xctest", "wrapper.cfbundle")]:
        add(name, f'isa=PBXFileReference;explicitFileType={filetype};path={q(path)};sourceTree=BUILT_PRODUCTS_DIR;')
    for name, reference in [("appBuild", "appSource"), ("legacyBuild", "legacySource"), ("reportBuild", "reportSource"), ("testBuild", "testSource")]:
        add(name, f'isa=PBXBuildFile;fileRef={identifier(reference)};')
    add("sourceGroup", f'isa=PBXGroup;children={refs(["appSource", "legacySource", "reportSource", "testSource", "info"])};path=Sources;sourceTree="<group>";')
    add("productGroup", f'isa=PBXGroup;children={refs(["appProduct", "testProduct"])};name=Products;sourceTree="<group>";')
    add("mainGroup", f'isa=PBXGroup;children={refs(["sourceGroup", "productGroup"])};sourceTree="<group>";')
    for phase, builds in [("appSources", ["appBuild", "legacyBuild", "reportBuild"]), ("testSources", ["testBuild"])]:
        add(phase, f'isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files={refs(builds)};runOnlyForDeploymentPostprocessing=0;')
    for phase in ["appFrameworks", "testFrameworks"]:
        add(phase, 'isa=PBXFrameworksBuildPhase;buildActionMask=2147483647;files=();runOnlyForDeploymentPostprocessing=0;')
    add("appProxy", f'isa=PBXContainerItemProxy;containerPortal={identifier("project")};proxyType=1;remoteGlobalIDString={identifier("appTarget")};remoteInfo=WKRuntimeHarness;')
    add("appDependency", f'isa=PBXTargetDependency;target={identifier("appTarget")};targetProxy={identifier("appProxy")};')
    add("appTarget", f'isa=PBXNativeTarget;buildConfigurationList={identifier("appConfigList")};buildPhases={refs(["appSources", "appFrameworks"])};buildRules=();dependencies=();name=WKRuntimeHarness;productName=WKRuntimeHarness;productReference={identifier("appProduct")};productType="com.apple.product-type.application";')
    add("testTarget", f'isa=PBXNativeTarget;buildConfigurationList={identifier("testConfigList")};buildPhases={refs(["testSources", "testFrameworks"])};buildRules=();dependencies={refs(["appDependency"])};name=WKRuntimeTests;productName=WKRuntimeTests;productReference={identifier("testProduct")};productType="com.apple.product-type.bundle.unit-test";')
    common = {
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CODE_SIGNING_ALLOWED": "NO", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        "SWIFT_STRICT_CONCURRENCY": "minimal", "TARGETED_DEVICE_FAMILY": "1",
        "DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES",
    }
    app_settings = {"INFOPLIST_FILE": "Sources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.y3pos.wkruntime"}
    test_settings = {"GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_NAME": "$(TARGET_NAME)",
                     "PRODUCT_BUNDLE_IDENTIFIER": "org.example.y3pos.wkruntime.tests",
                     "BUNDLE_LOADER": "$(TEST_HOST)", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/WKRuntimeHarness.app/WKRuntimeHarness"}
    for prefix, settings in [("project", common), ("app", app_settings), ("test", test_settings)]:
        build_settings = "".join(f'{key}={q(value)};' for key, value in settings.items())
        add(prefix + "Config", f'isa=XCBuildConfiguration;buildSettings={{{build_settings}}};name=Debug;')
        add(prefix + "ConfigList", f'isa=XCConfigurationList;buildConfigurations={refs([prefix + "Config"])};defaultConfigurationIsVisible=0;defaultConfigurationName=Debug;')
    add("project", f'isa=PBXProject;attributes={{LastUpgradeCheck=1640;TargetAttributes={{{identifier("testTarget")}={{TestTargetID={identifier("appTarget")};}};}};}};buildConfigurationList={identifier("projectConfigList")};compatibilityVersion="Xcode 14.0";developmentRegion=en;hasScannedForEncodings=0;knownRegions=(en,Base,);mainGroup={identifier("mainGroup")};productRefGroup={identifier("productGroup")};projectDirPath="";projectRoot="";targets={refs(["appTarget", "testTarget"])};')
    project = output / "WKRuntimeHarness.xcodeproj"
    schemes = project / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True)
    text = "// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={\n"
    text += "\n".join(f"{key}={{{value}}};" for key, value in objects.items())
    text += f'\n}};rootObject={identifier("project")};}}\n'
    (project / "project.pbxproj").write_text(text)
    workspace = project / "project.xcworkspace"
    workspace.mkdir()
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')

    def reference(target, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(target)}" BuildableName="{product}" BlueprintName="{product.split(".")[0]}" ReferencedContainer="container:WKRuntimeHarness.xcodeproj"/>'

    app_ref = reference("appTarget", "WKRuntimeHarness.app")
    test_ref = reference("testTarget", "WKRuntimeTests.xctest")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
<BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>{launch_environment}</LaunchAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Debug" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemes / "WKRuntimeHarness.xcscheme").write_text(scheme)
    print(project)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--simulator-swift-libraries", type=Path,
                        help="Test-only runtime Cryptex Swift directory containing libswiftWebKit.dylib")
    args = parser.parse_args()
    generate(args.app_source.resolve(), args.output.resolve(), args.simulator_swift_libraries)

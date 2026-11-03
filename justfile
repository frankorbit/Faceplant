# Faceplant 开发命令

default: check

# 重新生成 Xcode 工程
gen:
    xcodegen generate

# 全量检查：lint + 格式 + 真机 SDK 编译
check: lint format-check build

lint:
    swiftlint lint --strict --quiet

format:
    swiftformat .

format-check:
    swiftformat --lint .

# 不签名编译，验证代码在 iphoneos SDK 下可通过
build:
    xcodebuild -project Faceplant.xcodeproj -scheme Faceplant -sdk iphoneos -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet

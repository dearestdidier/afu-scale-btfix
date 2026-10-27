# AFUScale (Combined)

AFU-SCALE 体脂秤 iOS App — 合并自两个开源项目，解决各自的问题：

| 项目 | 蓝牙连接 | HealthKit |
|------|----------|-----------|
| Fatpandac/AFUScale | ✅ | ❌ (无 entitlement) |
| Aoko-Aozaki/ant-afu-scale | ❌ (扫描问题) | ✅ |
| **本项目 (合并版)** | ✅ | ✅ |

## 一键构建 IPA

推送到 GitHub 后，Actions 会自动构建，在 Artifacts 里下载 AFUScale.ipa。

`ash
git add .
git commit -m "init"
git push
`

## 安装 (TrollStore)

1. Actions 跑完后点 Artifacts 下载 AFUScale.ipa
2. 用 TrollStore 安装到 iPhone

## 本地开发

需要 macOS + Xcode 15+：

`ash
brew install xcodegen
xcodegen generate
open AFUScale.xcodeproj
`

## 修改 Bundle ID

编辑 project.yml 的 PRODUCT_BUNDLE_IDENTIFIER 字段。
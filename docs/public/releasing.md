# macOS ARM64 发布

## 构建

在 Apple Silicon Mac 上执行：

```bash
./scripts/test.sh
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
./scripts/release.sh v0.1.0
```

发布脚本独立使用 `.build/release-arm64/`，以 Release 配置和 `--arch arm64` 构建，不覆盖正在运行的开发 App。构建映射源码路径、移除调试符号、核验 App 和 CLI 都只有 ARM64 架构，并签名 App 与 CLI。

`dist/` 输出：

- `huantai-v0.1.0-macos-arm64.dmg`：换台 App 与 Applications 安装入口。
- `huantai-cli-v0.1.0-macos-arm64.tar.gz`：`ht` 与命令行使用说明。
- `SHA256SUMS.txt`：两个产物的 SHA-256 校验。

默认使用临时签名，不包含 Apple Developer ID 签名或公证。若本机配置了 Developer ID，可通过 `HUANTAI_SIGNING_IDENTITY` 指定签名身份；脚本仍不会自动提交 Apple 公证。发布说明应如实列明签名状态。

## 标签与 GitHub Release

```bash
git tag -a v0.1.0 -m "Release v0.1.0 for macOS ARM64"
git push origin main
git push origin v0.1.0
gh release create v0.1.0 \
  dist/huantai-v0.1.0-macos-arm64.dmg \
  dist/huantai-cli-v0.1.0-macos-arm64.tar.gz \
  dist/SHA256SUMS.txt \
  --verify-tag --title "换台 v0.1.0 · macOS ARM64" \
  --notes-file release-notes.md
```

产物必须对应已验证的标签内容。发布后重新下载附件，检查 SHA-256，再从安装包解出 App 检查架构、版本及代码签名；远端提交和标签应与本地一致。源码或标签存在不等于已上传可下载的产物。

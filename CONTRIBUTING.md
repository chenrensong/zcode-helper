# 贡献指南

感谢你关注 ZCode Helper!欢迎通过 Issue 与 Pull Request 参与贡献。

## 开发环境

- Flutter 3.47+（stable channel），Dart 3.12+
- macOS 构建需要 Xcode；Windows 构建需要 Visual Studio（含 C++ 桌面开发工作负载）

```bash
git clone https://github.com/chenrensong/zcode-helper.git
cd zcode-helper
flutter pub get
```

## 提交 PR 前

1. `flutter analyze` 无告警；
2. `flutter test` 全部通过——**尤其改动 `lib/core/crypto.dart`、`lib/services/switcher.dart`
   或任何加密相关代码时**，`test/crypto_compat_test.dart` 内含与 Node 实现的
   跨语言加密夹具，必须保持全绿；
3. 新功能请附带单元测试（现有测试都在 `test/` 下，用 Fake 替代平台桥，可直接参考）；
4. UI 文案保持中文（与现有界面一致）。

## 提交规范

使用 Conventional Commits 风格的提交信息：`feat:` / `fix:` / `docs:` / `refactor:`
/ `test:` / `chore:`。

## 分支与发布

- `main` 为开发主线，PR 合入后 CI 自动构建双平台产物；
- 以 `v*` tag 触发正式发布（自动创建 GitHub Release 并附带安装包）；
- 显著变更请同步更新 [CHANGELOG.md](CHANGELOG.md)。

## 行为准则

保持友善与专业，对事不对人。

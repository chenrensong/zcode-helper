# Changelog

本项目的所有显著变更都记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

## [1.0.0] - 2026-08-16

首个公开版本。

### 新增

- **双体系 OAuth 登录**：Z.ai（全球区，chat.z.ai）与 BigModel（中国区，bigmodel.cn）；
  浏览器授权 + 本地 loopback 回调自动完成，支持手动粘贴授权码兜底；BigModel
  登录后自动派生 coding-plan key。
- **账号快照库**：捕获 `~/.zcode/v2` 登录态为本地加密快照（AES-256-GCM，
  `enc:v1` 格式，与 ZCode 客户端字节级兼容），支持重命名、备注、删除、导入/导出。
- **一键安全切换**：自动备份 → 原子写入 → 清理缓存 → 自动重启 ZCode；
  BigModel 账号自动标准化为原生 cached-profile（v2）；切换失败可从 `~/.zcas/.last`
  一键回滚。
- **额度查询**：BigModel quota/limit 接口优先，Z.ai usage、billing 兜底，
  归一化展示用量/余额/档位/重置时间。
- **多开实例**：隔离数据目录的多 ZCode 实例（macOS 重定向 HOME，Windows 使用
  `ZCODE_DESKTOP_HOME_DIR`），可绑定账号快照。
- **健康检查**：过期令牌、损坏凭据、重复账号识别。
- **CI**：GitHub Actions 双平台（macOS / Windows）自动构建，打 tag 自动发布 Release。
- 原生 Flutter 实现（macOS Swift / Windows C++ 平台桥），无 Electron、无遥测。

[Unreleased]: https://github.com/chenrensong/zcode-helper/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/chenrensong/zcode-helper/releases/tag/v1.0.0

# 本地开发调试与打包指南

本文档只保留本地开发中最常用的方式：临时调试、以及打包出一个可安装的 DMG。签名/公证等对外分发流程见 [docs/release-signing.md](./release-signing.md) 和 [docs/releasing.md](./releasing.md)。

## 环境要求

- macOS 14+（开发机建议 15+）
- Xcode / Swift 6.2 工具链（`swift --version` 确认）
- 打包 DMG 需要 `create-dmg`：
  ```bash
  brew install create-dmg
  ```

## 一、临时调试：Open Island Dev.app

`~/Applications/Open Island Dev.app` 是仓库代码的 debug 构建套壳，是真正的 `.app`，能测试菜单栏图标、Dock、通知等真实行为，并会自动装好 Agent Hooks。

**首次使用，先做一次性签名设置**（否则每次 `swift build` 后 App 的 cdhash 都会变，系统会静默吊销已授予的「辅助功能」权限，导致相关功能反复要求重新授权）：

```bash
zsh scripts/setup-dev-signing.sh
```

**之后每次改完代码，用这条命令启动/刷新开发 App**（不要用 `open -na` 手动启动代替，那样打开的是上一次的构建产物）：

```bash
zsh scripts/launch-dev-app.sh
```

## 二、打包 DMG（本地自用安装）

```bash
zsh scripts/package-app.sh
```

流程：`swift build -c release` 编译三个产物 → 组装 `.app` bundle → 校验并冒烟测试 → 未配置签名身份时自动走 ad-hoc 签名 → 用 `create-dmg` 生成 DMG。

产物：

```
output/package/Open Island.app
output/package/Open Island.zip
output/package/Open Island.dmg
```

安装：

```bash
open "output/package/Open Island.dmg"
# 拖 Open Island.app 到 Applications 即可
```

**「无法打开，因为无法验证开发者」/「已损坏，无法打开」**：ad-hoc 签名触发的 Gatekeeper 隔离提示，本机自用直接放行：

```bash
# 方式一：右键点击 App → 打开 → 再次确认「打开」（只需一次）
# 方式二：命令行去隔离属性
xattr -dr com.apple.quarantine "/Applications/Open Island.app"
```

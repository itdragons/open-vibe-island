# WG 发布流水线与上游同步设计

## 背景

`itdragons/open-vibe-island` 是 `Octane0411/open-vibe-island` 的真实 GitHub fork。`wg` 分支在此基础上
新增了信号灯（signal-light）模块，并把应用重命名为 "WG Open Island"（`scripts/package-app.sh` 中
`app_name` 默认值已改，`Info.plist` 增加了 `NSBluetoothAlwaysUsageDescription`）。

现有的 `.github/workflows/release.yml` 是上游的发布流水线，绑定了上游专属的资源：
- Apple 签名/公证密钥（上游账号）
- Sparkle EdDSA 签名 + `appcast.xml`（指向 `raw.githubusercontent.com/Octane0411/...`）
- `Octane0411/homebrew-tap` 推送
- `Octane0411/open-vibe-island` 专属的 contributors 图片刷新

这套流水线不适合直接套用在 `wg` 分支上。需要：
1. 一条只属于这个 fork、产出 "WG Open Island" 安装包的发布流水线。
2. 一套简单可重复的流程，把上游的新提交同步进 `wg` 分支，同时不丢失信号灯相关的改动。

## 仓库拓扑

- **`main`**：纯上游镜像。只通过 GitHub 的 fork 关系（`gh repo sync` 或网页 "Sync fork" 按钮）保持与
  `Octane0411/open-vibe-island` 一致，不在这个分支上开发。
- **`wg`**：长期存在的产品分支，承载信号灯模块和 WG 品牌化改动。所有 feature 分支从 `wg` 切出，
  PR 合回 `wg`（不合回 `main`）。发布只从 `wg` 出。

## 组件一：WG 发布流水线（`.github/workflows/wg-release.yml`）

新建文件，不修改现有 `release.yml`（后者继续跟随上游变化，保持可 diff/可参考）。

**触发方式**：
- `push: tags: ['wg-v*']` — 正式发布。
- `workflow_dispatch`，必填输入 `version`（例如 `1.2.1-dev1`）——手动触发时，workflow 先以此输入
  创建并推送 `wg-v<version>` tag，然后走与 tag-push 完全相同的后续步骤。手动触发和 tag 触发最终
  都统一在 Releases 页面产出一个 draft release，只维护一条路径。

**构建步骤**：
1. `actions/checkout@v4`
2. 安装依赖：`create-dmg`、`Pillow`
3. 调用 `scripts/package-app.sh`，环境变量：
   - `OPEN_ISLAND_APP_NAME`：使用脚本默认值 `WG Open Island`
   - `OPEN_ISLAND_BUNDLE_ID=app.openisland.wg`（新增，独立于上游的 `app.openisland.OpenIsland`，
     避免 TCC 授权/LaunchAgent/Sparkle 更新器身份冲突）
   - `OPEN_ISLAND_VERSION`：来自 tag
   - `OPEN_ISLAND_BUILD_NUMBER`：`github.run_number`
   - `OPEN_ISLAND_UNIVERSAL=true`（arm64 + x86_64，与上游发布件保持一致）
   - **不设置** `OPEN_ISLAND_SIGN_IDENTITY` → 复用脚本里已有的 ad-hoc 签名分支，无需 Apple 开发者
     证书/密钥
   - `OPEN_ISLAND_SPARKLE_FEED_URL`：见组件二
4. 校验产物存在（`.dmg`/`.zip`）、`codesign --verify --deep --strict`（ad-hoc 签名下仍可结构性验证）、
   bundle 必需文件检查——精简版，复用 `release.yml` 里已验证过的检查逻辑。
5. EdDSA 签名 + 更新 `appcast-wg.xml`（见组件二）。
6. `gh release create`，tag 为 `wg-v*`，`--draft`，上传 `WG Open Island.dmg` / `.zip`，
   安装说明注明"未公证，右键打开以绕过 Gatekeeper"。

**明确不做**（上游专属逻辑，直接删除，不迁移）：Apple 公证、`Octane0411/homebrew-tap` 推送、
contributors 图片刷新 PR。

## 组件二：Sparkle 自动更新（独立 appcast + EdDSA，不依赖 Apple 签名）

Apple 代码签名/公证 和 Sparkle 更新签名是两条独立的信任链——后者只是一对本地生成的 Ed25519
密钥，不需要 Apple 开发者账号。即使 WG 安装包暂不做 Apple 签名，也可以让"检查更新"正常工作。

- 一次性生成一对 EdDSA 密钥，私钥存入 `itdragons/open-vibe-island` 仓库的 GitHub Secrets
  （例如 `WG_SPARKLE_EDDSA_KEY`），公钥编译进 `Info.plist`。
- `scripts/package-app.sh` 新增 `OPEN_ISLAND_SPARKLE_FEED_URL` 环境变量，默认值仍是上游 URL
  （不影响上游自身构建），`Info.plist` 的 `SUFeedURL` 改为读取该变量。
- `wg-release.yml` 中：
  - 传入 `OPEN_ISLAND_SPARKLE_FEED_URL=https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/appcast-wg.xml`
  - 对 `.zip` 做 EdDSA 签名（复用上游 `sign_update` 工具，换成 WG 的私钥）
  - 更新仓库里的 `appcast-wg.xml`（与上游 `appcast.xml` 是两个独立文件，互不影响），提交回 `wg` 分支

这样用户点"检查更新"时，会拉到你自己发布的 WG 版本，而不是报错或误拉上游版本。

## 组件三：上游同步流程（手动按需，`scripts/sync-upstream.sh`）

不做定时自动化（按用户选择：按需手动同步）。脚本把步骤固定下来，减少每次回忆命令的成本：

1. `gh repo sync --branch main`（或提示改用网页 "Sync fork" 按钮）——利用真实 fork 关系，让
   `origin/main` 快进到上游最新，无需额外配置 `upstream` remote。
2. `git fetch origin`，`git checkout main && git pull --ff-only origin main`。
3. 创建临时分支 `sync/wg-<date>`（从当前 `wg` 切出），在临时分支上 `git merge main`。
   - **不直接在 `wg` 上 merge**——先在临时分支合并、构建验证，确认无误后再手动合入 `wg`，
     降低把坏的合并结果直接留在长期分支上的风险。
   - 使用 **merge**，不用 rebase：`wg` 已推送到远端且是团队可见的产品分支，rebase 需要
     force-push，历史上也一直是用 merge commit（如 `Merge branch 'wg' of origin into wg`）。
4. 有冲突时，脚本停下并打印冲突文件列表。已知容易冲突的点（写进脚本注释里，帮助人工排查）：
   - `Assets/Brand/*`（图标资源，两边都可能改动同一批文件）
   - `scripts/package-app.sh` 的 `app_name` 默认值那一行
   - `Info.plist` 模板里新增的 `NSBluetoothAlwaysUsageDescription` / `SUFeedURL` 变量化部分
5. 冲突解决后，脚本在临时分支跑一次 `swift build`（结构性验证），确认无误后由人工执行
   `git checkout wg && git merge sync/wg-<date>` 并推送。

## 风险

- EdDSA 私钥一旦泄露，任何人都能伪造"更新"推送恶意包给 WG 用户——只能放在 GitHub Secrets，
  绝不进代码库。
- `gh repo sync` 只同步默认分支（`main`）；如果上游在其他分支/tag 发布 hotfix，需要人工关注，
  脚本不覆盖这种情况。
- 合并后如遇到 `Info.plist` 模板、`package-app.sh`、`Assets/Brand/*` 的结构性冲突，需要重新走一遍
  `package-app.sh` 自带的启动冒烟测试，确认应用没有崩溃。

## 验证计划

1. `swift build` / `swift test` 通过（沿用现有 CI harness）。
2. 本地跑一次 `scripts/package-app.sh`（不设签名身份），确认 WG 版能正常打包、冒烟测试通过。
3. 用 `workflow_dispatch` 手动跑一次 `wg-release.yml`，确认 draft release、`appcast-wg.xml` 都按预期生成。
4. 用 `sync-upstream.sh` 在临时分支上跑一次真实同步，人工检查冲突提示是否准确、构建是否仍然通过。

## 范围之外

- 不改动 `.github/workflows/release.yml`、`ci.yml`（上游自己的流水线，保持不动方便对比/合并）。
- 不做 Apple 代码签名/公证（本次明确选择暂不做，后续如需要再单独立项）。
- 不做上游同步的定时自动化（本次明确选择手动按需）。

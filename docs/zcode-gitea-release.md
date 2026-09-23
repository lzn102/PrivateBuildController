# XCode macOS ARM Gitea Release

`.github/workflows/zcode-macos-arm-release.yml` 从 Gitea 拉取指定完整 commit SHA，在
`macos-14` 上执行 `ci/build.sh macos-arm64 <output-directory>`，然后创建 XCode/ZCode
的草稿 Release，上传 DMG、ZIP、逐文件 SHA-256 和 Electron 更新 manifest，最后将草稿
Release 发布。

正式发布只接受手动触发，且 `github.actor` 必须等于 `TRUSTED_ACTOR`。需要在控制仓库
设置：

- `GITEA_SOURCE_TOKEN`：读取私有源码时使用；
- `GITEA_PACKAGE_TOKEN`：创建 Release、上传资产和发布草稿所需的 Gitea token；工作流会将它映射到发布脚本使用的 `GITEA_RELEASE_TOKEN` 环境变量；
- `SOURCE_REPO_URL` 或 workflow 输入中的 Gitea 源地址；
- `REPOSITORY_API_URL`：以 `/api/v1/repos/<owner>/<repo>` 结尾的 Gitea API 地址；
- `TAILSCALE_OAUTH_CLIENT_ID`、`TAILSCALE_OAUTH_SECRET`、`TAILSCALE_TAGS`；
- `TRUSTED_ACTOR`：允许执行发布的 GitHub 用户名。

`release_tag` 可留空，脚本会使用源码根 `package.json` 的版本生成 `v<version>`；如果
填写，必须与该版本一致。同一个 tag 已存在 Release 时流程直接失败，不覆盖已发布资产。

发布资产包括：

- `XCode-<version>-mac-arm64.dmg`：人工下载安装包；
- `XCode-<version>-mac-arm64.zip`：macOS 自动更新使用的归档；
- 两个安装包各自的 `.sha256` 文件；
- `latest-darwin-aarch64.yml`：自建更新服务的 canonical manifest；
- `latest-mac.yml`：传统 electron-updater 命名兼容文件。

manifest 中的 URL 指向同一个 Gitea Release 的下载资产，包含版本、文件大小、SHA-256
和 SHA-512。已打包桌面端仍请求自建服务的 manifest endpoint；自建服务负责按 stable
或 preview channel 选择并转发对应 Release manifest，不由客户端运行时自行切换到可变
的 Gitea 地址。

正式 Release 与开发版可以共存：Release 使用正式 app ID `dev.zcode.app` 和历史
`ZCode` 数据目录；开发态使用 `dev.zcode.app.development`、`ZCode Dev` 目录以及
9229 调试端口。二者共享 `zcode://` scheme，macOS 只会保留一个默认协议 handler，
这是唯一需要注意的 LaunchServices 行为，不会造成数据目录或更新包冲突。

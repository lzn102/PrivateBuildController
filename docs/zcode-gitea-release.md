# XCode macOS ARM Gitea Release

`.github/workflows/zcode-macos-arm-release.yml` 从 Gitea 拉取指定完整 commit SHA，在
`macos-14` 上执行 `ci/build.sh macos-arm64 <output-directory>`，然后创建 XCode/ZCode
的草稿 Release，上传 DMG、ZIP、逐文件 SHA-256 和 Electron 更新 manifest，最后将草稿
Release 发布。

正式发布只接受手动触发，且 `github.actor` 必须等于 `TRUSTED_ACTOR`。需要在控制仓库
设置：

- `GITEA_SOURCE_TOKEN`：读取私有源码和私有 CUA Helper Release 附件时使用；
- 私有 CUA Helper 的 Release URL、归档 SHA-256 和稳定签名证书 SHA-1 固定在 `scripts/fetch-cua-helper-app.sh`；更新该资产时同步更新这三个 pin。签名私钥留在受信任设备，不上传到 GitHub。
- `GITEA_ZCODE_RELEASE_TOKEN`：对 `XCode/ZCode` 有写入权限的 Gitea token；工作流会将它映射到发布脚本使用的 `GITEA_RELEASE_TOKEN` 环境变量；不要复用控制器中其他项目的 `GITEA_PACKAGE_TOKEN`；
- workflow 输入中的 Gitea 源地址（同时作为发布目标仓库）；
- 发布目标从 `source_repo_url` 的 owner/repository 推导为同一个 Gitea 仓库，不读取控制器中其他项目的 `REPOSITORY_API_URL`；
- `TAILSCALE_OAUTH_CLIENT_ID`、`TAILSCALE_OAUTH_SECRET`、`TAILSCALE_TAGS`；
- `TRUSTED_ACTOR`：允许执行发布的 GitHub 用户名。

源码拉取步骤会一并下载固定的私有 CUA Helper 签名包并核对归档 SHA-256，通过
`GITHUB_ENV` 将解包后的路径传给构建步骤；桌面构建再校验 Helper
的版本、arm64 launcher、bundle ID、证书 SHA-1 和 designated requirement。签名私钥不离开
受信任设备；任务结束时清理私有 Helper 包和桌面源码。缺少任一固定值时，工作流会在构建前失败。

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

## XCode 3.15.2 Helper 输入

本次桌面发布使用私有仓库中同版本的自建 Helper 归档，保留既有稳定证书与 designated requirement，严格校验 SHA-256 和应用版本。只更新固定下载 URL 与哈希，不上传源码、产物到 GitHub Artifact；正式安装包仍仅发布到 Gitea。

私有 Helper 下载单独使用发布仓库已有的 `GITEA_ZCODE_RELEASE_TOKEN`，通过步骤级 `GITEA_CUA_HELPER_TOKEN` 传入；不扩大或替换多个项目共用的 `GITEA_SOURCE_TOKEN`。下载脚本保留旧 token fallback 以兼容已有构建入口，仍严格限制凭据只能发往私有 Helper 下载前缀。

2026-10-16 一次性上传诊断：隔离 macOS Runner 以同一发布凭据向草稿上传 16 MiB 合成数据，60 秒发送约 9.1 MB（约 150 KB/s）后按上限超时；本机同一接口与 multipart 路径 16 MiB 约 2 秒成功。测试附件已清理，临时探针 workflow 与脚本在诊断后移除。正式构建 ZIP 为 225.8 MiB，慢速传输不能误判为编译失败。此次没有上传 GitHub Artifact、没有公开不完整草稿，也没有修改正式应用或业务数据。

## 一次性加密中转恢复

本次直传 Gitea 的链路严重限速，按同一固定源码 SHA 重建，通过已配置的 R2 做了一次中转。产物先以随机 AES-256-GCM 密钥加密，密钥用调用者提供的 RSA 公钥 OAEP 包装；RSA 私钥仅留在调用者本机。R2 只收到密文。短时下载/删除签名 URL 与明文、密文 SHA-256 仅写入私有 Helper 仓库的临时附件，不写入 GitHub 日志、公开附件或 Artifact。接收者验密文摘要、解密认证和明文摘要后上传到 Gitea，同版本草稿仍按原发布规则完整校验后公开；回收 R2 对象及临时指针。不得改动本机正式应用，也不把中转变成本机编译。

恢复构建 `38848213960` 已成功，源码固定为 `8e78ac937cec465d2cbae256fc53128515b9a21f`。Gitea `v3.15.2` 已公开，8 个资产的版本、大小、摘要、manifest 一致性和匿名下载已验证。恢复任务仅用于此次交付；完成后移除临时 workflow 与传输脚本，不改变后续正式发布入口。

## 随包 Server 的构建预算

桌面安装包包含四个平台的 Server 完整归档后，正式发布任务允许最长 240 分钟，
用于完整构建、最终包校验及既有 Gitea 上传链路；不跳过校验、不改用公开 Artifact。
CUA Helper 固定为与桌面版本一致的 3.16.5，继续使用原稳定签名证书。

## 3.16.5 一次性传输恢复

本次 CI 直传 Gitea 持续受限时，临时启用既有的接收方公钥加密中转。
固定源码 e7ef0d4412524239804ddaa370ee47a1a093d78b，仍在 GitHub 构建并执行相同最终包校验。
仅密文存入私有 R2；解密私钥只留在接收者本机，临时下载指针只放私有 Helper 仓库。
本机验密文/明文摘要后，使用原发布脚本上传并公开 Gitea Release；不得安装或替换本机正式应用。
公开前停止原直传任务，防止两个发布者同时写入。公开后校验全部资产，删除中转对象、私有指针和临时工作流。
此恢复仅限本次，不改变后续默认发布入口。

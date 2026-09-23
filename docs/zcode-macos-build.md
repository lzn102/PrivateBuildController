# XCode macOS ARM 构建与发布

`.github/workflows/zcode-macos-arm.yml` 是 XCode 的 staging 构建入口；
`.github/workflows/zcode-macos-arm-release.yml` 是正式 Gitea Release 入口。两个流程都
只接受 Gitea HTTPS 源地址和完整 commit SHA，不从 GitHub checkout 产品源码。

两个 workflow 都在 `macos-14` 上验证 arm64，临时加入 Tailscale，执行源码仓库的
`ci/build.sh macos-arm64 <output-directory>`。staging 流程把 DMG/ZIP 打成归档交付到
R2 或 direct 目标；Release 流程保留原生 DMG/ZIP，生成逐文件校验和与 manifest 后发布
到 Gitea Release。

Release 运行前需要控制仓库的 `TRUSTED_ACTOR` variable，以及现有的 Tailscale、Gitea
源码读取、Gitea Release、R2 或 direct secrets。正式发布使用
`docs/zcode-gitea-release.md` 中列出的 `GITEA_RELEASE_TOKEN` 和输入约束。

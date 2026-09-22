# ZCode macOS ARM 构建

`.github/workflows/zcode-macos-arm.yml` 是 ZCode 的第一阶段构建入口。它只接受
Gitea HTTPS 源地址和完整 commit SHA，不从 GitHub checkout 产品源码。

工作流会在 `macos-14` 上验证 arm64，临时加入 Tailscale，拉取指定源码，执行源码
仓库的 `ci/build.sh macos-arm64 <output-directory>`，再将 DMG/ZIP 打成 staging
归档交付到 R2 或 direct 目标。它不使用 GitHub Artifact、Cache，也不创建正式
Gitea Release。

源码拉取脚本兼容 macOS 默认用户态：有 GNU `timeout` 时使用系统命令，否则使用
Bash 计时和进程清理实现 5 分钟 fetch 上限。

运行前需要控制仓库配置 `TRUSTED_ACTOR` variable，以及现有的 Tailscale、Gitea
只读源码、R2 或 direct secrets。构建输入应使用 ZCode Gitea 仓库的完整 commit
SHA；重复构建会进入不同的 GitHub run 目录，不覆盖旧 staging。

正式发布前还需要独立的 Release workflow：保留 Electron 原生安装包和
`latest*.yml`，完成版本、校验和和平台资产校验后再发布 Gitea Release。

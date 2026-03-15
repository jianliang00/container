# macOS Codex image example

这个示例基于 `ghcr.io/jianliang00/macos-base:26.3` 构建一个 `darwin/arm64` 镜像，并带上：

- Xcode 26.3
- Homebrew
- Node.js
- Codex CLI
- `Codex.app`

约定如下：

- 只有 `Xcode.xip` 从本地注入到构建上下文
- Homebrew、Node.js、Codex CLI、`Codex.app` 都在镜像构建时通过网络下载安装
- Dockerfile 会创建一个非 root 的 `brew` 用户，并把最终镜像默认用户设为 `brew`

## 1. 准备构建上下文

默认会使用：

- `XCODE_XIP=/Users/jianliang/Code/container/Xcode_26.3_Apple_silicon.xip`

执行：

```bash
cd /Users/jianliang/Code/container

chmod +x "$PWD/docs/examples/macos-codex/prepare-context.sh"
"$PWD/docs/examples/macos-codex/prepare-context.sh"
```

脚本会在 `docs/examples/macos-codex/` 里生成：

- `Xcode.xip`

如果本机路径不同，可以覆盖环境变量：

```bash
XCODE_XIP=/path/to/Xcode_26.3_Apple_silicon.xip \
"$PWD/docs/examples/macos-codex/prepare-context.sh"
```

## 2. 构建镜像

```bash
cd /Users/jianliang/Code/container

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$PWD/docs/examples/macos-codex/Dockerfile" \
  -t ghcr.io/jianliang00/macos-codex:26.3 \
  "$PWD/docs/examples/macos-codex"
```

如果想固定 Node.js 或 Codex CLI 版本，可以在构建时覆盖 build arg：

```bash
bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  --build-arg NODE_FORMULA=node@22 \
  --build-arg CODEX_NPM_SPEC=@openai/codex@0.111.0 \
  -f "$PWD/docs/examples/macos-codex/Dockerfile" \
  -t ghcr.io/jianliang00/macos-codex:26.3 \
  "$PWD/docs/examples/macos-codex"
```

构建时需要 guest VM 能访问外网，至少包括：

- `raw.githubusercontent.com` 用于 Homebrew 安装脚本
- Homebrew 源和 bottle/cask 下载地址
- npm registry 用于 `@openai/codex`

## 3. 校验

```bash
bin/container run --os darwin --rm ghcr.io/jianliang00/macos-codex:26.3 \
  /bin/sh -lc 'whoami && xcodebuild -version && xcrun swift --version && node -v && npm -v && codex --version && ls -ld /Applications/Codex.app && ls -ld "$HOME/Applications/Codex.app"'
```

## 4. 推送

```bash
bin/container image push ghcr.io/jianliang00/macos-codex:26.3
```

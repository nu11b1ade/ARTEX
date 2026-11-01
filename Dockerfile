# syntax=docker/dockerfile:1
#
# 运行镜像（不在镜像里编译）：只装常用工具，放入**预编译好的 Linux 单二进制**。
# 二进制由 CI 的 binaries job 交叉编译（纯 Go、无 QEMU），按目标架构放在
# 构建上下文的 dist/<TARGETARCH>/artex。这样多架构构建时 arm64 只需模拟 apt 层，
# 不再模拟 Next/Go 编译，速度快得多。
#
# 本地手动构建镜像时，先自行准备二进制：
#   cd web && npm run build:static && cd ..
#   cp -r web/out server/webui/dist
#   CGO_ENABLED=0 GOARCH=amd64 go build -tags embedui -o dist/amd64/artex ./cmd/artex
#   docker build -t artex:local .
FROM python:3.12-slim-bookworm
ARG TARGETARCH
# Android 逆向 / CVE 查询工具版本（可用 --build-arg 覆盖）。
ARG JADX_VERSION=1.5.6
ARG APKTOOL_VERSION=3.0.3
ARG VULNX_VERSION=2.0.2
# 常用工具：ripgrep / curl / vim，加一批 recon 常备件（按需增删）。
# Node 从 NodeSource 装 22.x，与前端构建使用的主版本一致。
# openjdk-17-jre-headless 供 JADX / Apktool 使用。
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      tzdata openjdk-17-jre-headless \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
# 预装 Playwright MCP 与 CLI（全局），运行时不再 npx 联网下载。
# @playwright/mcp：browser MCP 直接 `npx @playwright/mcp`（已全局装好，无需 -y/@latest）。
# @playwright/cli：提供 playwright-cli，装完顺带 --help 验证可执行。
# 再装 playwright（提供浏览器管理），装完用 --with-deps 预置 chromium 及其系统依赖，
# 这样容器内 MCP/CLI 首次启动即可用，不再联网下载浏览器。
RUN npm install -g @playwright/mcp@latest @playwright/cli@latest playwright@latest \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*
# Android 逆向分析及 CVE 查询工具：JADX CLI / Apktool / vulnx。
# vulnx 发布包按 TARGETARCH 选择 linux_amd64 / linux_arm64。
RUN set -eux; \
    \
    # JADX CLI
    mkdir -p /opt/jadx; \
    curl -fL --retry 3 \
      "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip" \
      -o /tmp/jadx.zip; \
    unzip -q /tmp/jadx.zip -d /opt/jadx; \
    chmod +x /opt/jadx/bin/jadx; \
    ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx; \
    \
    # Apktool
    mkdir -p /opt/apktool; \
    curl -fL --retry 3 \
      "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" \
      -o /opt/apktool/apktool.jar; \
    printf '#!/bin/sh\nexec java -jar /opt/apktool/apktool.jar "$@"\n' \
      > /usr/local/bin/apktool; \
    chmod +x /usr/local/bin/apktool; \
    \
    # ProjectDiscovery vulnx（适配 amd64/arm64）
    curl -fL --retry 3 \
      "https://github.com/projectdiscovery/vulnx/releases/download/v${VULNX_VERSION}/vulnx_${VULNX_VERSION}_linux_${TARGETARCH}.zip" \
      -o /tmp/vulnx.zip; \
    mkdir -p /tmp/vulnx; \
    unzip -q /tmp/vulnx.zip -d /tmp/vulnx; \
    install -m 755 /tmp/vulnx/vulnx /usr/local/bin/vulnx; \
    \
    # 清理并检查
    rm -rf /tmp/jadx.zip /tmp/vulnx.zip /tmp/vulnx; \
    java -version; \
    jadx --version; \
    apktool --version; \
    vulnx version --disable-update-check
WORKDIR /app
ENV TZ=Asia/Shanghai
# 预编译好的对应架构二进制（dist/amd64/artex 或 dist/arm64/artex）
COPY dist/${TARGETARCH}/artex /app/artex
# 守护启动脚本：进程退出后按退出码决定是否重新拉起，页面一键更新靠它完成换装。
# 它同时负责把 SIGTERM 转发给 artex —— docker stop 只把信号发给 PID 1，
# 不转发的话 artex 收不到、做不了优雅关闭，10 秒后被 SIGKILL 硬杀。
COPY start.sh /app/start.sh
RUN chmod +x /app/artex /app/start.sh
COPY skills/ /app/skills/
# data/（SQLite + jwt.key）持久化点
VOLUME ["/app/data"]
EXPOSE 8787 8788
ENTRYPOINT ["/app/start.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]

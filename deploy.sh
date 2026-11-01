#!/usr/bin/env bash
# ARTEX 生产部署脚本：Docker Host 网络 + Nginx HTTPS 统一入口。
#
# 设计目标：
#   - Host 网络让 Agent 自主监听动态端口（反弹 shell、临时监听器等）；
#   - ARTEX Web/API、流量录制代理、PostgreSQL 只绑定宿主机回环，公网只能走 Nginx 443；
#   - 首次启动自动种入 HTTP Basic Auth，第一次访问就必须认证；
#   - 一条命令完成安装、更新、配置检查和故障恢复。
#
# 常用命令：
#   ./deploy.sh install     首次安装 / 幂等重装
#   ./deploy.sh update      拉取新镜像并重建 ARTEX，重载 Nginx
#   ./deploy.sh check       配置、端口暴露、证书、认证、数据库和磁盘检查
#   ./deploy.sh recover     自动修复配置、证书、容器与 Nginx
#   ./deploy.sh status      查看容器状态与访问地址
#   ./deploy.sh logs [svc]  跟踪日志
#
# 与根目录 docker-compose.yml（Bridge 部署）互斥，切换前先停掉另一套。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$ROOT/deploy"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.host.yml"
ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"
NGINX_DIR="$DEPLOY_DIR/nginx"
SITE_TMPL="$NGINX_DIR/site.conf.template"
SITE_CONF="$NGINX_DIR/site.conf"
CERTS_DIR="$NGINX_DIR/certs"
STATE_DIR="$DEPLOY_DIR/state"
PROJECT="artex-host"

ASSUME_YES=0
NO_GIT_PULL=0
TARGET_TAG=""

if [ -t 1 ]; then
  C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_FAIL=''; C_RESET=''
fi

info(){ printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
die(){  printf '%s[x]%s %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; exit 1; }

is_interactive(){
  [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]
}

ask(){
  local prompt="$1" default="${2:-}" answer=""
  if ! is_interactive; then printf '%s' "$default"; return 0; fi
  read -rp "$prompt${default:+ [$default]}: " answer || true
  printf '%s' "${answer:-$default}"
}

ask_secret(){
  local prompt="$1" default="${2:-}" answer=""
  if ! is_interactive; then printf '%s' "$default"; return 0; fi
  read -rsp "$prompt${default:+ [回车使用随机值]}: " answer || true
  # 换行只用于终端观感，必须走 stderr；否则会被 "$(ask_secret …)" 一并捕获。
  printf '\n' >&2
  printf '%s' "${answer:-$default}"
}

confirm(){
  local prompt="$1" default="${2:-n}" answer=""
  if ! is_interactive; then
    if [ "$default" = "y" ]; then return 0; fi
    return 1
  fi
  read -rp "$prompt [$default]: " answer || true
  answer="${answer:-$default}"
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

rand(){ head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }

env_get(){
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$ENV_FILE"
}

env_has(){
  local key="$1"
  [ -f "$ENV_FILE" ] || return 1
  awk -v k="$key" 'index($0, k "=") == 1 { found = 1 } END { exit !found }' "$ENV_FILE"
}

set_env(){
  local key="$1" value="$2" tmp
  case "$value" in *$'\n'*|*$'\r'*) die "配置值不能包含换行: $key" ;; esac
  [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  V="$value" awk -v k="$key" '
    BEGIN { v = ENVIRON["V"]; done = 0 }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 } next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

valid_db_password(){ case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~-]{8,128}$'; }
valid_pg_ident(){ case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; printf '%s' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]{0,62}$'; }
valid_basic_user(){ case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~!@%^*+=,-]{1,128}$'; }
valid_basic_password(){ case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~!@%^*+=,:-]{8,72}$'; }
valid_domain(){
  if [ -z "$1" ]; then return 0; fi
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$'
}

is_ipv4(){
  local ip="$1" octet IFS=.
  printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
  for octet in $ip; do
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

port_free(){
  local port="$1" found=0
  if command -v ss >/dev/null 2>&1; then
    found="$(ss -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" { found = 1 } END { print found + 0 }' || true)"
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then found=1; fi
  else
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then found=1; fi
  fi
  [ "$found" -eq 0 ]
}

listeners_for_port(){
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":${port}" 'NR > 1 && $4 ~ p "$" { print $4 }' || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" { print $4 }' || true
  fi
}

addr_is_loopback(){
  case "$1" in
    127.*|localhost:*|\[::1\]:*) return 0 ;;
    *) return 1 ;;
  esac
}

pick_pg_port(){
  local p=5432
  while [ "$p" -le 5599 ]; do
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

detect_ip(){
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  if [ -z "$ip" ] && command -v ipconfig >/dev/null 2>&1; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  case "$ip" in *:*) ip="" ;; esac
  printf '%s' "${ip:-127.0.0.1}"
}

file_mode(){
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

compose(){ docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
project_running(){ docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}' 2>/dev/null | grep -q .; }
nginx_image(){ local v; v="$(env_get NGINX_IMAGE)"; printf '%s' "${v:-nginx:1.27-alpine}"; }
artex_image(){ printf '%s:%s' "$(env_get ARTEX_IMAGE)" "$(env_get ARTEX_TAG)"; }
curl_host(){ local d; d="$(env_get ARTEX_DOMAIN)"; printf '%s' "${d:-localhost}"; }

ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 Docker"
    if [ "$(uname -s)" = "Linux" ] && confirm "自动安装 Docker?" n; then
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "$USER" 2>/dev/null || true
      warn "Docker 已安装；若当前用户不在 docker 组，请重新登录后重试"
    else
      die "请先安装 Docker：https://docs.docker.com/engine/install/"
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    if [ "$(uname -s)" = "Linux" ] && command -v systemctl >/dev/null 2>&1 \
       && confirm "Docker 守护进程未运行，尝试 sudo systemctl start docker?" y; then
      sudo systemctl start docker || true
    fi
    docker info >/dev/null 2>&1 || die "Docker 守护进程未运行，或当前用户无权访问 /var/run/docker.sock"
  fi
  docker compose version >/dev/null 2>&1 || die "未检测到 docker compose 插件"
}

prepare_env(){
  local first=0 v answer
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_EXAMPLE" ]; then cp "$ENV_EXAMPLE" "$ENV_FILE"; else : > "$ENV_FILE"; fi
    first=1
  fi
  chmod 600 "$ENV_FILE"

  v="$(env_get ARTEX_IMAGE)"; [ -n "$v" ] || v="nullblade/artex"; set_env ARTEX_IMAGE "$v"
  v="$(env_get ARTEX_TAG)"; [ -n "$v" ] || v="latest"; set_env ARTEX_TAG "$v"
  v="$(env_get POSTGRES_USER)"; [ -n "$v" ] || v="artex"; set_env POSTGRES_USER "$v"
  valid_pg_ident "$v" || die "POSTGRES_USER 只能使用字母、数字和下划线，且不能以数字开头"
  v="$(env_get POSTGRES_DB)"; [ -n "$v" ] || v="artex"; set_env POSTGRES_DB "$v"
  valid_pg_ident "$v" || die "POSTGRES_DB 只能使用字母、数字和下划线，且不能以数字开头"
  v="$(env_get TZ)"; [ -n "$v" ] || v="Asia/Shanghai"; set_env TZ "$v"

  # PostgreSQL 密码只允许 URL/Compose 安全字符，避免 DSN 解析和 .env 插值问题。
  v="$(env_get POSTGRES_PASSWORD)"
  if [ -z "$v" ] || [ "$v" = "change-me-please" ] || ! valid_db_password "$v"; then
    if [ -n "$v" ] && [ "$v" != "change-me-please" ]; then
      die "POSTGRES_PASSWORD 含不支持的特殊字符（仅允许字母、数字和 . _ ~ -），请先修改 .env"
    fi
    v="$(ask_secret 'PostgreSQL 密码' "$(rand)")"
    valid_db_password "$v" || die "PostgreSQL 密码至少 8 位，且仅允许字母、数字和 . _ ~ -"
    set_env POSTGRES_PASSWORD "$v"
  fi

  # 访问域名（可留空 → 自签名证书 + IP 访问）。
  if [ "$first" -eq 1 ] || ! env_has ARTEX_DOMAIN; then
    v="$(env_get ARTEX_DOMAIN)"
    answer="$(ask 'HTTPS 访问域名（留空则使用自签名证书 + 服务器 IP）' "$v")"
    valid_domain "$answer" || die "域名格式不正确（不要包含 https:// 或路径）"
    set_env ARTEX_DOMAIN "$answer"
  else
    # .env 可能被手工改过；每次安装/更新/恢复都重新校验，避免异常字符进入 Nginx 配置。
    valid_domain "$(env_get ARTEX_DOMAIN)" || die "ARTEX_DOMAIN 格式不正确（不要包含 https://、路径或特殊字符）"
  fi

  # PostgreSQL 回环端口：未配置时自动挑一个空闲端口。
  if [ -z "$(env_get ARTEX_PG_PORT)" ]; then
    if project_running; then
      v="5432"
    else
      v="$(pick_pg_port)" || die "5432-5599 没有空闲端口可用于 PostgreSQL"
    fi
    set_env ARTEX_PG_PORT "$v"
  fi
  case "$(env_get ARTEX_PG_PORT)" in
    ''|*[!0-9]*) die "ARTEX_PG_PORT 必须是数字" ;;
  esac
  v="$(env_get ARTEX_PG_PORT)"
  [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || die "ARTEX_PG_PORT 超出范围"
  case "$v" in
    80|443|8787|8788) die "ARTEX_PG_PORT 不能使用 ${v}（会与 Nginx/ARTEX Web/流量代理端口冲突）" ;;
  esac
  [ -n "$(env_get ARTEX_PG_VOLUME)" ] || set_env ARTEX_PG_VOLUME "artex-host-pgdata"

  # HTTP Basic Auth：默认开启；数据库已有配置时服务端不会覆盖。
  if [ -z "$(env_get ARTEX_BASIC_AUTH_USER)" ]; then
    v="$(ask 'HTTP Basic Auth 用户名' 'admin')"
    valid_basic_user "$v" || die "Basic Auth 用户名只能包含字母、数字和 . _ ~ ! @ % ^ * + = , -"
    set_env ARTEX_BASIC_AUTH_USER "$v"
  else
    valid_basic_user "$(env_get ARTEX_BASIC_AUTH_USER)" || die "ARTEX_BASIC_AUTH_USER 含不支持字符，请修改 .env"
  fi
  if [ -z "$(env_get ARTEX_BASIC_AUTH_PASSWORD)" ]; then
    v="$(ask_secret 'HTTP Basic Auth 密码' "$(rand)")"
    valid_basic_password "$v" || die "Basic Auth 密码至少 8 位、最多 72 字节，仅允许字母、数字和 . _ ~ ! @ % ^ * + = , : -"
    set_env ARTEX_BASIC_AUTH_PASSWORD "$v"
  else
    valid_basic_password "$(env_get ARTEX_BASIC_AUTH_PASSWORD)" || die "ARTEX_BASIC_AUTH_PASSWORD 含不支持字符，请修改 .env"
  fi
}

ensure_ports(){
  local p pg_port
  pg_port="$(env_get ARTEX_PG_PORT)"
  for p in 80 443 8787 8788 "$pg_port"; do
    [ -n "$p" ] || continue
    if ! port_free "$p"; then
      if project_running; then
        info "端口 $p 已由现有 ARTEX 生产容器占用"
      else
        die "端口 $p 已被其他进程占用；请释放后重试（若是旧 Bridge 部署，先在其目录执行 docker compose down）"
      fi
    fi
  done
}

cert_valid(){ [ -s "$CERTS_DIR/fullchain.pem" ] && [ -s "$CERTS_DIR/privkey.pem" ]; }

cert_key_match(){
  local a b
  a="$(openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null || true)"
  b="$(openssl pkey -in "$CERTS_DIR/privkey.pem" -pubout 2>/dev/null | openssl sha256 2>/dev/null || true)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

cert_expired(){ ! openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; }
cert_expiring(){ ! openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -checkend "${1:-2592000}" >/dev/null 2>&1; }

san_has(){
  local kind="$1" value="$2" san
  san="$(openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2 || true)"
  if [ -z "$san" ]; then
    # 旧版 LibreSSL 不支持 -ext，退回解析 -text 里的 SAN 行。
    san="$(openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -text 2>/dev/null \
      | sed -n '/Subject Alternative Name/{n;s/^[[:space:]]*//;p;}' || true)"
  fi
  [ -n "$san" ] || return 1
  printf '%s\n' "$san" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq "${kind}:${value}"
}

generate_self_signed(){
  local domain ip name cnf n ipn
  domain="$(env_get ARTEX_DOMAIN)"
  ip="$(detect_ip)"
  name="${domain:-$ip}"
  [ -n "$name" ] || name="localhost"
  mkdir -p "$CERTS_DIR"; chmod 700 "$CERTS_DIR"
  cnf="$(mktemp)"
  {
    echo '[req]'
    echo 'distinguished_name = dn'
    echo 'x509_extensions = v3_req'
    echo 'prompt = no'
    echo '[dn]'
    echo "CN = ${name}"
    echo '[v3_req]'
    echo 'basicConstraints = critical,CA:FALSE'
    echo 'keyUsage = critical,digitalSignature,keyEncipherment'
    echo 'extendedKeyUsage = serverAuth'
    echo 'subjectAltName = @alt_names'
    echo '[alt_names]'
    echo 'DNS.1 = localhost'
    echo 'IP.1 = 127.0.0.1'
    n=2; ipn=2
    if [ -n "$domain" ]; then
      # 域名按 DNS SAN 写入；如果用户填的是 IP，必须写成 IP SAN，
      # 否则浏览器不会把证书与该 IP 访问匹配。
      if is_ipv4 "$domain"; then
        if [ "$domain" != "$ip" ] && [ "$domain" != "127.0.0.1" ]; then
          echo "IP.${ipn} = ${domain}"; ipn=$((ipn + 1))
        fi
      else
        echo "DNS.${n} = ${domain}"; n=$((n + 1))
      fi
    fi
    if [ "$ip" != "127.0.0.1" ]; then echo "IP.${ipn} = ${ip}"; fi
  } > "$cnf"
  if ! openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 -config "$cnf" \
      -keyout "$CERTS_DIR/privkey.pem" -out "$CERTS_DIR/fullchain.pem" >/dev/null 2>&1; then
    rm -f "$cnf"
    die "生成自签名证书失败；请检查 openssl，或手工放置 deploy/nginx/certs/fullchain.pem 与 privkey.pem"
  fi
  rm -f "$cnf"
  chmod 600 "$CERTS_DIR/privkey.pem"
  chmod 644 "$CERTS_DIR/fullchain.pem"
  printf 'domain=%s\nip=%s\n' "$domain" "$ip" > "$CERTS_DIR/.self-signed"
  chmod 600 "$CERTS_DIR/.self-signed"
  ok "已生成自签名证书（CN=${name}，SAN 含 localhost/127.0.0.1${domain:+/$domain}${ip:+/$ip}）"
}

ensure_certs(){
  local ask_mode="${1:-1}" cert_path key_path recorded_domain
  mkdir -p "$CERTS_DIR"; chmod 700 "$CERTS_DIR"
  if cert_valid; then
    cert_key_match || die "证书与私钥不匹配：$CERTS_DIR/fullchain.pem / privkey.pem"
    if cert_expired; then
      if [ -f "$CERTS_DIR/.self-signed" ]; then
        warn "自签名证书已过期，重新生成"
        generate_self_signed
      else
        warn "自定义证书已过期，请替换 $CERTS_DIR/fullchain.pem 与 privkey.pem"
      fi
    elif [ -f "$CERTS_DIR/.self-signed" ]; then
      recorded_domain="$(sed -n 's/^domain=//p' "$CERTS_DIR/.self-signed" | head -n 1)"
      if [ "$recorded_domain" != "$(env_get ARTEX_DOMAIN)" ]; then
        if [ "$ask_mode" -eq 1 ]; then
          if confirm "访问域名已变更，重新生成自签名证书?" y; then
            generate_self_signed
          fi
        else
          warn "访问域名已变更，重新生成自签名证书"
          generate_self_signed
        fi
      fi
    fi
    return 0
  fi

  if [ "$ask_mode" -eq 1 ] && confirm "使用已有证书文件?" n; then
    cert_path="$(ask '证书 fullchain.pem 路径' '')"
    key_path="$(ask '私钥 privkey.pem 路径' '')"
    [ -n "$cert_path" ] && [ -n "$key_path" ] || die "证书和私钥路径不能为空"
    [ -f "$cert_path" ] && [ -f "$key_path" ] || die "证书或私钥文件不存在"
    cp "$cert_path" "$CERTS_DIR/fullchain.pem"
    cp "$key_path" "$CERTS_DIR/privkey.pem"
    chmod 644 "$CERTS_DIR/fullchain.pem"
    chmod 600 "$CERTS_DIR/privkey.pem"
    rm -f "$CERTS_DIR/.self-signed"
    cert_key_match || die "证书与私钥不匹配"
    ok "已导入自定义证书"
    return 0
  fi

  generate_self_signed
}

render_site(){
  local domain v6 tmp
  domain="$(env_get ARTEX_DOMAIN)"
  domain="${domain:-_}"
  v6=0
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" = "0" ]; then v6=1; fi
  fi
  [ -f "$SITE_TMPL" ] || die "缺少 Nginx 模板：$SITE_TMPL"
  mkdir -p "$NGINX_DIR" "$NGINX_DIR/webroot"
  tmp="$(mktemp "${TMPDIR:-/tmp}/artex-site.XXXXXX")"
  awk -v domain="$domain" -v v6="$v6" '
    /^#__IF_IPV6__$/ { if (v6 != "1") skip = 1; next }
    /^#__ENDIF__$/    { skip = 0; next }
    skip { next }
    { gsub(/__ARTEX_DOMAIN__/, domain); print }
  ' "$SITE_TMPL" > "$tmp"
  if grep -q '__ARTEX_DOMAIN__' "$tmp"; then
    rm -f "$tmp"
    die "Nginx 配置渲染失败"
  fi
  # 就地写入，先校验完整内容再落地；避免 Nginx reload 读到只写了一半的新配置。
  cat "$tmp" > "$SITE_CONF"
  rm -f "$tmp"
  chmod 644 "$SITE_CONF"
  ok "已生成 Nginx 配置（server_name ${domain}）"
}

validate_compose(){ compose config -q || die "Compose 配置校验失败，请检查 .env 与 deploy/docker-compose.host.yml"; }

image_exists(){ docker image inspect "$1" >/dev/null 2>&1; }

pull_images(){
  local aimg nimg
  aimg="$(artex_image)"
  nimg="$(nginx_image)"
  info "拉取 ARTEX 镜像 ${aimg}…"
  if ! compose pull artex; then
    if image_exists "$aimg"; then
      warn "拉取失败，使用本地镜像 ${aimg}"
    else
      die "无法拉取 ${aimg}，且本地不存在该镜像（仓库尚未发布镜像时可先本地构建并设置 ARTEX_IMAGE/ARTEX_TAG）"
    fi
  fi
  if ! image_exists "$nimg"; then
    info "拉取 Nginx 镜像 ${nimg}…"
    docker pull "$nimg" >/dev/null || die "无法拉取 ${nimg}"
  fi
}

validate_site_config(){
  local nimg
  nimg="$(nginx_image)"
  image_exists "$nimg" || docker pull "$nimg" >/dev/null || die "无法拉取 ${nimg}"
  docker run --rm --network none --entrypoint nginx \
    -v "$SITE_CONF:/etc/nginx/conf.d/default.conf:ro" \
    -v "$CERTS_DIR:/etc/nginx/certs:ro" \
    "$nimg" -t >/dev/null 2>&1 || die "Nginx 配置校验失败（检查证书与 site.conf）"
}

wait_for_url(){
  local url="$1" tries="${2:-60}" i=1
  while [ "$i" -le "$tries" ]; do
    if curl -fsS --noproxy '*' --max-time 3 "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

wait_for_https(){
  local host code i=1
  host="$(curl_host)"
  while [ "$i" -le 60 ]; do
    code="$(curl -ksS --noproxy '*' --max-time 3 --resolve "${host}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${host}/nginx-health" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then return 0; fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

wait_for_pg(){
  local port i=1
  port="$(env_get ARTEX_PG_PORT)"
  while [ "$i" -le 60 ]; do
    if compose exec -T postgres pg_isready -h 127.0.0.1 -p "$port" \
        -U "$(env_get POSTGRES_USER)" -d "$(env_get POSTGRES_DB)" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

reload_nginx(){
  [ -n "$(compose ps -q nginx 2>/dev/null || true)" ] || return 0
  compose exec -T nginx nginx -t >/dev/null 2>&1 || die "Nginx 配置校验失败"
  compose exec -T nginx nginx -s reload >/dev/null 2>&1 || compose restart nginx
}

save_credentials(){
  local domain url user pass
  domain="$(env_get ARTEX_DOMAIN)"
  user="$(env_get ARTEX_BASIC_AUTH_USER)"
  pass="$(env_get ARTEX_BASIC_AUTH_PASSWORD)"
  if [ -n "$domain" ]; then url="https://${domain}"; else url="https://$(detect_ip)"; fi
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  (
    umask 077
    {
      echo "ARTEX 生产部署凭据"
      echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
      echo "访问地址: ${url}"
      echo
      echo "HTTP Basic Auth 用户名: ${user}"
      echo "HTTP Basic Auth 密码: ${pass}"
      echo
      echo "首次访问先通过 Basic Auth，再在 /setup 设置 ARTEX 管理员密码。"
      echo "Basic Auth 配置持久化在数据库；在 UI 中修改后，本文件与 .env 中的密码"
      echo "可能不再生效，以 UI 配置为准。"
      echo
      echo "自签名证书只提供加密传输；浏览器会提示不受信任。可替换"
      echo "deploy/nginx/certs/fullchain.pem 与 privkey.pem 后重启 Nginx。"
    } > "$STATE_DIR/initial-credentials.txt"
  )
  chmod 600 "$STATE_DIR/initial-credentials.txt"
}

verify_gate(){
  local code
  code="$(https_code "/")"
  case "$code" in
    401) ok "HTTP Basic Auth 已生效（匿名访问返回 401）" ;;
    000) warn "无法通过 HTTPS 验证 HTTP Basic Auth"; return 1 ;;
    *) warn "HTTP Basic Auth 未拦截匿名访问（返回 ${code}）：数据库已有配置，可能已在 UI 中关闭"; return 1 ;;
  esac
  code="$(https_auth_code "/api/auth/status")"
  case "$code" in
    200) ok ".env 中的 Basic Auth 凭据有效" ;;
    401) warn ".env 中的 Basic Auth 凭据无效（密码可能已在 UI 中修改）"; return 1 ;;
    *) warn "带认证访问 /api/auth/status 返回 ${code}，无法确认凭据有效"; return 1 ;;
  esac
  return 0
}

print_summary(){
  local domain url
  domain="$(env_get ARTEX_DOMAIN)"
  if [ -n "$domain" ]; then url="https://${domain}"; else url="https://$(detect_ip)"; fi
  printf '\n'
  ok "生产部署已就绪"
  printf '  访问地址:        %s\n' "$url"
  if [ -t 1 ]; then
    printf '  Basic Auth:      %s / %s\n' "$(env_get ARTEX_BASIC_AUTH_USER)" "$(env_get ARTEX_BASIC_AUTH_PASSWORD)"
  else
    printf '  Basic Auth 用户: %s（密码见凭据文件，避免写入日志）\n' "$(env_get ARTEX_BASIC_AUTH_USER)"
  fi
  printf '  凭据文件:        %s（600）\n' "$STATE_DIR/initial-credentials.txt"
  printf '  公网开放端口:    80, 443（Nginx）\n'
  printf '  仅回环监听:      127.0.0.1:8787 Web/API, 127.0.0.1:8788 流量代理, 127.0.0.1:%s PostgreSQL\n' "$(env_get ARTEX_PG_PORT)"
  printf '  配置检查:        ./deploy.sh check\n'
  printf '  故障恢复:        ./deploy.sh recover\n\n'
}

maybe_git_pull(){
  if [ ! -d "$ROOT/.git" ] || ! command -v git >/dev/null 2>&1; then
    warn "非 git 工作副本，跳过 git pull"
    return 0
  fi
  confirm "拉取最新代码 (git pull --ff-only)?" y || return 0
  if ! (cd "$ROOT" && git pull --ff-only); then
    warn "git pull 未能快进（本地有改动或分支分叉），本次沿用当前代码"
  fi
}

cmd_install(){
  [ "$(uname -s)" = "Linux" ] || warn "Host 网络生产部署面向 Linux 宿主机；Docker Desktop 的 host 网络行为可能不同，仅供本地验证"
  ensure_docker
  prepare_env
  ensure_ports
  mkdir -p "$ROOT/data" "$ROOT/skills"
  ensure_certs 1
  render_site
  validate_compose
  pull_images
  validate_site_config

  info "启动生产栈（artex + postgres + nginx）…"
  if ! compose up -d; then
    compose logs --tail=80 || true
    die "启动失败，请查看上面的日志"
  fi
  reload_nginx
  if ! wait_for_url "http://127.0.0.1:8787/api/health"; then
    compose logs --tail=80 artex || true
    die "ARTEX 未在预期时间内就绪，请查看上面的日志"
  fi
  if ! wait_for_https; then
    compose logs --tail=80 nginx || true
    die "Nginx HTTPS 入口未就绪，请查看上面的日志"
  fi
  verify_gate || true
  save_credentials
  print_summary
}

cmd_update(){
  ensure_docker
  [ -f "$ENV_FILE" ] || die "未找到 .env，请先运行 ./deploy.sh install"
  [ -f "$COMPOSE_FILE" ] || die "未找到 $COMPOSE_FILE"
  [ "$NO_GIT_PULL" -eq 1 ] || maybe_git_pull
  if [ -n "$TARGET_TAG" ]; then set_env ARTEX_TAG "$TARGET_TAG"; ok "ARTEX_TAG=${TARGET_TAG}"; fi
  prepare_env
  ensure_certs 0
  render_site
  validate_compose
  pull_images
  validate_site_config

  info "应用 Compose 配置变更（重建有变化的服务，数据库与 data/ 不受影响）…"
  if ! compose up -d; then
    compose logs --tail=80 || true
    die "ARTEX 容器重建失败，请查看上面的日志"
  fi
  if ! wait_for_url "http://127.0.0.1:8787/api/health"; then
    compose logs --tail=80 artex || true
    die "ARTEX 更新后未就绪，请查看上面的日志（可执行 ./deploy.sh recover）"
  fi

  info "校验并重载 Nginx…"
  reload_nginx
  if ! wait_for_https; then
    compose logs --tail=80 nginx || true
    die "Nginx HTTPS 入口未就绪，请查看上面的日志（可执行 ./deploy.sh recover）"
  fi
  verify_gate || true
  save_credentials
  print_summary
}

CHECK_OK=0
CHECK_WARN=0
CHECK_FAIL=0
c_pass(){ CHECK_OK=$((CHECK_OK + 1)); printf '%s[+]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
c_warn(){ CHECK_WARN=$((CHECK_WARN + 1)); printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
c_fail(){ CHECK_FAIL=$((CHECK_FAIL + 1)); printf '%s[x]%s %s\n' "$C_FAIL" "$C_RESET" "$*"; }

container_field(){
  local svc="$1" field="$2" cid
  cid="$(compose ps -a -q "$svc" 2>/dev/null || true)"
  [ -n "$cid" ] || return 0
  docker inspect -f "$field" "$cid" 2>/dev/null || true
}

https_code(){
  local path="$1" host code
  host="$(curl_host)"
  code="$(curl -ksS --noproxy '*' --max-time 10 --resolve "${host}:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://${host}${path}" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

https_auth_code(){
  local path="$1" host user pass code
  host="$(curl_host)"
  user="$(env_get ARTEX_BASIC_AUTH_USER)"
  pass="$(env_get ARTEX_BASIC_AUTH_PASSWORD)"
  code="$(
    printf 'user = "%s:%s"\n' "$user" "$pass" | \
    curl -ksS --noproxy '*' --max-time 10 --resolve "${host}:443:127.0.0.1" -K - \
      -o /dev/null -w '%{http_code}' "https://${host}${path}" 2>/dev/null || true
  )"
  printf '%s' "${code:-000}"
}

cmd_check(){
  local host code pg_port user pass domain san_kind mode avail_kb state health addrs exposed a
  CHECK_OK=0; CHECK_WARN=0; CHECK_FAIL=0

  if ! command -v docker >/dev/null 2>&1; then
    c_fail "未安装 Docker"
  elif ! docker info >/dev/null 2>&1; then
    c_fail "Docker 守护进程未运行或当前用户无权访问"
  elif ! docker compose version >/dev/null 2>&1; then
    c_fail "未检测到 docker compose 插件"
  else
    c_pass "Docker 与 Compose 可用"
  fi

  if [ ! -f "$ENV_FILE" ]; then
    c_fail "未找到 .env（请先运行 ./deploy.sh install）"
  else
    mode="$(file_mode "$ENV_FILE")"
    case "$mode" in
      600|400) c_pass ".env 权限为 ${mode}" ;;
      *) c_warn ".env 权限为 ${mode}，建议 chmod 600 .env" ;;
    esac
  fi

  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
    if compose config -q >/dev/null 2>&1; then c_pass "Compose 配置有效"; else c_fail "Compose 配置无效"; fi
    for key in POSTGRES_PASSWORD ARTEX_PG_PORT ARTEX_IMAGE ARTEX_TAG ARTEX_BASIC_AUTH_USER ARTEX_BASIC_AUTH_PASSWORD; do
      if [ -n "$(env_get "$key")" ]; then c_pass ".env 已设置 ${key}"; else c_fail ".env 缺少 ${key}"; fi
    done
    if ! valid_domain "$(env_get ARTEX_DOMAIN)"; then
      c_fail ".env 中 ARTEX_DOMAIN 格式不正确"
    fi
    for key in POSTGRES_USER POSTGRES_DB; do
      if [ -n "$(env_get "$key")" ] && ! valid_pg_ident "$(env_get "$key")"; then
        c_fail ".env 中 ${key} 不是合法的 PostgreSQL 标识符"
      fi
    done
  fi

  for svc in postgres artex nginx; do
    state="$(container_field "$svc" '{{.State.Status}}')"
    health="$(container_field "$svc" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    if [ -z "$state" ]; then
      c_fail "${svc} 容器未创建"
    elif [ "$state" != "running" ]; then
      c_fail "${svc} 容器状态为 ${state}"
    elif [ "$health" = "unhealthy" ]; then
      c_fail "${svc} 容器健康检查失败"
    elif [ "$health" = "starting" ]; then
      c_warn "${svc} 容器健康检查仍在启动中"
    else
      c_pass "${svc} 容器运行正常"
    fi
  done

  pg_port="$(env_get ARTEX_PG_PORT)"
  for p in 8787 8788 "$pg_port"; do
    [ -n "$p" ] || continue
    addrs="$(listeners_for_port "$p")"
    if [ -z "$addrs" ]; then
      c_fail "端口 ${p} 未监听"
      continue
    fi
    exposed=""
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      addr_is_loopback "$a" || exposed="${exposed} ${a}"
    done <<< "$addrs"
    if [ -n "$exposed" ]; then
      c_fail "端口 ${p} 暴露在非回环地址:${exposed}"
    else
      c_pass "端口 ${p} 仅监听回环"
    fi
  done
  for p in 80 443; do
    if [ -n "$(listeners_for_port "$p")" ]; then c_pass "端口 ${p} 正在监听"; else c_fail "端口 ${p} 未监听"; fi
  done

  host="$(curl_host)"
  code="$(https_code "/api/health")"
  if [ "$code" = "200" ]; then c_pass "HTTPS 健康检查 /api/health 返回 200"; else c_fail "HTTPS 健康检查失败（HTTP ${code}）"; fi

  code="$(https_code "/")"
  case "$code" in
    401) c_pass "HTTP Basic Auth 已开启（匿名访问返回 401）" ;;
    200|204|301|302|303|307|308) c_fail "HTTP Basic Auth 未开启（匿名访问返回 ${code}）" ;;
    000) c_fail "无法通过 HTTPS 访问 ${host}" ;;
    *) c_warn "匿名访问 / 返回 ${code}" ;;
  esac

  user="$(env_get ARTEX_BASIC_AUTH_USER)"
  pass="$(env_get ARTEX_BASIC_AUTH_PASSWORD)"
  if [ -n "$user" ] && [ -n "$pass" ]; then
    code="$(https_auth_code "/api/auth/status")"
    case "$code" in
      200) c_pass "Basic Auth 凭据有效，ARTEX 数据库可读" ;;
      401) c_warn "Basic Auth 已开启，但 .env 中的凭据无效（可能已在 UI 中修改）" ;;
      503) c_fail "ARTEX 返回 503：数据库暂不可用" ;;
      000) c_fail "带认证的 HTTPS 请求失败" ;;
      *) c_warn "带认证访问 /api/auth/status 返回 ${code}" ;;
    esac
  fi

  if [ -s "$CERTS_DIR/fullchain.pem" ] && [ -s "$CERTS_DIR/privkey.pem" ]; then
    if cert_expired; then
      c_fail "HTTPS 证书已过期"
    elif cert_expiring 2592000; then
      c_warn "HTTPS 证书将在 30 天内过期"
    else
      c_pass "HTTPS 证书有效期充足"
    fi
    if ! cert_key_match; then c_fail "HTTPS 证书与私钥不匹配"; fi
    domain="$(env_get ARTEX_DOMAIN)"
    if [ -n "$domain" ]; then
      if is_ipv4 "$domain"; then san_kind="IP Address"; else san_kind="DNS"; fi
      if san_has "$san_kind" "$domain"; then
        c_pass "证书 SAN 包含 ${san_kind}:${domain}"
      else
        c_warn "证书 SAN 不包含 ${san_kind}:${domain}（浏览器会提示证书不匹配）"
      fi
    fi
    if [ -f "$CERTS_DIR/.self-signed" ]; then
      c_warn "当前使用自签名证书，浏览器会提示不受信任"
    fi
  else
    c_fail "HTTPS 证书文件缺失"
  fi

  if [ -n "$(container_field nginx '{{.Id}}')" ]; then
    if compose exec -T nginx nginx -t >/dev/null 2>&1; then c_pass "Nginx 配置校验通过"; else c_fail "Nginx 配置校验失败"; fi
  fi

  if [ -n "$pg_port" ]; then
    if compose exec -T postgres pg_isready -h 127.0.0.1 -p "$pg_port" \
        -U "$(env_get POSTGRES_USER)" -d "$(env_get POSTGRES_DB)" >/dev/null 2>&1; then
      c_pass "PostgreSQL 可连接"
    else
      c_fail "PostgreSQL 不可连接"
    fi
  fi

  if [ -d "$ROOT/data" ] && [ -w "$ROOT/data" ]; then c_pass "data/ 可写"; else c_fail "data/ 不存在或不可写"; fi
  if [ -d "$ROOT/skills" ] && [ -w "$ROOT/skills" ]; then c_pass "skills/ 可写"; else c_fail "skills/ 不存在或不可写"; fi

  avail_kb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [ -n "$avail_kb" ]; then
    if [ "$avail_kb" -lt 512000 ]; then
      c_fail "磁盘剩余不足 500MB（${avail_kb}KB）"
    elif [ "$avail_kb" -lt 2097152 ]; then
      c_warn "磁盘剩余不足 2GB（${avail_kb}KB），证据与日志可能占用较多空间"
    else
      c_pass "磁盘剩余空间充足（$((avail_kb / 1024))MB）"
    fi
  fi

  printf '\n检查结果：通过 %d 项，警告 %d 项，失败 %d 项\n' "$CHECK_OK" "$CHECK_WARN" "$CHECK_FAIL"
  [ "$CHECK_FAIL" -eq 0 ]
}

cmd_recover(){
  local stamp
  ensure_docker
  [ -f "$ENV_FILE" ] || die "未找到 .env，无法恢复；请先运行 ./deploy.sh install"
  [ -f "$COMPOSE_FILE" ] || die "未找到 $COMPOSE_FILE"
  prepare_env

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$STATE_DIR/env.${stamp}.bak"
  chmod 600 "$STATE_DIR/env.${stamp}.bak"
  if [ -f "$SITE_CONF" ]; then
    cp "$SITE_CONF" "$STATE_DIR/site.${stamp}.bak"
    chmod 600 "$STATE_DIR/site.${stamp}.bak"
  fi
  info "已将当前配置备份到 ${STATE_DIR}（${stamp}）"

  ensure_certs 0
  render_site
  validate_compose
  validate_site_config

  info "启动/修复 PostgreSQL…"
  compose up -d postgres || { warn "PostgreSQL 启动失败，重建容器（数据卷保留）"; compose rm -sf postgres >/dev/null 2>&1 || true; compose up -d postgres || true; }
  wait_for_pg || { warn "PostgreSQL 未就绪，重启一次"; compose restart postgres || true; wait_for_pg || true; }

  info "启动/修复 ARTEX…"
  compose up -d artex || { warn "ARTEX 启动失败，重建容器（数据卷保留）"; compose rm -sf artex >/dev/null 2>&1 || true; compose up -d artex || true; }
  if ! wait_for_url "http://127.0.0.1:8787/api/health"; then
    warn "ARTEX 未就绪，重启一次"
    compose restart artex || true
    wait_for_url "http://127.0.0.1:8787/api/health" || true
  fi
  if ! wait_for_url "http://127.0.0.1:8787/api/health"; then
    warn "ARTEX 仍未就绪，强制重建容器（data/ 与数据库卷保留）"
    compose up -d --force-recreate --no-deps artex || true
    wait_for_url "http://127.0.0.1:8787/api/health" || true
  fi

  info "启动/修复 Nginx…"
  if ! compose up -d nginx; then
    compose rm -sf nginx >/dev/null 2>&1 || true
    compose up -d nginx || true
  fi
  if ! compose exec -T nginx nginx -t >/dev/null 2>&1; then
    warn "Nginx 配置校验失败，重新生成并重建 Nginx 容器"
    render_site
    validate_site_config || true
    compose up -d --force-recreate nginx || true
  else
    compose exec -T nginx nginx -s reload >/dev/null 2>&1 || compose restart nginx || true
  fi
  wait_for_https || true

  printf '\n'
  info "恢复流程结束，执行完整检查…"
  if cmd_check; then
    ok "恢复完成，所有关键检查通过"
  else
    warn "仍有检查项失败，请查看上方输出"
    printf '  查看日志: ./deploy.sh logs\n'
    printf '  ARTEX 日志: ./deploy.sh logs artex\n'
    printf '  数据库卷: docker volume inspect %s\n' "$(env_get ARTEX_PG_VOLUME)"
    return 1
  fi
}

cmd_status(){
  ensure_docker
  [ -f "$ENV_FILE" ] || die "未找到 .env，请先运行 ./deploy.sh install"
  local domain url
  domain="$(env_get ARTEX_DOMAIN)"
  if [ -n "$domain" ]; then url="https://${domain}"; else url="https://$(detect_ip)"; fi
  printf '访问地址: %s\n' "$url"
  printf 'Basic Auth 用户: %s（密码见 .env / deploy/state/initial-credentials.txt）\n' "$(env_get ARTEX_BASIC_AUTH_USER)"
  printf '证书: %s\n\n' "$CERTS_DIR/fullchain.pem"
  compose ps
}

cmd_logs(){
  [ -f "$ENV_FILE" ] || die "未找到 .env，请先运行 ./deploy.sh install"
  compose logs -f --tail=200 "$@"
}

usage(){
  cat <<'EOF'
用法: ./deploy.sh <命令> [选项]

命令:
  install            首次安装 / 幂等重装（Host 网络 + Nginx HTTPS）
  update             拉取新镜像并重建 ARTEX，重载 Nginx
  check              配置、端口暴露、证书、认证、数据库与磁盘检查
  recover            自动修复配置、证书、容器与 Nginx
  status             查看容器状态与访问地址
  logs [服务名]      跟踪日志（服务名: artex / postgres / nginx）

选项:
  -y, --yes          非交互模式，使用默认值/随机凭据
      --no-git-pull  update 时不执行 git pull
      --tag <tag>    update 时指定 ARTEX_TAG
  -h, --help         显示帮助

示例:
  ./deploy.sh install
  ./deploy.sh update --tag v0.3.26
  ./deploy.sh check
  ./deploy.sh recover
EOF
}

# 只有直接执行时才跑命令分发；被 source 时仅提供函数（便于测试）。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
# 选项可以出现在子命令之前或之后（例如 update --tag v0.3.26）。
COMMAND=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --no-git-pull) NO_GIT_PULL=1; shift ;;
    --tag)
      [ $# -ge 2 ] || die "--tag 需要一个值"
      TARGET_TAG="$2"; shift 2 ;;
    --tag=*) TARGET_TAG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        if [ -z "$COMMAND" ]; then COMMAND="$1"; else EXTRA[${#EXTRA[@]}]="$1"; fi
        shift
      done ;;
    -*) die "未知选项: $1" ;;
    *)
      if [ -z "$COMMAND" ]; then COMMAND="$1"; else EXTRA[${#EXTRA[@]}]="$1"; fi
      shift ;;
  esac
done

COMMAND="${COMMAND:-help}"

case "$COMMAND" in
  install) cmd_install ;;
  update)  cmd_update ;;
  check)   cmd_check ;;
  recover) cmd_recover ;;
  status)  cmd_status ;;
  logs)
    if [ "${#EXTRA[@]}" -gt 0 ]; then cmd_logs "${EXTRA[@]}"; else cmd_logs; fi ;;
  help|-h|--help) usage ;;
  *) usage; die "未知命令: $COMMAND" ;;
esac
fi

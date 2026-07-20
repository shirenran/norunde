#!/usr/bin/env bash
# Build DMG and publish a GitHub Release (requires gh auth).
# Usage:
#   bash scripts/release.sh              # v$VERSION (default 0.1.0)
#   VERSION=0.1.1 bash scripts/release.sh
#   bash scripts/release.sh --draft
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-universal}"
TAG="v${VERSION}"
DRAFT=0
TITLE="Norunde ${TAG}"

for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    -h|--help)
      echo "Usage: VERSION=0.1.0 bash scripts/release.sh [--draft]"
      exit 0
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI required" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not logged in. Run: gh auth login" >&2
  exit 1
fi

export VERSION BUILD_NUMBER ARCHS
bash "$ROOT/scripts/package-dmg.sh"

DMG="$ROOT/dist/Norunde-${VERSION}.dmg"
SUM="$DMG.sha256"
if [[ ! -f "$DMG" ]]; then
  echo "DMG missing: $DMG" >&2
  exit 1
fi

SHA256="$(awk '{print $1}' "$SUM")"

NOTES="$(cat <<EOF
## Norunde ${TAG}

macOS 菜单栏工具：管理本地 Node 前端项目的导入、启停与实时日志。

### 安装

1. 下载 \`Norunde-${VERSION}.dmg\`
2. 打开 DMG，把 **Norunde** 拖到 **Applications**
3. 首次打开若被 Gatekeeper 拦截：Finder 中右键 App → **打开**
4. 菜单栏找 shippingbox（箱子）图标

也可从源码安装：

\`\`\`bash
git clone https://github.com/shirenran/norunde.git
cd norunde
bash scripts/install.sh --login
\`\`\`

### 构建信息

- 版本：\`${VERSION}\` (build ${BUILD_NUMBER})
- 架构：universal (\`arm64\` + \`x86_64\`)
- 最低系统：macOS 14+
- 签名：ad-hoc（**未** Apple 公证）
- SHA-256：\`${SHA256}\`

### 说明

- Bundle ID：\`app.norunde\`
- 配置目录：\`~/Library/Application Support/Norunde/\`
- 纯本地工具，不上传项目数据
EOF
)"

GH_ARGS=(release create "$TAG" "$DMG" "$SUM" --title "$TITLE" --notes "$NOTES")
if [[ "$DRAFT" -eq 1 ]]; then
  GH_ARGS+=(--draft)
else
  GH_ARGS+=(--latest)
fi

# Re-run friendly: delete existing tag/release only if we own a failed draft? Prefer fail if exists.
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists. Delete it first or bump VERSION." >&2
  gh release view "$TAG" --json url --jq .url
  exit 1
fi

echo "==> Publishing GitHub Release $TAG"
gh "${GH_ARGS[@]}"
echo "==> Done"
gh release view "$TAG" --json url,tagName,isDraft,isLatest --jq .

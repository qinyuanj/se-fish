#!/usr/bin/env bash
# 钓鱼图的 acceptance 入口：parse → dry-check（advisory）→ generate → run，一条命令跑完。
# 在任意目录执行；脚本自己 cd 到仓库根。
#
# 用法：run_acceptance.sh [车道...] | --all
#   无参数：跑 features/ 下除 art 外的全部车道，外加 features/ 根下的裸 feature（代码收尾门）；
#   车道名：只跑 features/<车道>/，可给多个；未知车道非零退出；
#   --all：跑全部车道与裸 feature。
#
# 需要 PATH 里的 lua5.4（可用 ACCEPTANCE_LUA_BIN 覆盖；裸 lua 在 WSL 上可能指向 5.1）；
# acceptance4lua 在有 feature 时由 tools/acceptance/bootstrap.lua 按需安装；
# 见 tools/acceptance/README.md。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# art 车道断言的是仓库外美术工作区的产物（重导入校验报告），红绿取决于资产状态，
# 与代码回归不在同一维度，所以写死排除在无参数的收尾门之外；要跑就显式给 art 或 --all。
# 决策见 #136。
DEFAULT_EXCLUDED_LANES=(art)

usage() {
  echo "用法: bash tools/acceptance/run_acceptance.sh [车道...] | --all" >&2
}

shopt -s nullglob
mode=default
lanes=()
for arg in "$@"; do
  case "$arg" in
    --all) mode=all ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知选项: $arg" >&2; usage; exit 2 ;;
    *)
      # 车道名就是 features/ 下的一级目录名；拒绝路径分隔与 . / ..，免得指到 features/ 外面。
      if [[ "$arg" == */* || "$arg" == . || "$arg" == .. || ! -d "features/$arg" ]]; then
        known="$(cd features 2>/dev/null && for d in */; do printf '%s ' "${d%/}"; done)"
        echo "未知车道: $arg（features/ 下现有车道: ${known:-无}）" >&2
        exit 2
      fi
      lanes+=("$arg")
      ;;
  esac
done
if [ "$mode" = all ] && [ "${#lanes[@]}" -gt 0 ]; then
  echo "--all 不能与车道名同时使用" >&2
  usage
  exit 2
fi
if [ "${#lanes[@]}" -gt 0 ]; then
  mode=lanes
fi

# stem 带车道名，同名文件不会撞。
features=()
case "$mode" in
  all)
    features=(features/*.feature features/*/*.feature)
    ;;
  lanes)
    for lane in "${lanes[@]}"; do
      features+=("features/$lane/"*.feature)
    done
    ;;
  default)
    features=(features/*.feature)
    for dir in features/*/; do
      lane="$(basename "$dir")"
      skip=0
      for excluded in "${DEFAULT_EXCLUDED_LANES[@]}"; do
        [ "$lane" = "$excluded" ] && skip=1
      done
      [ "$skip" -eq 1 ] && continue
      features+=("$dir"*.feature)
    done
    ;;
esac

if [ "${#features[@]}" -eq 0 ]; then
  rm -rf build/acceptance
  echo "所选范围内没有 feature 文件，跳过验收"
  exit 0
fi

LUA="${ACCEPTANCE_LUA_BIN:-lua5.4}"
if ! command -v "$LUA" >/dev/null 2>&1; then
  echo "找不到 lua 解释器（PATH 里没有 $LUA）；用 ACCEPTANCE_LUA_BIN 指一个" >&2
  exit 1
fi
LUA_VERSION="$("$LUA" -v 2>&1 | head -1)"
case "$LUA_VERSION" in
  *5.4*) ;;
  *) echo "acceptance 需要 Lua 5.4，$LUA 报的是: $LUA_VERSION" >&2; exit 1 ;;
esac
export ACCEPTANCE_LUA_BIN="$LUA"

GEN_DIR="build/acceptance/generated"
IR_DIR="build/acceptance/ir"
DRY_DIR="build/acceptance/dry"
# 先清生成的 spec：改过名的 feature 会留下旧 stem，不清就会一直跑着过期的用例。
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR" "$IR_DIR" "$DRY_DIR"

LUA_PATH_FOR_SPECS="$("$LUA" -e 'package.path="./?.lua;"..package.path; io.write(require("tools.acceptance.bootstrap").lua_path())')"

fail=0
for feature in "${features[@]}"; do
  echo "== $feature"
  stem="$(echo "${feature#features/}" | sed 's|/|_|g; s|\.feature$||')"
  tools/acceptance/gherkin-parser "$feature" "$IR_DIR/$stem.json"
  if ! tools/acceptance/ir-dry-checker "$IR_DIR/$stem.json" "$DRY_DIR/$stem.json"; then
    if [ "${ACCEPTANCE_STRICT_TOOLS:-0}" = 1 ]; then
      echo "IR-DRY 工具运行失败：$feature" >&2
      exit 1
    fi
  fi
  mkdir -p "$GEN_DIR/$stem"
  tools/acceptance/entrypoint_generator "$IR_DIR/$stem.json" "$GEN_DIR/$stem/feature_acceptance_spec.lua"
  if ! ACCEPTANCE_FEATURE_JSON="$IR_DIR/$stem.json" LUA_PATH="$LUA_PATH_FOR_SPECS" \
       "$LUA" "$GEN_DIR/$stem/feature_acceptance_spec.lua"; then
    echo "FAILED: $feature" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "acceptance run FAILED" >&2
  exit 1
fi
echo "acceptance run OK"

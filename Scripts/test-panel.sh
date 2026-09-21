#!/usr/bin/env bash
# 跑面板契约测试（见 Scripts/panel-contract-test.cjs 的说明）。
#
# 默认带 --selfcheck：会额外把原来的双重插入 bug 改回去跑一遍，
# 确认断言真的会变红。没有这一步，测试可能是恒真的。
#
#   ./Scripts/test-panel.sh              # 完整（含自检）
#   ./Scripts/test-panel.sh --quick      # 只跑主用例
set -euo pipefail

cd "$(dirname "$0")/.."

# node 的位置：优先 PATH，其次几个常见安装点。
# 别写死某台机器上的绝对路径——别人 clone 下来那条永远不存在。
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
    if [ -x "$candidate" ]; then NODE="$candidate"; break; fi
  done
fi
if [ -z "$NODE" ]; then
  echo "找不到 node 运行时（装一下 Node.js 即可）" >&2
  exit 2
fi

if [ "$#" -eq 0 ]; then
  set -- --selfcheck
elif [ "$1" = "--quick" ]; then
  shift
fi

exec "$NODE" Scripts/panel-contract-test.cjs "$@"

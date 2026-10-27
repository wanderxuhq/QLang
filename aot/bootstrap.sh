#!/bin/sh
# 引导构建 QLang 工具链(target/tools/{stdlib,build,link,verify})——不使用 Python。
#
# 引导的特殊性:此刻 QLang 链接器还不存在,所以第一次用 clang 直接链接
# (把 .ll + runtime.c 编成可执行)。工具一旦生成,后续可以用
#   target/tools/link <tool.ll> -o <binary>
# 重新构建它们自己(自举),见 --self。
#
# 用法:
#   aot/bootstrap.sh [--self] [--compiler <path>]
#
#   --self      用已有的 target/tools/link 重建工具(默认用 clang 引导)
#   --compiler  编译器路径,默认 target/selfhost/stage2
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=target/selfhost/stage2
SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self) SELF=1; shift ;;
    --compiler) COMPILER=$2; shift 2 ;;
    *) echo "bootstrap: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -x "$COMPILER" ] || { echo "bootstrap: compiler not found: $COMPILER" >&2; exit 1; }
mkdir -p target/tools

build_tool() {
  name=$1
  case "$name" in
    stdlib) src="aot/stdlib_build.ql" ;;
    *)      src="aot/$name.ql" ;;
  esac
  ir="target/tools/$name.ll"
  "$COMPILER" --emit-llvm "$src" aot/runtime.ql > "$ir"
  if [ "$SELF" = 1 ] && [ -x target/tools/link ]; then
    # 自举:用 QLang 链接器重建自己。工具 IR 是单模块(自带 runtime),所以不带
    # --stdlib-object;runtime.c 的叶子由链接器自己补。
    target/tools/link "$ir" -o "target/tools/$name" --no-verify
  else
    # 引导:clang 一步到位(和原先 Python 版做的事一样)。
    clang -O2 -fuse-ld=lld -Wl,--threads=1 -Wl,--export-dynamic "$ir" aot/runtime.c -ldl -o "target/tools/$name"
  fi
  rm -f "$ir"
  echo "built target/tools/$name"
}

for tool in verify link build stdlib; do
  build_tool "$tool"
done

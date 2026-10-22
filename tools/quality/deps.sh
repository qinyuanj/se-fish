#!/bin/sh
# 兼容旧入口：Lua 依赖（含 luafilesystem 的 lfs.so）已登记在 project.json 的 lua_tools，
# 由 install 拉取、校验与构建；这里只原样转发。
exec "$(dirname "$0")/project" install "$@"

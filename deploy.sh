#!/usr/bin/env bash
# 兼容入口 — 调用 deploy/deploy.sh
exec "$(dirname "$0")/deploy/deploy.sh" "$@"

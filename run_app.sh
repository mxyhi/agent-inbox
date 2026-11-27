#!/bin/bash

echo "🚀 启动 Agent Inbox 应用..."
echo ""

# 界面文案从可执行文件旁的 <lang>.lproj 查；缺了就只显示英文。
scripts/l10n.sh compile .build/debug

# 启动应用（.build/debug 在新旧构建系统下都指向 debug 产物目录）
.build/debug/agent-inbox > /tmp/agent-inbox.log 2>&1 &
MPID=$!

sleep 3

echo "✅ 应用已启动 (PID: $MPID)"
echo ""
echo "📍 请检查以下位置:"
echo ""
echo "1. 菜单栏图标: 待办(!) / 运行中(⚡) / 全部完成(✓) / 空闲"
echo "2. Dock 图标: 右键可新建清单"
echo "3. 「Agent Inbox」收件箱便签: 首次启动在主屏右上角(或旧浮窗位置)"
echo "   - 可拖动、拖到屏幕左右边缘停靠、双击标题栏卷起"
echo "   - 关闭后从菜单栏「显示 Agent 收件箱」或点 Dock 图标再打开"
echo ""
echo "📋 日志文件: /tmp/agent-inbox.log"
echo ""
echo "⏹️  停止应用: pkill agent-inbox"
echo ""

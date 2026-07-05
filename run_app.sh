#!/bin/bash

echo "🚀 启动 Agent Inbox 应用..."
echo ""

# 启动应用
.build/arm64-apple-macosx/debug/agent-inbox > /tmp/agent-inbox.log 2>&1 &
MPID=$!

sleep 3

echo "✅ 应用已启动 (PID: $MPID)"
echo ""
echo "📍 请检查以下位置:"
echo ""
echo "1. 菜单栏 (屏幕顶部右侧)"
echo "   应该看到一个图标,可能是:"
echo "   - 🌙 (空闲状态)"
echo "   - ⚡ (运行中)"
echo "   - ⭕ (待办)"
echo "   - ✅ (完成)"
echo ""
echo "2. 浮窗 (屏幕右上角)"
echo "   应该看到一个 420×280 的窗口"
echo "   标题: Agent Inbox"
echo ""
echo "💡 操作提示:"
echo "   - 点击菜单栏图标可以看到菜单"
echo "   - 选择'显示/隐藏浮窗'可以切换浮窗显示"
echo "   - 浮窗可以拖动位置"
echo ""
echo "🔍 如果看不到浮窗,可以:"
echo "   1. 检查 Mission Control (F3 或三指上滑)"
echo "   2. 点击菜单栏图标手动显示"
echo "   3. 检查系统设置 > 隐私与安全性 > 屏幕录制"
echo ""
echo "📋 日志文件: /tmp/agent-inbox.log"
echo ""
echo "⏹️  停止应用: pkill agent-inbox"
echo ""

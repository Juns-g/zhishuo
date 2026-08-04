# DJI Mic 2 声控语音输入项目

**目标**: 拿起 DJI Mic 2 即说即录（声控 VAD），放下即停，配合豆包输入法在任何输入框语音输入。

**方案**: 方案 B 声控（VAD 检测说话 → 触发豆包右 Option 免按模式）

**流程**: 全程走 Agent SOP skill（research → plan → 审批 → implement → review → verify → signoff）

**协作**: Pi (orchestrator) + Codex (sole-writer) + Grok (reviewer)，Herdr 为控制平面

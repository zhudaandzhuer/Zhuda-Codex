# Zhuda-Codex Skills

这个目录用于放入要随 Zhuda-Codex portable 一起携带的公开 Codex skills。

每个 skill 应该放在独立子目录中，并包含 `SKILL.md`：

```text
skills/
  your-skill/
    SKILL.md
```

构建 portable 包时，这个目录会被复制到应用包内；启动时再同步到隔离的 `CODEX_HOME/skills`，因此不会污染系统里的官方 `~/.codex/skills`。

不要把私有工作流、公司资料、真实 API key、账号信息或本机路径写进公开 skills。若你只是在自己的电脑上生成私有 portable 包，可以使用平台对应的私有 skills 导入开关。

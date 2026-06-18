# 说入法

说入法是一个自用 macOS 语音输入工具：默认轻按 `fn` 开始录音，再按一次停止并输出 ASR 原文；长按 `fn` 开始录音，松开后会交给润色模型整理。你也可以在设置里录制自己的快捷键，最后的文字会自动粘贴到当前光标。

## API 约定

ASR 默认请求格式是 OpenAI-compatible multipart audio transcription：

- `POST <ASR endpoint>`
- Header：默认 `Authorization: Bearer <API key>`
- Form fields：`file`, `model`, `language`, `prompt`, `response_format=json`
- 默认从 JSON 响应的 `text` 字段取转写结果
- 默认从 ASR endpoint 自动推导模型列表 endpoint；读取后分别在 ASR 模型和转写模型两个下拉菜单里选择

如果你的服务不是 multipart，可以在设置里切到 `JSON base64`。它会发送：

```json
{
  "model": "your-model",
  "audio_base64": "...",
  "mime_type": "audio/wav",
  "language": "zh",
  "prompt": "..."
}
```

如果使用 DashScope Qwen ASR，可以在设置里切到 `DashScope Qwen ASR`。ASR endpoint 可以填 base URL：

```text
https://dashscope.aliyuncs.com/compatible-mode/v1
```

说入法会自动补成 `chat/completions`，并把本地 WAV 录音作为 Data URL 放进 `input_audio.data`。

如果开启“使用流式 ASR”，说入法会使用 DashScope realtime WebSocket 协议，边录边发送音频，并在浮动输入框里显示识别状态和预览文本。停止录音后只要已有候选文本就会立刻输入，final 结果回来后会尽量原地校正刚输入的文本。

ASR 和转写的 `response key path` 都支持类似 `text`、`data.text`、`choices.0.message.content` 的路径。

转写模型使用 OpenAI-compatible chat completions JSON：

```json
{
  "model": "your-rewrite-model",
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": "ASR 原始文本..." }
  ],
  "temperature": 0.2
}
```

模型列表接口支持这些常见响应：

```json
{ "data": [{ "id": "model-a" }, { "id": "model-b" }] }
```

```json
{ "models": ["model-a", "model-b"] }
```

## 构建

```bash
cd VoiceTyper
swift build
```

生成 `.app`：

```bash
cd VoiceTyper
Scripts/build_app.sh
```

输出会在：

```text
build/说入法.app
```

第一次运行后，在设置里填 API endpoint、API key，并从下拉框分别选择 ASR model 和润色 model。默认润色复用同一个 API endpoint；只有 ASR 和润色走不同服务时，才需要在高级设置里填写润色 endpoint 覆盖。快捷键录制、流式 ASR、Dock 图标、录音浮窗、输入历史隐私控制、自动用户词库学习都在设置里可用。

## License

Apache License 2.0. See [LICENSE](LICENSE).

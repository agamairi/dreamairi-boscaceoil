<p align="center">
	<img src="icon-512.png" width="128">
</p>

# Bosca Ceoil — DreamAiri

_[bús-ka kyó-al] — a music box, supercharged with AI._

**Bosca Ceoil — DreamAiri** is a fork of [Bosca Ceoil Blue](https://github.com/YuriSizov/boscaceoil-blue) that adds an AI-powered music agent. Using natural language, you can describe the kind of music you want — and the agent will compose it for you using Bosca Ceoil's step sequencer and synthesized instruments.

Everything that made the original great — the playful pattern editor, drag-and-drop arrangement, 300+ instruments — is still here. DreamAiri just adds a creative AI co-pilot on top.


## What's New in DreamAiri

### 🤖 AI Music Agent

A built-in conversational agent that creates music via tool calls:

- **Describe what you want** — _"make a lofi synth beat"_, _"compose a happy chiptune melody"_
- **The agent calls tools** — creates songs, adds instruments, writes patterns, arranges the timeline
- **You hear the result** — plays back immediately, edit and iterate with natural language

### 🔌 Multi-Provider LLM Support

Works with your preferred LLM backend:

| Provider | Setup |
|----------|-------|
| **Ollama** (local) | No API key needed — just run Ollama locally |
| **OpenAI** | API key required |
| **OpenRouter** | API key required — access to 100+ models |
| **Google Gemini** | API key required |

Auto-detection finds whatever's running — or configure manually in the Settings tab.

### 🎵 All Original Features Preserved

- Playful piano roll pattern editor
- Drag-and-drop arrangement with 8 channels
- 300+ synthesized instruments via [GDSiON](https://github.com/YuriSizov/gdsion)
- Export to WAV and MIDI
- Full `.ceol` file compatibility


## Getting Started

### Requirements

- **[Godot 4.4](https://godotengine.org/download/)** or later
- **[GDSiON 0.7](https://github.com/YuriSizov/gdsion/releases)** — extract into the `bin/` folder
- **[Ollama](https://ollama.ai/)** (recommended) or an API key for OpenAI / OpenRouter / Gemini

### Setup

1. Clone this repository
2. Download [GDSiON 0.7-beta8](https://github.com/YuriSizov/gdsion/releases/tag/0.7-beta8) for your platform and extract into the `bin/` folder
3. Open the project in Godot 4.4
4. Run the project — the AI agent window is accessible from the app

### Using the AI Agent

1. Open the **AI Music Agent** window
2. Go to the **Settings** tab and configure your LLM provider (or click **Auto Detect** for Ollama)
3. Select a model from the dropdown
4. Switch to the chat tab and describe what you want: _"make a chill beat at 90 BPM"_
5. Watch the agent create instruments, patterns, and arrangements in real-time


## Remote control (DreamAiri plugin)

Bosca Ceoil can be launched as a remote-controlled sub-app by the DreamAiri Godot editor plugin using `--dreamairi-handoff <path>`. An embedded loopback TCP server (`ai/remote_control.gd`) binds to `127.0.0.1` and speaks length-prefixed framed JSON, allowing the plugin and the user to drive the live composition simultaneously. Remote export supports MIDI only; WAV rendering through remote control is a known limitation and WAV export is done by the user via **File > Export > WAV** in the app. See [ai/REMOTE_CONTROL.md](ai/REMOTE_CONTROL.md) for launch parameters, protocol operations, and security details.


## Architecture

```
ai/
├── agent_executor.gd        # Agentic loop: plan → tools → verify → iterate
├── agent_system_prompt.gd    # System prompt optimized for tool calling
├── music_tools.gd            # 11 music tools (create_song, add_notes, etc.)
├── llm_manager.gd            # Provider management and auto-detection
└── providers/
    ├── llm_provider.gd       # Base class (async HTTP)
    ├── ollama_provider.gd    # Ollama API
    ├── openai_provider.gd    # OpenAI API
    ├── openrouter_provider.gd # OpenRouter API
    └── gemini_provider.gd    # Google Gemini API

gui/views/agent/
├── AgentWindow.tscn          # Floating window layout
├── AgentWindow.gd            # Window controller
├── ChatPanel.gd              # Chat input/output
├── StatusPanel.gd            # Agent state display
├── LogsPanel.gd              # Tool call logs
├── ToolsPanel.gd             # Available tools reference
└── AISettingsView.gd         # Provider/model configuration
```


## Legacy Documentation

This project is based on **Bosca Ceoil Blue** by Yuri Sizov. The original README with full documentation about the base application, its features, FAQ, and contribution guidelines is preserved here:

📄 **[Bosca Ceoil Blue — Original README](README_LEGACY.md)**

Online documentation for the base app: **[Learn Bosca Ceoil](https://humnom.net/apps/boscaceoil/docs/)**


## License

This project is provided under an [MIT license](LICENSE).

- Original Bosca Ceoil Blue: [MIT license](https://github.com/YuriSizov/boscaceoil-blue) by Yuri Sizov
- Original Bosca Ceoil: [BSD-2-Clause-Views license](https://github.com/TerryCavanagh/boscaceoil) by Terry Cavanagh
- GDSiON: [MIT license](https://github.com/YuriSizov/gdsion) by Yuri Sizov


## Credits

- **[Terry Cavanagh](https://github.com/TerryCavanagh)** — original Bosca Ceoil
- **[Yuri Sizov](https://github.com/YuriSizov)** — Bosca Ceoil Blue and GDSiON
- **[DreamAiri](https://github.com/agamairi)** — AI agent integration

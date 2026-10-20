# Vaani: on-device voice agent for iPhone (English + Hinglish)

Vaani is an iOS voice assistant that understands and speaks **English and Hinglish**. **Speech-to-text and text-to-speech both run fully on the phone.** Only the language model (and the weather lookup) use the network.

Built for the IISc Computational Intelligence Lab, Round 1 assignment.


## What it does

Ask by voice, in English or Hinglish:

- "What is the weather forecast for Bangalore tomorrow?"
- "Can you set a reminder for my meeting at 5 PM?"
- "Mujhe kal subah 7 baje ka alarm set karna hai."
- "Aaj ka schedule kya hai, aur meri next meeting kab hai?"

The agent calls real tools: Open-Meteo for weather, and the iPhone's Reminders, Calendar and AlarmKit for reminders, schedule and alarms.

## Requirements checklist

| Requirement | How it is met |
|---|---|
| STT fully on-device | WhisperKit (Whisper small, CoreML), bundled in the app |
| TTS fully on-device | Hinglish: Kokoro via sherpa-onnx. English: Apple on-device Indian English voice |
| LLM may be cloud | Groq `openai/gpt-oss-120b`, with automatic fallback to `gpt-oss-20b`, then Gemini 3.5 / 3.1 Flash-Lite |
| English + Hinglish | Language toggle drives STT language, LLM reply language and TTS voice |
| Latency, transcription, pronunciation | See "Design" and "Results" below |

## Pipeline

```
mic -> VAD (auto-stop on silence) -> Whisper (on-device) -> LLM (cloud, streaming)
    -> tool calls (weather / reminder / alarm / calendar)
    -> clause-chunked TTS (on-device), speaking while the reply is still generated
```

## Design

**Hinglish pronunciation (the main focus).** Reading Roman-script Hindi directly with a Hindi voice sounds foreign. Vaani keeps the LLM output in simple Roman Hinglish and then converts it to Devanagari just before synthesis:

- Hindi words are mapped to Devanagari with a transliteration lexicon.
- English loanwords the assistant uses (meeting, alarm, reminder, weather, percent, degrees, ...) have a dedicated Devanagari dictionary so they are not read with Hindi letter rules.
- Digits, times, decimals and percentages are converted to spoken Hindi number words (for example "28" becomes "अट्ठाईस").
- City names (Bengaluru, Hyderabad, Mumbai, ...) have fixed pronunciations.

I compared several voices and strategies by ear on a 1 to 5 scale. Kokoro `hf_beta` with the Devanagari-mix strategy was the best Hinglish option, and Apple's en-IN voice was the best fast English option, so those are the locked defaults.

**Transcription.** Whisper small is run with a short Roman-script Hinglish prompt so code-mixed speech comes out in Roman letters. A guard detects Devanagari output in Hinglish mode and re-decodes once with the Roman prompt.

**Latency.**

- Voice activity detection stops recording after about 800 ms of silence.
- Replies are split into short clauses and the first one is synthesized and played while the rest is generated.
- For tool turns (weather, alarm, reminder, schedule) the reply is built from the tool result with templates, skipping the second LLM round trip.
- Coordinates for about 20 major Indian cities are built in, and forecasts are cached for 10 minutes.
- "Response time" in the app is measured from the end of the user's speech to the first audible audio.

## Results

Measured on a physical iPhone (iOS 27) with the final build. These are sample runs from manual testing, not a large benchmark.

| Turn | Language | STT | LLM total | TTS first audio | Response time |
|---|---|---|---|---|---|
| Weather: "What's the weather forecast for Bangalore today?" | English | 346 ms | 589 ms | 73 ms | **1028 ms** |
| Alarm: "Mujhe kal subah 9 baje ka alarm set karna hai." | Hinglish | 751 ms | 468 ms | 1000 ms | **2429 ms** |
| Schedule: "Aaj ka schedule kya hai, aur meri next meeting kab hai?" | Hinglish | 764 ms | 874 ms | 1099 ms | **2907 ms** |

**Transcription.** The four example sentences from the assignment were transcribed correctly in both languages on the final build. I did not run a formal word-error-rate evaluation; this is based on spot checks on the device.

**Offline proof.** The Dev section has an "Offline echo test" that records, transcribes and speaks the text back with no network call. It works with Airplane Mode on.

## Known limitations

- **Hinglish is slower than English.** Whisper takes about 0.75 s for Hinglish (about 0.35 s for English), and Kokoro needs about 1 s to produce the first audio. English uses Apple's built-in voice, which starts almost instantly.
- **The Kokoro voice pronounces a few English words with an accent** (for example "set").
- **AlarmKit alarms are real iOS alarms but are not listed in the Clock app.** They ring on the lock screen, and Vaani lists its own alarms in the Dev section.
- **The LLM and weather lookup need internet.** STT and TTS do not.
- **Free personal-team signing** means the app must be reinstalled every 7 days.
- **AlarmKit needs iOS 26 or later.**

## Setup

Requirements: a Mac with Xcode, an iPhone on iOS 26+ (tested on iOS 27), free Groq and Google AI Studio API keys.

1. Clone the repo.
2. Download the models (they are too large for GitHub) into `Staging/`:
   ```
   ./scripts/setup_models.sh
   ```
   If the script's Whisper step fails with a `huggingface-cli` deprecation message, run this instead:
   ```
   hf download argmaxinc/whisperkit-coreml --include "openai_whisper-small/*" --local-dir Staging
   ```
   You should end up with `Staging/kokoro-int8-multi-lang-v1_0` and `Staging/openai_whisper-small`.
3. Copy `Secrets.example.swift` to `Vaani/Secrets.swift` and add your Groq and Gemini keys. This file is gitignored.
4. Open `Vaani.xcodeproj`, select your personal team under Signing & Capabilities, and check that the target's **Build Phases → Run Script** copies both model folders into the app bundle.
5. Select your iPhone and press Run. Allow microphone, calendar, reminders, notifications and location when asked.

On first launch the app should show "Loading speech model" (the bundled model). If the Whisper folder is missing from the bundle, it falls back to downloading it.

## Dev flags

In `ContentView.swift`:

- `kDevTools`: shows the Dev section (offline echo test, demo events, alarm list, results CSV export, TTS lab).
- `kDemoCalendarOnly`: when `true`, schedule questions read only the "Vaani Demo" calendar, so personal events are never spoken. Use Dev → "Seed demo events" to create sample events.

## Stack

- App: Swift, SwiftUI, iOS 27 target
- STT: [WhisperKit](https://github.com/argmaxinc/WhisperKit), Whisper small (CoreML)
- TTS: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) with Kokoro int8 multi-lang v1.0 (Hinglish), AVSpeechSynthesizer with the en-IN voice (English)
- LLM: Groq (`openai/gpt-oss-120b`, fallback `gpt-oss-20b`), Gemini 3.5 / 3.1 Flash-Lite as a second fallback
- Tools: Open-Meteo (weather), EventKit (calendar, reminders), AlarmKit (alarms)

## Project layout

```
Vaani/
  AudioRecorder.swift      mic capture, level meter, VAD
  WhisperKitSTT.swift      on-device STT, Hinglish prompt and script guard
  AgentOrchestrator.swift  LLM loop, streaming, fast path for tool replies
  LLMClients.swift         Groq and Gemini clients with fallback chain
  Tools.swift              weather, reminders, alarms, calendar tools
  SystemPrompt.swift       language and voice-output rules
  AppleTTS.swift           English TTS and the Hinglish text-prep layer
  KokoroTTS.swift          Kokoro synthesis via sherpa-onnx
  VoiceAgentViewModel.swift  state, routing, latency metrics
  ContentView.swift        UI and Dev section
scripts/setup_models.sh    model download script
```
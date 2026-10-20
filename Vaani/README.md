## Setup

1. **Clone the repository**
   ```bash
   git clone <repo-url>
   cd Vaani
   ```

2. **Download models and frameworks**
   ```bash
   ./scripts/setup_models.sh
   ```
   This populates `Staging/kokoro-int8-multi-lang-v1_0` (Kokoro int8 multi-lang TTS for `sherpa-onnx`), `Staging/openai_whisper-small` (WhisperKit CoreML `small` model from `argmaxinc/whisperkit-coreml`), and the `sherpa-onnx` iOS XCFrameworks under `Staging/build-ios`.

3. **Configure API keys**
   Copy `Secrets.example.swift` to `Vaani/Secrets.swift` and add your Groq and/or Gemini API keys:
   ```bash
   cp Secrets.example.swift Vaani/Secrets.swift
   ```

4. **Open the project in Xcode**
   ```bash
   open Vaani.xcodeproj
   ```
   Ensure `Staging/openai_whisper-small` is added to the **Vaani** target's **Copy Bundle Resources** as a folder reference (or synced via the Run Script phase alongside `Staging/kokoro-int8-multi-lang-v1_0`).

5. **Select a personal signing team**
   In Xcode, select the **Vaani** project → **Vaani** target → **Signing & Capabilities**, enable **Automatically manage signing**, and select your Personal Team and a unique Bundle Identifier if needed.

6. **Run on an iOS 27 device and grant permissions**
   Connect your iPhone running iOS 27, select it as the run destination, and press **Run** (`⌘R`). On first launch and tool usage, grant permissions for **Microphone**, **Alarms**, **Calendar**, **Reminders**, and **Location**.

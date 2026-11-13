# Third-party notices

Oops's own code is under the [MIT License](LICENSE). It includes or is derived from the work below, each
under its own terms.

## Code

- **ShaderGradient** (`@shadergradient/react` 2.4, by ruucm, MIT as declared in its package metadata). The
  onboarding gradient's sphere and noise (`Resources/Shaders/ShaderGradient.metal`,
  `Sources/Oops/Onboarding/Gradient/`) are ported from it.
- **three.js** r169, Copyright © 2010-2024 three.js authors, MIT. The physically based shading in
  `ShaderGradient.metal` is ported from its shader chunks.
- **webgl-noise**, Copyright (C) 2011 Ashima Arts, Copyright (C) 2011-2016 Stefan Gustavson, MIT. The
  periodic classic Perlin noise in `ShaderGradient.metal`.
- **Sparkle** 2, Copyright (c) 2006-2013 Andy Matuschak and the other authors in its licence, MIT with the
  additional notices in that file. Linked as a Swift package for updates; its licence ships inside
  `Sparkle.framework`.
- **Hex**, Copyright (c) 2026 Christopher Langton, MIT. The clipboard rules of text written at the caret
  (`Sources/OopsCore/Editor/PasteClipboard.swift`, `Sources/Oops/Editor/InsertClipboard.swift`) and their
  tests are ported from its `src/paste.rs`. Dictation's capture timeline, release tail and silence gate
  (`CaptureInstant.swift`, `DictationCapture*.swift`, `DictationClip.swift`, `SpeechFrames.swift` and
  `VoiceTrack.swift` in `Sources/OopsCore/Dictation/`) and their tests are ported from its `src/dictation.rs`,
  `src/transcription/pause_segmenter.rs` and `src/audio/instant.rs`; the WAV stand-in for the microphone
  (`Sources/Oops/Dictation/DictationAudioFile.swift`) follows its `src/audio/fixture.rs`. The hold-or-double-tap
  shortcut mode (`Sources/OopsCore/Dictation/DictationDoubleTap.swift`) and its tests
  (`Tests/OopsCoreTests/DictationActivationHexTests.swift`) are ported from its `src/suppression/hotkey.rs`,
  `src/suppression.rs`, `src/suppression/tests.rs` and the short-tap rule of `src/dictation.rs` (v3.4.0). The
  speech model catalog and its language rules (`Sources/OopsCore/Dictation/Models/SpeechModel*.swift` and
  `SpeechLanguage.swift`) and their tests (`Tests/OopsCoreTests/ModelCatalog*Tests.swift`) are ported from its
  `src/transcription/models.rs`, `src/transcription/artifacts.rs` and `src/transcription/languages.rs`; the
  keyboard model switching policy (`Sources/OopsCore/Dictation/Models/KeyboardModelSwitching.swift`) and its tests
  from `src/transcription/keyboard_model_switching.rs`; the input-source observer
  (`Sources/Oops/Dictation/KeyboardInputSources.swift`) from `src/keyboard_input_sources/macos.rs` (v3.4.0).
  Model downloads (`Sources/OopsCore/Dictation/Models/ModelDownload*.swift`) and their tests follow
  `download_artifact` in `src/transcription/models.rs` and `src/net/download.rs` (v3.4.0).
- **Handy**, Copyright (c) 2025 CJ Pais, MIT. The dictation activation state machine
  (`Sources/OopsCore/Dictation/DictationCoordinator.swift`) and its tests are ported from its
  `src-tauri/src/transcription_coordinator.rs` (revision 73cc857).
- **transcribe.cpp** 0.4.1, Copyright (c) 2026 The transcribe.cpp authors, MIT. Speech to text for dictation
  (`Sources/OopsEngine/`), linked as `CTranscribe.framework`, built from our fork
  ([0xmrwn/transcribe.cpp](https://github.com/0xmrwn/transcribe.cpp), branch `oops`). Embedded only in preview
  builds for now. Its release archive also carries, each MIT:
  - **ggml**, Copyright (c) 2023-2026 The ggml authors.
  - **miniz**, Copyright 2013-2014 RAD Game Tools and Valve Software, Copyright 2010-2014 Rich Geldreich and
    Tenacious Software LLC.
  - **Silero VAD**, Copyright (c) 2020-present Silero Team.

## Assets

- **Potsdamer Platz** environment map from [Poly Haven](https://polyhaven.com/a/potsdamer_platz), CC0, as
  used by `@react-three/drei`'s `city` preset (Copyright (c) 2020 react-spring, MIT).
  `Resources/Gradient/city-pmrem.bin` is its prefiltered form.
- **earshot**, Copyright (c) 2026 Leon Lin, MIT. The onboarding key, space bar and swell sounds in
  `Resources/Sounds/Onboarding/` are rendered from its sound bank (`design/onboarding/sound/`); the app's
  own cues follow its bubble recipe without using the package.
- **lobehub/icons** (`@lobehub/icons-static-svg` 1.98.0), Copyright (c) 2023 LobeHub, MIT. The provider
  marks in `Resources/Assets.xcassets`. The names and marks belong to their owners and identify the
  providers Oops connects to; they are not an endorsement.
- **ChatGPT marks**: OpenAI brand assets, used under [OpenAI's brand guidelines](https://openai.com/brand/)
  on the Continue with ChatGPT button only. Not covered by Oops's licence.

`design/providers/README.md` records where each mark came from and what was changed.

## MIT License

Applies to each MIT entry above, with that entry's copyright line.

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction, including
> without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
> following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial
> portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
> LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
> EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
> IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
> USE OR OTHER DEALINGS IN THE SOFTWARE.

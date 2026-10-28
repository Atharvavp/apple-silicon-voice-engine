# GitHub presentation settings (for the owner to apply)

These values can only be set in the repository's **About** panel (gear icon on the repository page)
or with `gh repo edit`. They are written to match the README. Nothing here has been applied.

| Setting | Proposed value |
|---|---|
| Description | `Swift/Python benchmark harness for streaming ASR and speaker diarization on Apple Silicon: sample-exact replay, sealed artifacts, reproducible scoring. Mock adapters by default; optional FluidAudio/speech-swift wrappers.` |
| Website | Leave empty. There is no hosted site, and the README is the landing page |
| Topics | `swift`, `python`, `apple-silicon`, `macos`, `speech-recognition`, `asr`, `speaker-diarization`, `benchmark`, `coreml`, `streaming-audio`, `evaluation`, `reproducibility` |
| Include in the home page | Releases: off (no release exists). Packages: off. Deployments: off |
| Social preview | None for now. The default card shows the name and description. Add an image only if it states the same scope as the README (harness, not engine) |
| Pinned-repository blurb | Uses the description above |

Equivalent command, to run only after the publication branch is merged:

```sh
gh repo edit Atharvavp/apple-silicon-voice-engine \
  --description "Swift/Python benchmark harness for streaming ASR and speaker diarization on Apple Silicon: sample-exact replay, sealed artifacts, reproducible scoring. Mock adapters by default; optional FluidAudio/speech-swift wrappers." \
  --add-topic swift,python,apple-silicon,macos,speech-recognition,asr,speaker-diarization,benchmark,coreml,streaming-audio,evaluation,reproducibility
```

Words to avoid in the description, topics and any caption, because the evidence does not support
them: "voice engine" (as a present capability), "real-time" (as a performance claim), "fastest",
"x faster than real time", "production-ready", "on the ANE", "simultaneous ASR and diarization".

Add a CI badge only after the `ci` workflow has passed on `main`.

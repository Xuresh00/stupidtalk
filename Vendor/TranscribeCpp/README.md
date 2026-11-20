# TranscribeCpp (vendored)

The Swift wrapper for [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), the
open-source speech engine that the [Handy](https://github.com/cjpais/Handy) app runs on.

- Copied unchanged from `bindings/swift/Sources/TranscribeCpp` at tag `v0.4.2`.
- The native part, `TranscribeCpp.xcframework`, is not stored in git. `scripts/fetch-engine.sh`
  downloads it from the v0.4.2 release and checks its SHA-256 before the build uses it.
- MIT licensed, see `LICENSE`. The engine bundles ggml, miniz and Silero VAD, see
  `THIRD-PARTY-LICENSES.md`.

To update: copy the wrapper from the new tag, then change `VERSION` and `SHA256` in
`scripts/fetch-engine.sh` to match the new release's `TranscribeCpp.xcframework.zip`.

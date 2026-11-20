# StupidTalk by Stupidesigner

**Hold a key, talk, let go. Your words land where your cursor is.**

StupidTalk is voice typing for the Mac. You speak the way you normally speak, and Mr. Oops types what you said, in whatever app you are in. The ums and uhs are taken out. Nothing else gets added.

Free. Open source. No account. Your voice and your words never leave your Mac.

Made by [Stupidesigner](https://stupidesigner.com). Stupid talk. Smart text.

## What it does

- **Hold to talk.** Hold Right Option (or Right Command, or Fn), speak, let go. The words are typed at your cursor in any app: mail, chat, docs, the browser, your editor.
- **Hears you right.** Speech to text runs on [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), the open-source engine behind the [Handy](https://github.com/cjpais/Handy) app, with NVIDIA's Parakeet model on your Mac's GPU. A short dictation is written down in well under a second.
- **Types exactly what you said.** Fillers go ("um", "uh") and accidental repeats ("the the") are dropped. When you change your mind out loud ("on Monday, no wait, Tuesday"), only the final version stays. It never adds commas, brackets or lists of its own.
- **Leaves your clipboard alone.** The words are typed like a keyboard would, so whatever you copied before is still there to paste. After each dictation a **Copy** button shows in the pill for 2 seconds, for when you do want the words on the clipboard.
- **Your own word list.** Teach it the names it keeps getting wrong, like your brand or your clients. Near misses are fixed too: "stupid dark" still comes out as StupidTalk.
- **Spoken commands.** Say "new line", "new paragraph", "bullet point", "open bracket" and "close bracket", "comma", "full stop" or "question mark" and it is done for you, without the words.
- **Your original words are always kept.** Every dictation is saved in both versions, so you can copy what you actually said.
- **Optional AI polish.** Off by default. Switch it on in Settings and the model that comes with macOS also fixes small grammar mistakes, with a short time limit so it never holds you up.

Example:

> You say: "um so send the the thumbnails to Sam on Monday, no wait, Tuesday, and uh tell him the font is fixed"
>
> It types: "So send the thumbnails to Sam on Tuesday, and tell him the font is fixed."

## What you need

- A Mac with Apple silicon running **macOS 26 or newer**.
- About 1 GB of free space for the speech model, downloaded once.
- English, for now. See the roadmap.
- For the optional AI polish only: Apple Intelligence turned on.

## Install

1. Download `StupidTalk-x.y.z.dmg` from the [Releases](https://github.com/Xuresh00/stupidtalk/releases) page and open it.
2. Drag **StupidTalk** onto the Applications shortcut, then open it from your Applications folder.
3. macOS will say it cannot check the app, because it is not notarized by Apple. Open **System Settings, Privacy & Security**, scroll down, and click **Open Anyway**. You only do this once.
4. Mr. Oops appears in the menu bar and the setup checklist opens. It walks you through three things:
   - **Microphone**, so it can hear you. It only listens while you hold the key.
   - **Accessibility**, so it can notice the key in any app and type the words at your cursor.
   - **Speech model**, a one-time download of Parakeet (731 MB) from Hugging Face. After that it works offline.

## Use it

1. Click where you want the text.
2. Hold **Right Option**, say it, let go.
3. A small pill with Mr. Oops shows that he is listening, then done, with the Copy button.

Good to know:

- A quick tap does nothing. Pressing any other key while you hold cancels the dictation, so normal shortcuts keep working. Escape cancels too.
- A new line is typed as Shift-Return, so it makes a line break in chat apps instead of sending the message.
- Click Mr. Oops in the menu bar for **Type last result again**, **Copy what I actually said**, the history, the word list and the settings.
- In Settings you can change the key, the microphone, the speech model, how the words go in (typed, or pasted with your clipboard put back), and whether a space is added after each dictation.
- If Parakeet keeps mishearing your accent, try **Whisper Turbo** in Settings, General. It is a bit slower, and it also understands Hindi, for later.
- By default it uses the Mac's own microphone, which keeps AirPods in music quality. Pick "System default" if you use an external mic.

## Speech models

| Model | Size | English mistakes (FLEURS) | 11 s of audio on an M4 | License |
| --- | --- | --- | --- | --- |
| Parakeet, recommended | 731 MB | 3.99% of words | 141 ms | NVIDIA Open Model License |
| Whisper Turbo | 886 MB | 4.38% of words | 1101 ms | MIT |

Numbers from [transcribe.cpp's model catalog](https://github.com/handy-computer/transcribe.cpp/tree/main/catalog). Both files are the GGUF builds that Handy publishes on Hugging Face. StupidTalk checks every download against its published size and SHA-256 before using it.

## Privacy

- Audio is captured only while you hold the key and is never written to disk.
- Speech to text runs on your Mac's GPU. The optional AI polish uses Apple's on-device model. Nothing you say is sent anywhere.
- The only network call StupidTalk ever makes is the one-time speech model download from Hugging Face.
- The history and the word list are plain files in `~/Library/Application Support/StupidTalk`, and the model sits in its `Models` folder. You can switch the history off or clear it in Settings.
- The log in `~/Library/Logs/StupidTalk` records timings and errors, never what you said.
- No analytics, no account.

Permissions it asks for: **Microphone** and **Accessibility**. Accessibility is what lets an app see a global key and type for you.

## Limits, said plainly

- English only in this version.
- The rules only fix self-corrections they are sure about. An unclear one is typed the way you said it, unless the AI polish is on.
- The speech model still mishears now and then, mostly names. Add those to the word list. Your original words are kept either way.
- A few apps ignore typed text from other apps. For those, pick "Paste it" in Settings, General. Pasting uses Command-V, so on keyboard layouts where V sits elsewhere it may not land. Your clipboard is put back afterwards.
- The app is ad-hoc signed and not notarized. After you update it, macOS may ask for the permissions again. If the key stops working after an update, switch StupidTalk off and on under Privacy & Security, Accessibility.

## Build it yourself

You need macOS 26 or newer and Swift 6 (Xcode, or only the Command Line Tools).

```sh
git clone https://github.com/Xuresh00/stupidtalk.git
cd stupidtalk
scripts/test.sh                                   # tests for the clean-up logic
scripts/build.sh                                  # makes dist/StupidTalk.app and a zip
scripts/build.sh /Applications                    # or build straight into a folder
STUPIDTALK_DMG_DIR=dist scripts/build.sh          # also makes dist/StupidTalk-x.y.z.dmg
```

The first build downloads the speech engine (transcribe.cpp 0.4.2, about 10 MB) and checks its SHA-256. `scripts/fetch-engine.sh` does that on its own if you want it ahead of time.

How the code is laid out:

- `Sources/StupidTalkCore` is plain Swift with no Mac frameworks: the clean-up rules, the word list and its near-miss matching, silence trimming, how text is split into key presses, the prompt and the checks on the AI's answer, and the hold-to-talk logic. Its tests also run on Linux (`swift test`).
- `Sources/StupidTalk` is the Mac app: the key monitor, the recorder, the speech engine and model download, the optional AI polish (FoundationModels), the typing, the pill, the menu bar item and the windows.
- `Vendor/TranscribeCpp` is the Swift wrapper of transcribe.cpp, copied unchanged from its 0.4.2 release.
- `Packaging` holds the Info.plist and the icon. `scripts/make_icon.py` turns one square picture into the icon set.

## Thanks

- [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) (MIT) does the speech to text. It bundles ggml, miniz and Silero VAD, see [its third-party licenses](Vendor/TranscribeCpp/THIRD-PARTY-LICENSES.md).
- [Handy](https://github.com/cjpais/Handy) (MIT) showed the way: the engine, the models, and the idea behind the near-miss word matching.
- NVIDIA Parakeet and OpenAI Whisper are the speech models.

## Roadmap

- Hindi and Hinglish, with Whisper Turbo.
- Your own key combination.
- Windows.

## License

Code: [MIT](LICENSE). The Stupidesigner name, the wordmark and Mr. Oops are brand assets and are not covered by it. See [BRAND.md](BRAND.md).

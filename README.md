# StupidTalk by Stupidesigner

**Hold a key, talk, let go. Clean text lands where your cursor is.**

StupidTalk is voice typing for the Mac. You speak the way you normally speak, with the ums, the restarts and the "no wait, I meant Tuesday". Mr. Oops cleans it up and types what you meant, in whatever app you are in.

Free. Open source. No account. Your voice and your words never leave your Mac.

Made by [Stupidesigner](https://stupidesigner.com). Stupid talk. Smart text.

## What it does

- **Hold to talk.** Hold Right Option (or Right Command, or Fn), speak, let go. The text is typed at your cursor in any app: mail, chat, docs, the browser, your editor.
- **Clean-up that keeps up.** Fillers go ("um", "uh"). Repeated words are dropped. When you change your mind mid-sentence ("on Monday, no wait, Tuesday"), only the final version stays. Small grammar mistakes and punctuation get fixed. The model that ships with macOS does the polish, usually in well under a second, and it has a short time limit so it never holds you up.
- **Lists, brackets and line breaks.** Dictate a list and it is typed as a list, one item per line. Say "new line", "new paragraph", "bullet point", "open bracket" and "close bracket", "comma", "full stop" or "question mark" and it is done for you, without the words.
- **Your own word list.** Teach it the names it keeps getting wrong, like your brand or your clients. Add the right spelling and what it tends to hear instead.
- **Your original words are always kept.** Every dictation is saved in both versions, so you can copy what you actually said. You can also switch the AI off, or let it polish every dictation.
- **Runs on your Mac.** Speech to text and the clean-up both use the models that ship with macOS. Nothing is uploaded, and there is no server.

Example:

> You say: "um so send the the thumbnails to Sam on Monday, no wait, Tuesday, and uh tell him the the font is fixed"
>
> It types: "Send the thumbnails to Sam on Tuesday and tell him the font is fixed."

## What you need

- A Mac with Apple silicon running **macOS 26 or newer**.
- For the AI clean-up: **Apple Intelligence turned on** (System Settings, Apple Intelligence & Siri). Without it StupidTalk still works and uses the basic clean-up.
- English, for now. See the roadmap.

## Install

1. Download `StupidTalk-x.y.z.dmg` from the [Releases](https://github.com/Xuresh00/stupidtalk/releases) page and open it.
2. Drag **StupidTalk** onto the Applications shortcut, then open it from your Applications folder.
3. macOS will say it cannot check the app, because it is not notarized by Apple. Open **System Settings, Privacy & Security**, scroll down, and click **Open Anyway**. You only do this once.
4. Mr. Oops appears in the menu bar and the setup checklist opens. It walks you through four things:
   - **Microphone**, so it can hear you. It only listens while you hold the key.
   - **Accessibility**, so it can notice the key in any app and paste the text at your cursor.
   - **Speech model**, a one-time download through macOS.
   - **AI clean-up**, which is ready when Apple Intelligence is on.

## Use it

1. Click where you want the text.
2. Hold **Right Option**, say it, let go.
3. A small pill with Mr. Oops shows that he is listening, then cleaning up, then done.

Good to know:

- A quick tap does nothing. Pressing any other key while you hold cancels the dictation, so normal shortcuts keep working. Escape cancels too.
- The model polishes every dictation of four words or more. For the fastest typing, set it to "Only when I correct myself" in Settings, Clean-up.
- Click Mr. Oops in the menu bar for **Paste last result again**, **Copy what I actually said**, the history, the word list and the settings.
- In Settings you can change the key, the microphone, your English accent, and whether a space is added after each dictation.
- By default it uses the Mac's own microphone, which is meant to keep AirPods in music quality. Pick "System default" if you use an external mic.

## How the clean-up stays honest

A language model can do the wrong job. Ask it to clean "what is the capital of France" and it may answer the question instead. StupidTalk guards against that:

1. Your word list is applied first, and the rules fix what they are sure about: fillers, repeats, punctuation and clear self-corrections. Most dictations are done here and typed at once.
2. Only a self-correction the rules are not sure about goes to the on-device model, and only that part of the text. It is asked to clean it, nothing else, and it gets a short time limit.
3. The answer is checked against what you said. A real clean-up is mostly your own words, in the same order, with pieces removed. If the answer is longer than what you said, drops most of it, apologizes, answers a question, or wanders off, it is thrown away.
4. When an answer is thrown away or comes too late, your words are typed with the rule-based clean-up instead.

So the worst case is a dictation that is a little less polished, never one that says something you did not say. The checks live in [`CleanupValidator.swift`](Sources/StupidTalkCore/CleanupValidator.swift), the self-correction rules in [`SelfCorrection.swift`](Sources/StupidTalkCore/SelfCorrection.swift), and both are covered by tests.

## Privacy

- Audio is captured only while you hold the key and is never written to disk.
- Speech to text uses Apple's on-device speech model. The clean-up uses Apple's on-device language model. Both run on your Mac.
- The history and the word list are plain files in `~/Library/Application Support/StupidTalk`. You can switch the history off or clear it in Settings.
- The log in `~/Library/Logs/StupidTalk` records timings and errors, never what you said.
- No analytics, no account, no network calls by StupidTalk.

Permissions it asks for: **Microphone** and **Accessibility**. Accessibility is what lets any app see a global key and press Command-V for you.

## Limits, said plainly

- English only in this version.
- The rules only fix self-corrections they are sure about. An unclear one waits a moment for the model, and when the model is too slow it is typed the way you said it.
- The polish adds a short wait: usually well under a second, about 2 seconds at most for a sentence or two, more for very long dictations.
- The clean-up will sometimes guess wrong. That is why the original is kept.
- Text is inserted by pasting (Command-V), like most dictation apps. On keyboard layouts where V is in a different place, the paste may not land. Your clipboard is put back afterwards.
- The app is ad-hoc signed and not notarized. After you update it, macOS may ask for the permissions again. If the key stops working after an update, switch StupidTalk off and on under Privacy & Security, Accessibility.

## Build it yourself

You need macOS 26 or newer and Swift 6 (Xcode, or only the Command Line Tools).

```sh
git clone https://github.com/Xuresh00/stupidtalk.git
cd stupidtalk
scripts/test.sh                  # tests for the clean-up logic
scripts/build.sh                                  # makes dist/StupidTalk.app and a zip
scripts/build.sh /Applications                    # or build straight into a folder
STUPIDTALK_DMG_DIR=dist scripts/build.sh          # also makes dist/StupidTalk-x.y.z.dmg
```

How the code is laid out:

- `Sources/StupidTalkCore` is plain Swift with no Mac frameworks: the rule-based clean-up, the word list, the prompt, the checks on the model's answer, and the hold-to-talk logic. Its tests also run on Linux (`swift test`).
- `Sources/StupidTalk` is the Mac app: the key monitor, the recorder, speech to text (Speech framework), the on-device model (FoundationModels), the paste, the menu bar item and the windows.
- `Packaging` holds the Info.plist and the icon. `scripts/make_icon.py` turns one square picture into the icon set.

## Roadmap

- Hindi and Hinglish.
- An optional open model for the clean-up, for Macs without Apple Intelligence.
- Your own key combination.
- Spoken commands such as "new line".
- Windows.

## License

Code: [MIT](LICENSE). The Stupidesigner name, the wordmark and Mr. Oops are brand assets and are not covered by it. See [BRAND.md](BRAND.md).

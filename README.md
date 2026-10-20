# Grok Bot for Apple Watch

A watchOS 11 app for Apple Watch Ultra 2. You talk to a Grok Bot like a call, see which bots are working, switch bots mid-call, and change the language, speed, and voice of the spoken reply.

It is a companion you build and sideload. It is not the TestFlight app from [@0xmoalo](https://x.com/0xmoalo/status/2111198124769472535). That post is the interaction this one is aiming at: a call, every bot, switch mid-call, and voice controls, with a shorter wait before you hear the first sentence.

## Transport

There is no public Grok Bot REST API to point a client at. The watch uses the four routes already implemented by `@cursor/bdk` 0.2.27 (`cursor-grokbot-agents`), on `https://api.cursor.com`, with your Cursor user API key. The route table, the reason those routes were chosen, and the offline queue are in [docs/TRANSPORT.md](docs/TRANSPORT.md).

Until a key is saved, the app runs on a mock transport with two sample bots so the call UI works with no account. The key goes in the watch Keychain from Settings. It is not a file in this repository.

The API does not stream tokens. The app polls the transcript the same way the BDK client does, splits each delivered reply into sentences, and starts watch TTS on the first sentence while the turn is still settling.

## Project

```text
project.yml                 xcodegen spec (watch app, complication, tests)
Packages/GrokBotCore        transport, call model, queue, complication snapshot
GrokBotWatch                SwiftUI watch app, system dictation, Keychain, App Intent
GrokBotComplication         WidgetKit complication
```

`GrokBotCore` has no WatchKit dependency. `swift test` runs it on a Mac or Linux. The watchOS unit-test bundle compiles those same tests.

## Build on a Mac

You need Xcode 16 or newer, because the project targets watchOS 11. Xcode includes the watchOS simulator. This repository does not vendor Xcode.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. From this directory, generate the project: `xcodegen generate`
3. Open `GrokBotWatch.xcodeproj`.
4. Select the `GrokBotWatch` scheme and an Apple Watch Ultra 2 (49mm) simulator, or a paired Ultra 2.
5. Signing is set up for a free Personal Team. The only bundle id to change is `options.bundleIdPrefix` in `project.yml`. The default is `com.aneesh15here.grokbotwatch`. If Apple says that id is already registered, change that one value and run `xcodegen generate` again. The targets become `<prefix>.GrokBotWatch`, `<prefix>.GrokBotComplication`, and `<prefix>.GrokBotWatchTests`.
6. Set your Team under Signing & Capabilities for both the app and the complication.
7. Run.

Logic tests, without signing:

```sh
xcodebuild test \
  -scheme GrokBotWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 2 (49mm)' \
  CODE_SIGNING_ALLOWED=NO
```

The same tests on a machine with Swift, without the watch SDK:

```sh
swift test --package-path Packages/GrokBotCore
```

### Free Apple ID (7-day sideload)

This is the default. A personal team can install the app on your own watch for 7 days. Connect the watch, select it as the run destination, and accept the profile on the watch if iOS asks. Re-run from Xcode when the week is up.

App Groups are not available to a free personal team. `GROKBOT_USE_APP_GROUP` is `NO`, and both targets sign with the empty entitlement files:

- `GrokBotWatch/GrokBotWatch.free.entitlements`
- `GrokBotComplication/GrokBotComplication.free.entitlements`

Calls, the offline queue, and the Siri / Action Button shortcut still work. Their state stays in the app's documents directory and in UserDefaults. The complication cannot see bot activity and stays on "Open Grok Bot".

### Paid Apple Developer Program

A paid account keeps the install for a year and can use TestFlight. Create the App Group `group.` plus your `bundleIdPrefix`. With the default prefix that is `group.com.aneesh15here.grokbotwatch`. Then in `project.yml` set `GROKBOT_USE_APP_GROUP` to `YES`, and point `entitlements.path` and `CODE_SIGN_ENTITLEMENTS` for both targets at:

- `GrokBotWatch/GrokBotWatch.entitlements`
- `GrokBotComplication/GrokBotComplication.entitlements`

Those files request `$(GROKBOT_APP_GROUP_ID)`, which is `group.` plus the bundle id prefix. Run `xcodegen generate` again. The complication then shows the bot the app last reported as working, queued, or idle.

Add the complication by editing a watch face and choosing Grok Bot. It has circular, rectangular, inline, and corner families.

## Use

1. Open the app. Sample bots are already listed.
2. Tap a bot. Tap the mic to dictate, or tap Type. The watchOS SDK has no Speech framework, so the mic opens the system dictation screen (`presentTextInputController` with no suggestions, which starts the microphone directly). Swipe up on that screen to change the dictation language. Type opens the same controller with text suggestions, plus Scribble and dictation. If that screen cannot be presented, Type falls back to the in-app text field. The first sentence of a reply is spoken as soon as that sentence is complete. The simulator may show a keyboard for dictation instead of the microphone.
3. Switch changes who hears the next thing you say and leaves the previous bot's turn running.
4. The digital crown changes speech speed during a call. Voice changes the language, speed, and voice of the spoken reply. Those settings stay on the watch. Dictation follows the language on the system dictation screen, not this voice setting.
5. To talk to your own bots, open Settings, paste a Cursor user API key, and save. Turn Sample bots off. Add each bot by the exact name shown in the Grok Bot app. A name that does not exist creates an empty bot on the account; the app warns when that happens.
6. If the watch is offline, what you said stays queued and sends when the network returns, using the same message id.

### Action Button and Siri

The app publishes a shortcut, "Talk to last bot". On an Ultra 2, assign the Action Button to that shortcut (Watch app, Action Button, Shortcut). Siri phrases:

- "Talk to my last Grok Bot with Grok Bot"
- "Call my last bot with Grok Bot"

The shortcut opens the app into a call with the last bot you used. The first time, before any call, it stays on the roster and says there is no last bot yet.

A bot that finishes a turn you were waiting on plays a success haptic.

## What was verified here

This environment is Ubuntu 24.04 with Swift 6.4.1. It does not have Xcode, `xcodebuild`, or a watchOS SDK, so a real watchOS build was not run. The watch app and complication still have to be compiled in Xcode.

`swift test --package-path Packages/GrokBotCore` passed on Swift 6.4.1: 32 tests, 0 failures. It covers the HTTP route builder (only the four documented routes, bearer token not copied into errors), the sentence splitter, the idle-poll wait, the call model (first sentence before the turn settles, haptics, mid-call switch, barge-in interrupt, offline queue, launch plan), the free-team App Group fallback, and the mock transport.

The watch targets do not import Speech. Spoken replies still use `AVSpeechSynthesizer`, which is in the watchOS SDK. The shortcut uses App Intents (`AppIntent`, `AppShortcutsProvider`), and the complication uses WidgetKit accessory families plus `WidgetCenter`. Those frameworks are on watchOS. The microphone path is WatchKit system dictation.

SwiftUI previews were not rendered. Open the project in Xcode and run the watch simulator to see the call screen.

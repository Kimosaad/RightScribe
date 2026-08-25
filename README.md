# RightScribe

RightScribe is a private, personal macOS 26 menu-bar dictation app. Press right Command once, speak, then press it again. The finalized transcript is inserted into the field that already had focus.

It can also detect an active call in common meeting apps, ask for explicit consent, and create private meeting notes with separate **You** and **Attendee** transcript channels.

## V1 behavior

- Uses Apple's new `SpeechAnalyzer` and `SpeechTranscriber` APIs.
- Runs transcription on-device after the English model asset is downloaded.
- Shows a floating indicator without taking focus from the target app.
- Uses one consistent clipboard-preserving paste path across native, browser, Electron, terminal, and document apps.
- Preserves the existing clipboard after fallback insertion.
- Never stores audio; successfully inserted transcripts are kept only in local history on this Mac.
- Treats a press-and-release of right Command as a start/finish toggle. Command-key chords remain normal shortcuts and do not toggle dictation.
- Stops an active recording immediately on right-Command key-down, with key-release, listener-interruption, and timeout recovery paths as safeguards.
- Pressing Escape while recording or finalizing immediately discards the session without inserting or saving its transcript.
- Opens a visible setup window and keeps a Dock icon available until you choose **Continue in Menu Bar**.
- Rechecks permissions automatically while setup is open.
- Uses Accessibility for the right-Command listener, so Input Monitoring is not required.
- Prewarms Apple's speech analyzer before showing Ready, so the first spoken words are captured immediately.
- Removes conservative filler phrases such as “um,” “uh,” and “you know” by default without removing meaningful uses of “like.”
- Shows only a compact waveform indicator above the Dock while dictating.
- Saves successfully pasted transcripts in a local history view; audio is never saved.
- Opens to a warm cream Recent view, with searchable History and all setup controls moved into Settings.
- Supports up to 100 locally saved custom vocabulary entries and supplies them directly to Apple's on-device analyzer as contextual phrases.
- Uses a stable Apple Development signature so macOS permissions survive future rebuilds.
- Detects likely active calls from real per-process microphone or call-audio activity, with meeting-window checks to avoid browser false positives and support muted calls.
- Never starts meeting capture automatically: a detected call always opens a **Start Notes** / **Not Now** prompt first.
- Captures the microphone and meeting-app audio through Core Audio's process-only tap as separate channels, then saves a chronological **You** / **Attendee** transcript in the Meetings section. It does not start a screen-sharing session.
- Ends meeting capture through the menu-bar icon and **End Meeting Recording**, or through a confirmation in the Meetings page.
- Connects directly to Google Calendar with read-only OAuth access—without reading Apple Calendar—and matches active calls to their event title, organizer, attendees, time, and meeting link.
- Stores Google access and refresh tokens in the macOS Keychain. Only the calendar details attached to saved meeting notes are kept in RightScribe's local meeting history.

## First launch

1. Open `RightScribe.app`.
2. In the setup window, choose **Set Up Permissions**.
3. Approve each permission shown in the checklist.
4. RightScribe checks again automatically and prepares Apple's local English model.
5. When it says **Ready**, choose **Continue in Menu Bar**.
6. Click into any text field, press and release right Command once, speak, and press it once more to paste. Press Escape instead to cancel and discard it.

Use **Prepare Meeting Audio** in Settings before your first call. macOS may show one system-audio privacy prompt, but RightScribe does not request or use screen sharing. Recording still begins only after **Start Notes** is clicked, and raw audio is never saved.

## Connect Google Calendar directly

In **Settings → Google Calendar**, use the two setup links to enable the Google Calendar API and create an OAuth client with application type **Desktop app**. Paste the resulting client ID into RightScribe and choose **Connect Google Calendar**. Google opens its own sign-in and consent page in your default browser; RightScribe requests only `calendar.readonly` access.

This is a direct Google Calendar API connection. It does not use, sync through, or require the macOS Calendar app.

Launching the app again restores its setup window if the menu-bar item is hard to find.

## Build locally

Run `./build-app.sh`. The signed personal app is produced at `outputs/RightScribe.app`. The build stops the previous copy before replacing it, preventing stale code from remaining active.

## V2 extension point

`TranscriptRouting` separates transcription from what happens next. V1 always returns `.insertText`. V2 can add explicit command routing, previews, and approved actions without changing audio capture or the right-Command interaction.

Meeting capture also keeps microphone and attendee audio separate. That boundary is the extension point for adding FluidAudio diarization so the current generic **Attendee** channel can later be split into named speakers without replacing meeting detection, consent, or storage.

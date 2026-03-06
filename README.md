# Elara Ink iOS

iOS handwriting + math coaching app built on MyScript Interactive Ink.

This project is based on the MyScript iOS examples and has been extended with an Elara analysis workflow, coaching UI, anchored highlights, and practice-problem support.

## Current Features

- Raw Content (`text_math_shape`) workflow for mixed text/math recognition.
- Analyze with Elara from:
  - More menu
  - SmartGuide button
  - Toolbar AI button
  - Elara drawer actions
- Backend response support for:
  - `status`, `confidence`, `hint`
  - `agent_goal`
  - `highlights`
  - `practice_problem`
- Highlight overlay anchored to recognized step bboxes using MyScript renderer transform.
- Practice problem flow:
  - decoded and shown in drawer
  - explicit user action to insert onto canvas
  - inserted as editable content so future analyzes include it

## Repository Layout

- `Examples/DemoCopy` — main app project/workspace (`Demo.xcworkspace`)
- `Examples/Frameworks` — shared UI reference implementation used by the app
- `configurations` — recognition/profile config files
- `fonts` — font assets used by the app

## Requirements

- Xcode (recent stable)
- CocoaPods
- iOS target as defined in project settings

## Setup

1. Install CocoaPods (if needed):

```bash
brew install cocoapods
```

2. Install pods:

```bash
cd Examples/DemoCopy
pod install
```

3. Open workspace:

```bash
open Demo.xcworkspace
```

4. Build and run the `Demo` scheme.

## MyScript Certificate (Important)

This repo keeps a placeholder certificate file at:

- `Examples/DemoCopy/Demo/MyScriptCertificate/MyCertificate.c`

To run recognition, replace it locally with your real MyScript certificate bytes.

Do **not** commit real certificate bytes.

Recommended local protection:

```bash
git update-index --skip-worktree Examples/DemoCopy/Demo/MyScriptCertificate/MyCertificate.c
```

If you need to update and commit the placeholder later:

```bash
git update-index --no-skip-worktree Examples/DemoCopy/Demo/MyScriptCertificate/MyCertificate.c
# edit and commit placeholder
git update-index --skip-worktree Examples/DemoCopy/Demo/MyScriptCertificate/MyCertificate.c
```

## Backend Configuration

Set the Elara endpoint in app plist:

- key: `ELARA_ANALYZE_URL`
- value example: `https://<your-host>/check/ios`

## Notes

- Recognition assets retrieval script is included in `Examples/DemoCopy/retrieve_recognition-assets.sh`.
- Keep license files and notices when redistributing.
- Review MyScript SDK and recognition asset terms for your intended use.

## License

Base sample code originates from MyScript examples under Apache 2.0 (see `LICENSE`), with additional third-party notices under `LICENSES/`.

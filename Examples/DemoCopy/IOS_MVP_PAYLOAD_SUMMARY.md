# iOS Analyze Payload (Current MVP Shape)

This document describes the current payload shape that the `DemoCopy` iOS client sends from the Elara Analyze flow.

It is intended as context for backend integration and LLM-assisted backend contract design.

## Example Payload

```json
{
  "requestId": "65CD07CC-7C16-4833-979A-2558857AD9B7",
  "sessionId": "session_local_uuid",
  "timestampMs": 1760000000000,
  "document": {
    "partId": "wlfqfboj",
    "partType": "Raw Content"
  },
  "recognition": {
    "mimeType": "JSON iink Exchange Format",
    "rawJiix": "{...full MyScript JIIX string...}",
    "transcriptionText": "2x+3=11\n2x=8\nx=4",
    "wordLocations": [
      {
        "label": "Differentiation",
        "x": 21.9,
        "y": 11.56,
        "width": 39.35,
        "height": 8.29,
        "candidates": ["Differentiation", "..."],
        "strokeIds": ["000001...", "000002..."]
      }
    ],
    "provisionalSteps": [
      {
        "stepId": "step_0",
        "text": "2x+3=11",
        "elementType": "Math",
        "bbox": {
          "x": 25.016,
          "y": 13.505,
          "width": 33.910,
          "height": 8.874
        },
        "wordLocations": null,
        "strokeIds": [],
        "lineIndex": 0
      },
      {
        "stepId": "step_1",
        "text": "2x=8",
        "elementType": "Math",
        "bbox": {
          "x": 25.321,
          "y": 28.016,
          "width": 31.280,
          "height": 7.769
        },
        "wordLocations": null,
        "strokeIds": [],
        "lineIndex": 1
      }
    ]
  },
  "clientMeta": {
    "device": "iPad",
    "appVersion": "4.3",
    "canvasWidth": 1180.0,
    "canvasHeight": 820.0,
    "viewScale": 1.0,
    "viewOffsetX": 0.0,
    "viewOffsetY": 0.0,
    "coordinateSpace": "myscript_editor"
  },
  "exportedDataBase64": null
}
```

## Field Types (Current iOS structs)

### Top-level

- `requestId: String`
- `sessionId: String`
- `timestampMs: Int64`
- `document: ElaraDocumentRef`
- `recognition: ElaraRecognitionPayload`
- `clientMeta: ElaraClientMeta`
- `exportedDataBase64: String?` (fallback if export is non-UTF8)

### `document`

- `partId: String`
- `partType: String`
  - Examples: `"Raw Content"`, `"Math"`, `"Text"`

### `recognition`

- `mimeType: String`
  - Example: `"JSON iink Exchange Format"`
- `rawJiix: String?`
  - Full MyScript JIIX JSON string (large)
- `transcriptionText: String?`
  - Human-readable recognized text / math labels joined by line
- `wordLocations: [ElaraWordLocation]?`
  - Usually available for text blocks
  - Often `null` / empty for math blocks in current parser
- `provisionalSteps: [ElaraProvisionalStep]?`
  - Client-side approximation from JIIX `elements[]` (sorted by bbox)

### `ElaraWordLocation`

- `label: String`
- `x: Double?`
- `y: Double?`
- `width: Double?`
- `height: Double?`
- `candidates: [String]?`
- `strokeIds: [String]?`

Notes:

- Whitespace text tokens may appear unless filtered (can produce nil bbox entries).
- `strokeIds` are extracted from text `words[].items[].id` when present.

### `ElaraProvisionalStep`

- `stepId: String` (e.g. `"step_0"`)
- `text: String`
- `elementType: String`
  - Examples: `"Text"`, `"Math"`
- `bbox: ElaraBBox?`
- `wordLocations: [ElaraWordLocation]?` (text blocks may have these)
- `strokeIds: [String]`
- `lineIndex: Int`

### `ElaraBBox`

- `x: Double`
- `y: Double`
- `width: Double`
- `height: Double`

Important:

- Coordinates are in **MyScript editor coordinate space**, not normalized screen coords.
- `y` can be negative.

### `clientMeta`

- `device: String` (currently `"iPad"`)
- `appVersion: String`
- `canvasWidth: Double`
- `canvasHeight: Double`
- `viewScale: Double`
- `viewOffsetX: Double`
- `viewOffsetY: Double`
- `coordinateSpace: String` (currently `"myscript_editor"`)

## Current Behavior / Guarantees

- `provisionalSteps` works for mixed text + math and multiline math in `Raw Content (text_math_shape)` based on current tests.
- Math blocks usually produce:
  - `elementType = "Math"`
  - `text` as LaTeX-like string (e.g. `\\dfrac{d}{dx}...`)
  - block bbox
  - no word-level boxes in current parser
- Text blocks can produce word-level boxes/candidates/stroke IDs.

## Backend Adapter Recommendation (for `app_v2`)

Map:

- `recognition.provisionalSteps[*].text` -> `StepSnapshot.raw_myscript`
- `recognition.provisionalSteps[*].bbox` -> `StepSnapshot.bbox` (normalize later)
- `recognition.provisionalSteps[*].strokeIds` -> `StepSnapshot.stroke_ids`
- `recognition.provisionalSteps[*].lineIndex` -> `StepSnapshot.line_index`
- `clientMeta` -> `Snapshot.client_meta`
- Keep `recognition.rawJiix` for debugging / future deeper parsing

## Constraints / Caveats

- This is **client-side provisional segmentation**, not canonical tutoring "steps".
- Coordinate normalization to `[0,1]` is not done on iOS yet.
- Symbol-level math boxes (`+`, `=` etc.) are not extracted yet, but raw JIIX may contain enough data to support that later.

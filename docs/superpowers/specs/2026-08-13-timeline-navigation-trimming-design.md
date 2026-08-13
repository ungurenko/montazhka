# Timeline navigation and trimming design

## Result

The timeline keeps the current Montazhka visual style while gaining Final Cut-like navigation: a Hand tool, temporary `H` mode, pointer-anchored zoom, native trackpad scrolling, optional playback following, and direct shortening of clip edges.

## Navigation

- A latched Hand toolbar button and temporary `H` key let the user drag the viewport from any point. Hand mode suppresses seeking, selection, reordering, and trimming.
- Native `NSScrollView` scrolling remains responsible for trackpad and Magic Mouse behavior. A small AppKit bridge exposes the current offset and controlled scrolling.
- Zoom stays within 3...240 pixels per second. Magnification and `Command` plus/minus retain the time under the pointer; when there is no pointer anchor, the playhead is the anchor. `Shift-Z` fits the full timeline.
- Playback following is opt-in. Once the playhead reaches the viewport midpoint, the viewport advances to keep it centered. Any manual pan or wheel scroll turns following off.

## Trimming

- Hovered and selected clips show narrow left and right handles. Handle drags visually preview the result without rebuilding AVFoundation on every pointer update.
- This version only shortens clips. The operation preserves clip identity and source, enforces a 0.1-second minimum, and keeps the timeline magnetic.
- The edge snaps to the playhead within 6 points; holding `Option` disables snapping. `Escape` cancels the preview.
- Mouse-up commits one undoable project edit, clears stale range selection, keeps the clip selected, seeks to the edited boundary, and rebuilds preview once.

## Boundaries

Project persistence, export, audio processing, smart editing, transitions, gaps, multiple tracks, speed changes, and re-extending hidden source media are unchanged.

## Verification

Pure tests cover viewport math and clip shortening. Controller tests cover commit and undo. The installed macOS app is checked for mouse/trackpad navigation, shortcuts, following, trimming, cancellation, undo, reordering, splitting, saving, and reopening.

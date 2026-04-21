# TODO

Prioritized follow-ups from project review.

## High Impact

- [x] Honor `LivelyInfo.FileName` when resolving wallpaper entry resources for web, video, and image bundles. Many Lively wallpapers do not use `index.html` or rely on a specific media file.
- [x] Make import classifications enforceable. `allowedWithLimits(fps:networkBudget:warnings:)` is currently surfaced to users, but runtime enforcement is incomplete.
- [x] Fix property editor routing so edits apply only to displays running the selected wallpaper, or expose an explicit target display/all-displays choice.
- [x] Wire Performance preferences into persisted settings and runtime behavior instead of showing static controls.

## Hardening

- [x] Strengthen monitor identity persistence beyond raw `CGDirectDisplayID`, using display metadata where available and falling back gracefully.
- [x] Add runtime network policy for web wallpapers: block external navigation by default and enforce any configured allowlist or request budget.
- [x] Support `.zip` and `.lively` package imports by extracting to a temporary directory, validating, then copying into Application Support.

## Testing

- Add focused tests for Lively parsers, resource resolution, import validation, property persistence, and property editor routing.
- Add regression fixtures for bundled sample wallpapers and representative third-party Lively bundles.

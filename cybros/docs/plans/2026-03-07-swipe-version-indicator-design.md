# Swipe Version Indicator Design

## Goal

Make assistant swipe controls show the current version position as `x / y`, and disable the left/right arrows when there is no selectable version in that direction.

## Design

- Extend the server-side `swipe` action policy to include version metadata:
  - `current`
  - `total`
  - `left_available`
  - `right_available`
- Keep the policy as the single source of truth so the UI does not need to recompute version positions from DOM state.
- Render the swipe control as a DaisyUI `join` group:
  - left arrow button
  - centered counter chip (`x / y`)
  - right arrow button
- Show the swipe control whenever swipe is available on the current tail assistant, including the `1 / 1` case.
- Disable each arrow independently based on the directional availability flags.
- Align keyboard arrow hotkeys with the same directional availability so they do not send no-op swipe requests.

## Testing

- Add model tests for swipe action policy metadata on single-version and multi-version tails.
- Add integration tests for server-rendered swipe count and disabled arrow states.

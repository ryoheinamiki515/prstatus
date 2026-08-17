# PRStatus

A menu bar circle that tracks pull requests waiting on your review.

- `○` hollow — nothing waiting
- `● 3` green — waiting, none over an hour
- `● 3` yellow — something has waited over an hour
- `● 3` red — something has waited over three hours

The colour follows the worst item. Click the circle for the list; click a row to open
that PR. "Open at Login" is in the footer, off until you turn it on.

## Build and install

```sh
./build.sh          # tests, release build, bundle, ad-hoc sign, install to ~/Applications
open ~/Applications/PRStatus.app
```

There is no Xcode on this machine, so the `.app` is assembled by hand from a SwiftPM
build rather than by `xcodebuild`. Requires only the Command Line Tools.

## Tests

```sh
swift build --product SelfTest && ./.build/debug/SelfTest
```

`swift test` cannot run here: the Command Line Tools ship neither XCTest nor
swift-testing. `SelfTest` is a plain executable that asserts and exits non-zero, covering
`PRStatusCore` — the urgency thresholds, the `waitingSince` cascade, response decoding,
and error presentation. The AppKit/SwiftUI layer is checked with the render probe below.

## Auth

The app shells out to `gh auth token`, so it inherits whatever account `gh` is signed in
as and stores no credential of its own. `gh` is looked up at absolute paths first because
an app launched from Finder does not get Homebrew on its `PATH`.

## Environment switches

Used for verification; the app ignores them unless set.

| Variable | Effect |
| --- | --- |
| `PRSTATUS_THRESHOLDS=10,20` | Ages in seconds instead of 1h/3h, so the colour walk is watchable. |
| `PRSTATUS_FIXTURE=<path>` | Loads rows from a captured response instead of the network, with every item's clock starting at launch. |
| `PRSTATUS_TRACE=1` | Prints each icon state change to stdout. |
| `PRSTATUS_RENDER=<dir>` | Writes a PNG of every popover state in light and dark, then exits. Needs no Screen Recording permission. |
| `PRSTATUS_LOGIN_PROBE=1` | Reports whether launch-at-login registers via SMAppService or the LaunchAgent fallback, then restores the original setting. |

Watch the full colour progression in about half a minute:

```sh
PRSTATUS_FIXTURE=Fixtures/response.json PRSTATUS_THRESHOLDS=10,20 PRSTATUS_TRACE=1 \
  ./.build/debug/PRStatus
```

## Fixtures

`Fixtures/response.json` is a real GraphQL response with titles, logins and repository
names replaced. The structure is untouched, including the case that matters most: a
review request routed through a team carries the team's `name` and no `login`, which is
why `resolveWaitingSince` needs its second branch.

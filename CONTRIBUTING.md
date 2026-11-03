# Contributing to Dabble

Thanks for helping out! Dabble is a small project, so a few guidelines keep things smooth.

## Before you start

- **Bugs:** open an issue with steps to reproduce, what you expected, and your macOS / iOS version.
- **Features:** open an issue to talk it through before writing a lot of code. Dabble aims to follow the spirit of Things: calm, focused, and fast. Not every feature fits.
- **Security problems:** please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Development setup

You need macOS 15+ and Xcode 26+.

```sh
git clone https://github.com/nearbycoder/dabble.git
cd dabble
open Dabble.xcodeproj
```

- The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you add, remove or move files, or change build settings, edit `project.yml` and run `xcodegen generate`, then commit both. CI warns when they drift apart.
- App code lives in `Apps/` (`macOS`, `iOS`, `Shared`). Everything that isn't UI (the data model, store, URL scheme, reminders and sync) lives in the `DabbleKit` package in `Packages/DabbleKit`.
- Run the tests before sending a PR:

  ```sh
  cd Packages/DabbleKit && swift test
  ```

## Pull requests

- Keep each PR focused on one change, and describe what it does and how you tested it. Screenshots help for UI changes, ideally on both Mac and iPhone and in light and dark mode.
- Add tests for changes to `DabbleKit`, especially anything touching merging or sync.
- **Sync compatibility matters.** Devices running different versions of Dabble sync with each other. Don't change the meaning of existing record fields or sync messages. Add new fields instead, and make sure older versions ignore what they don't understand.
- Match the surrounding code style. Prefer clear names and small types over comments that explain clever code.
- Keep the website (`docs/`) free of build steps, trackers and external scripts.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

If you change `agent/skills/dabble/SKILL.md`, run `scripts/embed-skill.sh` so the copy built into the `dabble` CLI matches (a test checks this). Check the plugin with `claude plugin validate ./agent` and `claude plugin validate .`.

# pin-dotnet-sdk

Installs a stable .NET 10 SDK and pins the exact installed version in the
checkout's root `global.json`. The action creates the file if missing or
replaces only its `sdk` section, preserving other settings such as
`msbuild-sdks` and `test`. It disables SDK roll-forward and does not change
project target frameworks or nested `global.json` files.

The action logs whether it created, updated, or left `global.json` unchanged
and shows the resulting `sdk` section without logging unrelated settings.

Run this action after checkout, before invoking `dotnet` from the workspace
root. Each job that needs the pin must call the action independently.
The action has no inputs, outputs, or secrets. It requires no additional
permissions beyond `contents: read` for checkout.

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: SkylineCommunications/_ReusableWorkflows/.github/actions/pin-dotnet-sdk@main
  - run: dotnet build
  - run: dotnet test --no-build
```

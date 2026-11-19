# pin-dotnet-sdk

Installs the version specified by `sdk.version` in the checkout's root
`global.json` and leaves that file unchanged, including its SDK resolution
settings. If no version is specified, the action installs a stable .NET 10
SDK and pins the exact installed version with roll-forward disabled, while
preserving other top-level settings such as `msbuild-sdks` and `test`.
The action does not change project target frameworks or nested `global.json` files.

The action logs the requested version when leaving `global.json` unchanged,
or shows the resulting `sdk` section when creating or updating the file.

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

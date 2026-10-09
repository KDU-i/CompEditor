# VS Code completion styling adaptation

Pinned official Code OSS source: Microsoft `microsoft/vscode` commit
[`651237c307271b300329a7039913da7e5676afa5`](https://github.com/microsoft/vscode/tree/651237c307271b300329a7039913da7e5676afa5).
The checked files carry Microsoft's MIT header; the exact repository license is preserved in `VSCode-MIT-LICENSE.txt` and packaged at `Contents/Resources/ThirdPartyNotices/VSCode-MIT-LICENSE.txt`.

`SemanticSuggestStyle.swift` adapts the 430 px default widget width and default theme-token relationships/colors from:

- `src/vs/editor/contrib/suggest/browser/suggestWidget.ts`
- `src/vs/editor/contrib/suggest/browser/media/suggest.css`
- `src/vs/platform/theme/common/colors/editorColors.ts`
- `src/vs/platform/theme/common/colors/listColors.ts`
- `src/vs/platform/theme/common/colors/quickpickColors.ts`

The AppKit widget implements the compact row layout, one-pixel border, minimal corners, aligned icon/name/signature, rectangular selection and bounded documentation footer. These native view implementations are original; the adapted constants file retains MIT copyright attribution. The 22 pt row height is our native compact default. SF Symbols are used rather than copied VS Code artwork.

Ranking, adaptive delay, cancellation and gray ghost drawing are original Swift implementations using LSP `filterText`, `sortText` and `preselect`. They are not ports of VS Code's full fuzzy scorer or Monaco/Electron runtime. No Pylance, proprietary Marketplace extension, Microsoft branding asset or Electron runtime is included. The actual services remain the approved Pyright and Eclipse JDT LS distributions.

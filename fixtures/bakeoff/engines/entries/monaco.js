// Monaco's editor core with the editing features a prose field uses, and no language services:
// prose is plain text. No workers: Monaco falls back to running them in the page.
import "monaco-editor/features/clipboard/register.js";
import "monaco-editor/features/dropOrPasteInto/register.js";
import "monaco-editor/features/contextmenu/register.js";
import "monaco-editor/features/cursorUndo/register.js";
import "monaco-editor/features/codicon/register.js";
export * from "monaco-editor/editor.js";

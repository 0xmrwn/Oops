// Lexical, vanilla (no React): core, rich text, history and the helpers its playground nodes use.
export * from "lexical";
export { registerRichText, HeadingNode, QuoteNode } from "@lexical/rich-text";
export { registerHistory, createEmptyHistoryState } from "@lexical/history";
export { mergeRegister } from "@lexical/utils";

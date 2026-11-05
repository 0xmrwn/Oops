// Draft.js 0.11 needs React 17 (it calls findDOMNode, which React 19 removed).
export { default as React } from "react";
export { default as ReactDOM } from "react-dom";
export * as Draft from "draft-js";
export { default as Immutable } from "immutable";

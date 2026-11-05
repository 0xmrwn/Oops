// The bake-off's Electron shell: one BrowserWindow on the bake-off page, as Electron apps (Slack,
// Discord, Notion, Linear, Obsidian, VS Code) host their editors. The window takes the page's title.
// Usage: Electron <this folder> <page url>
const { app, BrowserWindow } = require('electron');

const url = process.argv.find(arg => arg.startsWith('http'));
app.whenReady().then(() => {
  const window = new BrowserWindow({ x: 185, y: 95, width: 1100, height: 760, show: true });
  window.loadURL(url);
});
app.on('window-all-closed', () => app.quit());

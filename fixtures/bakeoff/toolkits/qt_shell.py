"""The bake-off's Qt shell (Telegram Desktop, OBS, VirtualBox, Anki): QTextEdit and a password
QLineEdit, bridged to Accessibility by Qt's own macOS layer. Usage: qt_shell.py <server url>. Like the
other shells it polls <server>/control for host "qt" and posts the editor's own text to <server>/state.
Runs inside a small .app (run.py builds it) so the process has a bundle, as real Qt apps do."""

import json
import sys
import urllib.request

from PySide6.QtCore import QCoreApplication, QEvent, Qt, QTimer
from PySide6.QtGui import QFont, QInputMethodEvent, QTextCursor
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QScrollArea,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

SERVER = sys.argv[1].rstrip("/")
LINES = ["Sam: Morning! Did the deploy go out last night?", "Priya: It did, but the login page looked off."]
RTL_LINES = ["سارة: صباح الخير! هل تم النشر الليلة الماضية؟", "كريم: نعم، لكن صفحة الدخول بدت غريبة."]


class Editor(QTextEdit):
    """A QTextEdit whose app takes pastes over when `intercept` is on: plain text, inserted a moment later."""

    intercept = False

    def insertFromMimeData(self, source):
        if not self.intercept:
            return super().insertFromMimeData(source)
        text = source.text()
        QTimer.singleShot(80, lambda: self.textCursor().insertText(text))


class Shell(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setGeometry(185, 95, 1100, 760)
        self.setWindowTitle("oops native lab · bakeoff")
        self.nonce, self.editor, self.ready, self.error, self.reported = None, None, False, None, ""
        self.dialog = self.menu = None
        self.busy = False
        timer = QTimer(self)
        timer.timeout.connect(self.poll)
        timer.start(120)

    def poll(self):
        try:
            control = json.loads(urllib.request.urlopen(SERVER + "/control", timeout=1).read())
            if control.get("host") == "qt" and control.get("nonce") != self.nonce:
                self.nonce = control["nonce"]
                self.show_case(control["case"])
        except Exception as error:  # a fixture problem is reported, not raised
            self.error = self.error or str(error)
        self.report()

    def text(self):
        if isinstance(self.editor, QLineEdit):
            return self.editor.text()
        return self.editor.toPlainText() if self.editor else None

    def report(self):
        composing = bool(
            self.editor
            and isinstance(self.editor, QTextEdit)
            and self.editor.textCursor().block().layout().preeditAreaText()
        )
        state = {"host": "qt", "nonce": self.nonce, "ready": self.ready, "error": self.error, "composing": composing}
        if self.editor:
            state.update(text=self.text(), counts={"chips": 0, "images": 0})
        body = json.dumps(state, sort_keys=True, ensure_ascii=False)
        if body == self.reported:
            return
        self.reported = body
        try:
            urllib.request.urlopen(
                urllib.request.Request(SERVER + "/state", data=body.encode(), method="POST"), timeout=1
            )
        except OSError:
            self.reported = ""

    def show_case(self, case):
        self.ready, self.error = False, None
        for window in (self.dialog, self.menu):
            if window:
                window.close()
        self.dialog = self.menu = None
        rtl = case.get("presentation") == "rtl"
        size = 30 if case.get("presentation") == "zoom" else 15
        paragraphs = [
            "".join("@" + s["mention"] if "mention" in s else s.get("emoji") or s.get("text", "") for s in p)
            for p in case["draft"]["paragraphs"]
        ]
        if case["toolkit"] == "qt-secure":
            self.editor = QLineEdit("\n".join(paragraphs))
            self.editor.setEchoMode(QLineEdit.Password)
        else:
            self.editor = Editor()
            self.editor.setPlainText("\n".join(paragraphs))
            self.editor.intercept = case.get("reaction") == "paste-intercept"
            self.editor.textChanged.connect(lambda: self.changed(case))
        self.editor.setFont(QFont("Helvetica", size))
        self.editor.setAccessibleName("Message")
        if rtl:
            self.editor.setLayoutDirection(Qt.RightToLeft)
        self.setWindowTitle(f"oops native lab · bakeoff · {case['id']}")
        self.build(case["layout"], rtl, case["id"])
        QTimer.singleShot(300, lambda: self.focus(case))

    def build(self, layout, rtl, case_id):
        def label(text):
            return QLabel(text, wordWrap=True)

        box = QFrame(frameShape=QFrame.StyledPanel)
        QVBoxLayout(box).addWidget(self.editor)
        box.setFixedHeight(160 if layout == "modal" else 90)

        def column(title, editor):
            lines = RTL_LINES if rtl else LINES
            return [label(f"<b>{title}</b>")] + [label(t) for t in lines] + ([box] if editor else [])

        root = QWidget()
        if layout in ("thread", "side-panel"):
            row = QHBoxLayout(root)
            for widgets, width in (
                (column("# release" if layout == "thread" else "Quarterly planning", False), None),
                (column("Thread" if layout == "thread" else "Assistant", True), 360),
            ):
                pane = QWidget()
                stack = QVBoxLayout(pane)
                stack.addStretch()
                for widget in widgets:
                    stack.addWidget(widget)
                if width:
                    pane.setFixedWidth(width)
                row.addWidget(pane)
        elif layout == "document":
            stack = QVBoxLayout(root)
            stack.addWidget(label("<b>Weekly update</b>"))
            stack.addWidget(self.editor)
        elif layout == "nested-scroll":

            def fill(n):
                return [label(f"Earlier note {i + 1}: the build moved to the new runners.") for i in range(n)]

            inner_widget, outer_widget = QWidget(), QWidget()
            inner_stack, outer_stack = QVBoxLayout(inner_widget), QVBoxLayout(outer_widget)
            inner, outer = QScrollArea(widgetResizable=True), QScrollArea(widgetResizable=True)
            for widget in fill(8) + [box] + fill(4):
                inner_stack.addWidget(widget)
            inner.setWidget(inner_widget)
            inner.setFixedHeight(300)
            for widget in fill(10) + [inner] + fill(10):
                outer_stack.addWidget(widget)
            outer.setWidget(outer_widget)
            QVBoxLayout(root).addWidget(outer)
            QTimer.singleShot(100, lambda: (inner.ensureWidgetVisible(box), outer.ensureWidgetVisible(inner)))
        elif layout == "modal":
            QVBoxLayout(root).addWidget(label("<b>Feed</b>"))
            self.dialog = QDialog(self)
            self.dialog.setWindowTitle(f"oops native lab · bakeoff · {case_id} · New post")
            stack = QVBoxLayout(self.dialog)
            stack.addWidget(label("<b>New post</b>"))
            stack.addWidget(box)
            self.dialog.resize(560, 240)
            self.dialog.show()
        else:
            stack = QVBoxLayout(root)
            stack.addStretch()
            for widget in column("# release", True):
                stack.addWidget(widget)
        self.setCentralWidget(root)

    def focus(self, case):
        (self.dialog or self).activateWindow()
        self.editor.setFocus()
        start, end = case.get("selection") or [case.get("caret", 0)] * 2
        if isinstance(self.editor, QLineEdit):
            self.editor.setSelection(start, end - start)
        else:
            cursor = self.editor.textCursor()
            cursor.setPosition(start)
            cursor.setPosition(end, QTextCursor.KeepAnchor)
            self.editor.setTextCursor(cursor)
        if case.get("reaction") == "slash-menu":
            self.open_menu()
        if case.get("reaction") == "ime":
            QCoreApplication.sendEvent(self.editor, QInputMethodEvent("にほんご", []))
        self.ready = True

    def changed(self, case):
        if self.menu and not self.text().endswith("/"):
            self.menu.close()
            self.menu = None
        if case.get("reaction") != "rerender" or self.busy:
            return
        self.busy = True

        def rerender():
            cursor = self.editor.textCursor()
            anchor, position = cursor.anchor(), cursor.position()
            self.editor.setPlainText(self.editor.toPlainText())
            cursor = self.editor.textCursor()
            cursor.setPosition(anchor)
            cursor.setPosition(position, QTextCursor.KeepAnchor)
            self.editor.setTextCursor(cursor)
            QTimer.singleShot(0, lambda: setattr(self, "busy", False))

        QTimer.singleShot(60, rerender)

    def open_menu(self):
        self.menu = QListWidget()
        self.menu.addItems(["Summarize", "Insert table", "Mention someone", "Add emoji"])
        self.menu.setWindowFlags(Qt.ToolTip | Qt.FramelessWindowHint)
        self.menu.setAttribute(Qt.WA_ShowWithoutActivating)
        rect = self.editor.cursorRect()
        self.menu.move(self.editor.mapToGlobal(rect.topLeft()).x(), self.editor.mapToGlobal(rect.topLeft()).y() - 120)
        self.menu.resize(200, 110)
        self.menu.show()

    def event(self, event):
        if event.type() == QEvent.WindowActivate and self.editor and not self.dialog:
            self.editor.setFocus()
        return super().event(event)


app = QApplication(sys.argv)
shell = Shell()
shell.show()
app.exec()

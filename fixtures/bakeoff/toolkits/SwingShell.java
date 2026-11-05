import java.awt.*;
import java.awt.datatransfer.DataFlavor;
import java.net.URI;
import java.net.http.*;
import java.util.*;
import java.util.regex.*;
import javax.swing.*;
import javax.swing.event.*;
import javax.swing.text.*;

/**
 * The bake-off's Swing shell (JetBrains IDEs' commit and comment fields, many Java desktop tools):
 * JTextArea and JPasswordField, bridged to Accessibility by the JDK's macOS layer. Usage:
 * java SwingShell.java <server url>. Like the other shells it polls <server>/control for host "swing"
 * and posts the editor's own text to <server>/state. Runs inside a small .app (run.py builds it).
 */
public class SwingShell {
    static final HttpClient HTTP = HttpClient.newHttpClient();
    static String server, nonce, error, reported = "";
    static boolean ready, busy;
    static JFrame frame;
    static JDialog dialog;
    static JWindow menu;
    static JTextComponent editor;

    public static void main(String[] args) {
        server = args[0].replaceAll("/$", "");
        SwingUtilities.invokeLater(() -> {
            frame = new JFrame("oops native lab · bakeoff");
            frame.setBounds(185, 95, 1100, 760);
            frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
            frame.setVisible(true);
            new javax.swing.Timer(120, e -> poll()).start();
        });
    }

    static String get(String path) throws Exception {
        return HTTP.send(HttpRequest.newBuilder(URI.create(server + path)).build(), HttpResponse.BodyHandlers.ofString()).body();
    }

    /** The few JSON fields a case needs, read with patterns: the JDK has no JSON parser. */
    static String field(String json, String name) {
        Matcher m = Pattern.compile("\"" + name + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").matcher(json);
        // The last match: a case's own fields come after its draft's segments, which reuse "text".
        String raw = null;
        while (m.find()) raw = m.group(1);
        if (raw == null) return null;
        Matcher escape = Pattern.compile("\\\\(u[0-9a-fA-F]{4}|.)").matcher(raw);
        StringBuilder out = new StringBuilder();
        while (escape.find()) {
            String e = escape.group(1);
            String c = e.startsWith("u") && e.length() == 5 ? String.valueOf((char) Integer.parseInt(e.substring(1), 16)) : e.equals("n") ? "\n" : e.equals("t") ? "\t" : e;
            escape.appendReplacement(out, Matcher.quoteReplacement(c));
        }
        escape.appendTail(out);
        return out.toString();
    }

    static int[] range(String json) {
        Matcher m = Pattern.compile("\"selection\"\\s*:\\s*\\[(\\d+),\\s*(\\d+)\\]").matcher(json);
        if (m.find()) return new int[] {Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2))};
        m = Pattern.compile("\"caret\"\\s*:\\s*(\\d+)").matcher(json);
        int caret = m.find() ? Integer.parseInt(m.group(1)) : 0;
        return new int[] {caret, caret};
    }

    static void poll() {
        try {
            String control = get("/control");
            String host = field(control, "host"), next = field(control, "nonce");
            if ("swing".equals(host) && next != null && !next.equals(nonce)) {
                nonce = next;
                show(control);
            }
        } catch (Exception e) {
            if (error == null) error = e.toString();
        }
        report();
    }

    static String escape(String s) {
        StringBuilder out = new StringBuilder();
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
            else out.append(c);
        }
        return out.toString();
    }

    static void report() {
        String text = editor == null ? null : editor.getText();
        String body = "{\"host\":\"swing\",\"nonce\":" + (nonce == null ? "null" : "\"" + nonce + "\"") + ",\"ready\":" + ready
            + ",\"error\":" + (error == null ? "null" : "\"" + escape(error) + "\"") + ",\"composing\":false"
            + (text == null ? "" : ",\"text\":\"" + escape(text) + "\",\"counts\":{\"chips\":0,\"images\":0}") + "}";
        if (body.equals(reported)) return;
        reported = body;
        HTTP.sendAsync(HttpRequest.newBuilder(URI.create(server + "/state")).POST(HttpRequest.BodyPublishers.ofString(body)).build(),
            HttpResponse.BodyHandlers.discarding());
    }

    static void show(String control) {
        ready = false; error = null;
        if (dialog != null) dialog.dispose();
        if (menu != null) menu.dispose();
        dialog = null; menu = null;
        String id = field(control, "id"), toolkit = field(control, "toolkit"), layout = field(control, "layout");
        String reaction = field(control, "reaction"), presentation = field(control, "presentation");
        boolean rtl = "rtl".equals(presentation);
        if ("swing-secure".equals(toolkit)) editor = new JPasswordField(field(control, "text"));
        else {
            JTextArea area = new JTextArea(field(control, "text"));
            area.setLineWrap(true); area.setWrapStyleWord(true);
            editor = area;
        }
        editor.setFont(new Font("Helvetica", Font.PLAIN, "zoom".equals(presentation) ? 30 : 15));
        editor.getAccessibleContext().setAccessibleName("Message");
        if (rtl) editor.setComponentOrientation(ComponentOrientation.RIGHT_TO_LEFT);
        if ("paste-intercept".equals(reaction)) interceptPaste();
        if ("rerender".equals(reaction)) rerender();
        frame.setTitle("oops native lab · bakeoff · " + id);
        SwingLayouts.build(frame, layout, editor, rtl, id);
        dialog = SwingLayouts.dialog;
        int[] selection = range(control);
        new javax.swing.Timer(300, e -> {
            ((javax.swing.Timer) e.getSource()).stop();
            (dialog != null ? dialog : frame).toFront();
            editor.requestFocusInWindow();
            editor.select(selection[0], selection[1]);
            if ("slash-menu".equals(reaction)) openMenu();
            ready = true;
        }).start();
    }

    /** The app takes the paste over: plain text, inserted a moment later. */
    static void interceptPaste() {
        TransferHandler original = editor.getTransferHandler();
        editor.setTransferHandler(new TransferHandler() {
            @Override public boolean importData(TransferSupport support) {
                try {
                    String text = (String) support.getTransferable().getTransferData(DataFlavor.stringFlavor);
                    javax.swing.Timer later = new javax.swing.Timer(80, e -> editor.replaceSelection(text));
                    later.setRepeats(false); later.start();
                    return true;
                } catch (Exception e) { return false; }
            }
            @Override public boolean canImport(TransferSupport support) { return support.isDataFlavorSupported(DataFlavor.stringFlavor); }
            @Override public void exportToClipboard(JComponent c, java.awt.datatransfer.Clipboard clip, int action) { original.exportToClipboard(c, clip, action); }
            @Override public int getSourceActions(JComponent c) { return original.getSourceActions(c); }
        });
    }

    /** The text set again from the app's state after each edit, the caret put back. */
    static void rerender() {
        editor.getDocument().addDocumentListener(new DocumentListener() {
            void changed() {
                if (busy) return;
                javax.swing.Timer later = new javax.swing.Timer(60, e -> {
                    busy = true;
                    int start = editor.getSelectionStart(), end = editor.getSelectionEnd();
                    editor.setText(editor.getText());
                    editor.select(start, end);
                    SwingUtilities.invokeLater(() -> busy = false);
                });
                later.setRepeats(false); later.start();
            }
            public void insertUpdate(DocumentEvent e) { changed(); }
            public void removeUpdate(DocumentEvent e) { changed(); }
            public void changedUpdate(DocumentEvent e) {}
        });
    }

    static void openMenu() {
        menu = new JWindow(dialog != null ? dialog : frame);
        menu.setFocusableWindowState(false);
        menu.add(new JList<>(new String[] {"Summarize", "Insert table", "Mention someone", "Add emoji"}));
        try {
            Rectangle caret = editor.modelToView2D(editor.getCaretPosition()).getBounds();
            Point at = editor.getLocationOnScreen();
            menu.setBounds(at.x + caret.x, at.y + caret.y - 110, 200, 100);
        } catch (Exception e) { menu.setBounds(300, 300, 200, 100); }
        menu.setVisible(true);
        editor.addCaretListener(e -> { if (menu != null) { menu.dispose(); menu = null; } });
    }
}

class SwingLayouts {
    static JDialog dialog;

    static JComponent column(String title, JComponent composer, boolean rtl) {
        JPanel panel = new JPanel(new BorderLayout());
        Box lines = Box.createVerticalBox();
        lines.add(new JLabel("<html><b>" + title + "</b></html>"));
        lines.add(Box.createVerticalGlue());
        for (String line : rtl ? new String[] {"سارة: صباح الخير!", "كريم: نعم، لكن صفحة الدخول بدت غريبة."}
                : new String[] {"Sam: Morning! Did the deploy go out?", "Priya: It did, but the login page looked off."}) lines.add(new JLabel(line));
        panel.add(lines, BorderLayout.CENTER);
        if (composer != null) panel.add(composer, BorderLayout.SOUTH);
        panel.setBorder(BorderFactory.createEmptyBorder(12, 14, 12, 14));
        return panel;
    }

    static JComponent composer(JTextComponent editor, int height) {
        JScrollPane scroll = new JScrollPane(editor);
        scroll.setPreferredSize(new Dimension(300, height));
        return scroll;
    }

    static void build(JFrame frame, String layout, JTextComponent editor, boolean rtl, String id) {
        dialog = null;
        JComponent root;
        switch (layout) {
            case "thread", "side-panel" -> {
                JComponent side = column("thread".equals(layout) ? "Thread" : "Assistant", composer(editor, 90), rtl);
                side.setPreferredSize(new Dimension("thread".equals(layout) ? 360 : 320, 700));
                root = new JPanel(new BorderLayout());
                root.add(column("thread".equals(layout) ? "# release" : "Quarterly planning", null, rtl), BorderLayout.CENTER);
                root.add(side, BorderLayout.EAST);
            }
            case "modal" -> {
                root = column("Feed", null, rtl);
                dialog = new JDialog(frame, "oops native lab · bakeoff · " + id + " · New post", false);
                dialog.add(column("New post", composer(editor, 160), rtl));
                dialog.setBounds(370, 260, 560, 260);
                dialog.setVisible(true);
            }
            case "nested-scroll" -> {
                Box inner = Box.createVerticalBox(), outer = Box.createVerticalBox();
                for (int i = 0; i < 8; i++) inner.add(new JLabel("Earlier note " + (i + 1) + ": the build moved to the new runners."));
                JComponent box = composer(editor, 70);
                inner.add(box);
                for (int i = 0; i < 4; i++) inner.add(new JLabel("Later note " + (i + 1)));
                JScrollPane innerScroll = new JScrollPane(inner);
                innerScroll.setPreferredSize(new Dimension(900, 300));
                innerScroll.setMaximumSize(new Dimension(2000, 300));
                for (int i = 0; i < 10; i++) outer.add(new JLabel("Activity " + (i + 1)));
                outer.add(innerScroll);
                for (int i = 0; i < 10; i++) outer.add(new JLabel("Older activity " + (i + 1)));
                root = new JScrollPane(outer);
                SwingUtilities.invokeLater(() -> { box.scrollRectToVisible(box.getBounds()); innerScroll.scrollRectToVisible(innerScroll.getBounds()); });
            }
            case "document" -> {
                root = new JPanel(new BorderLayout());
                root.add(new JLabel("<html><b>Weekly update</b></html>"), BorderLayout.NORTH);
                root.add(new JScrollPane(editor), BorderLayout.CENTER);
            }
            default -> root = column("# release", composer(editor, 90), rtl);
        }
        frame.setContentPane(root);
        frame.revalidate();
        frame.repaint();
    }
}

import UIKit

/// Where the editor sits: a bottom composer, a thread pane, a side panel, a sheet, nested scroll
/// views, or the whole window.
enum CatalystLayouts {
    static func label(_ text: String, bold: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text; label.numberOfLines = 0
        if bold { label.font = .boldSystemFont(ofSize: 15) }
        return label
    }

    static func composer(_ editor: UIView, height: CGFloat) -> UIView {
        let box = UIView()
        box.layer.borderColor = UIColor.separator.cgColor; box.layer.borderWidth = 1; box.layer.cornerRadius = 10
        editor.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), editor.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            editor.topAnchor.constraint(equalTo: box.topAnchor, constant: 4), editor.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            box.heightAnchor.constraint(equalToConstant: height),
        ])
        return box
    }

    static func column(_ title: String, _ views: [UIView]) -> UIStackView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [label(title, bold: true), spacer] + views)
        stack.axis = .vertical; stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true; stack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return stack
    }

    static func pin(_ view: UIView, in root: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    static func build(_ spec: CatalystCase, editor: UIView, in controller: UIViewController) {
        let root = controller.view!
        root.subviews.forEach { $0.removeFromSuperview() }
        root.accessibilityHint = spec.reaction
        root.semanticContentAttribute = spec.rtl ? .forceRightToLeft : .unspecified
        let messages = { (spec.rtl ? ["سارة: صباح الخير!", "كريم: نعم، لكن صفحة الدخول بدت غريبة."]
                : ["Sam: Morning! Did the deploy go out?", "Priya: It did, but the login page looked off."]).map { label($0) } }
        switch spec.layout {
        case "thread", "side-panel":
            let main = spec.layout == "thread" ? column("# release", messages())
                : column("Quarterly planning", (0..<5).map { _ in label("The roadmap for the next two sprints is final.") })
            let side = column(spec.layout == "thread" ? "Thread" : "Assistant", messages() + [composer(editor, height: 90)])
            side.widthAnchor.constraint(equalToConstant: spec.layout == "thread" ? 360 : 320).isActive = true
            let split = UIStackView(arrangedSubviews: [main, side])
            pin(split, in: root)
        case "modal":
            pin(column("Feed", [label("Recent posts from your team.")]), in: root)
            let sheet = UIViewController()
            sheet.view.backgroundColor = .systemBackground
            sheet.modalPresentationStyle = .formSheet
            pin(column("New post", [composer(editor, height: 160)]), in: sheet.view)
            controller.present(sheet, animated: false)
        case "nested-scroll":
            let filler = { (count: Int) in (0..<count).map { label("Earlier note \($0 + 1): the build moved to the new runners.") } }
            let inner = UIScrollView(), outer = UIScrollView()
            let innerStack = column("Reply", filler(8) + [composer(editor, height: 70)] + filler(4))
            let outerStack = column("Activity", filler(10) + [inner] + filler(10))
            for (scroll, stack) in [(inner, innerStack), (outer, outerStack)] {
                stack.translatesAutoresizingMaskIntoConstraints = false
                scroll.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                    stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                ])
            }
            inner.heightAnchor.constraint(equalToConstant: 300).isActive = true
            pin(outer, in: root)
            root.layoutIfNeeded()
            inner.contentOffset = CGPoint(x: 0, y: max(0, innerStack.arrangedSubviews[10].frame.minY - 60))
            outer.contentOffset = CGPoint(x: 0, y: max(0, inner.frame.minY - 120))
        case "document":
            pin(column("Weekly update", [editor]), in: root)
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        default:
            pin(column("# release", messages() + [composer(editor, height: 90)]), in: root)
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

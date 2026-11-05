import SwiftUI

// Hello's desktop: seven kinds of apps, each recognisable by its colours and layout alone. No names,
// no logos. Always light, like most people's apps, whatever the system appearance.

/// Hello's desktop is laid out at the camera's closest zoom, in the window's own points, and only ever
/// scaled down: the close-up is drawn 1:1. Scaled up, SwiftUI would magnify layers it already
/// rasterized; scaled by a fraction, every frame is resampled soft.
enum HelloZoom {
    static let factor: CGFloat = 1.85
    /// Window points per design point (the desktop is designed at 1200 × 750); set once, before Hello
    /// is built, by the window that shows it.
    nonisolated(unsafe) static var window: CGFloat = 0.9
    /// The stage, in window points.
    static var stage: CGSize { CGSize(width: HelloDraft.canvas.width * window, height: HelloDraft.canvas.height * window) }
}
/// A size in design points, in the zoomed layout's points.
func u(_ points: CGFloat) -> CGFloat { points * HelloZoom.factor * HelloZoom.window }

/// An app window on Hello's desktop.
struct HelloAppWindow<Content: View>: View {
    var background = Color.white
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: u(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: u(14), style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: u(0.5)))
            .shadow(color: .black.opacity(0.35), radius: u(26), y: u(18))
            .environment(\.colorScheme, .light)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: u(7)) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                Circle().fill($0).frame(width: u(11), height: u(11))
            }
        }
    }
}

extension View {
    /// The draft field reports where it is; HelloScene floats its drop above the trailing corner at
    /// native size, outside the scaled desktop, like the real drop's panel above a composer.
    func helloDrop(_ state: HelloWindowState) -> some View {
        anchorPreference(key: HelloFieldsKey.self, value: .bounds) { [state.id: $0] }
    }
}

struct HelloFieldsKey: PreferenceKey {
    static var defaultValue: [HelloDraft.App: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [HelloDraft.App: Anchor<CGRect>], nextValue: () -> [HelloDraft.App: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

func helloSymbol(_ name: String, _ size: CGFloat, _ color: Color = .secondary) -> some View {
    Image(systemName: name).font(.system(size: size, weight: .medium)).foregroundStyle(color)
}

// MARK: Chat, typed live

struct HelloChatApp: View {
    let state: HelloWindowState
    private let blue = Color(red: 0.04, green: 0.52, blue: 1)
    var body: some View {
        HelloAppWindow {
            HStack(spacing: u(0)) {
                VStack(alignment: .leading, spacing: u(2)) {
                    TrafficLights().padding(.init(top: u(12), leading: u(7), bottom: u(9), trailing: u(0)))
                    HStack(spacing: u(5)) { helloSymbol("magnifyingglass", u(10)); Text("Search").font(.system(size: u(10.5))).foregroundStyle(.secondary) }
                        .padding(.horizontal, u(7)).padding(.vertical, u(4)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: u(7)).fill(.black.opacity(0.07))).padding(.bottom, u(4))
                    conversation("L", "Léa", "where are you?? movie…", selected: true)
                    conversation("M", "Mom", "call me when you can")
                    conversation("T", "Tom", "haha yes")
                    conversation("5", "Climbing crew", "sunday 9am?")
                    Spacer()
                }
                .padding(.horizontal, u(6)).frame(width: u(142)).background(Color(white: 0.96))
                Divider()
                VStack(spacing: u(0)) {
                    VStack(spacing: u(2)) { avatar("L", warm: true); Text("Léa").font(.system(size: u(10.5))) }.padding(.vertical, u(7))
                    Divider()
                    VStack(spacing: u(4)) {
                        Spacer()
                        Text("Today 10:21").font(.system(size: u(9.5))).foregroundStyle(.secondary)
                        bubble("grabbing popcorn?", out: true).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Read 10:22").font(.system(size: u(9.5))).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                        bubble("where are you?? movie starts in 10", out: false).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, u(12)).padding(.vertical, u(8))
                    HStack(alignment: .bottom, spacing: u(7)) {
                        helloSymbol("plus", u(11)).frame(width: u(26), height: u(26)).background(Circle().fill(.black.opacity(0.08)))
                        HelloDraftText(state: state, size: u(13))
                            .padding(.horizontal, u(12)).padding(.vertical, u(6)).frame(minHeight: u(32))
                            .background(RoundedRectangle(cornerRadius: u(16)).strokeBorder(.black.opacity(0.2)))
                            .helloDrop(state)
                    }
                    .padding(.init(top: u(4), leading: u(10), bottom: u(12), trailing: u(10)))
                }
            }
        }
    }
    private func avatar(_ letter: String, warm: Bool = false) -> some View {
        Text(letter).font(.system(size: u(10), weight: .semibold)).foregroundStyle(.white).frame(width: u(26), height: u(26))
            .background(Circle().fill(LinearGradient(colors: warm ? [Color(red: 0.96, green: 0.64, blue: 0.42), Color(red: 0.88, green: 0.44, blue: 0.29)]
                                                     : [Color(white: 0.72), Color(white: 0.55)], startPoint: .top, endPoint: .bottom)))
    }
    private func conversation(_ letter: String, _ name: String, _ snippet: String, selected: Bool = false) -> some View {
        HStack(spacing: u(7)) {
            avatar(letter, warm: selected)
            VStack(alignment: .leading, spacing: u(1)) {
                Text(name).font(.system(size: u(11), weight: .semibold))
                Text(snippet).font(.system(size: u(10.5))).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(u(6)).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: u(8)).fill(selected ? blue : .clear))
    }
    private func bubble(_ text: String, out: Bool) -> some View {
        Text(text).font(.system(size: u(13))).foregroundStyle(out ? .white : .primary)
            .padding(.horizontal, u(11)).padding(.vertical, u(6))
            .background(RoundedRectangle(cornerRadius: u(16), style: .continuous).fill(out ? blue : Color(white: 0.91)))
            .frame(maxWidth: u(230), alignment: out ? .trailing : .leading)
    }
}

// MARK: Mail compose

struct HelloMailApp: View {
    let state: HelloWindowState
    var body: some View {
        HelloAppWindow {
            VStack(alignment: .leading, spacing: u(0)) {
                HStack {
                    Text("Nouveau message").font(.system(size: u(12.5), weight: .medium))
                    Spacer()
                    HStack(spacing: u(10)) { helloSymbol("minus", u(10)); helloSymbol("arrow.up.left.and.arrow.down.right", u(10)); helloSymbol("xmark", u(10)) }
                }
                .padding(.horizontal, u(12)).padding(.vertical, u(9)).background(Color(red: 0.95, green: 0.96, blue: 0.99))
                row {
                    Text("À").foregroundStyle(.secondary)
                    HStack(spacing: u(5)) {
                        Text("C").font(.system(size: u(8.5), weight: .semibold)).foregroundStyle(.white).frame(width: u(17), height: u(17))
                            .background(Circle().fill(Color(red: 0.49, green: 0.67, blue: 0.97)))
                        Text("Camille Martin")
                    }
                    .padding(.init(top: u(1), leading: u(2), bottom: u(1), trailing: u(8))).overlay(Capsule().strokeBorder(.black.opacity(0.2), lineWidth: u(0.5)))
                    Spacer()
                    Text("Cc Cci").foregroundStyle(.secondary)
                }
                row { Text("Devis, projet Atelier") }
                HelloDraftText(state: state, size: u(13)).padding(.horizontal, u(12)).padding(.top, u(9)).helloDrop(state)
                Spacer()
                HStack(spacing: u(11)) {
                    HStack(spacing: u(0)) {
                        Text("Envoyer").fixedSize().padding(.horizontal, u(14)).padding(.vertical, u(7))
                        Image(systemName: "chevron.down").font(.system(size: u(9), weight: .bold)).padding(.horizontal, u(8)).padding(.vertical, u(7))
                            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.35)).frame(width: u(0.5)) }
                    }
                    .font(.system(size: u(12.5), weight: .semibold)).foregroundStyle(.white)
                    .background(Capsule().fill(Color(red: 0.04, green: 0.34, blue: 0.82)))
                    Text("A").font(.system(size: u(13), weight: .semibold, design: .serif)).underline().foregroundStyle(.secondary)
                    ForEach(["paperclip", "link", "face.smiling", "photo", "lock", "pencil"], id: \.self) { helloSymbol($0, u(12)) }
                    Spacer()
                    helloSymbol("trash", u(12))
                }
                .padding(u(12))
            }
        }
    }
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: u(7), content: content).font(.system(size: u(12))).padding(.vertical, u(6))
            .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.1)).frame(height: u(0.5)) }
            .padding(.horizontal, u(12))
    }
}

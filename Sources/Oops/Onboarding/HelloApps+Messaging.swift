import SwiftUI

// MARK: Team channel: aubergine sidebar, threads, formatting toolbar

struct HelloTeamApp: View {
    let state: HelloWindowState
    var body: some View {
        HelloAppWindow {
            HStack(spacing: u(0)) {
                VStack(alignment: .leading, spacing: u(1)) {
                    TrafficLights().padding(.init(top: u(12), leading: u(6), bottom: u(8), trailing: u(0)))
                    Text("Atelier ⌄").font(.system(size: u(12), weight: .heavy)).foregroundStyle(.white).padding(.init(top: u(2), leading: u(6), bottom: u(8), trailing: u(0)))
                    item("Threads"); item("Activity")
                    section("Channels"); item("# general"); item("# release", selected: true); item("# design", unread: true)
                    section("Direct messages"); item("Nadia"); item("Sami")
                    Spacer()
                }
                .padding(.horizontal, u(6)).frame(width: u(104)).background(Color(red: 0.25, green: 0.05, blue: 0.25))
                VStack(alignment: .leading, spacing: u(0)) {
                    HStack {
                        Text("# release").font(.system(size: u(13), weight: .heavy))
                        Spacer()
                        HStack(spacing: u(-5)) {
                            ForEach([Color(red: 0.91, green: 0.57, blue: 0.18), Color(red: 0.17, green: 0.67, blue: 0.46), Color(red: 0.11, green: 0.61, blue: 0.82)], id: \.self) {
                                RoundedRectangle(cornerRadius: u(3)).fill($0).frame(width: u(13), height: u(13)).overlay(RoundedRectangle(cornerRadius: u(3)).strokeBorder(.white, lineWidth: u(1)))
                            }
                            Text("12").font(.system(size: u(10.5), weight: .medium)).foregroundStyle(.secondary).padding(.leading, u(9))
                        }
                        .padding(.horizontal, u(6)).padding(.vertical, u(2)).overlay(RoundedRectangle(cornerRadius: u(6)).strokeBorder(.black.opacity(0.15), lineWidth: u(0.5)))
                    }
                    .padding(.init(top: u(10), leading: u(12), bottom: u(8), trailing: u(12)))
                    Divider()
                    HStack(alignment: .top, spacing: u(8)) {
                        Text("N").font(.system(size: u(12), weight: .bold)).foregroundStyle(.white).frame(width: u(28), height: u(28))
                            .background(RoundedRectangle(cornerRadius: u(6)).fill(Color(red: 0.91, green: 0.57, blue: 0.18)))
                        VStack(alignment: .leading, spacing: u(2)) {
                            HStack(spacing: u(4)) { Text("Nadia").font(.system(size: u(12.5), weight: .heavy)); Text("10:08 AM").font(.system(size: u(10))).foregroundStyle(.secondary) }
                            Text("anyone free to review before the freeze?").font(.system(size: u(12.5)))
                            HStack(spacing: u(4)) {
                                RoundedRectangle(cornerRadius: u(4)).fill(Color(red: 0.17, green: 0.67, blue: 0.46)).frame(width: u(15), height: u(15))
                                RoundedRectangle(cornerRadius: u(4)).fill(Color(red: 0.11, green: 0.61, blue: 0.82)).frame(width: u(15), height: u(15))
                                Text("2 replies").font(.system(size: u(11), weight: .bold)).foregroundStyle(Color(red: 0.07, green: 0.39, blue: 0.64))
                            }
                            .padding(.top, u(2))
                        }
                    }
                    .padding(.horizontal, u(12)).padding(.vertical, u(9))
                    Spacer()
                    VStack(alignment: .leading, spacing: u(0)) {
                        HStack(spacing: u(9)) {
                            Text("B").bold(); Text("I").italic(); Text("S").strikethrough()
                            helloSymbol("link", u(10)); helloSymbol("list.bullet", u(10)); helloSymbol("chevron.left.forwardslash.chevron.right", u(10))
                        }
                        .font(.system(size: u(11))).foregroundStyle(.secondary).padding(.horizontal, u(9)).padding(.vertical, u(5))
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.97))
                        HelloDraftText(state: state, size: u(13)).padding(.horizontal, u(10)).padding(.vertical, u(6)).helloDrop(state)
                        HStack(spacing: u(9)) {
                            helloSymbol("plus", u(9)).frame(width: u(18), height: u(18)).background(Circle().fill(Color(white: 0.91)))
                            Text("Aa").font(.system(size: u(11))).foregroundStyle(.secondary)
                            helloSymbol("face.smiling", u(10)); helloSymbol("at", u(10))
                            Spacer()
                            Image(systemName: "paperplane.fill").font(.system(size: u(10))).foregroundStyle(.white).frame(width: u(26), height: u(22))
                                .background(RoundedRectangle(cornerRadius: u(4)).fill(Color(red: 0, green: 0.48, blue: 0.35)))
                        }
                        .padding(.init(top: u(2), leading: u(8), bottom: u(6), trailing: u(8)))
                    }
                    .overlay(RoundedRectangle(cornerRadius: u(8)).strokeBorder(Color(white: 0.73)))
                    .padding(u(10))
                }
            }
        }
    }
    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: u(9.5))).foregroundStyle(.white.opacity(0.55)).padding(.init(top: u(8), leading: u(6), bottom: u(2), trailing: u(0)))
    }
    private func item(_ title: String, selected: Bool = false, unread: Bool = false) -> some View {
        Text(title).font(.system(size: u(10.5), weight: unread ? .bold : .regular)).foregroundStyle(selected || unread ? .white : .white.opacity(0.72))
            .padding(.horizontal, u(6)).padding(.vertical, u(2)).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: u(5)).fill(selected ? Color(red: 0.07, green: 0.39, blue: 0.64) : .clear))
    }
}

// MARK: A native note: list with a yellow selection, the note on the right

struct HelloNoteApp: View {
    let state: HelloWindowState
    var body: some View {
        HelloAppWindow(background: Color(red: 1, green: 1, blue: 0.98)) {
            HStack(spacing: u(0)) {
                VStack(alignment: .leading, spacing: u(2)) {
                    TrafficLights().padding(.init(top: u(12), leading: u(7), bottom: u(8), trailing: u(0)))
                    day("Oggi")
                    note("Promemoria", "10:12  ricordarsi di chiamare…", selected: true)
                    note("Spesa", "09:40  latte, pane, caffè")
                    day("Ieri")
                    note("Idee regalo", "libro di cucina, piante")
                    Spacer()
                }
                .padding(.horizontal, u(6)).frame(width: u(150)).background(Color(red: 0.96, green: 0.96, blue: 0.95))
                Divider()
                VStack(alignment: .leading, spacing: u(5)) {
                    HStack(spacing: u(13)) {
                        Spacer()
                        ForEach(["checklist", "tablecells", "photo", "square.and.pencil"], id: \.self) { helloSymbol($0, u(12), Color(red: 0.84, green: 0.64, blue: 0)) }
                    }
                    Text("25 ottobre 2026 alle 10:12").font(.system(size: u(10))).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    Text("Promemoria").font(.system(size: u(18), weight: .bold))
                    HelloDraftText(state: state, size: u(13)).helloDrop(state)
                    Spacer()
                }
                .padding(.init(top: u(11), leading: u(22), bottom: u(14), trailing: u(14)))
            }
        }
    }
    private func day(_ title: String) -> some View {
        Text(title).font(.system(size: u(9.5), weight: .semibold)).foregroundStyle(.secondary).padding(.init(top: u(6), leading: u(8), bottom: u(2), trailing: u(0)))
    }
    private func note(_ title: String, _ preview: String, selected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: u(1)) {
            Text(title).font(.system(size: u(11), weight: .semibold))
            Text(preview).font(.system(size: u(10.5))).foregroundStyle(selected ? Color(red: 0.42, green: 0.35, blue: 0.1) : .secondary).lineLimit(1)
        }
        .padding(.horizontal, u(8)).padding(.vertical, u(5)).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: u(6)).fill(selected ? Color(red: 0.98, green: 0.83, blue: 0.3) : .clear))
    }
}

// MARK: Messenger: green header, patterned wallpaper, read ticks, right to left

struct HelloMessengerApp: View {
    let state: HelloWindowState
    var body: some View {
        HelloAppWindow(background: Color(red: 0.94, green: 0.92, blue: 0.89)) {
            VStack(spacing: u(0)) {
                HStack(spacing: u(9)) {
                    Text("س").font(.system(size: u(12), weight: .semibold)).foregroundStyle(Color(red: 0.33, green: 0.4, blue: 0.44)).frame(width: u(28), height: u(28))
                        .background(Circle().fill(Color(red: 0.78, green: 0.83, blue: 0.85)))
                    VStack(alignment: .leading, spacing: u(0)) { Text("سارة").font(.system(size: u(12.5), weight: .semibold)); Text("متصل الآن").font(.system(size: u(10))).opacity(0.85) }
                    Spacer()
                    HStack(spacing: u(14)) { helloSymbol("video", u(11), .white); helloSymbol("phone", u(11), .white); helloSymbol("magnifyingglass", u(11), .white) }
                    TrafficLights().environment(\.layoutDirection, .leftToRight)
                }
                .foregroundStyle(.white).padding(.horizontal, u(12)).padding(.vertical, u(9)).background(Color(red: 0, green: 0.5, blue: 0.41))
                VStack(spacing: u(5)) {
                    Spacer()
                    Text("اليوم").font(.system(size: u(10))).foregroundStyle(Color(red: 0.33, green: 0.4, blue: 0.44))
                        .padding(.horizontal, u(8)).padding(.vertical, u(2)).background(RoundedRectangle(cornerRadius: u(6)).fill(.white).shadow(color: .black.opacity(0.1), radius: u(0.5), y: u(1)))
                    bubble("صباح الخير، هل وصلت الملفات؟", time: "10:09", out: true)
                    bubble("متى الاجتماع؟", time: "10:11", out: false)
                }
                .padding(.horizontal, u(12)).padding(.vertical, u(8))
                .background(Canvas { context, size in
                    for x in stride(from: u(4), to: size.width, by: u(18)) {
                        for y in stride(from: u(4), to: size.height, by: u(18)) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: u(2.6), height: u(2.6))), with: .color(Color(red: 0.33, green: 0.4, blue: 0.44).opacity(0.09)))
                        }
                    }
                })
                HStack(alignment: .bottom, spacing: u(7)) {
                    helloSymbol("face.smiling", u(13)).padding(.bottom, u(9))
                    helloSymbol("plus", u(13)).padding(.bottom, u(9))
                    HelloDraftText(state: state, size: u(13)).padding(.horizontal, u(12)).padding(.vertical, u(7))
                        .background(RoundedRectangle(cornerRadius: u(20)).fill(.white)).helloDrop(state)
                    Image(systemName: "mic.fill").font(.system(size: u(13))).foregroundStyle(.white).frame(width: u(34), height: u(34))
                        .background(Circle().fill(Color(red: 0, green: 0.66, blue: 0.52)))
                }
                .padding(.init(top: u(6), leading: u(10), bottom: u(11), trailing: u(10)))
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
    /// Right to left: the user's own messages sit on the left, the other person's on the right.
    private func bubble(_ text: String, time: String, out: Bool) -> some View {
        VStack(alignment: .trailing, spacing: u(1)) {
            Text(text).font(.system(size: u(13)))
            HStack(spacing: u(3)) {
                Text(time).font(.system(size: u(9.5))).foregroundStyle(Color(red: 0.4, green: 0.47, blue: 0.51))
                if out { Text("✓✓").font(.system(size: u(9.5), weight: .bold)).kerning(u(-3)).foregroundStyle(Color(red: 0.33, green: 0.74, blue: 0.92)) }
            }
        }
        .padding(.init(top: u(5), leading: u(8), bottom: u(3), trailing: u(8)))
        .background(RoundedRectangle(cornerRadius: u(7)).fill(out ? Color(red: 0.85, green: 0.99, blue: 0.83) : .white).shadow(color: .black.opacity(0.13), radius: u(0.5), y: u(1)))
        .frame(maxWidth: .infinity, alignment: out ? .trailing : .leading)
    }
}

import SwiftUI

// MARK: A document in a browser

struct HelloDocApp: View {
    let state: HelloWindowState
    private let blue = Color(red: 0.26, green: 0.52, blue: 0.96)
    var body: some View {
        HelloAppWindow(background: Color(red: 0.98, green: 0.98, blue: 0.99)) {
            VStack(alignment: .leading, spacing: u(0)) {
                HStack(alignment: .bottom, spacing: u(6)) {
                    TrafficLights().padding(.bottom, u(9)).padding(.trailing, u(6))
                    HStack(spacing: u(6)) {
                        docIcon(9); Text("Informe Q3").font(.system(size: u(10.5))); Spacer(); helloSymbol("xmark", u(8))
                    }
                    .padding(.horizontal, u(10)).padding(.vertical, u(5)).frame(width: u(150))
                    .background(UnevenRoundedRectangle(topLeadingRadius: u(8), topTrailingRadius: u(8)).fill(.white))
                    helloSymbol("plus", u(10)).padding(.bottom, u(7))
                    Spacer()
                }
                .padding(.init(top: u(7), leading: u(8), bottom: u(0), trailing: u(8))).background(Color(red: 0.87, green: 0.89, blue: 0.91))
                HStack(spacing: u(8)) {
                    helloSymbol("arrow.left", u(10)); helloSymbol("arrow.right", u(10)); helloSymbol("arrow.clockwise", u(10))
                    HStack(spacing: u(6)) { helloSymbol("lock", u(9)); Capsule().fill(.black.opacity(0.1)).frame(width: u(150), height: u(6)); Spacer() }
                        .padding(.horizontal, u(8)).frame(height: u(20)).background(Capsule().fill(Color(red: 0.95, green: 0.95, blue: 0.96)))
                    helloSymbol("star", u(10))
                }
                .padding(.horizontal, u(10)).padding(.vertical, u(4)).background(.white)
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.12)).frame(height: u(0.5)) }
                HStack(spacing: u(9)) {
                    docIcon(13)
                    VStack(alignment: .leading, spacing: u(1)) {
                        Text("Informe Q3").font(.system(size: u(13)))
                        HStack(spacing: u(7)) { ForEach(["Archivo", "Editar", "Ver", "Insertar", "Formato"], id: \.self) { Text($0).fixedSize() } }
                            .font(.system(size: u(10))).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("A").font(.system(size: u(9.5), weight: .semibold)).foregroundStyle(.white).frame(width: u(22), height: u(22))
                        .background(Circle().fill(Color(red: 0.89, green: 0.45, blue: 0)))
                    HStack(spacing: u(5)) { Image(systemName: "lock.fill").font(.system(size: u(9))); Text("Compartir") }
                        .font(.system(size: u(11.5), weight: .semibold)).foregroundStyle(Color(red: 0, green: 0.11, blue: 0.21))
                        .padding(.horizontal, u(12)).padding(.vertical, u(5)).background(Capsule().fill(Color(red: 0.76, green: 0.91, blue: 1)))
                }
                .padding(.init(top: u(6), leading: u(12), bottom: u(0), trailing: u(12)))
                HStack(spacing: u(9)) {
                    helloSymbol("arrow.uturn.backward", u(9)); helloSymbol("arrow.uturn.forward", u(9)); helloSymbol("printer", u(9))
                    divider; Text("100%"); divider; Text("Texto normal"); divider; Text("Arial"); divider; Text("11"); divider
                    Text("B").bold(); Text("I").italic(); Text("U").underline()
                }
                .font(.system(size: u(10.5))).foregroundStyle(.secondary)
                .padding(.horizontal, u(10)).padding(.vertical, u(3))
                .background(Capsule().fill(Color(red: 0.93, green: 0.95, blue: 0.98))).padding(.init(top: u(4), leading: u(10), bottom: u(0), trailing: u(10)))
                HelloDraftText(state: state, size: u(12.5), color: Color(white: 0.13))
                    .helloDrop(state)
                    .padding(.horizontal, u(18)).padding(.vertical, u(9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.2), radius: u(1.5), y: u(1)))
                    .padding(.init(top: u(6), leading: u(30), bottom: u(0), trailing: u(30)))
            }
        }
    }
    private var divider: some View { Rectangle().fill(.black.opacity(0.2)).frame(width: u(0.5), height: u(12)) }
    private func docIcon(_ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: u(2)).fill(blue).frame(width: height * 0.76, height: height)
            .overlay { VStack(spacing: height * 0.12) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(.white).frame(height: max(1, height * 0.08)) } }.padding(height * 0.2) }
    }
}

// MARK: A notes page: workspace sidebar, emoji page icon, big title

struct HelloPageApp: View {
    let state: HelloWindowState
    private let ink = Color(red: 0.22, green: 0.21, blue: 0.18)
    var body: some View {
        HelloAppWindow {
            HStack(spacing: u(0)) {
                VStack(alignment: .leading, spacing: u(1)) {
                    TrafficLights().padding(.init(top: u(12), leading: u(6), bottom: u(9), trailing: u(0)))
                    HStack(spacing: u(6)) {
                        Text("A").font(.system(size: u(9), weight: .semibold)).foregroundStyle(.white).frame(width: u(17), height: u(17))
                            .background(RoundedRectangle(cornerRadius: u(4)).fill(ink))
                        Text("Atelier").font(.system(size: u(10.5), weight: .semibold))
                    }
                    .padding(.init(top: u(3), leading: u(4), bottom: u(6), trailing: u(0)))
                    item("magnifyingglass", "搜索"); item("tray", "收件箱")
                    Text("团队空间").font(.system(size: u(9.5))).foregroundStyle(.tertiary).padding(.init(top: u(8), leading: u(5), bottom: u(2), trailing: u(0)))
                    page("📌", "路线图"); page("📝", "周五复盘", selected: true); page("📚", "文档"); page("🎯", "目标")
                    Spacer()
                }
                .padding(.horizontal, u(6)).frame(width: u(104)).background(Color(red: 0.97, green: 0.97, blue: 0.96))
                VStack(alignment: .leading, spacing: u(5)) {
                    HStack(spacing: u(6)) {
                        Text("团队 / 周五复盘")
                        Spacer()
                        Text("分享"); helloSymbol("star", u(10)); helloSymbol("ellipsis", u(10))
                    }
                    .font(.system(size: u(10.5))).foregroundStyle(.secondary).padding(.bottom, u(6))
                    Text("📝").font(.system(size: u(28)))
                    Text("周五复盘").font(.system(size: u(22), weight: .bold)).foregroundStyle(ink)
                    HStack(spacing: u(14)) {
                        Text("标签")
                        Text("团队").foregroundStyle(ink).padding(.horizontal, u(6)).background(RoundedRectangle(cornerRadius: u(3)).fill(Color(red: 0.89, green: 0.89, blue: 0.88)))
                        Text("上周五")
                    }
                    .font(.system(size: u(11))).foregroundStyle(.secondary)
                    HelloDraftText(state: state, size: u(13.5), color: ink).padding(.top, u(4)).helloDrop(state)
                    Spacer()
                }
                .padding(.init(top: u(9), leading: u(20), bottom: u(14), trailing: u(12)))
            }
        }
    }
    private func item(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: u(5)) { helloSymbol(symbol, 9); Text(title) }.font(.system(size: u(10.5))).foregroundStyle(.secondary).padding(.horizontal, u(5)).padding(.vertical, u(3))
    }
    private func page(_ emoji: String, _ title: String, selected: Bool = false) -> some View {
        Text("\(emoji) \(title)").font(.system(size: u(10.5), weight: selected ? .medium : .regular)).foregroundStyle(selected ? ink : .secondary)
            .padding(.horizontal, u(5)).padding(.vertical, u(3)).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: u(5)).fill(selected ? Color(red: 0.92, green: 0.92, blue: 0.92) : .clear))
    }
}

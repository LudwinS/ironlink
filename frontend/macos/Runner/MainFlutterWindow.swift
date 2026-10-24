import Cocoa
import FlutterMacOS
import SwiftUI

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // IronLink abre ocupando toda el área útil de la pantalla, sin tapar la
    // barra de menús ni el Dock.
    if let screen = NSScreen.main ?? self.screen {
      self.setFrame(screen.visibleFrame, display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    NotchPanelController.shared.attach(
      channel: FlutterMethodChannel(
        name: "ironlink/notch",
        binaryMessenger: flutterViewController.engine.binaryMessenger),
      window: self)

    super.awakeFromNib()
  }
}

// MARK: - Avisos que salen del notch
//
// Diseño de Claude Design («IronLink — Correos y notificaciones»): un panel
// negro unido al notch que crece con curva de resorte; sin notch, una píldora
// negra arriba al centro. La cola y el temporizador viven en Flutter
// (lib/core/notify); aquí solo se dibuja y se devuelven acciones, cierres y el
// puntero encima (que pausa el cierre automático).

struct NotchAction: Equatable {
  let label: String
  let primary: Bool
}

struct NotchNotice: Equatable {
  let id: String
  let title: String
  let subtitle: String?
  let context: String?
  let initials: String?
  let symbol: String
  let accent: Color
  let avatarBackground: Color
  let alert: Bool
  let actions: [NotchAction]

  init?(_ args: [String: Any]) {
    guard let id = args["id"] as? String, let title = args["title"] as? String else {
      return nil
    }
    self.id = id
    self.title = title
    subtitle = args["subtitle"] as? String
    context = args["context"] as? String
    initials = args["initials"] as? String
    symbol = args["symbol"] as? String ?? "bell"
    accent = Color(argb: args["accent"] as? Int ?? 0xFF91_84D9)
    avatarBackground = Color(argb: args["avatarBackground"] as? Int ?? 0xFF2B_2741)
    alert = args["alert"] as? Bool ?? false
    actions = (args["actions"] as? [[String: Any]] ?? []).compactMap {
      guard let label = $0["label"] as? String else { return nil }
      return NotchAction(label: label, primary: $0["primary"] as? Bool ?? false)
    }
  }
}

extension Color {
  init(argb: Int) {
    self.init(
      .sRGB,
      red: Double((argb >> 16) & 0xFF) / 255,
      green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255,
      opacity: Double((argb >> 24) & 0xFF) / 255)
  }
}

final class NotchModel: ObservableObject {
  @Published var notice: NotchNotice?
  @Published var expanded = false
  @Published var hasNotch = false
  /// Tamaño del notch real (o de la píldora) y del panel desplegado.
  @Published var collapsed = CGSize(width: 200, height: 32)
  @Published var full = CGSize(width: 540, height: 104)
}

/// Rectángulo con radios distintos arriba y abajo, animable.
struct NotchShape: Shape {
  var top: CGFloat
  var bottom: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(top, bottom) }
    set {
      top = newValue.first
      bottom = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let t = min(top, rect.height / 2, rect.width / 2)
    let b = min(bottom, rect.height / 2, rect.width / 2)
    var p = Path()
    p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + t), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX - b, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
    p.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - b), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
    p.addQuadCurve(
      to: CGPoint(x: rect.minX + t, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    return p
  }
}

struct NotchView: View {
  @ObservedObject var model: NotchModel
  let onAction: (Int) -> Void
  let onClose: () -> Void
  let onOpen: () -> Void
  let onHover: (Bool) -> Void

  private let muted = Color(red: 0x93 / 255, green: 0x97 / 255, blue: 0xAB / 255)
  private let button = Color(red: 0x29 / 255, green: 0x2B / 255, blue: 0x31 / 255)
  private let ink = Color(red: 0x0C / 255, green: 0x0D / 255, blue: 0x14 / 255)

  var body: some View {
    let size = model.expanded ? model.full : model.collapsed
    // Con notch, unido al borde de arriba; sin notch, píldora.
    let top: CGFloat = model.hasNotch ? 0 : size.height / 2
    let bottom: CGFloat = model.expanded ? 30 : (model.hasNotch ? 10 : size.height / 2)
    VStack(spacing: 0) {
      ZStack(alignment: .bottom) {
        NotchShape(top: top, bottom: bottom).fill(Color.black)
        if let notice = model.notice {
          content(notice)
            .frame(width: model.full.width, height: model.full.height, alignment: .bottom)
            .opacity(model.expanded ? 1 : 0)
            .blur(radius: model.expanded ? 0 : 4)
            .scaleEffect(model.expanded ? 1 : 0.96, anchor: .bottom)
        }
      }
      .frame(width: size.width, height: size.height)
      .clipShape(NotchShape(top: top, bottom: bottom))
      .contentShape(NotchShape(top: top, bottom: bottom))
      .onHover(perform: onHover)
      .onTapGesture(perform: onOpen)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func content(_ n: NotchNotice) -> some View {
    HStack(spacing: 14) {
      ZStack {
        Circle().fill(n.avatarBackground)
        Circle().strokeBorder(n.accent, lineWidth: 1.5)
        if let initials = n.initials {
          Text(initials).font(.system(size: 16, weight: .bold))
            .foregroundColor(n.alert ? n.accent : Color(red: 0xD2 / 255, green: 0xCE / 255, blue: 0xFD / 255))
        } else {
          Image(systemName: n.symbol).font(.system(size: 18, weight: .medium))
            .foregroundColor(n.alert ? n.accent : Color(red: 0xD2 / 255, green: 0xCE / 255, blue: 0xFD / 255))
        }
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        if let context = n.context {
          Text(context).font(.system(size: 11, weight: .semibold)).kerning(0.6)
            .foregroundColor(n.accent).lineLimit(1)
        }
        Text(n.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
          .lineLimit(1)
        if let subtitle = n.subtitle {
          Text(subtitle).font(.system(size: 12)).foregroundColor(muted).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)

      Button(action: onClose) {
        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
          .foregroundColor(Color(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xED / 255))
          .frame(width: 36, height: 36)
          .background(Circle().fill(button))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Cerrar")

      if let index = n.actions.firstIndex(where: { $0.primary }) {
        Button(action: { onAction(index) }) {
          HStack(spacing: 6) {
            if n.symbol == "video" {
              Image(systemName: "video.fill").font(.system(size: 12, weight: .semibold))
            }
            Text(n.actions[index].label).font(.system(size: 13, weight: .bold))
          }
          .foregroundColor(ink)
          .padding(.horizontal, 16)
          .frame(height: 36)
          .background(Capsule().fill(n.accent))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.leading, 20)
    .padding(.trailing, 16)
    .padding(.bottom, 18)
  }
}

/// Panel que no roba el foco ni se vuelve ventana principal.
final class NotchPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Los botones responden al primer clic aunque IronLink no esté activa.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanelController: NSObject {
  static let shared = NotchPanelController()

  private let model = NotchModel()
  private var channel: FlutterMethodChannel?
  private weak var window: NSWindow?
  private var panel: NotchPanel?
  private var pendingHide: DispatchWorkItem?

  private var animation: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? .easeInOut(duration: 0.2)
      : .spring(response: 0.45, dampingFraction: 0.82)
  }

  func attach(channel: FlutterMethodChannel, window: NSWindow) {
    self.channel = channel
    self.window = window
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "show":
        guard let args = call.arguments as? [String: Any], let notice = NotchNotice(args) else {
          return result(FlutterError(code: "bad_args", message: nil, details: nil))
        }
        self.show(notice)
        result(nil)
      case "hide":
        self.hide()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // Al cambiar de monitor o de resolución se vuelve a medir el notch.
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSWindow.didChangeScreenNotification, object: window)
  }

  @objc private func screensChanged() {
    if panel?.isVisible == true { layout() }
  }

  private func makePanel() -> NotchPanel {
    let panel = NotchPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.contentView = NotchHostingView(
      rootView: NotchView(
        model: model,
        onAction: { [weak self] index in self?.send("action", ["index": index]) },
        onClose: { [weak self] in self?.send("dismiss") },
        onOpen: { [weak self] in
          NSApp.activate(ignoringOtherApps: true)
          self?.window?.makeKeyAndOrderFront(nil)
          self?.send("dismiss")
        },
        onHover: { [weak self] inside in self?.send("hover", ["inside": inside]) }))
    return panel
  }

  /// Mide el notch de la pantalla donde está IronLink y coloca el panel.
  private func layout() {
    guard let panel, let screen = window?.screen ?? NSScreen.main else { return }
    let frame = screen.frame
    let inset = screen.safeAreaInsets.top
    let hasNotch = inset > 0
    let width = min(540, frame.width - 32)
    let height: CGFloat = 104
    if hasNotch {
      let left = screen.auxiliaryTopLeftArea?.width ?? 0
      let right = screen.auxiliaryTopRightArea?.width ?? 0
      let notch = max(frame.width - left - right, 120)
      model.collapsed = CGSize(width: notch, height: inset)
    } else {
      model.collapsed = CGSize(width: 200, height: 32)
    }
    model.hasNotch = hasNotch
    model.full = CGSize(width: width, height: height)
    // Con notch, pegado al borde superior; sin notch, bajo la barra de menús.
    let top = hasNotch ? frame.maxY : screen.visibleFrame.maxY - 8
    panel.setFrame(
      NSRect(x: frame.midX - width / 2, y: top - height, width: width, height: height),
      display: true)
  }

  private func show(_ notice: NotchNotice) {
    pendingHide?.cancel()
    pendingHide = nil
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if model.expanded, model.notice != nil {
      // Ya desplegado: cambia el contenido con un fundido.
      withAnimation(.easeInOut(duration: 0.2)) { model.notice = notice }
      return
    }
    layout()
    model.expanded = false
    model.notice = notice
    panel.ignoresMouseEvents = false
    panel.orderFrontRegardless()
    DispatchQueue.main.async {
      withAnimation(self.animation) { self.model.expanded = true }
    }
  }

  private func hide() {
    guard let panel, model.notice != nil else { return }
    panel.ignoresMouseEvents = true
    withAnimation(animation) { model.expanded = false }
    let work = DispatchWorkItem { [weak self] in
      panel.orderOut(nil)
      self?.model.notice = nil
    }
    pendingHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
  }

  private func send(_ method: String, _ extra: [String: Any] = [:]) {
    guard let id = model.notice?.id else { return }
    channel?.invokeMethod(method, arguments: extra.merging(["id": id]) { $1 })
  }
}

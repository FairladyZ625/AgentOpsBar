import AppKit
import Combine
import SwiftUI

final class FloatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hudPanel: FloatingHUDPanel?
    private var hudHostingView: NSHostingView<MonitorContentView>?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleId = Bundle.main.bundleIdentifier {
            let currentPid = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { $0.processIdentifier != currentPid }
            if let existing = others.first {
                existing.activate()
                NSApplication.shared.terminate(nil)
                return
            }
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        setupPopover()
        setupStatusItem()
        bindStore()

        store.start()
        if store.isFloatingPinned {
            showFloatingPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store.isFloatingPinned {
            hudPanel?.orderFrontRegardless()
        } else {
            showPopover()
        }
        return true
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let rootView = MonitorContentView(
            store: store,
            mode: .popover,
            onDismissPopover: { [weak self] in
                self?.popover.performClose(nil)
            }
        )
        let controller = NSHostingController(rootView: rootView)
        if #available(macOS 13.0, *) {
            controller.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = controller
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.toolTip = "AgentOpsBar — 左键打开面板，右键快捷菜单"
        updateStatusItemAppearance()
    }

    private func bindStore() {
        store.onPresentationChange = { [weak self] in
            self?.updateStatusItemAppearance()
            self?.resizeFloatingPanelIfNeeded()
        }
        store.onFloatingToggle = { [weak self] pinned in
            guard let self else { return }
            if pinned {
                self.showFloatingPanel()
            } else {
                self.hideFloatingPanel()
            }
        }

        store.$isFloatingCollapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeFloatingPanelIfNeeded()
                }
            }
            .store(in: &cancellables)

        store.$activeTab
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeFloatingPanelIfNeeded()
                }
            }
            .store(in: &cancellables)

        store.$ciSubTab
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeFloatingPanelIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            presentContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.syncLaunchAtLoginStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func presentContextMenu() {
        store.syncLaunchAtLoginStatus()
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "立即刷新状态", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let pinItem = NSMenuItem(
            title: store.isFloatingPinned ? "关闭桌面置顶悬浮窗" : "打开桌面置顶悬浮窗",
            action: #selector(menuTogglePin),
            keyEquivalent: "p"
        )
        pinItem.target = self
        pinItem.state = store.isFloatingPinned ? .on : .off
        menu.addItem(pinItem)

        let rateItem = NSMenuItem(
            title: "显示菜单栏文字摘要",
            action: #selector(menuToggleRate),
            keyEquivalent: ""
        )
        rateItem.target = self
        rateItem.state = store.showMenuBarRate ? .on : .off
        menu.addItem(rateItem)

        let loginItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(menuToggleLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = store.launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AgentOpsBar", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() {
        store.refresh(forceLive: true)
    }

    @objc private func menuTogglePin() {
        store.isFloatingPinned.toggle()
    }

    @objc private func menuToggleRate() {
        store.showMenuBarRate.toggle()
    }

    @objc private func menuToggleLogin() {
        store.toggleLaunchAtLogin()
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let dotNSColor: NSColor = {
            switch store.healthState {
            case .loading:
                return NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.65, alpha: 1.0)
            case .error:
                return NSColor(calibratedRed: 0.97, green: 0.44, blue: 0.44, alpha: 1.0)
            case .zeroBurn:
                return NSColor(calibratedRed: 0.29, green: 0.87, blue: 0.50, alpha: 1.0)
            case .activeWork:
                return NSColor(calibratedRed: 0.36, green: 0.61, blue: 0.96, alpha: 1.0)
            case .idleWasting:
                return NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.14, alpha: 1.0)
            }
        }()

        button.image = Self.makeStatusIcon(dotColor: dotNSColor, isRefreshing: store.isRefreshing)

        let summary = store.menuBarSummaryText
        if summary.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .baselineOffset: -0.5,
            ]
            button.attributedTitle = NSAttributedString(string: " \(summary)", attributes: attrs)
        }
    }

    private static func makeStatusIcon(dotColor: NSColor, isRefreshing: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let ringRect = NSRect(x: 2.0, y: 2.0, width: 12.0, height: 12.0)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            dotColor.withAlphaComponent(isRefreshing ? 0.45 : 0.24).setFill()
            ringPath.fill()

            let coreRect = NSRect(x: 4.5, y: 4.5, width: 7.0, height: 7.0)
            let corePath = NSBezierPath(ovalIn: coreRect)
            dotColor.setFill()
            corePath.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func showFloatingPanel() {
        if let panel = hudPanel {
            resizeFloatingPanelIfNeeded()
            panel.orderFrontRegardless()
            return
        }

        let content = MonitorContentView(store: store, mode: .floating)
        let hosting = NSHostingView(rootView: content)
        let fit = hosting.fittingSize
        let width: CGFloat = 386
        let height: CGFloat = max(46, fit.height)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.maxX - width - 20
        let originY = screenFrame.maxY - height - 16
        let initialRect = NSRect(x: originX, y: originY, width: width, height: height)

        let panel = FloatingHUDPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setFrameAutosaveName("AgentOpsBarFloatingHUD")

        hudHostingView = hosting
        hudPanel = panel
        resizeFloatingPanelIfNeeded()
        panel.orderFrontRegardless()
    }

    private func hideFloatingPanel() {
        hudPanel?.orderOut(nil)
    }

    private func resizeFloatingPanelIfNeeded() {
        guard let panel = hudPanel, let hosting = hudHostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let newHeight = max(46, fit.height)
        let oldFrame = panel.frame
        if abs(oldFrame.height - newHeight) < 1.0 {
            return
        }
        let newOriginY = oldFrame.maxY - newHeight
        let nextFrame = NSRect(x: oldFrame.origin.x, y: newOriginY, width: 386, height: newHeight)
        panel.setFrame(nextFrame, display: true, animate: false)
    }
}

@main
struct AgentOpsBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

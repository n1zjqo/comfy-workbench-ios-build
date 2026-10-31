import SwiftUI
import UIKit

struct WorkflowCanvasView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    @State private var selected: String?
    @State private var editing: WorkflowField?
    @State private var searching = false
    @State private var query = ""
    @State private var command = CanvasCommand()
    @State private var zoom = 1.0
    private var node: CanvasNode? { store.canvas?.nodes.first { $0.id == selected } }
    private var matches: [CanvasNode] { (store.canvas?.nodes ?? []).filter { query.isEmpty || "\($0.type) #\($0.id)".localizedCaseInsensitiveContains(query) } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color(red: 0.082, green: 0.165, blue: 0.2).ignoresSafeArea()
                if let graph = store.canvas {
                    let workflowID = store.selectedID
                    CanvasSurface(graph: graph, selected: selected, command: command,
                                  bottomInset: node == nil ? 94 : min(geometry.size.height * 0.43, 350) + 80,
                                  trace: store.canvasJob?.execution, savedViewport: store.selected?.viewport,
                                  selection: { selected = $0 }, zoomChanged: { zoom = $0 }, viewportChanged: { store.saveViewport($0, workflowID: workflowID) })
                        .ignoresSafeArea(edges: .bottom)
                }
                VStack(spacing: 0) {
                    header.padding(.horizontal, 16).padding(.top, 8)
                    if let job = store.canvasJob { executionBanner(job).padding(.horizontal, 16).padding(.top, 8) }
                    Spacer(minLength: 12)
                    controls.padding(.bottom, 14)
                    if let node = node { inspector(node).frame(height: min(geometry.size.height * 0.43, 350)).padding(.horizontal, 12).padding(.bottom, 8) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { FieldEditor(field: $0) }
        .sheet(isPresented: $searching) {
            NavigationView {
                List(matches) { node in
                    Button {
                        selected = node.id; command = CanvasCommand(action: .focus(node.id)); searching = false
                    } label: {
                        HStack { Image(systemName: "circle.hexagongrid").foregroundColor(.mint)
                            VStack(alignment: .leading, spacing: 5) { Text(node.type).foregroundColor(.primary); Text("#\(node.id) · \(node.fields.count) 个参数").font(.caption).foregroundColor(.secondary) }
                            Spacer(); Image(systemName: "scope").foregroundColor(.secondary)
                        }.padding(.vertical, 5)
                    }
                }.searchable(text: $query, prompt: "节点默认名称或编号")
                    .navigationTitle("定位节点").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searching = false } } }
            }.navigationViewStyle(.stack).preferredColorScheme(.dark)
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button { presentation.wrappedValue.dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("关闭画布")
            VStack(alignment: .leading, spacing: 4) {
                Text("工作流画布").font(.system(size: 17, weight: .semibold))
                Text("\(store.canvas?.originalLayout == true ? "原始布局" : "自动布局") · \(store.canvas?.nodes.count ?? 0) 个节点").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 2)
            Button { searching = true } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("搜索节点")
        }.padding(6).glass(24).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 0.5)).foregroundColor(.white)
    }
    private var controls: some View {
        HStack(spacing: 2) {
            Button { store.undoEdit() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 44) }.disabled(!store.canUndo || store.busy).accessibilityLabel("撤销修改")
            Button { store.redoEdit() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 40, height: 44) }.disabled(!store.canRedo || store.busy).accessibilityLabel("重做修改")
            Button { selected = nil; command = CanvasCommand(action: .fit) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 48, height: 44) }.accessibilityLabel("显示整个工作流")
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18)
            Button { command = CanvasCommand(action: .zoom(0.75)) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.accessibilityLabel("缩小")
            Text("\(Int(zoom * 100))%").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 50).foregroundColor(.white.opacity(0.65)).accessibilityLabel("缩放百分之 \(Int(zoom * 100))")
            Button { command = CanvasCommand(action: .zoom(1.33)) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("放大")
        }.padding(4).glass(30).overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5)).foregroundColor(.white)
    }
    private func executionBanner(_ job: GenerationJob) -> some View {
        let trace = job.execution ?? ExecutionTrace()
        let target = store.canvas?.visibleNodeID(for: trace.failedNode ?? trace.activeNode)
        let type = store.canvas?.nodes.first { $0.id == target }?.type ?? "节点"
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Circle().fill(trace.phase == .failed || trace.phase == .interrupted ? Color.red : Color.mint).frame(width: 6, height: 6)
                Text(trace.phase == .disconnected ? "正在恢复实时连接" : (target.map { "\(type)  #\($0)" } ?? job.state)).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let target = target { Button { selected = target; command = CanvasCommand(action: .focus(target)) } label: { Image(systemName: "scope").frame(width: 34, height: 30) }.accessibilityLabel("定位运行或出错节点") }
            }
            if let fraction = trace.fraction, trace.phase == .running { ProgressView(value: fraction).tint(.mint) }
            if let detail = trace.detail { Text(detail).font(.caption2).foregroundColor(.red).lineLimit(2) }
            else { Text(trace.phase == .disconnected ? "历史结果仍会继续查询" : "已执行 \(trace.completedNodes.count) · 缓存 \(trace.cachedNodes.count)\(job.finished ? "" : " · 修改参数用于下一次生成")").font(.system(size: 10)).foregroundColor(.secondary) }
        }.padding(.horizontal, 14).padding(.vertical, 9).glass(16)
    }
    private func inspector(_ node: CanvasNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(.white.opacity(0.22)).frame(width: 30, height: 3).frame(maxWidth: .infinity).padding(.top, 9)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.53, green: 0.83, blue: 0.8)).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.type).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text("#\(node.id) · \(node.fields.count) 个参数\(node.bypassed ? " · 已绕过 / 禁用" : "")").font(.caption2).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button { selected = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("收起节点参数")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            if !node.fields.isEmpty {
                Toggle("显示到常用参数", isOn: Binding(get: { store.nodeIsInPanel(node) }, set: { enabled in
                    do { try store.showNodeInPanel(node.id, enabled: enabled) } catch { store.error = error.localizedDescription }
                })).font(.subheadline).tint(.mint).padding(.horizontal, 18).padding(.bottom, 12).disabled(store.busy)
                    .accessibilityIdentifier("node-common-parameters")
            }
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let issue = store.canvas?.groupSwitchIssues[node.id] {
                        Text(issue).font(.subheadline).foregroundColor(.secondary).padding(18)
                    } else if node.fields.isEmpty {
                        Text(WorkflowGroupSwitch.controllerTypes.contains(node.type) ? "没有匹配的分组，请检查此节点的名称或颜色筛选规则。" : "这个节点没有可直接编辑的参数。可以定位上游节点修改输入。").font(.subheadline).foregroundColor(.secondary).padding(18)
                    }
                    ForEach(node.fields) { field in
                        if store.canvas?.groupSwitches.contains(where: { $0.id == field.id }) == true {
                            WorkflowGroupSwitchRow(field: field)
                        } else {
                        Button { editing = field } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(field.title).font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.9))
                                    Text(field.value.displayValue.isEmpty ? "未填写" : field.value.displayValue).font(.system(size: 13)).foregroundColor(.white.opacity(0.52)).lineLimit(field.schema.multiline ? 3 : 1)
                                }
                                Spacer(minLength: 8); Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                            }.padding(.vertical, 13).padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy)
                        }
                        Divider().padding(.leading, 18)
                    }
                    let adjacent = (store.canvas?.links ?? []).filter { $0.target == node.id || $0.source == node.id }
                    if !adjacent.isEmpty {
                        Text("连接节点").font(.caption).foregroundColor(.secondary).padding(.horizontal, 18).padding(.top, 16)
                        ForEach(adjacent) { link in
                            let target = link.source == node.id ? link.target : link.source
                            let type = store.canvas?.nodes.first { $0.id == target }?.type ?? ""
                            Button { selected = target; command = CanvasCommand(action: .focus(target)) } label: {
                                Label("\(type)  #\(target)", systemImage: link.source == node.id ? "arrow.down.right" : "arrow.up.left").font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 18)
                            }.foregroundColor(Color(red: 0.53, green: 0.83, blue: 0.8))
                        }
                    }
                }
            }
        }.background(Color(red: 0.10, green: 0.19, blue: 0.23), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

struct CanvasCommand: Equatable {
    enum Action: Equatable { case fit, zoom(Double), focus(String) }
    var id = UUID()
    var action: Action = .fit
}

private struct CanvasSurface: UIViewRepresentable {
    let graph: WorkflowCanvas
    let selected: String?
    let command: CanvasCommand
    let bottomInset: CGFloat
    let trace: ExecutionTrace?
    let savedViewport: CanvasViewport?
    let selection: (String?) -> Void
    let zoomChanged: (Double) -> Void
    let viewportChanged: (CanvasViewport) -> Void
    func makeUIView(context: Context) -> GraphCanvasUIView {
        let view = GraphCanvasUIView(); view.onSelection = selection; view.onZoom = zoomChanged; return view
    }
    func updateUIView(_ view: GraphCanvasUIView, context: Context) {
        view.onSelection = selection; view.onZoom = zoomChanged
        view.onViewport = viewportChanged
        view.update(graph: graph, selected: selected, bottomInset: bottomInset, command: command, trace: trace, savedViewport: savedViewport)
    }
}

/// A screen-sized drawing surface: the full graph never becomes a giant bitmap.
final class GraphCanvasUIView: UIView, UIGestureRecognizerDelegate {
    var onSelection: ((String?) -> Void)?
    var onZoom: ((Double) -> Void)?
    var onViewport: ((CanvasViewport) -> Void)?
    private var graph: WorkflowCanvas?
    private var byID: [String: CanvasNode] = [:]
    private var selected: String?
    private var related = Set<String>()
    private var camera = CGPoint.zero
    private var scale: CGFloat = 1
    private var minimumScale: CGFloat = 0.025
    private var bottomInset: CGFloat = 94
    private var lastCommand: UUID?
    private var fitted = false
    private var lastSize = CGSize.zero
    private var miniRect = CGRect.zero
    private var graphBounds = CGRect.zero
    private var trace: ExecutionTrace?
    private var restoredViewport: CanvasViewport?
    private let teal = UIColor(red: 0.53, green: 0.83, blue: 0.8, alpha: 1)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true; backgroundColor = UIColor(red: 0.082, green: 0.165, blue: 0.2, alpha: 1)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))); pinch.delegate = self; addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); addGestureRecognizer(tap)
        accessibilityLabel = "工作流画布"; accessibilityHint = "可用顶部搜索按钮选择节点并编辑参数"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(graph: WorkflowCanvas, selected: String?, bottomInset: CGFloat, command: CanvasCommand, trace: ExecutionTrace?, savedViewport: CanvasViewport?) {
        self.graph = graph; self.selected = selected; self.bottomInset = bottomInset
        self.trace = trace
        if !fitted { restoredViewport = savedViewport }
        byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        related = Set(graph.links.filter { $0.source == selected || $0.target == selected }.flatMap { [$0.source, $0.target] })
        if let selected = selected { related.insert(selected) }
        graphBounds = graph.nodes.reduce(CGRect.null) { $0.union(rect($1)) }
        if lastCommand != command.id {
            lastCommand = command.id
            if bounds.width > 0 { perform(command.action) }
        }
        setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            let old = lastSize; lastSize = bounds.size
            if !fitted {
                fit()
                if let saved = restoredViewport, saved.valid {
                    scale = CGFloat(saved.zoom)
                    camera = CGPoint(x: viewport.midX - CGFloat(saved.x) * scale, y: viewport.midY - CGFloat(saved.y) * scale)
                    reportZoom()
                }
                fitted = true
            }
            else { camera.x += (bounds.width - old.width) / 2; camera.y += (bounds.height - old.height) / 2 }
            setNeedsDisplay()
        }
    }
    private var viewport: CGRect { let top: CGFloat = trace == nil ? 100 : 170; return CGRect(x: 18, y: top, width: max(1, bounds.width - 36), height: max(100, bounds.height - bottomInset - top - 16)) }
    private func rect(_ node: CanvasNode) -> CGRect { CGRect(x: node.x, y: node.y, width: node.width, height: node.height) }
    private func fit() {
        guard !graphBounds.isNull, graphBounds.width > 0 else { return }
        let area = viewport
        scale = min(1, min(area.width / (graphBounds.width + 80), area.height / (graphBounds.height + 80)))
        minimumScale = max(0.000005, min(0.025, scale * 0.5))
        camera = CGPoint(x: area.midX - graphBounds.midX * scale, y: area.midY - graphBounds.midY * scale)
        reportZoom()
    }
    private func perform(_ action: CanvasCommand.Action) {
        switch action {
        case .fit: fit()
        case .zoom(let amount): zoom(by: CGFloat(amount), anchor: CGPoint(x: viewport.midX, y: viewport.midY))
        case .focus(let id):
            guard let node = byID[id] else { return }
            scale = min(1.2, max(0.35, viewport.width / (CGFloat(node.width) + 60)))
            camera = CGPoint(x: viewport.midX - rect(node).midX * scale, y: viewport.midY - rect(node).midY * scale)
            reportZoom()
        }
        reportViewport()
    }
    private func reportViewport() {
        guard fitted, scale > 0 else { return }
        let value = CanvasViewport(x: Double((viewport.midX - camera.x) / scale), y: Double((viewport.midY - camera.y) / scale), zoom: Double(scale))
        DispatchQueue.main.async { [weak self] in self?.onViewport?(value) }
    }
    private func reportZoom() { let value = Double(scale); DispatchQueue.main.async { [weak self] in self?.onZoom?(value) } }
    private func zoom(by factor: CGFloat, anchor: CGPoint) {
        let next = min(3, max(minimumScale, scale * factor)), ratio = next / scale
        camera = CGPoint(x: anchor.x - (anchor.x - camera.x) * ratio, y: anchor.y - (anchor.y - camera.y) * ratio)
        scale = next; reportZoom(); setNeedsDisplay()
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self); camera.x += delta.x; camera.y += delta.y
        gesture.setTranslation(.zero, in: self); setNeedsDisplay()
        if gesture.state == .ended || gesture.state == .cancelled { reportViewport() }
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) { zoom(by: gesture.scale, anchor: gesture.location(in: self)); gesture.scale = 1; if gesture.state == .ended || gesture.state == .cancelled { reportViewport() } }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        if miniRect.contains(p), graphBounds.width > 0 {
            let world = CGPoint(x: graphBounds.minX + (p.x - miniRect.minX) / miniRect.width * graphBounds.width,
                                y: graphBounds.minY + (p.y - miniRect.minY) / miniRect.height * graphBounds.height)
            camera = CGPoint(x: viewport.midX - world.x * scale, y: viewport.midY - world.y * scale); setNeedsDisplay(); reportViewport(); return
        }
        let world = CGPoint(x: (p.x - camera.x) / scale, y: (p.y - camera.y) / scale)
        let hit = graph?.nodes.reversed().first { rect($0).insetBy(dx: -4 / scale, dy: -4 / scale).contains(world) }
        onSelection?(hit?.id)
    }
    private func port(_ node: CanvasNode, slot: Int, output: Bool) -> CGPoint {
        let r = rect(node), count = max(1, output ? node.outputs.count : node.inputs.count)
        let y = r.height < 65 ? r.midY : r.minY + 48 + CGFloat(slot) * min(23, max(1, (r.height - 64) / CGFloat(count)))
        return CGPoint(x: output ? r.maxX : r.minX, y: min(r.maxY - 8, y))
    }
    private func color(_ type: String) -> UIColor {
        let t = type.lowercased()
        if t.contains("model") || t.contains("latent") || t.contains("sampler") { return UIColor(red: 0.82, green: 0.69, blue: 0.91, alpha: 1) }
        if t.contains("clip") || t.contains("text") || t.contains("condition") { return UIColor(red: 0.89, green: 0.71, blue: 0.54, alpha: 1) }
        return teal
    }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let graph = graph else { return }
        backgroundColor?.setFill(); ctx.fill(bounds)
        drawGrid(ctx)
        ctx.saveGState(); ctx.translateBy(x: camera.x, y: camera.y); ctx.scaleBy(x: scale, y: scale)
        let visible = CGRect(x: -camera.x / scale, y: -camera.y / scale, width: bounds.width / scale, height: bounds.height / scale).insetBy(dx: -40 / scale, dy: -40 / scale)
        for link in graph.links {
            guard let a = byID[link.source], let b = byID[link.target] else { continue }
            let p = port(a, slot: link.sourceSlot, output: true), q = port(b, slot: link.targetSlot, output: false)
            let bend = max(45, abs(q.x - p.x) * 0.45)
            let path = UIBezierPath(); path.move(to: p)
            path.addCurve(to: q, controlPoint1: CGPoint(x: p.x + bend, y: p.y), controlPoint2: CGPoint(x: q.x - bend, y: q.y))
            guard path.bounds.insetBy(dx: -4, dy: -4).intersects(visible) else { continue }
            let visibleActive = graph.visibleNodeID(for: trace?.activeNode)
            let active = selected == link.source || selected == link.target || visibleActive == link.source || visibleActive == link.target
            color(link.type).withAlphaComponent(active ? 0.85 : (selected == nil ? 0.28 : 0.08)).setStroke()
            path.lineWidth = (active ? 1.5 : 0.9) / max(0.4, scale); path.stroke()
        }
        for node in graph.nodes where self.rect(node).intersects(visible) { drawNode(node, ctx: ctx) }
        ctx.restoreGState(); drawMinimap(graph, ctx: ctx)
    }
    private func drawGrid(_ ctx: CGContext) {
        var step = 26 * scale
        while step < 18 { step *= 4 }
        while step > 80 { step /= 4 }
        let x0 = camera.x.truncatingRemainder(dividingBy: step), y0 = camera.y.truncatingRemainder(dividingBy: step)
        UIColor.white.withAlphaComponent(0.09).setFill()
        for x in stride(from: x0, through: bounds.width, by: step) {
            for y in stride(from: y0, through: bounds.height, by: step) { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 1, height: 1)) }
        }
    }
    private func drawNode(_ node: CanvasNode, ctx: CGContext) {
        let running = trace?.phase == .running && graph?.visibleNodeID(for: trace?.activeNode) == node.id
        let failed = graph?.visibleNodeID(for: trace?.failedNode) == node.id
        let completed = trace?.completedNodes.contains(node.id) == true
        let cached = trace?.cachedNodes.contains(node.id) == true
        let r = rect(node), accent = failed ? UIColor.systemRed : (running || completed ? teal : color(node.type)), active = node.id == selected || running || failed
        ctx.saveGState()
        ctx.setAlpha(selected == nil || related.contains(node.id) || running || failed ? (node.bypassed ? 0.5 : 1) : 0.42)
        let path = UIBezierPath(roundedRect: r, cornerRadius: min(14, r.height / 3))
        if active { ctx.setShadow(offset: .zero, blur: 18 / max(0.3, scale), color: accent.withAlphaComponent(0.23).cgColor) }
        UIColor(red: 0.12, green: 0.225, blue: 0.265, alpha: 1).setFill(); path.fill(); ctx.setShadow(offset: .zero, blur: 0)
        (active ? accent.withAlphaComponent(0.9) : UIColor.white.withAlphaComponent(0.2)).setStroke()
        path.lineWidth = (active ? 1.3 : 0.65) / max(0.4, scale); path.stroke()
        ctx.saveGState(); path.addClip()
        accent.withAlphaComponent(0.07).setFill(); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: min(35, r.height)))
        if scale > 0.19 {
            text(node.type, in: CGRect(x: r.minX + 13, y: r.minY + 10, width: r.width - 55, height: 21), size: 12, weight: .semibold, color: .white.withAlphaComponent(0.92))
            text("#\(node.id)", in: CGRect(x: r.maxX - 49, y: r.minY + 11, width: 39, height: 18), size: 9, color: .white.withAlphaComponent(0.38), right: true)
        }
        if running || failed || completed || cached {
            accent.withAlphaComponent(running || failed ? 1 : 0.55).setFill()
            ctx.fill(CGRect(x: r.minX + 12, y: r.maxY - 4, width: (r.width - 24) * (running ? CGFloat(trace?.fraction ?? 0.08) : 1), height: 2))
        }
        if scale > 0.44 && r.height > 90 {
            let slots = max(node.inputs.count, node.outputs.count)
            var y = r.minY + 48 + CGFloat(min(slots, 4)) * 23 + 8
            for field in node.fields.prefix(4) {
                guard y + 25 < r.maxY - 8 else { break }
                let multiline = field.schema.multiline && r.maxY - y > 85
                let height: CGFloat = multiline ? min(140, r.maxY - y - 12) : 24
                let row = CGRect(x: r.minX + 12, y: y, width: r.width - 24, height: height)
                UIColor.black.withAlphaComponent(0.14).setFill(); UIBezierPath(roundedRect: row, cornerRadius: 6).fill()
                text(field.name, in: CGRect(x: row.minX + 8, y: y + 6, width: row.width * 0.45, height: 14), size: 9, color: .white.withAlphaComponent(0.48))
                if multiline {
                    text(String(field.value.displayValue.prefix(400)), in: CGRect(x: row.minX + 8, y: y + 25, width: row.width - 16, height: height - 34), size: 11, color: .white.withAlphaComponent(0.73), multiline: true)
                } else {
                    text(String(field.value.displayValue.prefix(160)).replacingOccurrences(of: "\n", with: " "), in: CGRect(x: row.minX + row.width * 0.46, y: y + 6, width: row.width * 0.54 - 8, height: 14), size: 9, color: .white.withAlphaComponent(0.8), right: true)
                }
                y += height + 6
            }
        }
        ctx.restoreGState()
        for output in [false, true] {
            let ports = output ? node.outputs : node.inputs
            for (i, name) in ports.enumerated() {
                let p = port(node, slot: i, output: output)
                accent.withAlphaComponent(0.8).setFill(); ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                if scale > 0.55 && r.height > 90 && i < 4 {
                    text(name, in: CGRect(x: output ? r.midX : r.minX + 11, y: p.y - 5, width: r.width / 2 - 22, height: 12), size: 8, color: accent.withAlphaComponent(0.65), right: output)
                }
            }
        }
        ctx.restoreGState()
    }
    private func text(_ value: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor, right: Bool = false, multiline: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail; paragraph.alignment = right ? .right : .left
        if multiline { paragraph.lineSpacing = 4 }
        (value as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func drawMinimap(_ graph: WorkflowCanvas, ctx: CGContext) {
        guard !graphBounds.isNull else { return }
        let outer = CGRect(x: bounds.width - 106, y: max(110, bounds.height - bottomInset - 74), width: 90, height: 58)
        UIColor(red: 0.07, green: 0.14, blue: 0.18, alpha: 0.92).setFill(); UIBezierPath(roundedRect: outer, cornerRadius: 10).fill()
        UIColor.white.withAlphaComponent(0.13).setStroke(); let border = UIBezierPath(roundedRect: outer, cornerRadius: 10); border.lineWidth = 0.5; border.stroke()
        let s = min(76 / graphBounds.width, 44 / graphBounds.height)
        miniRect = CGRect(x: outer.midX - graphBounds.width * s / 2, y: outer.midY - graphBounds.height * s / 2, width: graphBounds.width * s, height: graphBounds.height * s)
        ctx.saveGState(); ctx.clip(to: outer.insetBy(dx: 5, dy: 5))
        for node in graph.nodes {
            (node.id == selected ? UIColor.white : teal.withAlphaComponent(0.4)).setFill()
            ctx.fill(CGRect(x: miniRect.minX + (CGFloat(node.x) - graphBounds.minX) * s, y: miniRect.minY + (CGFloat(node.y) - graphBounds.minY) * s, width: max(1, CGFloat(node.width) * s), height: max(1, CGFloat(node.height) * s)))
        }
        let visible = CGRect(x: (viewport.minX - camera.x) / scale, y: (viewport.minY - camera.y) / scale, width: viewport.width / scale, height: viewport.height / scale)
        UIColor.white.withAlphaComponent(0.6).setStroke(); ctx.setLineWidth(0.6)
        ctx.stroke(CGRect(x: miniRect.minX + (visible.minX - graphBounds.minX) * s, y: miniRect.minY + (visible.minY - graphBounds.minY) * s, width: visible.width * s, height: visible.height * s))
        ctx.restoreGState()
    }
}

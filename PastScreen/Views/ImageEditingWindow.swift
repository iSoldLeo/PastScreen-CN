//
//  ImageEditingWindow.swift
//  PastScreen
//
//  Created for advanced screenshot editing functionality
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

class ImageEditingWindow: NSWindow {
    private var hostingView: NSHostingView<AnyView>!
    private var screenshotImage: NSImage
    private var onCompletion: ((NSImage) -> Void)?
    private var onCancel: (() -> Void)?
    
    init(image: NSImage, onCompletion: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void) {
        self.screenshotImage = image
        self.onCompletion = onCompletion
        self.onCancel = onCancel
        
        // Create window with appropriate size
        let windowSize = NSSize(width: 800, height: 600)
        let windowRect = NSRect(origin: .zero, size: windowSize)
        
        super.init(contentRect: windowRect,
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered,
                   defer: false)
        
        setupWindow()
        setupContentView()
    }
    
    private func setupWindow() {
        title = NSLocalizedString("editor.window.title", comment: "")
        center()
        isReleasedWhenClosed = false
        
        // Set minimum size
        minSize = NSSize(width: 600, height: 400)
        
        // Make window modal
        level = .floating
        // Remove isMovableByWindowBackground to prevent window dragging when drawing
    }
    
    private func setupContentView() {
        let editingView = ImageEditingView(
            image: screenshotImage,
            onCompletion: { [weak self] editedImage in
                self?.hide()
                self?.onCompletion?(editedImage)
            },
            onCancel: { [weak self] in
                self?.hide()
                self?.onCancel?()
            },
            radialTools: AppSettings.shared.radialDrawingTools
        )
        let wrappedView = AnyView(editingView.environmentObject(AppSettings.shared))
        
        hostingView = NSHostingView(rootView: wrappedView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: contentView!.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor)
        ])
    }
    
    func show() {
        makeKeyAndOrderFront(nil)
    }
    
    func hide() {
        orderOut(nil)
    }
}

struct ImageEditingView: View {
    let image: NSImage
    let onCompletion: (NSImage) -> Void
    let onCancel: () -> Void
    let radialTools: [DrawingTool]
    @EnvironmentObject private var settings: AppSettings
    
    @State private var editedImage: NSImage
    @State private var selectedTool: DrawingTool = ImageEditingView.defaultTool()
    @State private var selectedColor: Color = .red
    @State private var strokeWidth: Double = 2.0
    @State private var drawingPaths: [DrawingPath] = []
    @State private var currentPath: DrawingPath?
    @State private var isDrawing = false
    @State private var mosaicRegions: [MosaicRegion] = []
    private let ciContext = CIContext()
    
    // Radial tool selector state
    @State private var radialCenter: CGPoint? = nil
    @State private var radialCurrentPoint: CGPoint? = nil
    
    // Text tool properties
    @State private var textInputs: [TextInput] = []
    @State private var showTextInput = false
    @State private var textLocation: CGPoint = .zero
    @State private var currentText = ""
    @State private var waitingForTextPlacement = false
    @State private var previewTextPosition: CGPoint? = nil
    @State private var mousePosition: CGPoint = .zero

    // OCR tool properties
    @State private var ocrSelectedRect: CGRect? = nil
    @State private var ocrIsProcessing = false
    @State private var showOCRResult = false
    @State private var ocrResultText = ""
    @State private var showOCRError = false
    @State private var ocrErrorMessage = ""
    
    // Undo/Redo state
    @State private var undoStack: [EditAction] = []
    @State private var redoStack: [EditAction] = []
    @State private var undoManager = UndoManager()
    
    // Keyboard monitor for cleanup
    @State private var keyboardMonitor: Any? = nil
    
    init(
        image: NSImage,
        onCompletion: @escaping (NSImage) -> Void,
        onCancel: @escaping () -> Void,
        radialTools: [DrawingTool] = AppSettings.shared.radialDrawingTools
    ) {
        self.image = image
        self.onCompletion = onCompletion
        self.onCancel = onCancel
        self.radialTools = radialTools.isEmpty ? DrawingTool.defaultRadialTools : radialTools
        self._editedImage = State(initialValue: image)
    }
    
    private static func defaultTool() -> DrawingTool {
        let settings = AppSettings.shared
        if let firstEnabled = settings.orderedEnabledEditingTools.first {
            return firstEnabled
        }
        return settings.orderedEditingTools.first ?? .pen
    }
    
    // MARK: - Undo/Redo Properties
    
    private var canUndo: Bool {
        !undoStack.isEmpty
    }
    
    private var canRedo: Bool {
        !redoStack.isEmpty
    }
    
    private var toolbarTools: [DrawingTool] {
        let orderedEnabled = settings.orderedEnabledEditingTools
        return orderedEnabled.isEmpty ? settings.orderedEditingTools : orderedEnabled
    }
    
    private func ensureValidSelectedTool() {
        let available = toolbarTools
        if !available.contains(selectedTool) {
            selectedTool = available.first ?? .pen
        }
    }

    // MARK: - Body View
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                // Drawing tools
                HStack(spacing: 6) {
                    ForEach(toolbarTools, id: \.self) { tool in
                        Button(action: { 
                            selectTool(tool)
                        }) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 16))
                                .foregroundColor(selectedTool == tool ? .white : .primary)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedTool == tool ? Color.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(tool.localizedName)
                    }
                }
                .padding(.leading, 4)
                
                Divider()
                    .frame(height: 36)
                
                // Color picker and stroke controls
                Group {
                    if selectedTool == .ocr {
                        HStack(spacing: 10) {
                            Text(NSLocalizedString("editor.ocr.hint", value: "拖拽选择区域进行 OCR", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button(NSLocalizedString("editor.ocr.full_image", value: "全图 OCR", comment: "")) {
                                ocrSelectedRect = nil
                                startOCR(region: nil)
                            }
                            .controlSize(.small)
                            .disabled(ocrIsProcessing)
                        }
                    } else {
                        HStack(spacing: 20) {
                            // Color picker
                            ColorPicker("", selection: $selectedColor)
                                .labelsHidden()
                                .frame(width: 28, height: 28)

                            // Stroke width/Text size
                            let sliderMax = sliderMaximum(for: selectedTool)
                            VStack(spacing: 2) {
                                Text(sliderLabel(for: selectedTool))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 4) {
                                    Text("1")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.secondary.opacity(0.6))
                                    Slider(value: $strokeWidth, in: 1...sliderMax, step: 1)
                                        .frame(width: 100)
                                    Text("\(Int(sliderMax))")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.secondary.opacity(0.6))
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 10) {
                    // Undo/Redo buttons
                    Group {
                        Button(action: undo) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 14))
                                .foregroundColor(canUndo ? .primary : .secondary)
                        }
                        .disabled(!canUndo)
                        .help(NSLocalizedString("common.undo", comment: ""))
                        
                        Button(action: redo) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 14))
                                .foregroundColor(canRedo ? .primary : .secondary)
                        }
                        .disabled(!canRedo)
                        .help(NSLocalizedString("common.redo", comment: ""))
                    }
                    
                    Divider()
                        .frame(height: 28)
                    
                    Group {
                        Button(NSLocalizedString("common.cancel", comment: "")) {
                            onCancel()
                        }
                        .keyboardShortcut(.escape)
                        .controlSize(.small)
                        
                        Button(NSLocalizedString("common.done", comment: "")) {
                            saveEditedImage()
                        }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .sheet(isPresented: $showTextInput) {
                VStack {
                        Text(NSLocalizedString("editor.text.title", comment: ""))
                            .font(.headline)
                            .padding()
                        
                        TextField(NSLocalizedString("editor.text.placeholder", comment: ""), text: $currentText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal)
                            .onSubmit {
                                confirmTextAndPreparePlacement()
                            }
                        
                        HStack {
                            Button(NSLocalizedString("common.cancel", comment: "")) {
                                showTextInput = false
                                currentText = ""
                                waitingForTextPlacement = false
                                // 如果之前选择了文字工具，切换回画笔工具
                                if selectedTool == .text {
                                    selectedTool = .pen
                                    // 确保画笔粗细在合理范围内
                                    strokeWidth = min(strokeWidth, sliderMaximum(for: selectedTool))
                                }
                            }
                            .padding()
                            
                            Button(NSLocalizedString("common.confirm", comment: "")) {
                                confirmTextAndPreparePlacement()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding()
                        }
                    }
                    .frame(width: 300, height: 200)
            }
            
            Divider()
            
            // Image editing area
            GeometryReader { geometry in
                let inset: CGFloat = 6
                let canvasSize = CGSize(
                    width: max(0, geometry.size.width - inset * 2),
                    height: max(0, geometry.size.height - inset * 2)
                )

                let previewRegion = currentMosaicPreviewRegion()
                let ocrPreviewRect = currentOCRPreviewRect()
                let baseImage = previewRegion != nil
                    ? renderMosaicImage(additionalRegions: [previewRegion!])
                    : editedImage
                
                ZStack {
                    // Background image
                    Image(nsImage: baseImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    
                    // Mosaic live preview outline
                    if let previewRegion {
                        let displayRect = convertImageRectToDisplayRect(
                            previewRegion.rect,
                            canvasSize: canvasSize,
                            imageSize: editedImage.size
                        )
                        Path { path in
                            path.addRect(displayRect)
                        }
                        .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                        .allowsHitTesting(false)
                    }

                    // OCR selection outline (live + last selection)
                    if selectedTool == .ocr, let rectToShow = ocrPreviewRect ?? ocrSelectedRect {
                        let displayRect = convertImageRectToDisplayRect(
                            rectToShow,
                            canvasSize: canvasSize,
                            imageSize: editedImage.size
                        )
                        Path { path in
                            path.addRect(displayRect)
                        }
                        .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                        .allowsHitTesting(false)
                    }

                    if selectedTool == .ocr, ocrIsProcessing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .allowsHitTesting(false)
                    }

                    // Drawing overlay
                    Canvas { context, size in
                        // Calculate image display properties
                        let imageSize = editedImage.size
                        let aspectRatio = imageSize.width / imageSize.height
                        let canvasAspectRatio = size.width / size.height
                        
                        // Determine the displayed image size before scaling
                        let displaySize: CGSize
                        if aspectRatio > canvasAspectRatio {
                            // Image is wider, fit to width
                            displaySize = CGSize(width: size.width, height: size.width / aspectRatio)
                        } else {
                            // Image is taller, fit to height
                            displaySize = CGSize(width: size.height * aspectRatio, height: size.height)
                        }
                        
                        // Calculate offset to center the image
                        let offsetX = (size.width - displaySize.width) / 2
                        let offsetY = (size.height - displaySize.height) / 2
                        
                        // Calculate the scale factor from image coordinates to display coordinates
                        let imageToDisplayScale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
                        
                        // Draw all paths with proper transformation
                        for drawingPath in drawingPaths {
                            var contextCopy = context
                            contextCopy.translateBy(x: offsetX, y: offsetY)
                            contextCopy.scaleBy(x: imageToDisplayScale, y: imageToDisplayScale)
                            let width = drawingPath.tool == .mosaic ? 1.5 : drawingPath.strokeWidth
                            contextCopy.stroke(drawingPath.path, with: .color(drawingPath.color), lineWidth: width)
                        }
                        
                        // Draw the current path being drawn
                        if let currentPath = currentPath, currentPath.tool != .ocr {
                            var contextCopy = context
                            contextCopy.translateBy(x: offsetX, y: offsetY)
                            contextCopy.scaleBy(x: imageToDisplayScale, y: imageToDisplayScale)
                            let width = currentPath.tool == .mosaic ? 1.5 : currentPath.strokeWidth
                            contextCopy.stroke(currentPath.path, with: .color(currentPath.color), lineWidth: width)
                        }
                    }
                    
                    // Text inputs overlay
                    ForEach(Array(textInputs.enumerated()), id: \.element.id) { index, textInput in
                        let textPositionView = calculateTextPosition(
                            for: textInput, 
                            canvasSize: canvasSize, 
                            with: editedImage.size
                        )
                        
                        Text(textInput.text)
                            .font(.system(size: textInput.fontSize))
                            .foregroundColor(textInput.color)
                            .position(x: textPositionView.x, y: textPositionView.y)
                    }
                    
                    // Preview text for placement
                    if selectedTool == .text && waitingForTextPlacement && !currentText.isEmpty {
                        Text(currentText)
                            .font(.system(size: strokeWidth * 4))
                            .foregroundColor(selectedColor.opacity(0.5))
                            .position(x: mousePosition.x, y: mousePosition.y)
                    }
                }
                // Capture right-click gestures for radial tool selection
                .overlay {
                    if settings.radialWheelEnabled {
                        RightClickCaptureView(
                            onRightDown: { point in
                                radialCenter = point
                                radialCurrentPoint = point
                            },
                            onRightDrag: { point in
                                radialCurrentPoint = point
                            },
                            onRightUp: { point in
                                radialCurrentPoint = point
                                finalizeRadialSelection()
                            }
                        )
                    }
                }
                // Radial palette overlay
                .overlay {
                    if settings.radialWheelEnabled,
                       let center = radialCenter,
                       let current = radialCurrentPoint {
                        RadialToolPalette(
                            center: center,
                            current: current,
                            tools: radialTools,
                            deadZoneRadius: 30,
                            toolNameProvider: toolName(for:),
                            selectedIndex: radialSelectionIndex()
                        )
                    }
                }
                .clipped()
                .contentShape(Rectangle()) // Prevent window dragging in this area
                .onTapGesture { location in
                    // Handle tap for text placement
                    if selectedTool == .text && waitingForTextPlacement && !currentText.isEmpty {
                        placeTextAt(location: location, canvasSize: canvasSize)
                    }
                }
                .onHover { isHovering in
                    if isHovering && selectedTool == .text && waitingForTextPlacement {
                        // We'll handle position tracking in the gesture below
                    }
                }
                .gesture(
                    // Track mouse movement for text preview
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Always track mouse position when using text tool
                            if selectedTool == .text && waitingForTextPlacement {
                                mousePosition = value.location
                                previewTextPosition = value.location
                            }
                            // Handle drawing for other tools
                            if selectedTool != .text {
                                handleDragChanged(value: value, canvasSize: canvasSize)
                            }
                        }
                        .onEnded { value in
                            // Handle text placement on click
                            if selectedTool == .text && waitingForTextPlacement {
                                placeTextAt(location: value.location, canvasSize: canvasSize)
                            } else if selectedTool != .text {
                                handleDragEnded(value: value, canvasSize: canvasSize)
                            }
                        }
                )
                .onChange(of: settings.radialWheelEnabled) { _, isEnabled in
                    if !isEnabled {
                        radialCenter = nil
                        radialCurrentPoint = nil
                    }
                }
                .onAppear {
                    // Setup keyboard shortcuts for undo/redo
                    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                        // Handle plain Return/Enter to finish editing
                        if modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
                            if !showTextInput && !showOCRResult && !waitingForTextPlacement {
                                saveEditedImage()
                                return nil
                            }
                        }

                        if modifiers.contains(.command) {
                            switch event.charactersIgnoringModifiers {
                            case "z":
                                if modifiers.contains(.shift) {
                                    redo()
                                } else {
                                    undo()
                                }
                                return nil
                            case "y":
                                redo()
                                return nil
                            default:
                                break
                            }
                        }
                        return event
                    }
                }
                .onDisappear {
                    // Clean up keyboard monitor to prevent memory leak
                    if let monitor = keyboardMonitor {
                        NSEvent.removeMonitor(monitor)
                        keyboardMonitor = nil
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .onAppear {
            ensureValidSelectedTool()
        }
        .onChangeCompat(of: settings.enabledEditingTools) {
            ensureValidSelectedTool()
        }
        .sheet(isPresented: $showOCRResult) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(NSLocalizedString("editor.ocr.title", value: "OCR", comment: ""))
                        .font(.headline)
                    Spacer()
                }

                Group {
                    if ocrIsProcessing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.large)
                            Text(NSLocalizedString("editor.ocr.processing", value: "识别中…", comment: ""))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if ocrResultText.isEmpty {
                        Text(NSLocalizedString("editor.ocr.empty", value: "未识别到文字", comment: ""))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        TextEditor(text: $ocrResultText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 240)
                    }
                }

                HStack {
                    Button(NSLocalizedString("common.done", comment: "")) {
                        showOCRResult = false
                    }
                    Spacer()
                    Button(NSLocalizedString("editor.ocr.copy", value: "复制", comment: "")) {
                        copyOCRResultToPasteboard()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ocrIsProcessing || ocrResultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 520, height: 360)
        }
        .alert(NSLocalizedString("editor.ocr.title", value: "OCR", comment: ""), isPresented: $showOCRError) {
            Button(NSLocalizedString("common.ok", comment: "")) {}
        } message: {
            Text(ocrErrorMessage)
        }
    }
    
    private func handleDragChanged(value: DragGesture.Value, canvasSize: CGSize) {
        let location = value.location
        let size = canvasSize
        
        // Calculate image display properties (same as in Canvas)
        let imageSize = editedImage.size
        let displayRect = imageDisplayRect(canvasSize: size, imageSize: imageSize)
        guard displayRect.width > 0, displayRect.height > 0 else { return }
        
        // Clamp pointer to image display rect to avoid drawing on background
        let clampedLocation = CGPoint(
            x: min(max(location.x, displayRect.minX), displayRect.maxX),
            y: min(max(location.y, displayRect.minY), displayRect.maxY)
        )
        if clampedLocation != location && !isDrawing {
            // If starting outside image, ignore the drag
            return
        }
        
        // Calculate the scale factor from image coordinates to display coordinates
        let imageToDisplayScale = min(displayRect.width / imageSize.width, displayRect.height / imageSize.height)
        
        // Transform screen coordinates to original image coordinates
        let imageLocation = CGPoint(
            x: (clampedLocation.x - displayRect.minX) / imageToDisplayScale,
            y: (clampedLocation.y - displayRect.minY) / imageToDisplayScale
        )
        
        // Handle text tool separately
        if selectedTool == .text {
            // For text tool, update preview position if waiting for placement
            if waitingForTextPlacement {
                previewTextPosition = location
            }
            return
        }
        
        if !isDrawing {
            isDrawing = true
            var newPath = Path()
            
            switch selectedTool {
            case .pen:
                newPath.move(to: imageLocation)
            case .line:
                newPath.move(to: imageLocation)
            case .rectangle:
                newPath.move(to: imageLocation)
            case .circle:
                newPath.move(to: imageLocation)
            case .arrow:
                newPath.move(to: imageLocation)
            case .mosaic:
                newPath.move(to: imageLocation)
            case .text:
                newPath.move(to: imageLocation)
            case .ocr:
                newPath.move(to: imageLocation)
            }
            
            currentPath = DrawingPath(
                path: newPath,
                color: selectedColor,
                strokeWidth: strokeWidth,
                tool: selectedTool,
                startPoint: imageLocation
            )
        } else if var path = currentPath {
            var updatedPath = Path()
            
            switch selectedTool {
            case .pen:
                updatedPath = Path { path in
                    path.addPath(currentPath!.path)
                    path.addLine(to: imageLocation)
                }
            case .line:
                updatedPath = Path { path in
                    path.move(to: currentPath!.startPoint)
                    path.addLine(to: imageLocation)
                }
            case .rectangle:
                let startPoint = currentPath!.startPoint
                let rect = CGRect(
                    x: min(startPoint.x, imageLocation.x),
                    y: min(startPoint.y, imageLocation.y),
                    width: abs(imageLocation.x - startPoint.x),
                    height: abs(imageLocation.y - startPoint.y)
                )
                updatedPath = Path { path in
                    path.addRect(rect)
                }
            case .circle:
                let startPoint = currentPath!.startPoint
                let radius = sqrt(pow(imageLocation.x - startPoint.x, 2) + pow(imageLocation.y - startPoint.y, 2))
                updatedPath = Path { path in
                    path.addEllipse(in: CGRect(
                        x: startPoint.x - radius,
                        y: startPoint.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                }
            case .arrow:
                let startPoint = currentPath!.startPoint
                updatedPath = createArrowPath(from: startPoint, to: imageLocation)
            case .mosaic:
                let startPoint = currentPath!.startPoint
                let rect = CGRect(
                    x: min(startPoint.x, imageLocation.x),
                    y: min(startPoint.y, imageLocation.y),
                    width: abs(imageLocation.x - startPoint.x),
                    height: abs(imageLocation.y - startPoint.y)
                )
                updatedPath = Path { path in
                    path.addRect(rect)
                }
            case .text:
                updatedPath = currentPath!.path
            case .ocr:
                let startPoint = currentPath!.startPoint
                let rect = CGRect(
                    x: min(startPoint.x, imageLocation.x),
                    y: min(startPoint.y, imageLocation.y),
                    width: abs(imageLocation.x - startPoint.x),
                    height: abs(imageLocation.y - startPoint.y)
                )
                updatedPath = Path { path in
                    path.addRect(rect)
                }
            }
            
            path.path = updatedPath
            currentPath = path
        }
    }
    
    private func createArrowPath(from startPoint: CGPoint, to endPoint: CGPoint) -> Path {
        let arrowLength: CGFloat = 15
        let arrowAngle: CGFloat = .pi / 6
        
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        
        let arrowPoint1 = CGPoint(
            x: endPoint.x - arrowLength * cos(angle - arrowAngle),
            y: endPoint.y - arrowLength * sin(angle - arrowAngle)
        )
        
        let arrowPoint2 = CGPoint(
            x: endPoint.x - arrowLength * cos(angle + arrowAngle),
            y: endPoint.y - arrowLength * sin(angle + arrowAngle)
        )
        
        var path = Path()
        path.move(to: startPoint)
        path.addLine(to: endPoint)
        path.move(to: endPoint)
        path.addLine(to: arrowPoint1)
        path.move(to: endPoint)
        path.addLine(to: arrowPoint2)
        
        return path
    }
    
    private func handleDragEnded(value: DragGesture.Value, canvasSize: CGSize) {
        let location = value.location
        let size = canvasSize
        
        // Calculate the image position and scale in the canvas
        let imageSize = editedImage.size
        let displayRect = imageDisplayRect(canvasSize: size, imageSize: imageSize)
        guard displayRect.width > 0, displayRect.height > 0 else { return }
        
        let clampedLocation = CGPoint(
            x: min(max(location.x, displayRect.minX), displayRect.maxX),
            y: min(max(location.y, displayRect.minY), displayRect.maxY)
        )
        if clampedLocation != location && !isDrawing {
            return
        }
        
        let imageToDisplayScale = min(displayRect.width / imageSize.width, displayRect.height / imageSize.height)
        
        // Transform screen coordinates to original image coordinates
        let imageLocation = CGPoint(
            x: (clampedLocation.x - displayRect.minX) / imageToDisplayScale,
            y: (clampedLocation.y - displayRect.minY) / imageToDisplayScale
        )
        
        if selectedTool == .text {
            // For text tool, if we're waiting for placement, place the text
            if waitingForTextPlacement {
                placeTextAt(location: location, canvasSize: size)
            }
            return
        }
        
        if let path = currentPath {
            switch selectedTool {
            case .mosaic:
                let startPoint = path.startPoint
                let rect = CGRect(
                    x: min(startPoint.x, imageLocation.x),
                    y: min(startPoint.y, imageLocation.y),
                    width: abs(imageLocation.x - startPoint.x),
                    height: abs(imageLocation.y - startPoint.y)
                )
                let clampedRect = clampRectToImage(rect: rect, imageSize: imageSize)

                if clampedRect.width > 1 && clampedRect.height > 1 {
                    let region = MosaicRegion(rect: clampedRect, scale: mosaicScale(from: strokeWidth))
                    mosaicRegions.append(region)
                    undoStack.append(.addMosaic(region))
                    saveState()
                    refreshEditedImage()
                }
            case .ocr:
                if ocrIsProcessing { break }
                let startPoint = path.startPoint
                let rect = CGRect(
                    x: min(startPoint.x, imageLocation.x),
                    y: min(startPoint.y, imageLocation.y),
                    width: abs(imageLocation.x - startPoint.x),
                    height: abs(imageLocation.y - startPoint.y)
                )
                let clampedRect = clampRectToImage(rect: rect, imageSize: imageSize)
                if clampedRect.width > 1 && clampedRect.height > 1 {
                    ocrSelectedRect = clampedRect
                    startOCR(region: clampedRect)
                }
            default:
                drawingPaths.append(path)
                undoStack.append(.addPath(path))
                saveState()
            }
        }
        currentPath = nil
        isDrawing = false
    }
    
    private func confirmTextAndPreparePlacement() {
        if !currentText.isEmpty {
            waitingForTextPlacement = true
            showTextInput = false
            // Initialize mouse position to center if not set yet
            mousePosition = CGPoint(x: 400, y: 300) // Default center position
            // 保持文字工具选中状态，但改为放置模式
            // 不需要改变 selectedTool，因为用户已经在使用文字工具
        } else {
            showTextInput = false
            waitingForTextPlacement = false
            // 如果没有输入文字，切换回画笔工具
            selectedTool = .pen
            // 确保画笔粗细在合理范围内
            strokeWidth = min(strokeWidth, sliderMaximum(for: selectedTool))
        }
    }
    
    private func placeTextAt(location: CGPoint, canvasSize: CGSize) {
        // Convert screen coordinates to image coordinates
        let imageSize = editedImage.size
        let displayRect = imageDisplayRect(canvasSize: canvasSize, imageSize: imageSize)
        guard displayRect.width > 0, displayRect.height > 0 else { return }

        let clampedLocation = CGPoint(
            x: min(max(location.x, displayRect.minX), displayRect.maxX),
            y: min(max(location.y, displayRect.minY), displayRect.maxY)
        )
        let imageToDisplayScale = min(displayRect.width / imageSize.width, displayRect.height / imageSize.height)
        
        let imageLocation = CGPoint(
            x: (clampedLocation.x - displayRect.minX) / imageToDisplayScale,
            y: (clampedLocation.y - displayRect.minY) / imageToDisplayScale
        )
        
        let newText = TextInput(
            text: currentText,
            location: imageLocation,
            color: selectedColor,
            fontSize: strokeWidth * 4
        )
        textInputs.append(newText)
        undoStack.append(.addText(newText))
        saveState()
        
        // Reset state
        currentText = ""
        waitingForTextPlacement = false
        
        // Switch back to pen tool after text placement
        selectedTool = .pen
        // 确保画笔粗细在合理范围内
        strokeWidth = min(strokeWidth, sliderMaximum(for: selectedTool))
    }
    
    private func addTextAtLocation() {
        // This method is kept for backward compatibility but no longer used
        // New text placement is handled by placeTextAt method
        if !currentText.isEmpty {
            let newText = TextInput(
                text: currentText,
                location: textLocation,
                color: selectedColor,
                fontSize: 16
            )
            textInputs.append(newText)
            undoStack.append(.addText(newText))
            saveState()
        }
        showTextInput = false
        currentText = ""
    }
    
    private func sliderLabel(for tool: DrawingTool) -> String {
        switch tool {
        case .text:
            return NSLocalizedString("editor.text.size", comment: "")
        case .mosaic:
            return NSLocalizedString("editor.mosaic.size", comment: "")
        case .ocr:
            return NSLocalizedString("editor.ocr.hint", value: "拖拽选择区域进行 OCR", comment: "")
        default:
            return NSLocalizedString("editor.stroke.width", comment: "")
        }
    }
    
    private func sliderMaximum(for tool: DrawingTool) -> Double {
        switch tool {
        case .text, .mosaic:
            return 50
        case .ocr:
            return 10
        default:
            return 10
        }
    }
    
    private func selectTool(_ newTool: DrawingTool) {
        let previousTool = selectedTool
        
        if newTool == .text && previousTool != .text {
            strokeWidth = max(strokeWidth, 2)
        } else if newTool != .text && previousTool == .text {
            if showTextInput {
                showTextInput = false
                currentText = ""
            }
            if waitingForTextPlacement {
                waitingForTextPlacement = false
            }
        }

        if previousTool == .ocr && newTool != .ocr {
            ocrSelectedRect = nil
        }
        if newTool == .ocr && previousTool != .ocr {
            ocrResultText = ""
        }
        
        let maxStroke = sliderMaximum(for: newTool)
        strokeWidth = min(maxStroke, max(1, strokeWidth))
        
        selectedTool = newTool
        
        if newTool == .text {
            showTextInput = true
            waitingForTextPlacement = false
            previewTextPosition = nil
        }
    }
    
    // MARK: - Radial tool selector
    
    private func finalizeRadialSelection() {
        defer {
            radialCenter = nil
            radialCurrentPoint = nil
        }
        guard settings.radialWheelEnabled else { return }
        guard let index = radialSelectionIndex() else { return }
        let tool = radialTools[index]
        selectTool(tool)
    }
    
    private func radialSelectionIndex() -> Int? {
        guard let center = radialCenter, let current = radialCurrentPoint else { return nil }
        let dx = current.x - center.x
        let dy = center.y - current.y // flip Y so up is positive
        let distance = hypot(dx, dy)
        let deadZone: CGFloat = 30
        guard distance > deadZone else { return nil }
        // Angle in range [0, 2π), with 0 pointing up, clockwise increase
        let angle = atan2(dy, dx)
        let twoPi = CGFloat.pi * 2
        var angleFromTop = (CGFloat.pi / 2) - angle
        if angleFromTop < 0 { angleFromTop += twoPi }
        let sectorAngle = twoPi / CGFloat(max(1, radialTools.count))
        let index = Int(floor(angleFromTop / sectorAngle)) % radialTools.count
        return index
    }
    
    private func toolName(for tool: DrawingTool) -> String {
        switch tool {
        case .pen: return NSLocalizedString("tool.pen", comment: "")
        case .line: return NSLocalizedString("tool.line", comment: "")
        case .rectangle: return NSLocalizedString("tool.rectangle", comment: "")
        case .circle: return NSLocalizedString("tool.circle", comment: "")
        case .arrow: return NSLocalizedString("tool.arrow", comment: "")
        case .mosaic: return NSLocalizedString("tool.mosaic", comment: "")
        case .text: return NSLocalizedString("tool.text", comment: "")
        case .ocr: return NSLocalizedString("tool.ocr", value: "OCR", comment: "")
        }
    }
    
    private func saveEditedImage() {
        // Create a new image with drawings
        let mosaicBaseImage = renderMosaicImage()
        let renderer = ImageRenderer(content: 
            ZStack {
                Image(nsImage: mosaicBaseImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                
                Canvas { context, size in
                    for path in drawingPaths {
                        context.stroke(path.path, with: .color(path.color), lineWidth: path.strokeWidth)
                    }
                }
                
                // Render text inputs
                ForEach(Array(textInputs.enumerated()), id: \.element.id) { index, textInput in
                    Text(textInput.text)
                        .font(.system(size: textInput.fontSize))
                        .foregroundColor(textInput.color)
                        .position(textInput.location)
                }
            }
        )
        
        if let nsImage = renderer.nsImage {
            onCompletion(nsImage)
        }
    }
    
    // MARK: - Mosaic Helpers
    
    private func refreshEditedImage() {
        editedImage = renderMosaicImage()
    }
    
    private func renderMosaicImage(additionalRegions: [MosaicRegion] = []) -> NSImage {
        let regions = mosaicRegions + additionalRegions
        guard !regions.isEmpty else { return image }
        guard
            let tiffData = image.tiffRepresentation,
            let ciImage = CIImage(data: tiffData)
        else {
            return image
        }
        
        let baseSize = image.size
        var outputImage = ciImage
        
        for region in regions {
            let ciRect = ciRectFromImageRect(region.rect, imageSize: baseSize, ciExtent: ciImage.extent)
            guard ciRect.width > 0, ciRect.height > 0 else { continue }
            
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = outputImage
            pixellate.scale = Float(max(1, region.scale))
            pixellate.center = CGPoint(x: ciRect.midX, y: ciRect.midY)
            guard let pixellated = pixellate.outputImage?.cropped(to: outputImage.extent) else { continue }
            
            guard let mask = createMask(for: ciRect, extent: outputImage.extent) else { continue }
            
            if let blended = CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: pixellated,
                    kCIInputBackgroundImageKey: outputImage,
                    kCIInputMaskImageKey: mask
                ]
            )?.outputImage {
                outputImage = blended
            }
        }
        
        guard let cgImage = ciContext.createCGImage(outputImage, from: ciImage.extent) else {
            return image
        }
        
        return NSImage(cgImage: cgImage, size: image.size)
    }
    
    private func createMask(for rect: CGRect, extent: CGRect) -> CIImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let black = CIImage(color: .black).cropped(to: extent)
        let white = CIImage(color: .white).cropped(to: rect)
        return white.composited(over: black)
    }
    
    private func ciRectFromImageRect(_ rect: CGRect, imageSize: CGSize, ciExtent: CGRect) -> CGRect {
        let scaleX = ciExtent.width / imageSize.width
        let scaleY = ciExtent.height / imageSize.height
        return CGRect(
            x: rect.origin.x * scaleX,
            y: (imageSize.height - rect.origin.y - rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
    
    private func clampRectToImage(rect: CGRect, imageSize: CGSize) -> CGRect {
        let minX = max(0, min(rect.origin.x, imageSize.width))
        let minY = max(0, min(rect.origin.y, imageSize.height))
        let maxX = min(rect.maxX, imageSize.width)
        let maxY = min(rect.maxY, imageSize.height)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
    
    private func mosaicScale(from strokeWidth: Double) -> Double {
        max(4, strokeWidth * 4)
    }
    
    private func currentMosaicPreviewRegion() -> MosaicRegion? {
        guard selectedTool == .mosaic, isDrawing, let path = currentPath else { return nil }
        let rect = clampRectToImage(rect: path.path.boundingRect, imageSize: editedImage.size)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return MosaicRegion(rect: rect, scale: mosaicScale(from: strokeWidth))
    }

    private func currentOCRPreviewRect() -> CGRect? {
        guard selectedTool == .ocr, isDrawing, let path = currentPath else { return nil }
        let rect = clampRectToImage(rect: path.path.boundingRect, imageSize: editedImage.size)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    private func startOCR(region: CGRect?) {
        ocrIsProcessing = true
        ocrResultText = ""
        showOCRResult = true

        Task { @MainActor in
            defer { ocrIsProcessing = false }
            do {
                let text = try await OCRService.recognizeText(
                    in: editedImage,
                    region: region,
                    preferredLanguages: settings.ocrRecognitionLanguages
                )
                ocrResultText = text
                copyOCRResultToPasteboard()
            } catch {
                showOCRResult = false
                ocrErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showOCRError = true
            }
        }
    }

    private func copyOCRResultToPasteboard() {
        let content = ocrResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func convertImageRectToDisplayRect(_ rect: CGRect, canvasSize: CGSize, imageSize: CGSize) -> CGRect {
        let aspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = canvasSize.width / canvasSize.height
        
        let displaySize: CGSize
        if aspectRatio > canvasAspectRatio {
            displaySize = CGSize(width: canvasSize.width, height: canvasSize.width / aspectRatio)
        } else {
            displaySize = CGSize(width: canvasSize.height * aspectRatio, height: canvasSize.height)
        }
        
        let offsetX = (canvasSize.width - displaySize.width) / 2
        let offsetY = (canvasSize.height - displaySize.height) / 2
        let imageToDisplayScale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        
        return CGRect(
            x: offsetX + rect.origin.x * imageToDisplayScale,
            y: offsetY + rect.origin.y * imageToDisplayScale,
            width: rect.width * imageToDisplayScale,
            height: rect.height * imageToDisplayScale
        )
    }

    /// Returns the rect where the image is displayed inside the canvas (centered, aspect fit).
    private func imageDisplayRect(canvasSize: CGSize, imageSize: CGSize) -> CGRect {
        let aspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = canvasSize.width / canvasSize.height

        let displaySize: CGSize
        if aspectRatio > canvasAspectRatio {
            displaySize = CGSize(width: canvasSize.width, height: canvasSize.width / aspectRatio)
        } else {
            displaySize = CGSize(width: canvasSize.height * aspectRatio, height: canvasSize.height)
        }

        let offsetX = (canvasSize.width - displaySize.width) / 2
        let offsetY = (canvasSize.height - displaySize.height) / 2

        return CGRect(origin: CGPoint(x: offsetX, y: offsetY), size: displaySize)
    }
    
    // MARK: - Undo/Redo Functions
    
    private func undo() {
        guard let lastAction = undoStack.popLast() else { return }
        
        switch lastAction {
        case .addPath(let path):
            if let index = drawingPaths.firstIndex(where: { $0.id == path.id }) {
                drawingPaths.remove(at: index)
            }
        case .removePath(let path, let index):
            drawingPaths.insert(path, at: index)
        case .addText(let text):
            if let index = textInputs.firstIndex(where: { $0.id == text.id }) {
                textInputs.remove(at: index)
            }
        case .removeText(let text, let index):
            textInputs.insert(text, at: index)
        case .addMosaic(let region):
            if let index = mosaicRegions.firstIndex(where: { $0.id == region.id }) {
                mosaicRegions.remove(at: index)
                refreshEditedImage()
            }
        case .removeMosaic(let region, let index):
            mosaicRegions.insert(region, at: index)
            refreshEditedImage()
        }
        
        redoStack.append(lastAction)
    }
    
    private func redo() {
        guard let actionToRedo = redoStack.popLast() else { return }
        
        switch actionToRedo {
        case .addPath(let path):
            drawingPaths.append(path)
        case .removePath(let path, _):
            if let index = drawingPaths.firstIndex(where: { $0.id == path.id }) {
                drawingPaths.remove(at: index)
            }
        case .addText(let text):
            textInputs.append(text)
        case .removeText(let text, _):
            if let index = textInputs.firstIndex(where: { $0.id == text.id }) {
                textInputs.remove(at: index)
            }
        case .addMosaic(let region):
            mosaicRegions.append(region)
            refreshEditedImage()
        case .removeMosaic(let region, _):
            if let index = mosaicRegions.firstIndex(where: { $0.id == region.id }) {
                mosaicRegions.remove(at: index)
                refreshEditedImage()
            }
        }
        
        undoStack.append(actionToRedo)
    }
    
    private func calculateTextPosition(for textInput: TextInput, canvasSize: CGSize, with imageSize: CGSize) -> CGPoint {
        let aspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = canvasSize.width / canvasSize.height
        
        let displaySize: CGSize
        if aspectRatio > canvasAspectRatio {
            displaySize = CGSize(width: canvasSize.width, height: canvasSize.width / aspectRatio)
        } else {
            displaySize = CGSize(width: canvasSize.height * aspectRatio, height: canvasSize.height)
        }
        
        let offsetX = (canvasSize.width - displaySize.width) / 2
        let offsetY = (canvasSize.height - displaySize.height) / 2
        let imageToDisplayScale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        
        // Convert stored image coordinates to screen coordinates
        let screenX = offsetX + textInput.location.x * imageToDisplayScale
        let screenY = offsetY + textInput.location.y * imageToDisplayScale
        
        return CGPoint(x: screenX, y: screenY)
    }
    
    private func saveState() {
        // Clear redo stack when new action is performed
        redoStack.removeAll()
    }
}

// MARK: - Edit Action Enum

enum EditAction {
    case addPath(DrawingPath)
    case removePath(DrawingPath, index: Int)
    case addText(TextInput)
    case removeText(TextInput, index: Int)
    case addMosaic(MosaicRegion)
    case removeMosaic(MosaicRegion, index: Int)
}

enum DrawingTool: String, CaseIterable, Codable {
    case pen
    case line
    case rectangle
    case circle
    case arrow
    case mosaic
    case text
    case ocr
    
    static var defaultRadialTools: [DrawingTool] { [.arrow, .rectangle, .circle, .line] }
    static var defaultRadialIdentifiers: [String] { defaultRadialTools.map { $0.identifier } }
    
    static func tools(fromIdentifiers identifiers: [String], allowed: [DrawingTool]? = nil) -> [DrawingTool] {
        let allowedSet = allowed.map { Set($0) }
        var seen = Set<DrawingTool>()
        var tools: [DrawingTool] = []
        
        for identifier in identifiers {
            guard let tool = DrawingTool(identifier: identifier),
                  (allowedSet == nil || allowedSet!.contains(tool)),
                  !seen.contains(tool) else { continue }
            seen.insert(tool)
            tools.append(tool)
            
            if tools.count >= 4 {
                break
            }
        }
        
        if tools.isEmpty {
            let fallback = allowed ?? defaultRadialTools
            for tool in fallback where (allowedSet == nil || allowedSet!.contains(tool)) && !seen.contains(tool) {
                tools.append(tool)
                seen.insert(tool)
                if tools.count >= 4 { break }
            }
        }
        
        return tools
    }
    
    init?(identifier: String) {
        switch identifier {
        case "pen": self = .pen
        case "line": self = .line
        case "rectangle": self = .rectangle
        case "circle": self = .circle
        case "arrow": self = .arrow
        case "mosaic": self = .mosaic
        case "text": self = .text
        case "ocr": self = .ocr
        default: return nil
        }
    }
    
    var identifier: String {
        switch self {
        case .pen: return "pen"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arrow: return "arrow"
        case .mosaic: return "mosaic"
        case .text: return "text"
        case .ocr: return "ocr"
        }
    }
    
    var systemImage: String {
        switch self {
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arrow: return "arrow.right"
        case .mosaic: return "square.grid.3x3"
        case .text: return "textformat"
        case .ocr: return "text.magnifyingglass"
        }
    }
    
    var localizedName: String {
        switch self {
        case .pen: return NSLocalizedString("tool.pen", comment: "")
        case .line: return NSLocalizedString("tool.line", comment: "")
        case .rectangle: return NSLocalizedString("tool.rectangle", comment: "")
        case .circle: return NSLocalizedString("tool.circle", comment: "")
        case .arrow: return NSLocalizedString("tool.arrow", comment: "")
        case .mosaic: return NSLocalizedString("tool.mosaic", comment: "")
        case .text: return NSLocalizedString("tool.text", comment: "")
        case .ocr: return NSLocalizedString("tool.ocr", value: "OCR", comment: "")
        }
    }
}

struct DrawingPath: Identifiable {
    var id = UUID()
    var path: Path
    let color: Color
    let strokeWidth: Double
    let tool: DrawingTool
    let startPoint: CGPoint
}

struct MosaicRegion: Identifiable {
    var id = UUID()
    let rect: CGRect
    let scale: Double
}

struct TextInput: Identifiable {
    var id = UUID()
    let text: String
    let location: CGPoint
    let color: Color
    let fontSize: CGFloat
}

// MARK: - Radial Tool Palette Views

struct RadialToolPalette: View {
    let center: CGPoint
    let current: CGPoint
    let tools: [DrawingTool]
    let deadZoneRadius: CGFloat
    let toolNameProvider: (DrawingTool) -> String
    let selectedIndex: Int?
    
    var body: some View {
        let radius: CGFloat = 86
        let labelRadius: CGFloat = (deadZoneRadius + radius) / 2 + 8
        let twoPi = CGFloat.pi * 2
        let sectorAngle = twoPi / CGFloat(max(1, tools.count))
        let frameSize = (max(labelRadius, radius) + 22) * 2
        let localCenter = CGPoint(x: frameSize / 2, y: frameSize / 2)
        let highlightVector = CGPoint(x: current.x - center.x, y: current.y - center.y)
        let maxOffset = radius - 12
        let clampedVector = CGPoint(
            x: max(-maxOffset, min(maxOffset, highlightVector.x)),
            y: max(-maxOffset, min(maxOffset, highlightVector.y))
        )
        let highlightPoint = CGPoint(x: localCenter.x + clampedVector.x, y: localCenter.y + clampedVector.y)
        let highlightUnit = UnitPoint(x: highlightPoint.x / frameSize, y: highlightPoint.y / frameSize)
        
        ZStack {
            // Moving glow that follows the pointer
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.accentColor.opacity(0.4),
                            Color.accentColor.opacity(0.12),
                            Color.accentColor.opacity(0.0)
                        ]),
                        center: highlightUnit,
                        startRadius: 6,
                        endRadius: radius + 36
                    )
                )
                .blur(radius: 6)
                .blendMode(.plusLighter)
                .frame(width: frameSize, height: frameSize)
                .mask(
                    Circle()
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: frameSize / 2, y: frameSize / 2)
                )
                .allowsHitTesting(false)

            // Sectors and labels
            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                let sectorStart = -CGFloat.pi / 2 + sectorAngle * CGFloat(index)
                let sectorEnd = sectorStart + sectorAngle
                let midAngle = (sectorStart + sectorEnd) / 2
                let isSelected = selectedIndex == index
                
                SectorShape(startAngle: sectorStart, endAngle: sectorEnd, innerRadius: deadZoneRadius, outerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        SectorShape(startAngle: sectorStart, endAngle: sectorEnd, innerRadius: deadZoneRadius, outerRadius: radius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        SectorShape(startAngle: sectorStart, endAngle: sectorEnd, innerRadius: deadZoneRadius, outerRadius: radius)
                            .fill(Color.accentColor.opacity(isSelected ? 0.28 : 0.1))
                            .blendMode(.plusLighter)
                    )
                    .overlay(
                        SectorShape(startAngle: sectorStart, endAngle: sectorEnd, innerRadius: deadZoneRadius, outerRadius: radius)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.9)
                    )
                
                let labelX = localCenter.x + cos(midAngle) * labelRadius
                let labelY = localCenter.y + sin(midAngle) * labelRadius
                VStack(spacing: 4) {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(toolNameProvider(tool))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.thinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                        )
                )
                .shadow(color: Color.black.opacity(isSelected ? 0.25 : 0.12), radius: isSelected ? 8 : 5, y: isSelected ? 4 : 2)
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.quickSpring, value: isSelected)
                .position(x: labelX, y: labelY)

                // Divider line at sector boundary
                Path { path in
                    path.move(to: CGPoint(x: localCenter.x + cos(sectorStart) * deadZoneRadius,
                                          y: localCenter.y + sin(sectorStart) * deadZoneRadius))
                    path.addLine(to: CGPoint(x: localCenter.x + cos(sectorStart) * radius,
                                             y: localCenter.y + sin(sectorStart) * radius))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
            
            // Center marker
            Circle()
                .fill(.regularMaterial)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.7),
                                    Color.white.opacity(0.25)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.4
                        )
                )
                .shadow(color: Color.black.opacity(0.2), radius: 6, y: 4)
                .frame(width: deadZoneRadius * 2 + 12, height: deadZoneRadius * 2 + 12)
        }
        .frame(width: frameSize, height: frameSize)
        .position(x: center.x, y: center.y)
        .animation(.easeOut(duration: 0.08), value: selectedIndex)
        .allowsHitTesting(false)
    }
}

struct SectorShape: Shape {
    let startAngle: CGFloat
    let endAngle: CGFloat
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        
        path.addArc(center: center, radius: innerRadius, startAngle: Angle(radians: Double(startAngle)), endAngle: Angle(radians: Double(endAngle)), clockwise: false)
        path.addArc(center: center, radius: outerRadius, startAngle: Angle(radians: Double(endAngle)), endAngle: Angle(radians: Double(startAngle)), clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Right Click capture

private struct RightClickCaptureView: NSViewRepresentable {
    var onRightDown: (CGPoint) -> Void
    var onRightDrag: (CGPoint) -> Void
    var onRightUp: (CGPoint) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onRightDown = onRightDown
        view.onRightDrag = onRightDrag
        view.onRightUp = onRightUp
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private class CaptureView: NSView {
        var onRightDown: ((CGPoint) -> Void)?
        var onRightDrag: ((CGPoint) -> Void)?
        var onRightUp: ((CGPoint) -> Void)?
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only capture right/other mouse events; let left-clicks fall through.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                 .otherMouseDown, .otherMouseDragged, .otherMouseUp:
                return self
            default:
                return nil
            }
        }
        
        override func rightMouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let flipped = flipY(point)
            onRightDown?(flipped)
        }
        
        override func rightMouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let flipped = flipY(point)
            onRightDrag?(flipped)
        }
        
        override func rightMouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let flipped = flipY(point)
            onRightUp?(flipped)
        }
        
        private func flipY(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: bounds.height - point.y)
        }
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value, perform: { _ in action() })
        }
    }
}

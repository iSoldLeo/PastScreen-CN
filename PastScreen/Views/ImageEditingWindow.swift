//
//  ImageEditingWindow.swift
//  PastScreen
//
//  Created for advanced screenshot editing functionality
//

import SwiftUI
import AppKit

class ImageEditingWindow: NSWindow {
    private var hostingView: NSHostingView<ImageEditingView>!
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
            }
        )
        
        hostingView = NSHostingView(rootView: editingView)
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
    
    @State private var editedImage: NSImage
    @State private var selectedTool: DrawingTool = .pen
    @State private var selectedColor: Color = .red
    @State private var strokeWidth: Double = 2.0
    @State private var drawingPaths: [DrawingPath] = []
    @State private var currentPath: DrawingPath?
    @State private var isDrawing = false
    

    
    // Text tool properties
    @State private var textInputs: [TextInput] = []
    @State private var showTextInput = false
    @State private var textLocation: CGPoint = .zero
    @State private var currentText = ""
    @State private var waitingForTextPlacement = false
    @State private var previewTextPosition: CGPoint? = nil
    @State private var mousePosition: CGPoint = .zero
    
    // Undo/Redo state
    @State private var undoStack: [EditAction] = []
    @State private var redoStack: [EditAction] = []
    @State private var undoManager = UndoManager()
    
    // Keyboard monitor for cleanup
    @State private var keyboardMonitor: Any? = nil
    
    init(image: NSImage, onCompletion: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onCompletion = onCompletion
        self.onCancel = onCancel
        self._editedImage = State(initialValue: image)
    }
    
    // MARK: - Undo/Redo Properties
    
    private var canUndo: Bool {
        !undoStack.isEmpty
    }
    
    private var canRedo: Bool {
        !redoStack.isEmpty
    }
    
    // MARK: - Body View
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                // Drawing tools
                HStack(spacing: 6) {
                    ForEach(DrawingTool.allCases, id: \.self) { tool in
                        Button(action: { 
                            let previousTool = selectedTool
                            let newTool = tool
                            
                            // Reset stroke width when switching between text and drawing tools
                            if newTool == .text && previousTool != .text {
                                // Switching to text, adjust for text sizing (current value might be too small)
                                strokeWidth = max(strokeWidth, 2)
                            } else if newTool != .text && previousTool == .text {
                                // Switching from text to another tool
                                // Close text input dialog if open
                                if showTextInput {
                                    showTextInput = false
                                    currentText = ""
                                }
                                // If user has entered text but not placed it, cancel placement
                                if waitingForTextPlacement {
                                    print("Cancelling waitingForTextPlacement from \(waitingForTextPlacement) to false")
                                    waitingForTextPlacement = false
                                }
                                // Clamp to drawing limits (all non-text tools have max 10)
                                strokeWidth = min(strokeWidth, 10)
                            } else if newTool != .text {
                                // Switching between non-text tools, ensure it doesn't exceed 10
                                strokeWidth = min(strokeWidth, 10)
                            }
                            
                            selectedTool = newTool
                            
                            if newTool == .text {
                                showTextInput = true
                                waitingForTextPlacement = false
                                previewTextPosition = nil
                            }
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
                        .help(toolName(for: tool))
                    }
                }
                .padding(.leading, 4)
                
                Divider()
                    .frame(height: 36)
                
                // Color picker and stroke controls
                HStack(spacing: 20) {
                    // Color picker
                    ColorPicker("", selection: $selectedColor)
                        .labelsHidden()
                        .frame(width: 28, height: 28)
                    
                    // Stroke width/Text size
                    VStack(spacing: 2) {
                        Text(selectedTool == .text ? NSLocalizedString("editor.text.size", comment: "") : NSLocalizedString("editor.stroke.width", comment: ""))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Text("1")
                                .font(.system(size: 9))
                                .foregroundColor(Color.secondary.opacity(0.6))
                            Slider(value: $strokeWidth, in: 1...(selectedTool == .text ? 50 : 10), step: 1)
                                .frame(width: 100)
                            Text(selectedTool == .text ? "50" : "10")
                                .font(.system(size: 9))
                                .foregroundColor(Color.secondary.opacity(0.6))
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
                                    strokeWidth = min(strokeWidth, 10)
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
                ZStack {
                    // Background image
                    Image(nsImage: editedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    
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
                            contextCopy.stroke(drawingPath.path, with: .color(drawingPath.color), lineWidth: drawingPath.strokeWidth)
                        }
                        
                        // Draw the current path being drawn
                        if let currentPath = currentPath {
                            var contextCopy = context
                            contextCopy.translateBy(x: offsetX, y: offsetY)
                            contextCopy.scaleBy(x: imageToDisplayScale, y: imageToDisplayScale)
                            contextCopy.stroke(currentPath.path, with: .color(currentPath.color), lineWidth: currentPath.strokeWidth)
                        }
                    }
                    
                    // Text inputs overlay
                    ForEach(Array(textInputs.enumerated()), id: \.element.id) { index, textInput in
                        let textPositionView = calculateTextPosition(
                            for: textInput, 
                            in: geometry, 
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
                .clipped()
                .contentShape(Rectangle()) // Prevent window dragging in this area
                .onTapGesture { location in
                    // Handle tap for text placement
                    if selectedTool == .text && waitingForTextPlacement && !currentText.isEmpty {
                        placeTextAt(location: location, in: geometry)
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
                                handleDragChanged(value: value, in: geometry)
                            }
                        }
                        .onEnded { value in
                            // Handle text placement on click
                            if selectedTool == .text && waitingForTextPlacement {
                                placeTextAt(location: value.location, in: geometry)
                            } else if selectedTool != .text {
                                handleDragEnded(value: value, in: geometry)
                            }
                        }
                )
                .onAppear {
                    // Setup keyboard shortcuts for undo/redo
                    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        if event.modifierFlags.contains(.command) {
                            switch event.charactersIgnoringModifiers {
                            case "z":
                                if event.modifierFlags.contains(.shift) {
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
            }
        }
    }
    
    private func handleDragChanged(value: DragGesture.Value, in geometry: GeometryProxy) {
        let location = value.location
        let size = geometry.size
        
        // Calculate image display properties (same as in Canvas)
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
        
        // Transform screen coordinates to original image coordinates
        let imageLocation = CGPoint(
            x: (location.x - offsetX) / imageToDisplayScale,
            y: (location.y - offsetY) / imageToDisplayScale
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
            case .text:
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
            case .text:
                updatedPath = currentPath!.path
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
    
    private func handleDragEnded(value: DragGesture.Value, in geometry: GeometryProxy) {
        let location = value.location
        let size = geometry.size
        
        // Calculate the image position and scale in the canvas
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
        
        // Transform screen coordinates to original image coordinates
        let _ = CGPoint(
            x: (location.x - offsetX) / imageToDisplayScale,
            y: (location.y - offsetY) / imageToDisplayScale
        )
        
        if selectedTool == .text {
            // For text tool, if we're waiting for placement, place the text
            if waitingForTextPlacement {
                placeTextAt(location: location, in: geometry)
            }
            return
        }
        
        if let path = currentPath {
            drawingPaths.append(path)
            undoStack.append(.addPath(path))
            saveState()
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
            strokeWidth = min(strokeWidth, 10)
        }
    }
    
    private func placeTextAt(location: CGPoint, in geometry: GeometryProxy) {
        // Convert screen coordinates to image coordinates
        let size = geometry.size
        let imageSize = editedImage.size
        let aspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = size.width / size.height
        
        let displaySize: CGSize
        if aspectRatio > canvasAspectRatio {
            displaySize = CGSize(width: size.width, height: size.width / aspectRatio)
        } else {
            displaySize = CGSize(width: size.height * aspectRatio, height: size.height)
        }
        
        let offsetX = (size.width - displaySize.width) / 2
        let offsetY = (size.height - displaySize.height) / 2
        let imageToDisplayScale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        
        let imageLocation = CGPoint(
            x: (location.x - offsetX) / imageToDisplayScale,
            y: (location.y - offsetY) / imageToDisplayScale
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
        strokeWidth = min(strokeWidth, 10)
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
    
    private func toolName(for tool: DrawingTool) -> String {
        switch tool {
        case .pen: return NSLocalizedString("tool.pen", comment: "")
        case .line: return NSLocalizedString("tool.line", comment: "")
        case .rectangle: return NSLocalizedString("tool.rectangle", comment: "")
        case .circle: return NSLocalizedString("tool.circle", comment: "")
        case .arrow: return NSLocalizedString("tool.arrow", comment: "")
        case .text: return NSLocalizedString("tool.text", comment: "")
        }
    }
    
    private func saveEditedImage() {
        // Create a new image with drawings
        let renderer = ImageRenderer(content: 
            ZStack {
                Image(nsImage: image)
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
        }
        
        undoStack.append(actionToRedo)
    }
    
    private func calculateTextPosition(for textInput: TextInput, in geometry: GeometryProxy, with imageSize: CGSize) -> CGPoint {
        let aspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = geometry.size.width / geometry.size.height
        
        let displaySize: CGSize
        if aspectRatio > canvasAspectRatio {
            displaySize = CGSize(width: geometry.size.width, height: geometry.size.width / aspectRatio)
        } else {
            displaySize = CGSize(width: geometry.size.height * aspectRatio, height: geometry.size.height)
        }
        
        let offsetX = (geometry.size.width - displaySize.width) / 2
        let offsetY = (geometry.size.height - displaySize.height) / 2
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
}

enum DrawingTool: CaseIterable {
    case pen
    case line
    case rectangle
    case circle
    case arrow
    case text
    
    var systemImage: String {
        switch self {
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arrow: return "arrow.right"
        case .text: return "textformat"
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

struct TextInput: Identifiable {
    var id = UUID()
    let text: String
    let location: CGPoint
    let color: Color
    let fontSize: CGFloat
}

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
        title = "编辑截图"
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
    
    // Undo/Redo state
    @State private var undoStack: [EditAction] = []
    @State private var redoStack: [EditAction] = []
    @State private var undoManager = UndoManager()
    
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
            HStack {
                // Drawing tools
                HStack(spacing: 8) {
                    ForEach(DrawingTool.allCases, id: \.self) { tool in
                        Button(action: { selectedTool = tool }) {
                            Image(systemName: tool.systemImage)
                                .font(.title2)
                                .foregroundColor(selectedTool == tool ? .blue : .primary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .frame(width: 32, height: 32)
                    }
                }
                
                Divider()
                    .frame(height: 40)
                
                // Color picker
                ColorPicker("", selection: $selectedColor)
                    .labelsHidden()
                    .frame(width: 32, height: 32)
                
                // Stroke width
                VStack {
                    Text("粗细")
                        .font(.caption)
                    Slider(value: $strokeWidth, in: 1...10, step: 1)
                        .frame(width: 80)
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 12) {
                    // Undo/Redo buttons
                    Button(action: undo) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title2)
                            .foregroundColor(canUndo ? .primary : .secondary)
                    }
                    .disabled(!canUndo)
                    
                    Button(action: redo) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.title2)
                            .foregroundColor(canRedo ? .primary : .secondary)
                    }
                    .disabled(!canRedo)
                    
                    Divider()
                        .frame(height: 40)
                    
                    Button("取消") {
                        onCancel()
                    }
                    .keyboardShortcut(.escape)
                    
                    Button("完成") {
                        saveEditedImage()
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .sheet(isPresented: $showTextInput) {
                VStack {
                    Text("输入文字")
                        .font(.headline)
                        .padding()
                    
                    TextField("请输入文字", text: $currentText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .onSubmit {
                            addTextAtLocation()
                        }
                    
                    HStack {
                        Button("取消") {
                            showTextInput = false
                            currentText = ""
                        }
                        .padding()
                        
                        Button("确定") {
                            addTextAtLocation()
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
                            .font(.system(size: 16))
                            .foregroundColor(textInput.color)
                            .position(x: textPositionView.x, y: textPositionView.y)
                    }
                }
                .clipped()
                .contentShape(Rectangle()) // Prevent window dragging in this area
                .gesture(
                    // Drawing gesture
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDragChanged(value: value, in: geometry)
                        }
                        .onEnded { value in
                            handleDragEnded(value: value, in: geometry)
                        }
                )
                .onAppear {
                    // Setup keyboard shortcuts for undo/redo
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            // For text tool, we don't draw but set the location for text input
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
        let imageLocation = CGPoint(
            x: (location.x - offsetX) / imageToDisplayScale,
            y: (location.y - offsetY) / imageToDisplayScale
        )
        
        if selectedTool == .text {
            // For text tool, show text input dialog at the clicked location
            textLocation = imageLocation
            showTextInput = true
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
    
    private func addTextAtLocation() {
        if !currentText.isEmpty {
            let newText = TextInput(
                text: currentText,
                location: textLocation,
                color: selectedColor
            )
            textInputs.append(newText)
            undoStack.append(.addText(newText))
            saveState()
        }
        showTextInput = false
        currentText = ""
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
                        .font(.system(size: 16))
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
}

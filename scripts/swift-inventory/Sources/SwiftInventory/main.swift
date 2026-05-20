import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Output models

struct FunctionRecord {
    var file: String
    var startLine: Int
    var endLine: Int
    var kind: String          // func / init / deinit / get / set / subscript / willSet / didSet
    var name: String          // dotted: TypeA.TypeB.funcName
    var signature: String     // params with types, return type
    var paramCount: Int
    var bodyLines: Int        // lines inside { }, 0 if no body
    var complexity: Int       // 1 + count of branching nodes
    var callees: [String]     // identifiers used in call position inside body
}

// MARK: - Visitor

final class InventoryVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    var records: [FunctionRecord] = []
    private var typeStack: [String] = []

    init(filePath: String, source: String, tree: SourceFileSyntax) {
        self.filePath = filePath
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // Type context tracking

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.extendedType.trimmedDescription); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast() }

    // Function-like declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordFunction(
            node: Syntax(node),
            kind: "func",
            name: node.name.text,
            params: node.signature.parameterClause.parameters.count,
            signature: node.signature.trimmedDescription,
            body: node.body
        )
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordFunction(
            node: Syntax(node),
            kind: "init",
            name: "init",
            params: node.signature.parameterClause.parameters.count,
            signature: node.signature.trimmedDescription,
            body: node.body
        )
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordFunction(
            node: Syntax(node),
            kind: "deinit",
            name: "deinit",
            params: 0,
            signature: "",
            body: node.body
        )
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        let kind = node.accessorSpecifier.text   // get / set / willSet / didSet
        let propName = enclosingPropertyName(of: node) ?? "<accessor>"
        recordFunction(
            node: Syntax(node),
            kind: kind,
            name: "\(propName).\(kind)",
            params: node.parameters?.name != nil ? 1 : 0,
            signature: node.parameters?.trimmedDescription ?? "",
            body: node.body
        )
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        recordFunction(
            node: Syntax(node),
            kind: "subscript",
            name: "subscript",
            params: node.parameterClause.parameters.count,
            signature: node.parameterClause.trimmedDescription,
            body: nil
        )
        return .visitChildren
    }

    // MARK: helpers

    private func enclosingPropertyName(of accessor: AccessorDeclSyntax) -> String? {
        var parent: Syntax? = accessor.parent
        while let p = parent {
            if let binding = p.as(PatternBindingSyntax.self) {
                return binding.pattern.trimmedDescription
            }
            parent = p.parent
        }
        return nil
    }

    private func recordFunction(
        node: Syntax,
        kind: String,
        name: String,
        params: Int,
        signature: String,
        body: CodeBlockSyntax?
    ) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPosition)

        let qualifiedName = (typeStack + [name]).joined(separator: ".")
        let bodyLines: Int
        let complexity: Int
        let callees: [String]

        if let body = body {
            let bStart = converter.location(for: body.positionAfterSkippingLeadingTrivia)
            let bEnd = converter.location(for: body.endPosition)
            bodyLines = max(0, bEnd.line - bStart.line - 1)
            let analyzer = BodyAnalyzer(viewMode: .sourceAccurate)
            analyzer.walk(body)
            complexity = analyzer.complexity
            callees = Array(analyzer.callees).sorted()
        } else {
            bodyLines = 0
            complexity = 1
            callees = []
        }

        records.append(FunctionRecord(
            file: filePath,
            startLine: start.line,
            endLine: end.line,
            kind: kind,
            name: qualifiedName,
            signature: signature,
            paramCount: params,
            bodyLines: bodyLines,
            complexity: complexity,
            callees: callees
        ))
    }
}

// MARK: - Body analyzer (complexity + callees)

final class BodyAnalyzer: SyntaxVisitor {
    var complexity: Int = 1
    var callees: Set<String> = []

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind { complexity += 1; return .visitChildren }

    // Don't recurse into nested function bodies — they are recorded separately
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // Count closures lightly — they add a branch worth of complexity
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = extractCalleeName(node.calledExpression) {
            callees.insert(name)
        }
        return .visitChildren
    }

    private func extractCalleeName(_ expr: ExprSyntax) -> String? {
        if let decl = expr.as(DeclReferenceExprSyntax.self) {
            return decl.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}

// MARK: - File walker

func collectSwiftFiles(at root: String) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    while let rel = enumerator.nextObject() as? String {
        if rel.hasSuffix(".swift") {
            out.append((root as NSString).appendingPathComponent(rel))
        }
    }
    return out.sorted()
}

// MARK: - Output

enum OutputFormat: String { case csv, markdown, json }

func emitCSV(_ records: [FunctionRecord], to out: inout String) {
    out += "file,start,end,kind,name,params,body_lines,complexity,callees\n"
    for r in records {
        let callees = r.callees.joined(separator: ";")
        let name = r.name.replacingOccurrences(of: "\"", with: "'")
        out += "\(r.file),\(r.startLine),\(r.endLine),\(r.kind),\"\(name)\",\(r.paramCount),\(r.bodyLines),\(r.complexity),\"\(callees)\"\n"
    }
}

func emitMarkdown(_ records: [FunctionRecord], to out: inout String) {
    let sorted = records.sorted { ($0.bodyLines, $0.complexity) > ($1.bodyLines, $1.complexity) }

    out += "# Swift function inventory\n\n"
    out += "Total functions: **\(records.count)** across **\(Set(records.map { $0.file }).count)** files.\n\n"

    out += "## Top 50 by body lines\n\n"
    out += "| Body | CCN | Params | File:Line | Kind | Name |\n"
    out += "|---:|---:|---:|---|---|---|\n"
    for r in sorted.prefix(50) {
        out += "| \(r.bodyLines) | \(r.complexity) | \(r.paramCount) | \(r.file):\(r.startLine) | \(r.kind) | `\(r.name)` |\n"
    }

    out += "\n## Top 30 by complexity\n\n"
    let byCcn = records.sorted { $0.complexity > $1.complexity }
    out += "| CCN | Body | File:Line | Name |\n|---:|---:|---|---|\n"
    for r in byCcn.prefix(30) {
        out += "| \(r.complexity) | \(r.bodyLines) | \(r.file):\(r.startLine) | `\(r.name)` |\n"
    }

    out += "\n## Per-file summary\n\n"
    let grouped = Dictionary(grouping: records, by: { $0.file })
    let perFile = grouped.map { (file, recs) -> (String, Int, Int, Int) in
        let totalBody = recs.reduce(0) { $0 + $1.bodyLines }
        let maxBody = recs.map { $0.bodyLines }.max() ?? 0
        return (file, recs.count, totalBody, maxBody)
    }.sorted { $0.2 > $1.2 }

    out += "| File | Funcs | Total body lines | Max body |\n|---|---:|---:|---:|\n"
    for row in perFile {
        out += "| \(row.0) | \(row.1) | \(row.2) | \(row.3) |\n"
    }
}

func emitJSON(_ records: [FunctionRecord]) -> String {
    let arr: [[String: Any]] = records.map { r in
        [
            "file": r.file,
            "start": r.startLine,
            "end": r.endLine,
            "kind": r.kind,
            "name": r.name,
            "signature": r.signature,
            "params": r.paramCount,
            "body_lines": r.bodyLines,
            "complexity": r.complexity,
            "callees": r.callees
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8) ?? "[]"
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift-inventory <root-dir> [--format csv|markdown|json]\n".utf8))
    exit(2)
}
let root = args[1]
var format: OutputFormat = .markdown
if let idx = args.firstIndex(of: "--format"), idx + 1 < args.count,
   let f = OutputFormat(rawValue: args[idx + 1]) {
    format = f
}

let files = collectSwiftFiles(at: root)
var all: [FunctionRecord] = []
for path in files {
    guard let data = FileManager.default.contents(atPath: path),
          let source = String(data: data, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: source)
    let visitor = InventoryVisitor(filePath: path, source: source, tree: tree)
    visitor.walk(tree)
    all.append(contentsOf: visitor.records)
}

var output = ""
switch format {
case .csv: emitCSV(all, to: &output)
case .markdown: emitMarkdown(all, to: &output)
case .json: output = emitJSON(all)
}
print(output)

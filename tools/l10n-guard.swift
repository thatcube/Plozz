// l10n-guard.swift — localization regression guard for Plozz.
//
// Plozz serves all UI copy from one app-owned String Catalog (see
// docs/localization.md). The migration to that model is INCREMENTAL: one slice is
// done, ~1,140 strings are not. This guard exists so the finished slices cannot
// quietly rot back to English-only while the rest is still in flight.
//
// WHY SWIFTSYNTAX AND NOT A REGEX / LITERAL COUNTER
// -------------------------------------------------
// The first design was "count bare string literals in UI files, ratchet the count
// down". That drowns: SF Symbol names, log messages, URLs, codec names, provider
// ids and test fixtures are all bare literals, and none are copy. Worse, it MISSES
// the actual failure mode — copy modelled as a runtime `String`, which renders
// verbatim and is invisible to both the catalog and the extractor.
//
// So the rules below are deliberately chosen to be SYNTACTICALLY DECIDABLE. A
// syntax tree cannot tell `Text(section.title)` (a LocalizedStringResource, fine)
// from `Text(item.title)` (media content, must be verbatim) — they are the same
// shape. Any rule needing that distinction would be a guess, so it is not a rule.
// Type-level checking is a job for the compiler, not for this tool.
//
// WHAT IT CHECKS
// --------------
//  1. eager-localization      `Text(String(localized: ...))` freezes the value at
//                             resolution time and defeats live locale switching.
//  2. key-from-variable       `LocalizedStringKey(someString)` — a runtime string
//                             cannot be a catalog key; it silently renders as-is.
//  3. concatenated-copy       `Text("Season " + n)` — hard-codes English word
//                             order, so no translator can reorder it.
//  4. brand-not-verbatim      Brand names ("Jellyfin", "Plex", …) reaching a copy
//                             sink as plain literals get extracted as translatable
//                             and some translator WILL translate them.
//  5. copy-typed-as-string    In ALREADY-MIGRATED files only: a copy-shaped
//                             property (`title`, `header`, …) typed `String`.
//                             This is the regression that matters most — it is
//                             how a migrated slice silently reverts.
//
// Rules 1–4 run repo-wide because they cannot produce content-vs-copy false
// positives. Rule 5 runs only on `auditedPaths` from tools/l10n-guard.json, so
// legacy code is grandfathered and the ratchet tightens one slice at a time.
//
// THE RATCHET
// -----------
// Running the repo-wide rules over ~207k lines of pre-localization code finds
// real but pre-existing issues. Failing on all of them would mean the guard could
// never be switched on, which is how guards end up permanently disabled. Instead
// tools/l10n-guard-baseline.json records the accepted count PER RULE, and the
// guard fails only when a count goes UP — or when anything at all is found in an
// audited file. Baseline counts may only ever decrease (the tool refuses to
// rewrite them upward), so the debt is one-directional.
//
// ESCAPE HATCH
// ------------
// A declaration carrying real CONTENT (a media title, filename, username) inside
// an audited file is exempted with a trailing marker comment:
//
//     let title: String   // l10n:content — provider-supplied media title
//
// It is deliberately explicit and greppable: exempting content should be a
// visible decision, not an inferred one.

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Configuration

struct Config: Decodable {
    var auditedPaths: [String]
    var copyPropertyNames: [String]
    var appCopySinks: [String]
    var neverTranslate: [String]
}

// MARK: - Findings

struct Finding {
    let rule: String
    let file: String
    let line: Int
    let message: String
    let hint: String
}

// MARK: - Analyzer

final class Analyzer: SyntaxVisitor {
    private let config: Config
    private let relativePath: String
    private let converter: SourceLocationConverter
    private let isAudited: Bool
    private let lines: [String]
    private(set) var findings: [Finding] = []

    init(config: Config, relativePath: String, source: String, tree: SourceFileSyntax, isAudited: Bool) {
        self.config = config
        self.relativePath = relativePath
        self.converter = SourceLocationConverter(fileName: relativePath, tree: tree)
        self.isAudited = isAudited
        self.lines = source.components(separatedBy: .newlines)
        super.init(viewMode: .sourceAccurate)
    }

    private func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    private func record(_ rule: String, _ node: some SyntaxProtocol, _ message: String, _ hint: String) {
        findings.append(Finding(rule: rule, file: relativePath, line: line(of: node),
                                message: message, hint: hint))
    }

    /// Whether the source line carries the `// l10n:content` opt-out.
    private func isMarkedContent(_ node: some SyntaxProtocol) -> Bool {
        let index = line(of: node) - 1
        guard lines.indices.contains(index) else { return false }
        return lines[index].contains("l10n:content")
    }

    // MARK: Call-site rules

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = calleeName(node)

        // Rule 2 — a runtime String can never be a catalog key.
        if callee == "LocalizedStringKey",
           let first = node.arguments.first,
           first.label == nil,
           !isStringLiteral(first.expression) {
            record("key-from-variable", node,
                   "LocalizedStringKey built from a runtime value.",
                   "A key must be a literal. For content use Text(verbatim:); for copy use a LocalizedStringResource.")
        }

        guard config.appCopySinks.contains(callee) else { return .visitChildren }

        // `verbatim:` is the explicit "this is content, never translate it"
        // signal, so a sink using it is correct by construction.
        let isVerbatim = node.arguments.contains { $0.label?.text == "verbatim" }
        guard let first = node.arguments.first, first.label == nil || first.label?.text == "verbatim" else {
            return .visitChildren
        }

        // Rule 1 — eager resolution defeats live locale switching.
        if !isVerbatim, containsEagerLocalization(first.expression) {
            record("eager-localization", node,
                   "\(callee)(…) resolves its string eagerly with String(localized:).",
                   "Pass the LocalizedStringResource itself so SwiftUI can re-resolve it when the locale changes.")
        }

        // Rule 3 — `+` bakes English word order into the source.
        if !isVerbatim, isConcatenatedLiteral(first.expression) {
            record("concatenated-copy", node,
                   "\(callee)(…) builds its text by concatenating a literal.",
                   "Use one string with interpolation — \"Season \\(n)\" — so translators can reorder it.")
        }

        // Rule 4 — brand names must never enter the catalog.
        if !isVerbatim,
           let literal = stringLiteralValue(first.expression),
           config.neverTranslate.contains(literal) {
            // Only `Text` takes a `verbatim:` argument. Every other sink accepts a
            // `Text`, so the fix differs by sink and the hint must say which.
            let fix = callee == "Text"
                ? "Text(verbatim: \"\(literal)\")"
                : "\(callee)(Text(verbatim: \"\(literal)\"))"
            record("brand-not-verbatim", node,
                   "\(callee)(\"\(literal)\") extracts a brand name as translatable copy.",
                   "Brand names must not be translated — use \(fix). "
                   + "(Label uses a trailing closure: Label { Text(verbatim: \"\(literal)\") } icon: { … }.)")
        }

        return .visitChildren
    }

    // MARK: Declaration rule (audited files only)

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isAudited else { return .visitChildren }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  config.copyPropertyNames.contains(name),
                  let type = binding.typeAnnotation?.type.trimmedDescription,
                  isStringTyped(type),
                  !isMarkedContent(node)
            else { continue }
            record("copy-typed-as-string", node,
                   "`\(name): \(type)` is copy-shaped but typed String in a migrated file.",
                   "Text(aString) renders verbatim and is never localized. Use LocalizedStringResource, "
                   + "or mark it `// l10n:content` if it really carries provider content.")
        }
        return .visitChildren
    }


    // MARK: Copy returned as String (audited files only)

    /// Catches prose returned from a `-> String` function, computed property, or
    /// tuple element.
    ///
    /// This exists because the declaration-name rule above was demonstrably not
    /// enough: it only inspects properties literally named `title`, `header`, … so
    /// copy hiding in `var phase: String`, `func summary(...) -> String`, or a
    /// `(icon: String, text: String)` tuple sailed straight past a clean guard run.
    /// A guard that reports success while real English is unreachable is worse than
    /// no guard, because it is trusted.
    ///
    /// "Prose" is deliberately narrow — a literal containing a space AND a
    /// lowercase letter. That excludes SF Symbol names, identifiers, codec names,
    /// URLs and format specifiers, which is what keeps this from drowning.
    private func checkReturnedProse(_ node: some SyntaxProtocol, returnType: String?) {
        guard isAudited, let returnType, returnsString(returnType), !isMarkedContent(node) else { return }
        for literal in node.tokens(viewMode: .sourceAccurate).compactMap({ token -> String? in
            guard case let .stringSegment(text) = token.tokenKind else { return nil }
            return text
        }) where looksLikeProse(literal) {
            record("copy-returned-as-string", node,
                   "Returns prose as String: \"\(literal.prefix(48))\".",
                   "A String reaching Text renders verbatim and is never localized. Return "
                   + "LocalizedStringResource, or mark it `// l10n:content` if it is really content.")
            return
        }
    }

    private func returnsString(_ type: String) -> Bool {
        let bare = type.replacingOccurrences(of: "?", with: "")
        // Bare `String`, or a tuple with at least one String element.
        return bare == "String" || (bare.hasPrefix("(") && bare.contains("String"))
    }

    /// A literal with a space and a lowercase letter reads as a sentence rather
    /// than an identifier.
    private func looksLikeProse(_ text: String) -> Bool {
        text.contains(" ") && text.contains(where: \.isLowercase)
            && !text.hasPrefix("%") && !text.contains("://")
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkReturnedProse(node, returnType: node.signature.returnClause?.type.trimmedDescription)
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        // Computed property with an explicit type annotation and a body.
        guard node.accessorBlock != nil else { return .visitChildren }
        checkReturnedProse(node, returnType: node.typeAnnotation?.type.trimmedDescription)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        guard isAudited else { return .visitChildren }
        let name = (node.secondName ?? node.firstName).text
        guard config.copyPropertyNames.contains(name),
              isStringTyped(node.type.trimmedDescription),
              !isMarkedContent(node)
        else { return .visitChildren }
        record("copy-typed-as-string", node,
               "Parameter `\(name): \(node.type.trimmedDescription)` is copy-shaped but typed String.",
               "Use LocalizedStringResource, or mark it `// l10n:content` if it carries provider content.")
        return .visitChildren
    }

    // MARK: Syntax helpers

    private func calleeName(_ node: FunctionCallExprSyntax) -> String {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return node.calledExpression.trimmedDescription
    }

    private func isStringTyped(_ type: String) -> Bool {
        let bare = type.hasSuffix("?") ? String(type.dropLast()) : type
        return bare == "String"
    }

    private func isStringLiteral(_ expr: ExprSyntax) -> Bool {
        expr.is(StringLiteralExprSyntax.self)
    }

    /// The literal's text, but only when it is a plain literal with no
    /// interpolation — an interpolated literal is not a fixed brand name.
    private func stringLiteralValue(_ expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            value += text.content.text
        }
        return value
    }

    private func containsEagerLocalization(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              calleeName(call) == "String" else { return false }
        return call.arguments.contains { $0.label?.text == "localized" }
    }

    /// A `+` chain with at least one string literal in it. Concatenating two
    /// non-literals is usually path/id assembly, not copy, so it is left alone.
    private func isConcatenatedLiteral(_ expr: ExprSyntax) -> Bool {
        guard let sequence = expr.as(SequenceExprSyntax.self) else { return false }
        let hasPlus = sequence.elements.contains { element in
            element.as(BinaryOperatorExprSyntax.self)?.operator.text == "+"
        }
        let hasLiteral = sequence.elements.contains { $0.is(StringLiteralExprSyntax.self) }
        return hasPlus && hasLiteral
    }
}

// MARK: - Driver

let repoRoot: String = {
    if let index = CommandLine.arguments.firstIndex(of: "--repo-root"),
       CommandLine.arguments.indices.contains(index + 1) {
        return CommandLine.arguments[index + 1]
    }
    return FileManager.default.currentDirectoryPath
}()

let configPath = "\(repoRoot)/tools/l10n-guard.json"
guard let configData = FileManager.default.contents(atPath: configPath),
      let config = try? JSONDecoder().decode(Config.self, from: configData)
else {
    FileHandle.standardError.write(Data("✗ Could not read \(configPath)\n".utf8))
    exit(2)
}

let sourcesRoot = "\(repoRoot)/Sources"
guard let walker = FileManager.default.enumerator(atPath: sourcesRoot) else {
    FileHandle.standardError.write(Data("✗ Could not read \(sourcesRoot)\n".utf8))
    exit(2)
}

var findings: [Finding] = []
var scanned = 0

for case let path as String in walker where path.hasSuffix(".swift") {
    let relative = "Sources/\(path)"
    let absolute = "\(sourcesRoot)/\(path)"
    guard let source = try? String(contentsOfFile: absolute, encoding: .utf8) else { continue }
    scanned += 1

    let isAudited = config.auditedPaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    let tree = Parser.parse(source: source)
    let analyzer = Analyzer(config: config, relativePath: relative, source: source,
                            tree: tree, isAudited: isAudited)
    analyzer.walk(tree)
    findings += analyzer.findings
}

let auditedCount = config.auditedPaths.count
print("▸ l10n-guard: scanned \(scanned) files (\(auditedCount) audited path(s) under the strict rule)")

let byRule = Dictionary(grouping: findings, by: \.rule).mapValues(\.count)

// Findings inside an audited file are never acceptable — that slice is done, so
// any hit there is a genuine regression rather than inherited debt.
let auditedFindings = findings.filter { finding in
    config.auditedPaths.contains { finding.file == $0 || finding.file.hasPrefix($0 + "/") }
}

// MARK: Ratchet

let baselinePath = "\(repoRoot)/tools/l10n-guard-baseline.json"
let baselineExists = FileManager.default.fileExists(atPath: baselinePath)
let baseline: [String: Int] = {
    guard let data = FileManager.default.contents(atPath: baselinePath),
          let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return [:] }
    return decoded
}()

let wantsUpdate = CommandLine.arguments.contains("--update-baseline")

if wantsUpdate {
    // First run has nothing to ratchet against, so it SEEDS the file: whatever
    // the repo contains today becomes the accepted debt. Afterwards counts may
    // only ever go down — refusing to raise them is what makes this a ratchet
    // rather than a rubber stamp for new violations.
    var raised: [String] = []
    if baselineExists {
        for (rule, count) in byRule where count > (baseline[rule] ?? 0) {
            raised.append("\(rule): \(baseline[rule] ?? 0) → \(count)")
        }
    }
    guard raised.isEmpty else {
        print("✗ Refusing to raise the baseline for: \(raised.joined(separator: ", "))")
        print("  The baseline only ratchets DOWN. Fix the new findings instead.")
        exit(1)
    }
    let merged = byRule.filter { $0.value > 0 }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(merged) {
        try? data.write(to: URL(fileURLWithPath: baselinePath))
        let summary = merged.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        print(baselineExists
              ? "✓ Baseline updated: \(summary)"
              : "✓ Baseline seeded with existing debt: \(summary)")
    }
    exit(0)
}

var regressions: [String] = []
for (rule, count) in byRule {
    let allowed = baseline[rule] ?? 0
    if count > allowed { regressions.append("\(rule): \(count) (baseline \(allowed))") }
}

// Report improvements so the baseline gets tightened rather than silently drifting.
var improvements: [String] = []
for (rule, allowed) in baseline {
    let count = byRule[rule] ?? 0
    if count < allowed { improvements.append("\(rule): \(allowed) → \(count)") }
}

guard !regressions.isEmpty || !auditedFindings.isEmpty else {
    let debt = baseline.values.reduce(0, +)
    if improvements.isEmpty {
        print("✓ No localization regressions." + (debt > 0 ? " (\(debt) known legacy issue(s))" : ""))
    } else {
        print("✓ No localization regressions, and some were FIXED:")
        for improvement in improvements.sorted() { print("    \(improvement)") }
        print("  Run tools/l10n-guard.sh --update-baseline to lock that in.")
    }
    exit(0)
}

// Show only what must be acted on: everything in audited files, plus the rules
// that regressed. Reprinting inherited debt on every run trains people to ignore
// the output.
let regressedRules = Set(regressions.map { $0.components(separatedBy: ":")[0] })
let actionable = findings.filter { finding in
    auditedFindings.contains { $0.file == finding.file && $0.line == finding.line }
        || regressedRules.contains(finding.rule)
}

for finding in actionable.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
    print("""

    ✗ \(finding.file):\(finding.line) [\(finding.rule)]
      \(finding.message)
      → \(finding.hint)
    """)
}

if !auditedFindings.isEmpty {
    print("\n✗ \(auditedFindings.count) issue(s) in ALREADY-MIGRATED files — these must be zero.")
}
if !regressions.isEmpty {
    print("\n✗ Above baseline: \(regressions.sorted().joined(separator: ", "))")
}
print("  See docs/localization.md for the rules.")
exit(1)

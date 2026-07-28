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
//  6. copy-returned-as-string A function or computed property that RETURNS prose
//                             as `String`. Rule 5 only sees declarations whose
//                             name is copy-shaped, so this catches the rest.
//  7. hand-rolled-plural      `"\(n) \(n == 1 ? "item" : "items")"` builds a
//                             counted phrase out of fragments, which only works
//                             for English's two forms. Note this fires ONLY when
//                             the phrase shows the number: for copy that does
//                             not, Apple's toolchain rejects plural variations
//                             outright ("use separate top-level strings for one
//                             and greater than one"), so a bare ternary between
//                             two literals is the CORRECT answer and is allowed.
//
// Rules 1–4 run repo-wide because they cannot produce content-vs-copy false
// positives. Rule 5 runs only on `auditedPaths` from tools/l10n-guard.json, so
// legacy code is grandfathered and the ratchet tightens one slice at a time.
//
// SCOPE
// -----
// Rules 1–4 and 7 are safe repo-wide: they are syntactically decidable and cannot
// confuse content with copy. Rules 5 and 6 need to know whether a file has been
// migrated, so they run only on `auditedPaths` in tools/l10n-guard.json. Adding a
// path there is what tightens the net, and it is done as part of migrating that
// slice — never separately.
//
// There is no baseline file. There was one while the migration was in flight; the
// debt it tracked is now zero, so the ratchet only ever compared against zero.
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
    private let catalogKeys: Set<String>
    private let relativePath: String
    private let converter: SourceLocationConverter
    private let isAudited: Bool
    private let lines: [String]
    private(set) var findings: [Finding] = []

    init(config: Config, catalogKeys: Set<String>, relativePath: String, source: String,
         tree: SourceFileSyntax, isAudited: Bool) {
        self.config = config
        self.catalogKeys = catalogKeys
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

        // Rule 1 — eager resolution defeats live locale switching, wherever it
        // happens. Scoped to copy sinks originally, which missed the real cases:
        // they were resolutions assigned to a `String` property on the way to a
        // sink, not written at the sink itself.
        if callee == "String",
           node.arguments.contains(where: { $0.label?.text == "localized" }),
           !isMarkedContent(node) {
            record("eager-localization", node,
                   "String(localized:) resolves a resource at call time.",
                   "Keep the LocalizedStringResource (or build a Text) so it re-resolves when the "
                   + "language changes. Resolving early freezes the value.")
        }

        // Rule 2 — a runtime String can never be a catalog key.
        if callee == "LocalizedStringKey",
           let first = node.arguments.first,
           first.label == nil,
           !isStringLiteral(first.expression) {
            record("key-from-variable", node,
                   "LocalizedStringKey built from a runtime value.",
                   "A key must be a literal. For content use Text(verbatim:); for copy use a LocalizedStringResource.")
        }

        // Rule 8 — prose passed at a copy-shaped label that never reached the
        // catalog. This is the one check that works from the OUTSIDE: it does not
        // care why the string was missed, only that it is not there.
        //
        // It exists because `copy-typed-as-string` can be silenced by an
        // `l10n:content` marker, and a marker can be wrong. `HomeRowsGroupCard`
        // was typed `String` and marked "library name from the server" — true for
        // one of its three callers. The other two passed our own copy, which
        // rendered verbatim and was invisible to the catalog and to this tool.
        if isAudited, !catalogKeys.isEmpty, !isMarkedContent(node) {
            let isCopySink = config.appCopySinks.contains(callee)
            for argument in node.arguments {
                let label = argument.label?.text
                if label == "verbatim" { continue }
                // Either a copy-shaped argument label anywhere, or ANY argument of
                // a known copy sink. The second case matters: `Text(name ?? "Admin
                // — unrestricted")` has no label at all, and the literal is buried
                // in a `??`, so a rule that only reads whole arguments misses it.
                //
                // KNOWN LIMIT: this proves a string EXISTS in the catalog, not
                // that THIS site extracts it. If the same words are also written
                // somewhere that does extract, an occurrence that renders
                // verbatim here looks fine. Telling those apart needs types, so
                // it stays out of scope — see the note at the top of this file.
                let interesting = isCopySink || label.map(config.copyPropertyNames.contains) == true
                guard interesting else { continue }
                for literal in proseLiterals(in: argument.expression)
                where !catalogKeys.contains(literal) {
                    record("copy-not-in-catalog", argument,
                           "\(callee)(…\"\(literal.prefix(48))\") is not in the catalog.",
                           "It renders verbatim, so no translator can reach it — usually a copy "
                           + "parameter typed String. Type it LocalizedStringResource (or Text), or "
                           + "mark it `// l10n:content` if it really is content.")
                }
            }
        }

        guard config.appCopySinks.contains(callee) else { return .visitChildren }

        // `verbatim:` is the explicit "this is content, never translate it"
        // signal, so a sink using it is correct by construction.
        let isVerbatim = node.arguments.contains { $0.label?.text == "verbatim" }
        guard let first = node.arguments.first, first.label == nil || first.label?.text == "verbatim" else {
            return .visitChildren
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
        if bare == "String" { return true }
        // For a tuple, only a *copy-shaped* element counts. `(icon: String, text:
        // LocalizedStringResource)` is already migrated — the String there is an SF
        // Symbol name, and flagging it would report the tuple's prose literal
        // against an element that never carries prose.
        guard bare.hasPrefix("("), bare.hasSuffix(")") else { return false }
        return bare.dropFirst().dropLast()
            .split(separator: ",")
            .contains { element in
                let parts = element.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return false }
                let label = parts[0].trimmingCharacters(in: .whitespaces)
                let type = parts[1].trimmingCharacters(in: .whitespaces)
                return config.copyPropertyNames.contains(label) && type == "String"
            }
    }

    /// Every plain prose literal inside an expression, including ones nested in a
    /// `??` or a ternary. Interpolated literals are skipped: they are a format
    /// string, and the catalog key would be the specifier form, not this text.
    private func proseLiterals(in expr: ExprSyntax) -> [String] {
        expr.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
            guard case let .stringSegment(text) = token.tokenKind,
                  looksLikeProse(text),
                  token.parent?.parent?.as(StringLiteralExprSyntax.self)?
                      .segments.count == 1
            else { return nil }
            return text
        }
    }

    /// A literal with a space and a lowercase letter reads as a sentence rather
    /// than an identifier.
    private func looksLikeProse(_ text: String) -> Bool {
        text.contains(" ") && text.contains(where: \.isLowercase)
            && !text.hasPrefix("%") && !text.contains("://")
    }

    /// A counted phrase assembled from fragments — `"\(n) \(n == 1 ? "item" :
    /// "items")"`. The catalog can express this as one key with plural
    /// variations; Swift cannot express Polish's four forms at all.
    ///
    /// Deliberately NOT flagged: a standalone ternary between two plain literals
    /// that never shows the number ("Server" / "Servers"). `xcstringstool`
    /// refuses a plural variation whose values don't reference the count and
    /// tells you to use two top-level strings instead, so flagging that would be
    /// this tool arguing with the toolchain.
    ///
    /// SwiftParser does NOT fold operators without an `OperatorTable`, so this
    /// never arrives as a tidy `TernaryExprSyntax`. It is a flat sequence —
    /// `n`, `==`, `1`, `? "item" :`, `"items"` — and the rule has to read it
    /// that way or it silently matches nothing.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard let markIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
              let ternary = elements[markIndex].as(UnresolvedTernaryExprSyntax.self),
              elements.indices.contains(markIndex + 1)
        else { return .visitChildren }
        guard isStringLiteral(ternary.thenExpression),
              isStringLiteral(elements[markIndex + 1]),
              comparesToOne(elements[..<markIndex]),
              buildsCountedPhrase(node),
              !isMarkedContent(node)
        else { return .visitChildren }
        record("hand-rolled-plural", node,
               "Plural chosen in code: \(node.trimmedDescription.prefix(64)).",
               "Interpolate the count into ONE resource and add plural variations to "
               + "the catalog — languages with 3–6 plural forms cannot be served by a ternary.")
        return .visitChildren
    }

    /// True when the ternary is a fragment of a larger string — either nested in
    /// an interpolation (`"\(n) \(cond ? "item" : "items")"`) or with a branch
    /// that interpolates. That is what makes the number visible, and a visible
    /// number is what the catalog needs to vary the phrase by plural.
    private func buildsCountedPhrase(_ node: SequenceExprSyntax) -> Bool {
        var parent = node.parent
        while let current = parent {
            if current.is(StringLiteralExprSyntax.self) { return true }
            parent = current.parent
        }
        return node.elements.contains { element in
            element.as(StringLiteralExprSyntax.self)?.segments
                .contains { $0.is(ExpressionSegmentSyntax.self) } ?? false
        }
    }

    /// True when the condition compares something to the literal `1`, which is
    /// what separates a singular/plural decision from an arbitrary two-way choice.
    private func comparesToOne(_ condition: ArraySlice<ExprSyntax>) -> Bool {
        let comparesEqual = condition.contains {
            $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "=="
        }
        let mentionsOne = condition.contains {
            $0.as(IntegerLiteralExprSyntax.self)?.literal.text == "1"
        }
        return comparesEqual && mentionsOne
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

/// The catalog's key set, for rule 8. Empty (rule disabled) rather than fatal if
/// the catalog can't be read: the guard must still work in a checkout where the
/// catalog is mid-edit, and a missing catalog is caught by l10n-sync anyway.
let catalogKeys: Set<String> = {
    let path = "\(repoRoot)/App/Resources/Localizable.xcstrings"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = json["strings"] as? [String: Any]
    else { return [] }
    return Set(strings.keys)
}()

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
    let analyzer = Analyzer(config: config, catalogKeys: catalogKeys, relativePath: relative,
                            source: source, tree: tree, isAudited: isAudited)
    analyzer.walk(tree)
    findings += analyzer.findings
}

let auditedCount = config.auditedPaths.count
print("▸ l10n-guard: scanned \(scanned) files (\(auditedCount) audited path(s) under the strict rule)")

// MARK: Report

// Every rule is now enforced everywhere it applies, so any finding is a
// regression. There was a per-rule ratchet here while the migration was in
// flight — it seeded from the repo's existing debt and only allowed counts to
// fall. That debt reached zero, which left ~90 lines whose only behaviour was
// comparing every count against 0. Deleted rather than kept "in case", because
// a ratchet with an empty baseline is indistinguishable from no ratchet, and
// keeping it invited someone to seed it again and reintroduce accepted debt.

guard !findings.isEmpty else {
    print("✓ No localization regressions.")
    exit(0)
}

for finding in findings.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
    print("""

    ✗ \(finding.file):\(finding.line) [\(finding.rule)]
      \(finding.message)
      → \(finding.hint)
    """)
}

let counts = Dictionary(grouping: findings, by: \.rule)
    .map { "\($0.key): \($0.value.count)" }
    .sorted()
print("\n✗ \(findings.count) localization issue(s) — \(counts.joined(separator: ", "))")
print("  See docs/localization.md for the rules.")
exit(1)

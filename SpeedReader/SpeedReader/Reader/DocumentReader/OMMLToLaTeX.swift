import Foundation

/// A node in a stripped-down OMML (Office Math Markup Language) tree.
/// Built lazily by `DOCXContentParser` while it's inside an `<m:oMath>` element.
final class OMMLNode {
    /// Local tag name without `m:` prefix (e.g. `oMath`, `f`, `num`, `den`, `t`).
    let name: String
    /// XML attributes that matter for OMML semantics. Only a handful are read by the
    /// converter — the rest can be discarded to keep the tree light.
    let attributes: [String: String]
    var children: [OMMLNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    /// First child matching the given local name, or nil. Used for the OMML pattern
    /// where each element has a small fixed set of named slots (e.g. `m:f` always
    /// has one `m:num` and one `m:den`).
    func first(_ name: String) -> OMMLNode? {
        children.first { $0.name == name }
    }

    /// All children with the given local name. Used for repeated structures like
    /// `m:m/m:mr` (matrix rows) or `m:eqArr/m:e` (equation array entries).
    func all(_ name: String) -> [OMMLNode] {
        children.filter { $0.name == name }
    }
}

/// Converts an `<m:oMath>` OMML tree to a LaTeX string.
///
/// Scope: covers fractions, super/subscripts, radicals, n-ary operators
/// (sum/integral/product), delimited expressions, function-with-name, limits,
/// matrices, equation arrays, accents/bars, and groups-with-character. Falls back
/// to recursing into unknown elements so unsupported constructs leave a best-effort
/// trace (their text content) rather than a hole.
///
/// Not a full OMML implementation — there is no production-quality OMML→LaTeX
/// library for Swift, and writing one would dwarf the rest of this feature. The
/// goal is "renders most engineering / physics doc formulas correctly, degrades
/// gracefully for the rest." Caller is responsible for routing the result into
/// `BlockType.formula`.
enum OMMLToLaTeX {

    static func convert(_ root: OMMLNode) -> String {
        // Strip the wrapping `<m:oMath>` so the output is just the math body.
        // Tag names are matched in lowercase to align with `DOCXContentParser.localName`.
        let body = root.name == "omath" ? root.children.map(render).joined() : render(root)
        return body
            .replacingOccurrences(of: "\u{2212}", with: "-")   // Unicode minus → ASCII
            .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space → space
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dispatch

    private static func render(_ node: OMMLNode) -> String {
        switch node.name {
        case "r":         return renderRun(node)
        case "t":         return escapeText(node.text)
        case "f":         return renderFraction(node)
        case "num", "den", "e", "sup", "sub", "deg", "fname", "lim":
            return renderChildren(node)
        case "ssup":      return renderScript(node, sub: false, sup: true)
        case "ssub":      return renderScript(node, sub: true,  sup: false)
        case "ssubsup":   return renderScript(node, sub: true,  sup: true)
        case "rad":       return renderRadical(node)
        case "nary":      return renderNary(node)
        case "d":         return renderDelimited(node)
        case "func":      return renderFunc(node)
        case "limlow":    return renderLimit(node, upper: false)
        case "limupp":    return renderLimit(node, upper: true)
        case "m":         return renderMatrix(node)
        case "eqarr":     return renderEqArray(node)
        case "acc":       return renderAccent(node)
        case "bar":       return renderBar(node)
        case "groupchr":  return renderGroupChar(node)
        case "box", "borderbox":
            return renderChildren(node)
        default:
            // Unknown element — recurse so any nested text still reaches the output.
            return renderChildren(node)
        }
    }

    private static func renderChildren(_ node: OMMLNode) -> String {
        node.children.map(render).joined()
    }

    private static func renderRun(_ node: OMMLNode) -> String {
        // A run carries text inside `m:t`. Italic / bold formatting (`m:rPr/m:sty`)
        // is intentionally ignored — KaTeX renders math italics automatically and
        // re-applying \mathit{} per-token tends to hurt more than help.
        node.children.map(render).joined()
    }

    // MARK: - Operators

    private static func renderFraction(_ node: OMMLNode) -> String {
        let num = node.first("num").map(renderChildren) ?? ""
        let den = node.first("den").map(renderChildren) ?? ""
        return "\\frac{\(num)}{\(den)}"
    }

    private static func renderScript(_ node: OMMLNode, sub: Bool, sup: Bool) -> String {
        let base = node.first("e").map(renderChildren) ?? ""
        var out = "{\(base)}"
        if sub, let s = node.first("sub").map(renderChildren), !s.isEmpty {
            out += "_{\(s)}"
        }
        if sup, let s = node.first("sup").map(renderChildren), !s.isEmpty {
            out += "^{\(s)}"
        }
        return out
    }

    private static func renderRadical(_ node: OMMLNode) -> String {
        let body = node.first("e").map(renderChildren) ?? ""
        if let deg = node.first("deg").map(renderChildren), !deg.isEmpty {
            return "\\sqrt[\(deg)]{\(body)}"
        }
        return "\\sqrt{\(body)}"
    }

    private static func renderNary(_ node: OMMLNode) -> String {
        // The operator glyph lives in `m:naryPr/m:chr/@m:val` — default is `∑`.
        // We map a small set of common operators to LaTeX commands; anything else
        // is emitted as-is and KaTeX will draw it via its Unicode→symbol table.
        let chr = node.first("narypr")?.first("chr")?.attributes["m:val"] ?? "\u{2211}"
        let op = naryOperator(for: chr)
        let lower = node.first("sub").map(renderChildren) ?? ""
        let upper = node.first("sup").map(renderChildren) ?? ""
        let body  = node.first("e").map(renderChildren) ?? ""
        var out = op
        if !lower.isEmpty { out += "_{\(lower)}" }
        if !upper.isEmpty { out += "^{\(upper)}" }
        if !body.isEmpty  { out += "{\(body)}" }
        return out
    }

    private static func naryOperator(for chr: String) -> String {
        switch chr {
        case "\u{2211}": return "\\sum"
        case "\u{220F}": return "\\prod"
        case "\u{2210}": return "\\coprod"
        case "\u{222B}": return "\\int"
        case "\u{222C}": return "\\iint"
        case "\u{222D}": return "\\iiint"
        case "\u{222E}": return "\\oint"
        case "\u{22C3}": return "\\bigcup"
        case "\u{22C2}": return "\\bigcap"
        case "\u{22C1}": return "\\bigvee"
        case "\u{22C0}": return "\\bigwedge"
        default:         return chr   // best-effort
        }
    }

    private static func renderDelimited(_ node: OMMLNode) -> String {
        let pr = node.first("dpr")
        let begChr = pr?.first("begchr")?.attributes["m:val"] ?? "("
        let endChr = pr?.first("endchr")?.attributes["m:val"] ?? ")"
        let sepChr = pr?.first("sepchr")?.attributes["m:val"] ?? "|"
        let parts = node.all("e").map(renderChildren)
        let body = parts.joined(separator: sepChr == "|" ? " \\mid " : sepChr)
        return "\\left\(latexDelimiter(begChr, opening: true))\(body)\\right\(latexDelimiter(endChr, opening: false))"
    }

    private static func latexDelimiter(_ chr: String, opening: Bool) -> String {
        switch chr {
        case "(", ")", "[", "]", "/", "|": return chr
        case "{":  return "\\{"
        case "}":  return "\\}"
        case "":   return "."             // empty → null delimiter
        case "\u{2308}": return "\\lceil"
        case "\u{2309}": return "\\rceil"
        case "\u{230A}": return "\\lfloor"
        case "\u{230B}": return "\\rfloor"
        case "\u{27E8}": return "\\langle"
        case "\u{27E9}": return "\\rangle"
        case "\u{2016}": return "\\|"
        default:        return chr
        }
    }

    private static func renderFunc(_ node: OMMLNode) -> String {
        let nameText = node.first("fname").map(renderChildren) ?? ""
        let body = node.first("e").map(renderChildren) ?? ""
        // Wrap common function names in \operatorname so KaTeX upright-renders them.
        let stripped = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let known: Set<String> = ["sin","cos","tan","cot","sec","csc","arcsin","arccos","arctan",
                                  "sinh","cosh","tanh","log","ln","lg","exp","det","dim","gcd",
                                  "lim","max","min","sup","inf","arg","ker","Pr"]
        let formattedName: String
        if known.contains(stripped) {
            formattedName = "\\\(stripped)"
        } else if !stripped.isEmpty {
            formattedName = "\\operatorname{\(stripped)}"
        } else {
            formattedName = ""
        }
        return formattedName.isEmpty ? body : "\(formattedName){\(body)}"
    }

    private static func renderLimit(_ node: OMMLNode, upper: Bool) -> String {
        let base = node.first("e").map(renderChildren) ?? ""
        let lim = node.first("lim").map(renderChildren) ?? ""
        let cmd = upper ? "\\overset" : "\\underset"
        return "\(cmd){\(lim)}{\(base)}"
    }

    private static func renderMatrix(_ node: OMMLNode) -> String {
        let rows = node.all("mr").map { row in
            row.all("e").map(renderChildren).joined(separator: " & ")
        }
        return "\\begin{matrix}\n" + rows.joined(separator: " \\\\\n") + "\n\\end{matrix}"
    }

    private static func renderEqArray(_ node: OMMLNode) -> String {
        let lines = node.all("e").map(renderChildren)
        return "\\begin{aligned}\n" + lines.joined(separator: " \\\\\n") + "\n\\end{aligned}"
    }

    private static func renderAccent(_ node: OMMLNode) -> String {
        let chr = node.first("accpr")?.first("chr")?.attributes["m:val"] ?? "\u{0302}"
        let base = node.first("e").map(renderChildren) ?? ""
        return "\(accentCommand(for: chr)){\(base)}"
    }

    private static func accentCommand(for chr: String) -> String {
        switch chr {
        case "\u{0302}", "^": return "\\hat"
        case "\u{0303}", "~": return "\\tilde"
        case "\u{0304}", "\u{00AF}": return "\\bar"
        case "\u{0307}": return "\\dot"
        case "\u{0308}": return "\\ddot"
        case "\u{20D7}", "\u{2192}": return "\\vec"
        default: return "\\hat"
        }
    }

    private static func renderBar(_ node: OMMLNode) -> String {
        let pos = node.first("barpr")?.first("pos")?.attributes["m:val"] ?? "top"
        let body = node.first("e").map(renderChildren) ?? ""
        return pos == "bot" ? "\\underline{\(body)}" : "\\overline{\(body)}"
    }

    private static func renderGroupChar(_ node: OMMLNode) -> String {
        let chr = node.first("groupchrpr")?.first("chr")?.attributes["m:val"] ?? "\u{23DE}"
        let vertJc = node.first("groupchrpr")?.first("vertjc")?.attributes["m:val"] ?? "top"
        let base = node.first("e").map(renderChildren) ?? ""
        let isBracket = (chr == "\u{23DE}" || chr == "\u{23DF}" || chr == "\u{23DC}" || chr == "\u{23DD}")
        guard isBracket else { return base }
        let isOver = (chr == "\u{23DE}" || chr == "\u{23DC}")
        let bracket = (chr == "\u{23DE}" || chr == "\u{23DF}") ? "brace" : "paren"
        let cmd: String
        if isOver { cmd = bracket == "brace" ? "\\overbrace" : "\\overparen" }
        else      { cmd = bracket == "brace" ? "\\underbrace" : "\\underparen" }
        _ = vertJc
        return "\(cmd){\(base)}"
    }

    // MARK: - Text escaping

    /// Minimal escaping: characters that have special meaning in TeX but commonly
    /// appear verbatim inside OMML runs (e.g. `%` in a percent value). KaTeX is
    /// permissive about most of the rest.
    private static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\backslash "
            case "%":  out += "\\%"
            case "&":  out += "\\&"
            case "#":  out += "\\#"
            case "$":  out += "\\$"
            case "_":  out += "\\_"
            case "^":  out += "\\hat{}"
            case "{":  out += "\\{"
            case "}":  out += "\\}"
            case "~":  out += "\\sim "
            default:   out.append(ch)
            }
        }
        return out
    }
}

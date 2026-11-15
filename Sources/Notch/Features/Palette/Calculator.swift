import Foundation

/// Recursive-descent calculator: + - * / % ^, parentheses, unary minus,
/// sqrt sin cos tan log ln abs round floor ceil, pi and e. Returns nil on anything else.
/// (NSExpression raises ObjC exceptions on bad input, which would crash us.)
struct Calculator {
    private let s: [Character]
    private var i = 0

    static func eval(_ text: String) -> Double? {
        let t = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "").lowercased()
        // Must look like maths: at least one operator or function, and a digit.
        guard t.contains(where: \.isNumber),
              t.contains(where: { "+-*/%^(".contains($0) }) || t.range(of: "[a-z]+\\(", options: .regularExpression) != nil
        else { return nil }
        var c = Calculator(s: Array(t.filter { !$0.isWhitespace }))
        guard let v = c.expr(), c.i == c.s.count, v.isFinite else { return nil }
        return v
    }

    private init(s: [Character]) { self.s = s }

    private mutating func eat(_ ch: Character) -> Bool {
        if i < s.count, s[i] == ch { i += 1; return true }
        return false
    }

    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while true {
            if eat("+") { guard let r = term() else { return nil }; v += r }
            else if eat("-") { guard let r = term() else { return nil }; v -= r }
            else { return v }
        }
    }

    private mutating func term() -> Double? {
        guard var v = power() else { return nil }
        while true {
            if eat("*") { guard let r = power() else { return nil }; v *= r }
            else if eat("/") { guard let r = power() else { return nil }; v /= r }
            else if eat("%") { guard let r = power() else { return nil }; v = v.truncatingRemainder(dividingBy: r) }
            else { return v }
        }
    }

    private mutating func power() -> Double? {
        guard let b = unary() else { return nil }
        if eat("^") { guard let e = power() else { return nil }; return pow(b, e) }  // right-assoc
        return b
    }

    private mutating func unary() -> Double? {
        if eat("-") { return unary().map { -$0 } }
        if eat("+") { return unary() }
        return atom()
    }

    private mutating func atom() -> Double? {
        if eat("(") { let v = expr(); return eat(")") ? v : nil }
        var name = ""
        while i < s.count, s[i].isLetter { name.append(s[i]); i += 1 }
        if !name.isEmpty {
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            guard eat("("), let a = expr(), eat(")") else { return nil }
            switch name {
            case "sqrt": return sqrt(a)
            case "sin": return sin(a)
            case "cos": return cos(a)
            case "tan": return tan(a)
            case "log": return log10(a)
            case "ln": return log(a)
            case "abs": return abs(a)
            case "round": return a.rounded()
            case "floor": return floor(a)
            case "ceil": return ceil(a)
            default: return nil
            }
        }
        let start = i
        while i < s.count, s[i].isNumber || s[i] == "." { i += 1 }
        return Double(String(s[start..<i]))
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter(); f.maximumFractionDigits = 10; f.minimumIntegerDigits = 1
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

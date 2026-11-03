//! JSON the way Python's json module reads and writes it, as far as this daemon goes: the config file (json.load,
//! json.dump with indent=1), the status reply (json.dumps), kwinoutputconfig.json and kscreen-doctor -j - plus the
//! Python reprs that show up in log lines. Numbers keep Python's int / float distinction (120 and 120.0 print
//! differently), objects their key order (Python dicts keep insertion order; a repeated key keeps its first place and
//! its last value). Parse errors read like Python's ("Expecting value: line 1 column 1 (char 0)"), since the daemon
//! logs them.

use std::fmt::Write;

#[derive(Debug, Clone, PartialEq)]
pub enum J {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

impl J {
    pub fn get(&self, key: &str) -> Option<&J> {
        match self {
            J::Obj(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Python's name of the type, for the error texts that name one.
    pub fn type_name(&self) -> &'static str {
        match self {
            J::Null => "NoneType",
            J::Bool(_) => "bool",
            J::Int(_) => "int",
            J::Float(_) => "float",
            J::Str(_) => "str",
            J::Arr(_) => "list",
            J::Obj(_) => "dict",
        }
    }
}

pub fn parse(s: &str) -> Result<J, String> {
    let c: Vec<char> = s.chars().collect(); // Python's positions count characters
    let mut p = P { c: &c, i: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != c.len() {
        return Err(p.err("Extra data", p.i));
    }
    Ok(v)
}

struct P<'a> {
    c: &'a [char],
    i: usize,
}

impl P<'_> {
    fn err(&self, msg: &str, pos: usize) -> String {
        let before = &self.c[..pos.min(self.c.len())];
        let line = before.iter().filter(|&&c| c == '\n').count() + 1;
        let col = before.iter().rposition(|&c| c == '\n').map_or(pos + 1, |n| pos - n);
        format!("{msg}: line {line} column {col} (char {pos})")
    }

    fn at(&self, k: usize) -> Option<char> {
        self.c.get(self.i + k).copied()
    }

    fn ws(&mut self) {
        while matches!(self.at(0), Some(' ' | '\t' | '\n' | '\r')) {
            self.i += 1;
        }
    }

    fn value(&mut self) -> Result<J, String> {
        let start = self.i;
        match self.at(0) {
            Some('"') => {
                self.i += 1;
                return self.string(start).map(J::Str);
            }
            Some('{') => {
                self.i += 1;
                return self.object();
            }
            Some('[') => {
                self.i += 1;
                return self.array();
            }
            _ => {}
        }
        for (lit, v) in [("null", J::Null), ("true", J::Bool(true)), ("false", J::Bool(false)), ("NaN", J::Float(f64::NAN)),
            ("Infinity", J::Float(f64::INFINITY)), ("-Infinity", J::Float(f64::NEG_INFINITY))]
        {
            if lit.chars().enumerate().all(|(k, ch)| self.at(k) == Some(ch)) {
                self.i += lit.len();
                return Ok(v);
            }
        }
        self.number().ok_or_else(|| self.err("Expecting value", start))
    }

    /// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)? as Python's scanner: an int unless it has a fraction or exponent
    fn number(&mut self) -> Option<J> {
        let digit = |p: &P, j: usize| p.c.get(j).is_some_and(|c| c.is_ascii_digit());
        let mut j = self.i;
        if self.c.get(j) == Some(&'-') {
            j += 1;
        }
        if self.c.get(j) == Some(&'0') {
            j += 1;
        } else if digit(self, j) {
            while digit(self, j) {
                j += 1;
            }
        } else {
            return None;
        }
        let mut float = false;
        if self.c.get(j) == Some(&'.') && digit(self, j + 1) {
            j += 1;
            while digit(self, j) {
                j += 1;
            }
            float = true;
        }
        if matches!(self.c.get(j), Some('e' | 'E')) {
            let mut k = j + 1;
            if matches!(self.c.get(k), Some('+' | '-')) {
                k += 1;
            }
            if digit(self, k) {
                while digit(self, k) {
                    k += 1;
                }
                j = k;
                float = true;
            }
        }
        let text: String = self.c[self.i..j].iter().collect();
        self.i = j;
        // shortcut: an int past i64 becomes a float (Python's ints have no limit); no file here holds one
        Some(match (float, text.parse::<i64>()) {
            (false, Ok(i)) => J::Int(i),
            _ => J::Float(text.parse().unwrap_or(f64::NAN)),
        })
    }

    fn hex4(&mut self) -> Option<u32> {
        let h: String = self.c.get(self.i..self.i + 4)?.iter().collect();
        let v = u32::from_str_radix(&h, 16).ok().filter(|_| h.chars().all(|c| c.is_ascii_hexdigit()))?;
        self.i += 4;
        Some(v)
    }

    /// After the opening quote at `start`.
    fn string(&mut self, start: usize) -> Result<String, String> {
        let mut out = String::new();
        loop {
            let Some(c) = self.at(0) else { return Err(self.err("Unterminated string starting at", start)) };
            self.i += 1;
            match c {
                '"' => return Ok(out),
                '\\' => {
                    let Some(e) = self.at(0) else { return Err(self.err("Unterminated string starting at", start)) };
                    self.i += 1;
                    match e {
                        '"' | '\\' | '/' => out.push(e),
                        'b' => out.push('\u{8}'),
                        'f' => out.push('\u{c}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let mut u = self.hex4().ok_or_else(|| self.err("Invalid \\uXXXX escape", self.i - 1))?;
                            if (0xd800..0xdc00).contains(&u) && self.at(0) == Some('\\') && self.at(1) == Some('u') {
                                let back = self.i;
                                self.i += 2;
                                match self.hex4() {
                                    Some(l) if (0xdc00..0xe000).contains(&l) => u = 0x10000 + ((u - 0xd800) << 10) + (l - 0xdc00),
                                    _ => self.i = back,
                                }
                            }
                            // shortcut: a lone surrogate (Python keeps it in the str) becomes U+FFFD
                            out.push(char::from_u32(u).unwrap_or('\u{fffd}'));
                        }
                        _ => return Err(self.err("Invalid \\escape", self.i - 2)),
                    }
                }
                c if (c as u32) < 0x20 => return Err(self.err("Invalid control character at", self.i - 1)),
                c => out.push(c),
            }
        }
    }

    fn object(&mut self) -> Result<J, String> {
        let mut kv: Vec<(String, J)> = Vec::new();
        self.ws();
        if self.at(0) == Some('}') {
            self.i += 1;
            return Ok(J::Obj(kv));
        }
        loop {
            if self.at(0) != Some('"') {
                return Err(self.err("Expecting property name enclosed in double quotes", self.i));
            }
            let start = self.i;
            self.i += 1;
            let k = self.string(start)?;
            self.ws();
            if self.at(0) != Some(':') {
                return Err(self.err("Expecting ':' delimiter", self.i));
            }
            self.i += 1;
            self.ws();
            let v = self.value()?;
            match kv.iter_mut().find(|(have, _)| *have == k) {
                Some(e) => e.1 = v,
                None => kv.push((k, v)),
            }
            self.ws();
            match self.at(0) {
                Some('}') => {
                    self.i += 1;
                    return Ok(J::Obj(kv));
                }
                Some(',') => {
                    self.i += 1;
                    self.ws();
                }
                _ => return Err(self.err("Expecting ',' delimiter", self.i)),
            }
        }
    }

    fn array(&mut self) -> Result<J, String> {
        let mut v = Vec::new();
        self.ws();
        if self.at(0) == Some(']') {
            self.i += 1;
            return Ok(J::Arr(v));
        }
        loop {
            v.push(self.value()?);
            self.ws();
            match self.at(0) {
                Some(']') => {
                    self.i += 1;
                    return Ok(J::Arr(v));
                }
                Some(',') => {
                    self.i += 1;
                    self.ws();
                }
                _ => return Err(self.err("Expecting ',' delimiter", self.i)),
            }
        }
    }
}

/// json.dumps(j): ", " and ": " between items, ensure_ascii.
pub fn dumps(j: &J) -> String {
    let mut s = String::new();
    dump(j, None, 0, &mut s);
    s
}

/// json.dump(j, f, indent=n): one item per line, "," at line ends, no newline at the end.
pub fn dump_indent(j: &J, indent: usize) -> String {
    let mut s = String::new();
    dump(j, Some(indent), 0, &mut s);
    s
}

fn dump(j: &J, indent: Option<usize>, level: usize, out: &mut String) {
    let items = |out: &mut String, open: char, close: char, n: usize, item: &mut dyn FnMut(usize, &mut String)| {
        out.push(open);
        if n == 0 {
            out.push(close);
            return;
        }
        for k in 0..n {
            match indent {
                Some(w) => {
                    out.push_str(if k == 0 { "\n" } else { ",\n" });
                    out.push_str(&" ".repeat(w * (level + 1)));
                }
                None if k > 0 => out.push_str(", "),
                None => {}
            }
            item(k, out);
        }
        if let Some(w) = indent {
            out.push('\n');
            out.push_str(&" ".repeat(w * level));
        }
        out.push(close);
    };
    match j {
        J::Null => out.push_str("null"),
        J::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        J::Int(i) => write!(out, "{i}").unwrap(),
        J::Float(f) if f.is_nan() => out.push_str("NaN"),
        J::Float(f) if f.is_infinite() => out.push_str(if *f > 0.0 { "Infinity" } else { "-Infinity" }),
        J::Float(f) => out.push_str(&py_float(*f)),
        J::Str(s) => quote(s, out),
        J::Arr(v) => items(out, '[', ']', v.len(), &mut |k, out| dump(&v[k], indent, level + 1, out)),
        J::Obj(kv) => items(out, '{', '}', kv.len(), &mut |k, out| {
            quote(&kv[k].0, out);
            out.push_str(": ");
            dump(&kv[k].1, indent, level + 1, out);
        }),
    }
}

/// A JSON string with ensure_ascii: everything outside space..~ escaped, astral characters as surrogate pairs.
fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            ' '..='~' => out.push(c),
            c => {
                for u in c.encode_utf16(&mut [0u16; 2]) {
                    write!(out, "\\u{u:04x}").unwrap();
                }
            }
        }
    }
    out.push('"');
}

/// Python's repr() of a float: the shortest digits that read back the same, positional from 1e-4 up to 1e16 (with
/// ".0" when whole), scientific outside ("1e-05", "1e+16").
pub fn py_float(x: f64) -> String {
    if x.is_nan() {
        return "nan".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "inf" } else { "-inf" }.into();
    }
    let e = format!("{x:e}"); // shortest round-trip digits: "1.5e0", "-2.45e-5"
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let sign = if mant.starts_with('-') { "-" } else { "" };
    let digits: String = mant.chars().filter(char::is_ascii_digit).collect();
    if !(-4..16).contains(&exp) {
        let rest = if digits.len() > 1 { format!(".{}", &digits[1..]) } else { String::new() };
        return format!("{sign}{}{rest}e{}{:02}", &digits[..1], if exp < 0 { '-' } else { '+' }, exp.abs());
    }
    let point = exp + 1; // digits before the decimal point
    if point <= 0 {
        format!("{sign}0.{}{digits}", "0".repeat((-point) as usize))
    } else if point as usize >= digits.len() {
        format!("{sign}{digits}{}.0", "0".repeat(point as usize - digits.len()))
    } else {
        format!("{sign}{}.{}", &digits[..point as usize], &digits[point as usize..])
    }
}

/// Python's round(x, 1), as a float (the status's touch_age_s).
pub fn round1(x: f64) -> f64 {
    format!("{x:.1}").parse().unwrap_or(x)
}

/// Python's repr() of a parsed JSON value (the "config: ignoring" line): 'str', True, None, [..], {'k': v}.
pub fn py_repr(j: &J) -> String {
    match j {
        J::Null => "None".into(),
        J::Bool(b) => py_bool(*b).into(),
        J::Int(i) => i.to_string(),
        J::Float(f) => py_float(*f),
        J::Str(s) => py_str_repr(s),
        J::Arr(v) => format!("[{}]", v.iter().map(py_repr).collect::<Vec<_>>().join(", ")),
        J::Obj(kv) => format!("{{{}}}", kv.iter().map(|(k, v)| format!("{}: {}", py_str_repr(k), py_repr(v))).collect::<Vec<_>>().join(", ")),
    }
}

/// Python's str() of a value: a string as it is, anything else as its repr.
pub fn py_str(j: &J) -> String {
    match j {
        J::Str(s) => s.clone(),
        _ => py_repr(j),
    }
}

pub fn py_bool(b: bool) -> &'static str {
    if b {
        "True"
    } else {
        "False"
    }
}

/// Python's repr() of a str: single quotes unless it holds one and no double quote; control and non-printable
/// characters escaped.
pub fn py_str_repr(s: &str) -> String {
    let q = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
    let mut out = String::from(q);
    for c in s.chars() {
        let u = c as u32;
        match c {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if c == q => {
                out.push('\\');
                out.push(c);
            }
            // shortcut: "not printable" is Python's Unicode table cut down to the controls, separators and format
            // characters likely in a hand-edited config
            _ if u < 0x20 || (0x7f..=0xa0).contains(&u) || u == 0xad => write!(out, "\\x{u:02x}").unwrap(),
            _ if u == 0x1680 || (0x2000..=0x200f).contains(&u) || (0x2028..=0x202f).contains(&u)
                || (0x205f..=0x2064).contains(&u) || u == 0x3000 || u == 0xfeff || (0xe000..=0xf8ff).contains(&u) =>
            {
                write!(out, "\\u{u:04x}").unwrap()
            }
            c => out.push(c),
        }
    }
    out.push(q);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn python_floats() {
        // repr() of each, from python3 on the tablet
        for (x, want) in [(1.5, "1.5"), (3.0, "3.0"), (29.0, "29.0"), (24547.2, "24547.2"), (0.1, "0.1"), (1e-4, "0.0001"),
            (1e-5, "1e-05"), (1.5e-7, "1.5e-07"), (1e15, "1000000000000000.0"), (1e16, "1e+16"), (1.2345678901234568e17, "1.2345678901234568e+17"),
            (-0.0, "-0.0"), (-2.5, "-2.5"), (123456.789, "123456.789"), (0.30000000000000004, "0.30000000000000004")]
        {
            assert_eq!(py_float(x), want, "{x}");
        }
        assert_eq!((round1(24547.2499), round1(0.04), round1(3.96)), (24547.2, 0.0, 4.0));
    }

    #[test]
    fn config_round_trip() {
        // json.dump(DEFAULTS, f, indent=1) as the daemon leaves ~/.config/y700-refresh-auto.json (no final newline)
        let file = "{\n \"enabled\": true,\n \"base_hz\": 120,\n \"enter_delay_s\": 1.5,\n \"touch_hold_s\": 3.0,\n \"unknown_fps_hz\": 0,\n \"danmaku_min_hz\": 60,\n \"map\": [\n  [\n   29.0,\n   31.0,\n   30\n  ],\n  [\n   58.0,\n   61.0,\n   60\n  ],\n  [\n   14.5,\n   15.5,\n   30\n  ],\n  [\n   19.5,\n   20.5,\n   60\n  ],\n  [\n   9.5,\n   10.5,\n   30\n  ]\n ]\n}";
        let j = parse(file).unwrap();
        assert_eq!(j.get("touch_hold_s"), Some(&J::Float(3.0)));
        assert_eq!(j.get("base_hz"), Some(&J::Int(120)));
        assert_eq!(dump_indent(&j, 1), file);
        assert_eq!(dump_indent(&J::Obj(vec![("a".into(), J::Arr(vec![])), ("b".into(), J::Obj(vec![]))]), 1), "{\n \"a\": [],\n \"b\": {}\n}");
    }

    #[test]
    fn dumps_like_python() {
        let j = J::Obj(vec![
            ("base_hz".into(), J::Int(120)),
            ("expected_hz".into(), J::Null),
            ("active".into(), J::Arr(vec![J::Str("plasmashell".into()), J::Bool(true), J::Int(3344)])),
            ("players".into(), J::Obj(vec![])),
            ("touch_age_s".into(), J::Float(24547.2)),
            ("odd".into(), J::Str("a\"b\\c\nd\u{1}é😀\u{7f}".into())),
            ("nan".into(), J::Arr(vec![J::Float(f64::NAN), J::Float(f64::INFINITY), J::Float(f64::NEG_INFINITY)])),
        ]);
        assert_eq!(dumps(&j), "{\"base_hz\": 120, \"expected_hz\": null, \"active\": [\"plasmashell\", true, 3344], \"players\": {}, \
            \"touch_age_s\": 24547.2, \"odd\": \"a\\\"b\\\\c\\nd\\u0001\\u00e9\\ud83d\\ude00\\u007f\", \"nan\": [NaN, Infinity, -Infinity]}");
    }

    #[test]
    fn parses_like_python() {
        let j = parse(" [1, -0, 2.5, 1e2, -1E-2, null, \"\\u00e9\\ud83d\\ude00\\/\"] ").unwrap();
        assert_eq!(j, J::Arr(vec![J::Int(1), J::Int(0), J::Float(2.5), J::Float(100.0), J::Float(-0.01), J::Null, J::Str("é😀/".into())]));
        assert!(matches!(&parse("[NaN]").unwrap(), J::Arr(v) if matches!(v[0], J::Float(f) if f.is_nan())));
        assert_eq!(parse("[Infinity, -Infinity]").unwrap(), J::Arr(vec![J::Float(f64::INFINITY), J::Float(f64::NEG_INFINITY)]));
        // a repeated key: its first place, its last value
        assert_eq!(parse("{\"a\": 1, \"b\": 2, \"a\": 3}").unwrap(), J::Obj(vec![("a".into(), J::Int(3)), ("b".into(), J::Int(2))]));
        // json.loads's messages, from python3 on the tablet
        for (s, e) in [("", "Expecting value: line 1 column 1 (char 0)"), ("  \n ", "Expecting value: line 2 column 2 (char 4)"),
            ("{} x", "Extra data: line 1 column 4 (char 3)"), ("{\"a\" 1}", "Expecting ':' delimiter: line 1 column 6 (char 5)"),
            ("[1 2]", "Expecting ',' delimiter: line 1 column 4 (char 3)"), ("{1: 2}", "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"),
            ("\"ab", "Unterminated string starting at: line 1 column 1 (char 0)"), ("\"a\nb\"", "Invalid control character at: line 1 column 3 (char 2)"),
            ("[01]", "Expecting ',' delimiter: line 1 column 3 (char 2)")]
        {
            assert_eq!(parse(s).unwrap_err(), e, "{s:?}");
        }
    }

    #[test]
    fn python_reprs() {
        assert_eq!(py_repr(&parse("[\"60\", true, null, 1.0, {\"x\": \"it's\"}]").unwrap()), "['60', True, None, 1.0, {'x': \"it's\"}]");
        assert_eq!(py_str_repr("a'b\"c"), "'a\\'b\"c'");
        assert_eq!(py_str_repr("tab\there\u{1}\u{a0}é\u{3000}"), "'tab\\there\\x01\\xa0é\\u3000'");
        assert_eq!(py_str(&J::Str("1".into())), "1");
        assert_eq!(py_str(&J::Int(1)), "1");
    }
}

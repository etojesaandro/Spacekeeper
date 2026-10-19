#!/usr/bin/env python3
"""Keeps the app's translations complete and safe.

  python3 -I Localization/strings.py keys     # every key the code uses, as iOS will look it up
  python3 -I Localization/strings.py check    # what is missing or does not match, per language
  python3 -I Localization/strings.py build    # writes <lang>.lproj files; refuses while check fails

English text is the key. A key is found in the app's sources wherever a string literal
is not plainly something else (a symbol name, a log line, an identifier listed in
ignored.json). Interpolations become format specifiers the way Swift makes them: a count
(an expression ending in .count, or `left`) becomes %lld, anything else %@. The code
keeps to that: numbers shown as numbers are formatted to text first.

Translations live in translations/<lang>.json as {key: text}, or for a key with a count
{key: {"format": "... %#@n@ ...", "one": "%lld ...", "few": ..., "many": ..., "other": ...}}.
A translation must use exactly the specifiers of its key, in any order when numbered
(%1$@, %2$lld), since a wrong one crashes the app.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SOURCES = ROOT.parent / "Sources" / "Offload"
LANGUAGES = ["en", "ru", "uk", "de", "es", "fr", "it", "pt-BR", "zh-Hans", "ja"]
COUNTS = re.compile(r"(\.count|^left)$")
SKIPPED_LINE = re.compile(r"\blog\.(notice|error|info|debug)\(|Logger\(|precondition\(|fatalError\(")
SKIPPED_BEFORE = re.compile(
    r"(systemImage:|systemName:|verbatim:|forKey:|withIdentifier:|service:|subsystem:|"
    r"category:|AppStorage\(|appendingPathComponent\(|NSSelectorFromString\(|"
    r"\.task\(id:|\.id\(|URL\(string:|URLComponents\(string:|name:|value:|method:|"
    r"client:|top:|\[\"Content-Type\"\]|headers:)\s*$"
)


def literals(text, offset_line=1):
    """Every string literal of Swift source, with its key and the text just before it.

    Literals inside the interpolations of another literal are found as well.
    """
    found = []
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = end + 3
            continue
        if text[i] == '"':
            key, end, inner = literal(text, i)
            line_start = text.rfind("\n", 0, i) + 1
            line_end = text.find("\n", i)
            number = offset_line + text.count("\n", 0, i)
            found.append((key, text[line_start:i], text[line_start:line_end], number))
            for expression in inner:
                found += literals(expression, number)
            i = end
            continue
        i += 1
    return found


def literal(text, start):
    """The key of the literal opening at start, where it ends, and its interpolated expressions."""
    out, inner = [], []
    i = start + 1
    while True:
        c = text[i]
        if c == '"':
            return "".join(out), i + 1, inner
        if c == "\\":
            n = text[i + 1]
            if n == "(":
                depth, j = 1, i + 2
                while depth:
                    if text[j] == '"':
                        _, j, _ = literal(text, j)
                        continue
                    depth += {"(": 1, ")": -1}.get(text[j], 0)
                    j += 1
                expression = text[i + 2 : j - 1].strip()
                inner.append(expression)
                out.append("%lld" if COUNTS.search(expression) else "%@")
                i = j
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1


def used():
    """Keys of the code, each with where it is used; and literals that are not keys."""
    ignored = set(json.loads((ROOT / "ignored.json").read_text()))
    keys = {}
    for path in sorted(SOURCES.glob("*.swift")):
        for key, before, line, number in literals(path.read_text()):
            where = f"{path.name}:{number}"
            if (
                not re.search(r"[A-Za-z]{2}", key)
                or re.fullmatch(r"[a-z0-9.\-/]+", key)
                or key in ignored
                or SKIPPED_LINE.search(line)
                or SKIPPED_BEFORE.search(before)
            ):
                continue
            keys.setdefault(key, []).append(where)
    return keys


def specifiers(text):
    """The format specifiers of a text, by the position of the argument they take."""
    found = {}
    position = 0
    for match in re.finditer(r"%(?:(\d+)\$)?(#@\w+@|lld|@|%)", text):
        if match.group(2) == "%":
            continue
        position = int(match.group(1)) if match.group(1) else position + 1
        found[position] = "lld" if match.group(2).startswith("#@") else match.group(2)
    return found


def problems(language, keys, table):
    """What is wrong with one language's translations."""
    wrong = []
    for key in keys:
        if key not in table:
            if language != "en" or specifiers(key) and "lld" in specifiers(key).values():
                wrong.append(f"missing: {key!r}")
            continue
        wanted = specifiers(key)
        value = table[key]
        if isinstance(value, dict):
            if "%#@n@" not in re.sub(r"%\d+\$#@n@", "%#@n@", value.get("format", "")):
                wrong.append(f"plural without %#@n@: {key!r}")
            if specifiers(value["format"]) != wanted:
                wrong.append(f"format {value['format']!r} takes {specifiers(value['format'])}, key takes {wanted}")
            if "other" not in value:
                wrong.append(f"plural without 'other': {key!r}")
            for form in ("zero", "one", "two", "few", "many", "other"):
                if form in value and set(specifiers(value[form]).values()) - {"lld"}:
                    wrong.append(f"form {form} of {key!r} takes more than the count")
        elif specifiers(value) != wanted:
            wrong.append(f"{value!r} takes {specifiers(value)}, key {key!r} takes {wanted}")
    for key in table:
        if key not in keys and not key.startswith("Info:"):
            wrong.append(f"unused: {key!r}")
    return wrong


def table(language):
    path = ROOT / "translations" / f"{language}.json"
    return json.loads(path.read_text()) if path.exists() else {}


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(language, keys, entries):
    folder = ROOT / f"{language}.lproj"
    folder.mkdir(exist_ok=True)
    plain = sorted((k, v) for k, v in entries.items() if isinstance(v, str) and not k.startswith("Info:"))
    counted = sorted((k, v) for k, v in entries.items() if isinstance(v, dict))
    lines = ["/* Made by Localization/strings.py from translations/%s.json. */" % language, ""]
    lines += [f'"{escape(k)}" = "{escape(v)}";' for k, v in plain]
    (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    info = {k[len("Info:"):]: v for k, v in entries.items() if k.startswith("Info:")}
    (folder / "InfoPlist.strings").write_text(
        "".join(f'"{escape(k)}" = "{escape(v)}";\n' for k, v in sorted(info.items())), encoding="utf-8"
    )
    plist = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
    ]
    for key, value in counted:
        plist += [f"  <key>{xml(key)}</key>", "  <dict>"]
        plist += ["    <key>NSStringLocalizedFormatKey</key>", f"    <string>{xml(value['format'])}</string>"]
        plist += ["    <key>n</key>", "    <dict>"]
        plist += ["      <key>NSStringFormatSpecTypeKey</key>", "      <string>NSStringPluralRuleType</string>"]
        plist += ["      <key>NSStringFormatValueTypeKey</key>", "      <string>lld</string>"]
        for form in ("zero", "one", "two", "few", "many", "other"):
            if form in value:
                plist += [f"      <key>{form}</key>", f"      <string>{xml(value[form])}</string>"]
        plist += ["    </dict>", "  </dict>"]
    plist += ["</dict>", "</plist>", ""]
    (folder / "Localizable.stringsdict").write_text("\n".join(plist), encoding="utf-8")


def xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    keys = used()
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "keys":
        for key, where in sorted(keys.items()):
            print(f"{key!r}  ({', '.join(where)})")
        print(f"{len(keys)} keys", file=sys.stderr)
        return 0
    broken = 0
    for language in LANGUAGES:
        wrong = problems(language, keys, table(language))
        for line in wrong:
            print(f"{language}: {line}")
        broken += len(wrong)
    if command == "build":
        if broken:
            print(f"{broken} problems; nothing written", file=sys.stderr)
            return 1
        for language in LANGUAGES:
            write(language, keys, table(language))
        print(f"wrote {len(LANGUAGES)} languages, {len(keys)} keys", file=sys.stderr)
    elif not broken:
        print("all languages complete", file=sys.stderr)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Writes third_party/ufbx/ufbx.odin, the Odin binding of the whole ufbx API, from the description
of ufbx.h that the bindgen of ufbx makes (bindgen/ufbx_parser.py and bindgen/ufbx_ir.py of a
checkout of ufbx at the version of third_party/ufbx).

Structs keep the layout of C: a ufbx_string is an Odin string, a ufbx_blob a []u8 and a list a
slice, which are laid out the same; anonymous unions and structs are `using` fields. The binding
asserts the size of every struct and the offset of every named field on 64-bit targets, with the
numbers bindgen computed for x64, so a binding that drifts from the header does not compile.

Usage: uv run scripts/ufbx_binding.py <ufbx checkout>
"""

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
TARGET = os.path.join(ROOT, "third_party", "ufbx")

KEYWORDS = {
    "asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue",
    "defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if",
    "import", "in", "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
    "package", "proc", "return", "struct", "switch", "transmute", "typeid", "union", "using",
    "when", "where", "string", "rawptr", "any",
}

PRIMITIVES = {
    "bool": "bool", "char": "u8", "double": "f64", "float": "f32", "int32_t": "i32",
    "int64_t": "i64", "ptrdiff_t": "int", "size_t": "uint", "uint32_t": "u32", "uint64_t": "u64",
    "uint8_t": "u8", "uintptr_t": "uintptr", "UFBX_REAL_TYPE": "f64",
}


def type_name(c):
    name = c[len("ufbx_"):] if c.startswith("ufbx_") else c
    return "_".join(part[:1].upper() + part[1:] for part in name.split("_"))


def field_name(name):
    return name + "_" if name in KEYWORDS else name


class Binding:
    def __init__(self, ir):
        self.ir = ir
        self.types = ir["types"]
        self.structs = ir["structs"]
        self.enums = ir["enums"]
        self.values = ir["enumValues"]
        self.typedefs = ir["typedefs"]

    def is_function(self, key):
        t = self.types[key]
        if t["kind"] == "function":
            return True
        if t["kind"] == "typedef":
            return self.is_function(t["inner"])
        return False

    def odin(self, key):
        t = self.types[key]
        kind = t["kind"]
        if kind in ("", "define"):
            if t["key"] == "void":
                return ""
            return PRIMITIVES[t["key"]]
        if kind in ("const", "unsafe"):
            return self.odin(t["inner"])
        if kind == "typedef":
            name = t["baseName"]
            if name == "ufbx_real":
                return "Real"
            return type_name(name)
        if kind == "enum":
            return type_name(t["baseName"])
        if kind == "array":
            return f"[{t['arrayLength']}]{self.odin(t['inner'])}"
        if kind == "function":
            return self.proc_type(t)
        if kind == "struct":
            name = t["baseName"]
            if name == "ufbx_string":
                return "string"
            if name == "ufbx_blob":
                return "[]u8"
            st = self.structs.get(name)
            if st and st["isList"]:
                return "[]" + self.list_element(st)
            return type_name(name)
        if kind == "pointer":
            inner = t["inner"]
            if self.is_function(inner):
                return self.odin(inner)
            it = self.types[inner]
            while it["kind"] in ("const", "unsafe"):
                it = self.types[it["inner"]]
            if it["key"] == "char":
                return "cstring"
            if it["key"] == "void":
                return "rawptr"
            if it["kind"] in ("struct", "enum") or (it["kind"] == "typedef" and not self.is_function(it["key"])):
                return "^" + self.odin(it["key"])
            return "[^]" + self.odin(it["key"])
        raise RuntimeError(f"unhandled type {key} of kind {kind}")

    def list_element(self, st):
        data = next(f for f in st["fields"] if f["name"] == "data")
        t = self.types[data["type"]]
        assert t["kind"] == "pointer", data["type"]
        return self.odin(t["inner"])

    def proc_type(self, t):
        args = []
        for i, a in enumerate(t["funcArgs"]):
            if self.types[a["type"]]["key"] == "void" and len(t["funcArgs"]) == 1:
                break
            args.append(f"{field_name(a['name'] or f'arg{i}')}:{self.odin(a['type'])}")
        result = self.odin(t["inner"])
        tail = f" -> {result}" if result else ""
        return f"proc \"c\" ({','.join(args)}){tail}"

    # anonymous counts the anonymous members of the whole struct: `using` puts their names in one scope.
    def struct_body(self, name, indent, anonymous):
        st = self.structs[name]
        lines = []
        for f in st["fields"]:
            if f["name"] == "":
                inner = self.structs[f["type"]]
                head = "struct #raw_union" if inner["isUnion"] else "struct"
                lines.append(f"{indent}using _anonymous{anonymous[0]}:{head} {{")
                anonymous[0] += 1
                lines += self.struct_body(f["type"], indent + "    ", anonymous)
                lines.append(f"{indent}}},")
            else:
                lines.append(f"{indent}{field_name(f['name'])}:{self.odin(f['type'])},")
        return lines

    def write(self, out):
        w = out.append
        w("package ufbx")
        w("")
        w("// Generated by scripts/ufbx_binding.py from ufbx.h; do not edit.")
        w("")
        w("when ODIN_OS==.Windows {")
        w("    foreign import lib \"windows/ufbx.lib\"")
        w("} else when ODIN_OS==.Linux {")
        w("    foreign import lib \"linux/ufbx.a\"")
        w("} else when ODIN_OS==.Darwin {")
        w("    when ODIN_ARCH==.arm64 {foreign import lib \"macos-arm64/ufbx.a\"}")
        w("    else {foreign import lib \"macos/ufbx.a\"}")
        w("}")
        w("")
        w("Real :: f64")
        w("")
        for name, c in self.ir["constants"].items():
            if "valueInt" in c:
                w(f"{name[len('UFBX_'):]} :: {c['valueInt']}")
        w("")
        for name, td in self.typedefs.items():
            if name == "ufbx_real":
                continue
            if self.is_function(td["type"]):
                w(f"{type_name(name)} :: #type {self.proc_type(self.types[td['type']])}")
            else:
                w(f"{type_name(name)} :: {self.odin(td['type'])}")
        w("")
        for name, en in self.enums.items():
            if en["flag"]:
                w(f"{type_name(name)} :: distinct u32")
                for value in en["values"]:
                    v = self.values[value]
                    w(f"{value[len('UFBX_'):]} :: {type_name(name)}({v['value']})")
            else:
                w(f"{type_name(name)} :: enum i32 {{")
                for value in en["values"]:
                    v = self.values[value]
                    short = v["shortName"]
                    if short[:1].isdigit():
                        short = "_" + short
                    w(f"    {short}={v['value']},")
                w("}")
            w("")
        for name, st in self.structs.items():
            if st["isAnonymous"] or st["isList"] or name in ("ufbx_string", "ufbx_blob"):
                continue
            head = "struct #raw_union" if st["isUnion"] else "struct"
            w(f"{type_name(name)} :: {head} {{")
            out.extend(self.struct_body(name, "    ", [0]))
            w("}")
            w("")
        w("@(default_calling_convention=\"c\")")
        w("foreign lib {")
        for name, fn in self.ir["functions"].items():
            if fn["isInline"]:
                continue
            args = []
            for a in fn["arguments"]:
                args.append(f"{field_name(a['name'])}:{self.odin(a['type'])}")
            result = self.odin(fn["returnType"])
            tail = f" -> {result}" if result else ""
            w(f"    @(link_name=\"{name}\") {name[len('ufbx_'):]} :: proc({','.join(args)}){tail} ---")
        w("}")
        w("")
        w("// The layout of C, as bindgen computed it for x64.")
        w("when size_of(rawptr)==8 {")
        for name, st in self.structs.items():
            if st["isAnonymous"] or st["isList"] or name in ("ufbx_string", "ufbx_blob"):
                continue
            odin_name = type_name(name)
            w(f"    #assert(size_of({odin_name})=={self.types[name]['size']['x64']})")
            for f in st["fields"]:
                if f["name"]:
                    w(f"    #assert(offset_of({odin_name},{field_name(f['name'])})=={f['offset']['x64']})")
        w("}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    checkout = os.path.realpath(sys.argv[1])
    with open(os.path.join(checkout, "ufbx.h"), "rb") as a, open(os.path.join(TARGET, "ufbx.h"), "rb") as b:
        if a.read() != b.read():
            sys.exit("the ufbx.h of the checkout is not the one of third_party/ufbx")
    bindgen = os.path.join(checkout, "bindgen")
    for script in ("ufbx_parser.py", "ufbx_ir.py"):
        subprocess.run([sys.executable, os.path.join(bindgen, script)], cwd=bindgen, check=True)
    with open(os.path.join(bindgen, "build", "ufbx_typed.json"), encoding="utf-8") as f:
        ir = json.load(f)
    out = []
    Binding(ir).write(out)
    with open(os.path.join(TARGET, "ufbx.odin"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {os.path.join(TARGET, 'ufbx.odin')}")


if __name__ == "__main__":
    main()

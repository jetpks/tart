// Golden fixture generator: runs pi's REAL tool code (read.ts/write.ts/edit.ts/
// edit-diff.ts/truncate.ts copied verbatim from the read-only oracle repo) under
// node --experimental-strip-types, and records expected outputs. The Ruby port
// asserts these goldens; they are never derived from the port's own behavior.
import { createReadToolDefinition } from "./core/tools/read.ts";
import { createWriteToolDefinition } from "./core/tools/write.ts";
import { createEditToolDefinition } from "./core/tools/edit.ts";
import * as D from "./core/tools/edit-diff.ts";
import { splitBom } from "./utils/text.ts";
import * as T from "./core/tools/truncate.ts";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "i03-golden-"));
const out = {
  generated_by: "pi sources (packages/coding-agent/src/core/tools) via node --experimental-strip-types",
  workdir_basename: path.basename(workdir),
  read_cases: [],
  write_cases: [],
  edit_cases: [],
  edit_unit_cases: [],
  truncate_cases: [],
};

async function record(arr, name, fn) {
  try {
    const value = await fn();
    arr.push({ name, ok: true, value });
  } catch (e) {
    arr.push({ name, ok: false, error: e.message });
  }
}

// ---------- read ----------
const read = createReadToolDefinition(workdir);
function rf(name, bytes) {
  const p = path.join(workdir, name);
  fs.writeFileSync(p, Buffer.from(bytes, "base64"));
  return name;
}
// trailing whitespace survives verbatim
await record(out.read_cases, "trailing_ws", () =>
  read.execute("t1", { path: rf("trailing.txt", Buffer.from("line one  \nline two\t\n", "utf8").toString("base64"), ) ? "trailing.txt" : "" }));
await record(out.read_cases, "bom_crlf", () => {
  rf("bom.bin", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("a\r\nb\r\n", "utf8")]).toString("base64")) ? "bom.bin" : "";
  return read.execute("t2", { path: "bom.bin" }).then((r) => JSON.stringify(r.content[0].text));
});
await record(out.read_cases, "offset_limit", () =>
  read.execute("t3", { path: "trailing.txt", offset: 2, limit: 1 }).then((r) => r.content[0].text));
await record(out.read_cases, "offset_beyond_eof", () =>
  read.execute("t4", { path: "trailing.txt", offset: 99 }));
await record(out.read_cases, "missing_file", () =>
  read.execute("t5", { path: "nope.txt" }));
// long file: line-limit truncation notice
await record(out.read_cases, "many_lines", () => {
  fs.writeFileSync(path.join(workdir, "many.txt"), Array.from({length: 2500}, (_, i) => `l${i + 1}`).join("\n") + "\n");
  return read.execute("t6", { path: "many.txt" }).then((r) => r.content[0].text);
});
// byte-limit truncation notice (single long lines)
await record(out.read_cases, "byte_limit", () => {
  fs.writeFileSync(path.join(workdir, "big.txt"), Array.from({length: 100}, (_, i) => "x".repeat(2000) + `-${i}`).join("\n") + "\n");
  return read.execute("t7", { path: "big.txt" }).then((r) => r.content[0].text.slice(0, 400));
});

// ---------- write ----------
const write = createWriteToolDefinition(workdir);
await record(out.write_cases, "verbatim_trailing_ws", async () => {
  const content = "no trailing newline  \nsecond\t\n";
  const r = await write.execute("w1", { path: "out1.txt", content });
  const written = fs.readFileSync(path.join(workdir, "out1.txt"), "base64");
  return { message: r.content[0].text, written_base64: written, content_base64: Buffer.from(content, "utf8").toString("base64") };
});
await record(out.write_cases, "nested_dirs", async () => {
  const r = await write.execute("w2", { path: "deep/nested/dir/out.txt", content: "x" });
  return { message: r.content[0].text, exists: fs.existsSync(path.join(workdir, "deep/nested/dir/out.txt")) };
});

// ---------- edit ----------
const edit = createEditToolDefinition(workdir);
async function editCase(name, fileBytes, edits) {
  return record(out.edit_cases, name, async () => {
    const p = "e-" + name + ".txt";
    fs.writeFileSync(path.join(workdir, p), Buffer.from(fileBytes, "base64"));
    const r = await edit.execute("x", { path: p, edits });
    const written = fs.readFileSync(path.join(workdir, p)).toString("base64");
    return { message: r.content[0].text, details: r.details, written_base64: written };
  });
}
// exact match, no trailing WS
await editCase("exact", Buffer.from("alpha\nbeta\ngamma\n", "utf8").toString("base64"),
  [{ oldText: "beta", newText: "BETA" }]);
// oldText carries trailing WS that matches file exactly
await editCase("exact_trailing_ws", Buffer.from("alpha  \nbeta\t\n", "utf8").toString("base64"),
  [{ oldText: "alpha  \nbeta\t\n", newText: "alpha\n" }]);
// §5 case: clean oldText vs trailing-WS file -> fuzzy match; UNCHANGED lines keep their bytes
await editCase("fuzzy_trailing_ws", Buffer.from("alpha  \nbeta\t\ngamma \n", "utf8").toString("base64"),
  [{ oldText: "alpha\n", newText: "ALPHA\n" }]);
// §5 case: replacement ADDS trailing WS and it must survive verbatim
await editCase("replacement_trailing_ws", Buffer.from("alpha\nbeta\n", "utf8").toString("base64"),
  [{ oldText: "beta", newText: "beta  " }]);
// smart quotes fold
await editCase("smart_quotes", Buffer.from("don\u2019t stop\u2026\n", "utf8").toString("base64"),
  [{ oldText: "don't stop...", newText: "done" }]);
// en-dash fold
await editCase("dashes", Buffer.from("a\u2013b\u2014c\n", "utf8").toString("base64"),
  [{ oldText: "a-b-c", newText: "abc" }]);
// CRLF preserved
await editCase("crlf", Buffer.from("a\r\nb\r\nc\r\n", "utf8").toString("base64"),
  [{ oldText: "b", newText: "B" }]);
// BOM preserved
await editCase("bom", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("a\nb\n", "utf8")]).toString("base64"),
  [{ oldText: "a", newText: "A" }]);
// multi-edit disjoint
await editCase("multi", Buffer.from("one\ntwo\nthree\nfour\n", "utf8").toString("base64"),
  [{ oldText: "one", newText: "ONE" }, { oldText: "four", newText: "FOUR" }]);
// multi-edit mixed fuzzy
await editCase("multi_fuzzy", Buffer.from("x  \ny\nz\t\n", "utf8").toString("base64"),
  [{ oldText: "x\n", newText: "X\n" }, { oldText: "z\n", newText: "Z\n" }]);
// errors
await editCase("not_found", Buffer.from("a\nb\n", "utf8").toString("base64"),
  [{ oldText: "nope", newText: "x" }]);
await editCase("duplicate", Buffer.from("dup\ndup\n", "utf8").toString("base64"),
  [{ oldText: "dup", newText: "x" }]);
await editCase("no_change", Buffer.from("a\nb\n", "utf8").toString("base64"),
  [{ oldText: "a", newText: "a" }]);
await editCase("empty_old_text", Buffer.from("a\nb\n", "utf8").toString("base64"),
  [{ oldText: "", newText: "x" }]);
await editCase("overlap", Buffer.from("abcd\n", "utf8").toString("base64"),
  [{ oldText: "ab", newText: "X" }, { oldText: "bc", newText: "Y" }]);
await editCase("legacy_top_level_args", Buffer.from("a\nb\n", "utf8").toString("base64"), null); // placeholder

// legacy top-level oldText/newText (prepareEditArguments)
await record(out.edit_cases, "legacy_args", async () => {
  const p = "legacy.txt";
  fs.writeFileSync(path.join(workdir, p), "hello\nworld\n");
  const r = await edit.execute("x", { path: p, oldText: "hello", newText: "HELLO", edits: [] }).catch((e) => ({ error: e.message }));
  if (r.error) return { error: r.error };
  return { message: r.content[0].text, written_base64: fs.readFileSync(path.join(workdir, p)).toString("base64") };
});

// ---------- edit-diff units ----------
function unit(arr, name, fn) {
  try {
    arr.push({ name, ok: true, value: fn() });
  } catch (e) {
    arr.push({ name, ok: false, error: e.message });
  }
}
unit(out.edit_unit_cases, "normalize_smart_quotes", () => D.normalizeForFuzzyMatch("\u2018x\u2019 \u201Cy\u201D"));
unit(out.edit_unit_cases, "normalize_spaces", () => D.normalizeForFuzzyMatch("a\u00A0b\u2003c\u202Fd"));
unit(out.edit_unit_cases, "normalize_dashes", () => D.normalizeForFuzzyMatch("a\u2010b\u2013c\u2014d\u2212e"));
unit(out.edit_unit_cases, "normalize_trailing_ws", () => D.normalizeForFuzzyMatch("a  \nb\t\nc"));
unit(out.edit_unit_cases, "normalize_not_internal_runs", () => D.normalizeForFuzzyMatch("a  b"));
unit(out.edit_unit_cases, "fuzzy_find_exact", () => D.fuzzyFindText("abc\n", "abc"));
unit(out.edit_unit_cases, "fuzzy_find_fuzzy", () => D.fuzzyFindText("abc  \n", "abc"));
unit(out.edit_unit_cases, "fuzzy_find_miss", () => D.fuzzyFindText("abc\n", "xyz"));
unit(out.edit_unit_cases, "detect_line_ending_crlf", () => D.detectLineEnding("a\r\nb\n"));
unit(out.edit_unit_cases, "detect_line_ending_lf", () => D.detectLineEnding("a\nb\r\n"));
unit(out.edit_unit_cases, "detect_line_ending_none", () => D.detectLineEnding("ab"));
unit(out.edit_unit_cases, "split_bom", () => JSON.stringify(splitBom("\uFEFFab")));

// ---------- truncate units ----------
function tcase(name, fn) {
  unit(out.truncate_cases, name, () => JSON.stringify(fn()));
}
tcase("head_no_truncation", () => T.truncateHead("a\nb\nc"));
tcase("head_line_limit", () => T.truncateHead(Array.from({length: 30}, (_, i) => `l${i}`).join("\n"), { maxLines: 10 }));
tcase("head_byte_limit", () => T.truncateHead(Array.from({length: 10}, (_, i) => "y".repeat(10)).join("\n"), { maxBytes: 25 }));
tcase("head_first_line_exceeds", () => T.truncateHead("z".repeat(100) + "\nshort\n", { maxBytes: 50 }));
tcase("head_trailing_ws_lines", () => T.truncateHead("a  \nb\t\n  c\n", { maxLines: 2 }));
tcase("tail_no_truncation", () => T.truncateTail("a\nb\nc"));
tcase("tail_line_limit", () => T.truncateTail(Array.from({length: 30}, (_, i) => `l${i}`).join("\n"), { maxLines: 10 }));
tcase("tail_byte_limit", () => T.truncateTail(Array.from({length: 10}, (_, i) => "y".repeat(10)).join("\n"), { maxBytes: 25 }));
tcase("tail_single_huge_line_partial", () => T.truncateTail("s".repeat(100) + "\ntail\n", { maxBytes: 30 }));
tcase("format_size", () => [T.formatSize(500), T.formatSize(5000), T.formatSize(5000000)].join(","));
tcase("truncate_line", () => JSON.stringify(T.truncateLine("a".repeat(600))));
tcase("truncate_middle", () => T.truncateMiddle("m".repeat(1000), 100).content);

fs.rmSync(workdir, { recursive: true, force: true });
let json = JSON.stringify(out, null, 1).split(workdir).join("$WORKDIR");
json = json.split(path.basename(workdir)).join("$WORKDIR_NAME");
process.stdout.write(json);

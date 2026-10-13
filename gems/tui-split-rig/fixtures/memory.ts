import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const INDEX_FILE = "MEMORY.md";
const DEFAULT_HOME = path.join(os.homedir(), ".pi", "agent", "memory");
// Recall bound: first 200 lines AND 25KB of the index, whichever hits first.
// Injecting the whole index on every session start would tax context forever;
// anything past the bound is still reachable via the `memory list` action.
const RECALL_MAX_LINES = 200;
const RECALL_MAX_BYTES = 25 * 1024;
const SUMMARY_MAX_CHARS = 120;
const RECALL_HEADER =
	"[project memory] index loaded at session start; use the memory tool (read/list) for topic files:";
const TRUNCATION_NOTICE =
	"[project memory] index is truncated; more entries exist — use the memory tool list action.";
// sendMessage content reaches the model as a bare user-role message with no
// wrapper, so every injection self-identifies to avoid being attributed to the
// user's own words.
const CUSTOM_TYPE = "memory-recall";

function memoryHome(): string {
	return process.env.PI_MEMORY_HOME || DEFAULT_HOME;
}

/** Walk cwd upward for a `.git` entry (file or dir — worktrees use a file). */
function gitRoot(cwd: string): string | null {
	let dir = cwd;
	for (;;) {
		if (fs.existsSync(path.join(dir, ".git"))) return dir;
		const parent = path.dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

/**
 * Project key: basename of the git root so every worktree of a repo shares one
 * memory store; fall back to the cwd basename outside any repo.
 */
function projectName(cwd: string): string {
	return path.basename(gitRoot(cwd) ?? cwd);
}

function projectMemoryDir(cwd: string): string {
	return path.join(memoryHome(), projectName(cwd));
}

function slugify(topic: string): string {
	return topic
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "");
}

/** Resolve a topic to its file, rejecting anything that could escape the dir. */
function resolveTopicFile(cwd: string, topic: string): { file: string; slug: string; dir: string } {
	// Reject absolute and `..`-escaping topics outright rather than silently
	// sanitizing them, so the model learns the topic was unusable.
	if (topic.startsWith("/") || topic.split("/").includes("..")) {
		throw new Error(`Invalid topic "${topic}": topics are plain names inside the project memory directory, not paths.`);
	}
	const slug = slugify(topic);
	// The slug charset below admits no separators, so absolute or `..`-escaping
	// topics collapse to "" or a safe name — reject the empty case explicitly and
	// keep a resolved-path containment check as the real gate.
	if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(slug)) {
		throw new Error(`Invalid topic "${topic}": it must be a plain name like "deploy" (letters, numbers, dashes).`);
	}
	const dir = projectMemoryDir(cwd);
	const file = path.join(dir, `${slug}.md`);
	if (!file.startsWith(dir + path.sep)) {
		throw new Error(`Invalid topic "${topic}": it must stay inside the project memory directory.`);
	}
	return { file, slug, dir };
}

function firstLine(text: string): string {
	const line = text.split("\n").find((l) => l.trim() !== "") ?? "";
	return line.length > SUMMARY_MAX_CHARS ? `${line.slice(0, SUMMARY_MAX_CHARS - 1)}…` : line;
}

function upsertIndexLine(dir: string, slug: string, topic: string, text: string): void {
	const file = path.join(dir, INDEX_FILE);
	const existing = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
	const kept = existing
		.split("\n")
		.filter((l) => l.trim() !== "" && !l.includes(`](${slug}.md)`));
	kept.push(`- [${topic}](${slug}.md): ${firstLine(text)}`);
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(file, `${kept.join("\n")}\n`);
}

/** Truncate to the recall bound: stop at the first of 200 lines / 25KB. */
function boundIndex(raw: string): { text: string; truncated: boolean } {
	const kept: string[] = [];
	let bytes = 0;
	for (const line of raw.split("\n")) {
		if (kept.length >= RECALL_MAX_LINES) return { text: kept.join("\n"), truncated: true };
		const cost = Buffer.byteLength(line, "utf8") + 1;
		if (bytes + cost > RECALL_MAX_BYTES) return { text: kept.join("\n"), truncated: true };
		kept.push(line);
		bytes += cost;
	}
	return { text: kept.join("\n"), truncated: false };
}

function textResult(text: string, isError = false) {
	return { content: [{ type: "text" as const, text }], details: undefined, isError };
}

export default function memoryExtension(pi: ExtensionAPI): void {
	pi.on("session_start", (event, ctx) => {
		const file = path.join(projectMemoryDir(ctx.cwd), INDEX_FILE);
		if (!fs.existsSync(file)) return;
		const bound = boundIndex(fs.readFileSync(file, "utf8"));
		const content = [RECALL_HEADER, bound.text, ...(bound.truncated ? [TRUNCATION_NOTICE] : [])]
			.filter(Boolean)
			.join("\n");
		// Once per session_start, never per turn: per-turn recall re-sends the
		// index every turn and burns context for the whole session.
		pi.sendMessage({ customType: CUSTOM_TYPE, content, display: true }, { deliverAs: "nextTurn" });
	});

	pi.registerTool({
		name: "memory",
		label: "Memory",
		description:
			"Persistent per-project memory. Save durable facts, preferences, and corrections worth carrying to future sessions — never secrets, never one-off task state. Topic files are read on demand.",
		promptGuidelines: [
			"Use the memory tool to save durable facts, user preferences, and corrections worth carrying to future sessions — never secrets and never one-off task state.",
			"Use the memory tool list/read actions to recall saved topics on demand instead of guessing what was remembered.",
		],
		annotations: {},
		parameters: Type.Object({
			action: Type.Union([Type.Literal("save"), Type.Literal("read"), Type.Literal("list")], {
				description: "save: store text under topic; read: return a topic file; list: return the index",
			}),
			topic: Type.Optional(Type.String({ description: "Topic name, e.g. deploy (required for save/read)" })),
			text: Type.Optional(Type.String({ description: "Text to remember (save only)" })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			if (params.action !== "list" && !params.topic?.trim()) {
				return textResult(`The memory tool ${params.action} action needs a topic.`, true);
			}
			if (params.action === "save") {
				if (!params.text?.trim()) return textResult("The memory tool save action needs text to remember.", true);
				const { file, slug, dir } = resolveTopicFile(ctx.cwd, params.topic);
				fs.mkdirSync(dir, { recursive: true });
				fs.writeFileSync(file, `---\nmodified: ${new Date().toISOString()}\n---\n\n${params.text.trim()}\n`);
				upsertIndexLine(dir, slug, params.topic.trim(), params.text);
				return textResult(`Saved memory topic "${params.topic}" (${slug}.md).`);
			}
			if (params.action === "read") {
				const { file, slug } = resolveTopicFile(ctx.cwd, params.topic!);
				if (!fs.existsSync(file)) {
					return textResult(
						`No memory saved for topic "${params.topic}" (${slug}.md). Use the memory tool list action to see saved topics.`,
						true,
					);
				}
				return textResult(fs.readFileSync(file, "utf8"));
			}
			const indexFile = path.join(projectMemoryDir(ctx.cwd), INDEX_FILE);
			if (!fs.existsSync(indexFile)) {
				return textResult("No project memory yet. Save some with the memory tool save action.");
			}
			return textResult(fs.readFileSync(indexFile, "utf8"));
		},
	});
}

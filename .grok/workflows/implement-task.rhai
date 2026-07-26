let meta = #{
    name: "implement-task",
    description: "Implement one macverbs roadmap task (docs/tasks/TNN.md), verify with mise check, mark done",
    when_to_use: "Advancing macverbs one task at a time from the roadmap",
    phases: [
        #{ title: "Resolve", detail: "Pick task id and load specs" },
        #{ title: "Implement", detail: "Single-task implementation" },
        #{ title: "Verify", detail: "mise check + adversarial review" },
        #{ title: "Close", detail: "Mark task done or report blockers" },
    ],
};

let resolve_schema = #{
    "type": "object",
    "required": ["task_id", "task_path", "manual", "blocked", "block_reason", "summary"],
    "properties": #{
        "task_id": #{ "type": "string" },
        "task_path": #{ "type": "string" },
        "manual": #{ "type": "boolean" },
        "blocked": #{ "type": "boolean" },
        "block_reason": #{ "type": "string" },
        "summary": #{ "type": "string" },
    },
};

let implement_schema = #{
    "type": "object",
    "required": ["ok", "summary", "files_changed", "check_ran", "check_passed", "notes"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "files_changed": #{ "type": "array", "items": #{ "type": "string" }, "maxItems": 40 },
        "check_ran": #{ "type": "boolean" },
        "check_passed": #{ "type": "boolean" },
        "notes": #{ "type": "string" },
    },
};

let verify_schema = #{
    "type": "object",
    "required": ["pass", "issues", "evidence"],
    "properties": #{
        "pass": #{ "type": "boolean" },
        "issues": #{
            "type": "array",
            "maxItems": 12,
            "items": #{
                "type": "object",
                "required": ["severity", "detail"],
                "properties": #{
                    "severity": #{ "type": "string" },
                    "detail": #{ "type": "string" },
                },
            },
        },
        "evidence": #{ "type": "string" },
    },
};

let close_schema = #{
    "type": "object",
    "required": ["closed", "task_id", "status", "message"],
    "properties": #{
        "closed": #{ "type": "boolean" },
        "task_id": #{ "type": "string" },
        "status": #{ "type": "string" },
        "message": #{ "type": "string" },
    },
};

// --- args ---
let raw = if args == () { () } else { args.task };
if raw == () {
    pause("verification", "Pass args.task — e.g. \"T01\" or \"next\".");
}
let task_arg = raw;
if type_of(task_arg) != "string" {
    pause("verification", "args.task must be a string (T01 or next).");
}

phase("Resolve");

let resolve_prompt = "";
resolve_prompt += "You are resolving the next work item for the macverbs repo.\n";
resolve_prompt += "Working directory MUST be the macverbs git root (contains AGENTS.md and mise.toml).\n";
resolve_prompt += "Requested task arg: " + task_arg + "\n\n";
resolve_prompt += "Steps (use tools; do not invent file contents):\n";
resolve_prompt += "1. Read AGENTS.md and docs/ROADMAP.md.\n";
resolve_prompt += "2. If task arg is \"next\", run: mise run next   (prints T0N or empty).\n";
resolve_prompt += "3. If empty next, set blocked=true and explain all tasks done or only manual left.\n";
resolve_prompt += "4. Load docs/tasks/<ID>.md. Parse frontmatter: status, depends, manual.\n";
resolve_prompt += "5. For each dependency id, read its task file; if status is not done, blocked=true.\n";
resolve_prompt += "6. If status is already done, blocked=true with reason already done.\n";
resolve_prompt += "7. If manual=true, set manual=true (do not implement later phases as auto-done).\n";
resolve_prompt += "8. Return task_id, task_path, manual, blocked, block_reason, summary.\n";

let resolved = agent(resolve_prompt, #{
    label: "resolve-task",
    capability_mode: "execute",
    output_schema: resolve_schema,
});

if resolved == () || !resolved.success || resolved.output == () {
    complete(#{
        summary: "Resolve agent failed",
        ok: false,
        task: task_arg,
    });
}

let R = resolved.output;
// Canned validate_only outputs may leave fields as (); coerce carefully.
let r_blocked = R.blocked != () && R.blocked == true;
let r_manual = R.manual != () && R.manual == true;
let r_task_id = if R.task_id == () { task_arg } else { R.task_id };
let r_task_path = if R.task_path == () { "docs/tasks/" + r_task_id + ".md" } else { R.task_path };
let r_summary = if R.summary == () { "" } else { R.summary };
let r_block_reason = if R.block_reason == () { "" } else { R.block_reason };
let blocked_s = if r_blocked { "true" } else { "false" };
let manual_s = if r_manual { "true" } else { "false" };
log("Resolved " + r_task_id + " blocked=" + blocked_s + " manual=" + manual_s);

if r_blocked {
    let p = write_scratch_file("report.md", "# Blocked\n\n" + r_block_reason + "\n\n" + r_summary);
    complete(#{
        summary: "Blocked: " + r_block_reason,
        ok: false,
        blocked: true,
        task_id: r_task_id,
        path: p,
    });
}

if r_manual {
    let msg = "";
    msg += "# Manual task " + r_task_id + "\n\n";
    msg += r_summary + "\n\n";
    msg += "This task is marked manual:true. Human must run the smoke checklist,\n";
    msg += "update docs/gotchas.md if needed, then set status: done in " + r_task_path + ".\n";
    let p2 = write_scratch_file("report.md", msg);
    complete(#{
        summary: "Manual task — waiting on human: " + r_task_id,
        ok: true,
        manual: true,
        task_id: r_task_id,
        path: p2,
    });
}

phase("Implement");

let impl_prompt = "";
impl_prompt += "Implement ONLY task " + r_task_id + " for macverbs.\n";
impl_prompt += "Read and follow AGENTS.md strictly.\n";
impl_prompt += "Task file: " + r_task_path + "\n";
impl_prompt += "Also read docs/behavior.md and, if needed, the Python oracle at ~/nix/clis/apple (MACVERBS_APPLE_SPEC).\n\n";
impl_prompt += "Rules:\n";
impl_prompt += "- Implement only this task's Done when criteria. No drive-by refactors.\n";
impl_prompt += "- Use mise run build / mise run test / mise run check when code exists.\n";
impl_prompt += "- If Package.swift does not exist yet and this is T01, create the SPM scaffold.\n";
impl_prompt += "- Hybrid backends: EventKit for calendar/reminders; Apple Events for mail/notes.\n";
impl_prompt += "- Unit tests with mocks; no live Mail/Reminders required for check to pass.\n";
impl_prompt += "- Do not push to origin, do not create GitHub releases, do not publish Homebrew.\n";
impl_prompt += "- Commit locally with a conventional message if the tree is a git repo and changes are ready.\n";
impl_prompt += "- Set task frontmatter status to in_progress at start; do NOT set done yet.\n\n";
impl_prompt += "Return ok, summary, files_changed, check_ran, check_passed, notes.\n";

let implemented = agent(impl_prompt, #{
    label: "implement",
    capability_mode: "all",
    output_schema: implement_schema,
});

if implemented == () || !implemented.success || implemented.output == () {
    complete(#{
        summary: "Implement agent failed",
        ok: false,
        task_id: r_task_id,
    });
}

let I = implemented.output;
let i_ok = I.ok != () && I.ok == true;
let i_check = I.check_passed != () && I.check_passed == true;
let i_summary = if I.summary == () { "" } else { I.summary };
let iok = if i_ok { "true" } else { "false" };
let icp = if i_check { "true" } else { "false" };
log("Implement ok=" + iok + " check_passed=" + icp);

phase("Verify");

let ver_prompt = "";
ver_prompt += "Adversarially verify that task " + r_task_id + " is truly complete.\n";
ver_prompt += "Read " + r_task_path + " Done when criteria.\n";
ver_prompt += "Inspect the git diff and key files with tools (read_file, grep, run_terminal_command).\n";
ver_prompt += "Run: mise run check   (or report if impossible and why).\n";
ver_prompt += "Set pass=true ONLY if every Done when item is met AND check is green (or N/A with solid evidence for docs-only).\n";
ver_prompt += "List issues with severity bug|gap|nit. evidence must cite commands/files you actually ran/read.\n";
ver_prompt += "Empty issues is valid only after you inspected the tree.\n";

let verified = agent(ver_prompt, #{
    label: "verify",
    capability_mode: "execute",
    output_schema: verify_schema,
});

if verified == () || !verified.success || verified.output == () {
    complete(#{
        summary: "Verify agent failed",
        ok: false,
        task_id: r_task_id,
        implement_summary: i_summary,
    });
}

let V = verified.output;
let v_pass = V.pass != () && V.pass == true;
let v_evidence = if V.evidence == () { "" } else { V.evidence };
let vpass = if v_pass { "true" } else { "false" };
log("Verify pass=" + vpass);

phase("Close");

let close_prompt = "";
close_prompt += "Close out task " + r_task_id + ".\n";
close_prompt += "Verify pass flag: " + vpass + "\n";
close_prompt += "Implement summary: " + i_summary + "\n";
close_prompt += "Verify evidence: " + v_evidence + "\n\n";
close_prompt += "If verify pass is true:\n";
close_prompt += "- Edit " + r_task_path + ": set status: done; tick Done when checkboxes to [x].\n";
close_prompt += "- Optionally commit docs status if code was already committed.\n";
close_prompt += "- Return closed=true, status=done.\n\n";
close_prompt += "If verify pass is false:\n";
close_prompt += "- Leave status as in_progress or pending (not done).\n";
close_prompt += "- Return closed=false, status=blocked or in_progress, message listing issues.\n";
close_prompt += "Do not push remote.\n";

let closed = agent(close_prompt, #{
    label: "close",
    capability_mode: "all",
    output_schema: close_schema,
});

if closed == () || !closed.success || closed.output == () {
    complete(#{
        summary: "Close agent failed",
        ok: false,
        task_id: r_task_id,
        verify_pass: v_pass,
    });
}

let C = closed.output;
let c_closed = C.closed != () && C.closed == true;
let c_task_id = if C.task_id == () { r_task_id } else { C.task_id };
let c_status = if C.status == () { "unknown" } else { C.status };
let c_message = if C.message == () { "" } else { C.message };

let report = "";
report += "# implement-task " + r_task_id + "\n\n";
report += "## Resolve\n" + r_summary + "\n\n";
report += "## Implement\n" + i_summary + "\n";
report += "check_passed: " + icp + "\n\n";
report += "## Verify\npass=" + vpass + "\n" + v_evidence + "\n\n";
report += "## Close\n" + c_message + "\n";
let report_path = write_scratch_file("report.md", report);

complete(#{
    summary: c_message,
    ok: c_closed,
    task_id: c_task_id,
    status: c_status,
    verify_pass: v_pass,
    path: report_path,
});

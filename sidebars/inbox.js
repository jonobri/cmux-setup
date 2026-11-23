// inbox: a left sidebar that answers "which terminal do I need to go to?".
// It replaces the stock workspace list, so it has two halves:
//   1. Inbox (top): "Next" (the longest-waiting session you are not already
//      looking at), then "Your turn" (the rest), then which are running.
//   2. Workspaces (below): the usual list, drag to reorder, each row showing
//      branch, open PR and task progress, with a dot for agent state.
//   cmux sidebar select inbox
//
// Priority section (between Parked and Workspaces): right-click any session row
// and choose "Pin to Priority" to keep that exact tab one click away. Unpin the
// same way. It uses cmux's native tab pin, so any tab can be pinned from the tab
// bar too (right-click the tab), and pins persist across restarts.
//
// Thresholds were tuned on the author's own agent journal (19 days, 656 replies,
// 1,298 turns): the median wait before a reply was 4 min but 8% sat over an hour
// (amber past 1 hour); 28% of turns ran over 5 min and 7% over 15 (amber past
// 15). Sessions untouched for 24+ hours go under "Parked" so abandoned tabs
// don't bury live ones (24 hours, not 2, so an overnight run stays visible).
// Permission prompts were rare (17 in 19 days), so a session waiting on you is
// almost always a finished turn. Change the constants below to suit your habits.
//
// Gotcha: an agent's `panelId` is its terminal tab's `id`. Its `surfaceId` is
// NOT the tab's `surfaceId`, so match on panelId.

const [showParked, setShowParked] = signal(false);

const PARK_AFTER_SECS = 24 * 3600;
const STALE_WAIT_SECS = 3600;
const LONG_RUN_SECS = 15 * 60;
const MAX_PER_PILE = 6; // keep the workspace list on screen

const AMBER = "#FF9F0A";
const BLUE = "#0A84FF";
const GREEN = "#34C759";
const MUTED = "#7f7f7f66";
const PURPLE = "#BF5AF2";

function fmt(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h " + String(m % 60).padStart(2, "0") + "m";
  return Math.floor(h / 24) + "d";
}

// The "last prompt" cmux records is sometimes not something you typed:
// background-task notices arrive as <task-notification> blocks and pastes are
// wrapped in <pasted_content>. Show a plain label for the first and strip tags
// from the rest.
function cleanPrompt(p) {
  const s = String(p ?? "");
  if (s.trim().startsWith("<task-notification")) return "(background task finished)";
  return s.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

// Split every live agent session into three piles. Reads the 1s clock, so
// elapsed times and the parked cut-off stay current.
const piles = computed(() => {
  const epoch = data.clock()?.epoch ?? 0;
  const waiting = [];
  const running = [];
  const parked = [];
  for (const w of data.workspaces() ?? []) {
    const live = (w.agents ?? []).filter((a) => a.status !== "ended");
    for (const a of live) {
      const tab = (w.tabs ?? []).find((t) => t.id === a.panelId);
      const since = a.sinceEpoch ?? a.lastActivityAt ?? epoch;
      const item = {
        key: "r:" + w.id + ":" + a.id,
        kind: "row",
        wsId: w.id,
        wsTitle: w.title || "untitled",
        wsColor: w.color || "",
        multi: live.length > 1,
        agent: a,
        here: !!(w.selected && tab && tab.focused),
        tabTitle: (tab && tab.title) || "",
        // The id surface.focus needs: the TAB's surfaceId (same as its id), never
        // the agent's own surfaceId, which points at nothing cmux can focus.
        focusId: (tab && (tab.surfaceId || tab.id)) || a.panelId || "",
        lastPrompt: cleanPrompt(tab && tab.latestPrompt),
        pinned: !!(tab && tab.pinned),
        age: epoch - since,
        subagents: (a.children ?? []).filter((c) => c.running).length,
      };
      if (a.status === "working") running.push(item);
      else if (a.status !== "needs_input" && item.age > PARK_AFTER_SECS) {
        // A pinned tab never parks. It already lives in Priority.
        if (!item.pinned) parked.push(item);
      } else waiting.push(item);
    }
  }
  waiting.sort((x, y) => y.age - x.age); // longest-waiting first
  running.sort((x, y) => y.age - x.age);
  parked.sort((x, y) => x.age - y.age); // most recently touched first
  return { waiting, running, parked };
});

// Priority: every tab pinned with cmux's own tab pin (tabs[i].pinned). Using the
// native pin means it survives restarts with no storage of our own, and the tab
// also stays at the left of its tab bar. Any terminal can be pinned, not just
// agent sessions. Order is stable (workspace order, then tab order) so a row
// doesn't move under the cursor.
const priority = computed(() => {
  const epoch = data.clock()?.epoch ?? 0;
  const out = [];
  for (const w of data.workspaces() ?? []) {
    const tabs = w.tabs ?? [];
    for (const t of tabs) {
      if (!t.pinned) continue;
      const a = (w.agents ?? []).find((x) => x.panelId === t.id && x.status !== "ended") ?? null;
      const since = a ? (a.sinceEpoch ?? a.lastActivityAt ?? epoch) : epoch;
      out.push({
        key: "p:" + w.id + ":" + t.id,
        kind: "pin",
        wsId: w.id,
        wsTitle: w.title || "untitled",
        wsColor: w.color || "",
        multi: tabs.length > 1,
        tabTitle: t.title || "",
        focusId: t.surfaceId || t.id,
        pinned: true,
        agent: a,
        here: !!(w.selected && t.focused),
        age: epoch - since,
        lastPrompt: a ? cleanPrompt(t.latestPrompt) : "",
      });
    }
  }
  return out;
});

function pinTab(row, pin) {
  cmux("tab.action", {
    action: pin ? "pin" : "unpin",
    surface_id: row.focusId,
    workspace_id: row.wsId,
  });
}

function capped(rows, key) {
  const out = rows.slice(0, MAX_PER_PILE);
  if (rows.length > MAX_PER_PILE) {
    out.push({ key: "m:" + key, kind: "more", text: "+" + (rows.length - MAX_PER_PILE) + " more" });
  }
  return out;
}

// First waiting session that is not the terminal already on screen.
const nextUp = computed(() => piles().waiting.find((r) => !r.here) ?? null);

const entries = computed(() => {
  const p = piles();
  const out = [];
  // "Next" is the top of the waiting list, pulled out under its own header. The
  // terminal already on screen is skipped, so it stays in "Your turn".
  const next = nextUp();
  const rest = next ? p.waiting.filter((r) => r !== next) : p.waiting;
  if (next) {
    out.push({ key: "h:next", kind: "header", label: "Next", color: AMBER, count: "" });
    out.push(next);
  }
  if (rest.length > 0 || !next) {
    out.push({ key: "h:waiting", kind: "header", label: "Your turn", color: AMBER, count: rest.length });
    for (const r of capped(rest, "waiting")) out.push(r);
    if (rest.length === 0) out.push({ key: "e:waiting", kind: "empty", text: "Nothing waiting on you." });
  }
  out.push({ key: "h:running", kind: "header", label: "Running", color: BLUE, count: p.running.length });
  for (const r of capped(p.running, "running")) out.push(r);
  if (p.running.length === 0) out.push({ key: "e:running", kind: "empty", text: "Nothing running." });
  if (p.parked.length > 0) {
    out.push({
      key: "h:parked",
      kind: "header",
      label: "Parked 24h+",
      color: "#8E8E93",
      count: p.parked.length,
      toggle: true,
    });
    if (showParked()) for (const r of p.parked) out.push(r);
  }
  const pri = priority();
  out.push({ key: "h:priority", kind: "header", label: "Priority", color: PURPLE, count: pri.length });
  for (const r of pri) out.push(r);
  if (pri.length === 0) out.push({ key: "e:priority", kind: "empty", text: "Right-click a session to pin it here." });
  return out;
});

function jump(row) {
  cmux("workspace.select", { workspace_id: row.wsId });
  if (row.focusId) {
    cmux("surface.focus", { surface_id: row.focusId, workspace_id: row.wsId });
  }
}

function sectionHeader(e) {
  return HStack({ spacing: 6 }, [
    Text(() => e().label).font(11).weight("semibold").color(() => e().color),
    Text(() => String(e().count)).font(10).monospaced().color("tertiary"),
    Spacer(),
    Text(() => (e().toggle ? (showParked() ? "hide" : "show") : "")).font(10).color("tertiary"),
  ])
    .paddingHorizontal(10).paddingVertical(4)
    .frame({ maxWidth: "infinity" })
    .onTap(() => {
      if (e().toggle) setShowParked(!showParked());
    });
}

function plainRow(e) {
  return Text(() => e().text).font(11).color("tertiary").paddingHorizontal(10).paddingVertical(2);
}

function timeColor(r) {
  if (r.agent.status === "working") return r.age > LONG_RUN_SECS ? AMBER : "tertiary";
  return r.age > STALE_WAIT_SECS ? AMBER : "tertiary";
}

function dotColor(r) {
  if (r.agent.status === "working") return BLUE;
  if (r.agent.status === "needs_input") return AMBER;
  return r.age > PARK_AFTER_SECS ? MUTED : GREEN;
}

// Row anatomy (same for session and pinned rows):
//   line 1: the session name (the tab title), what you'd call this conversation
//   line 2: two tags. Workspace is the heavy one (it is the first thing to
//           know about a row), the time or state is the light one, amber when stale
//   line 3: what you last asked, dimmed
// Text that stays readable on a workspace colour: dark ink on pale colours
// (the yellow, the orange), white on the rest.
function inkOn(hex) {
  const m = /^#?([0-9a-f]{6})/i.exec(hex || "");
  if (!m) return "primary";
  const n = parseInt(m[1], 16);
  const lum = 0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255);
  return lum > 150 ? "#1c1c1e" : "#ffffff";
}

function workspaceTag(r) {
  return Text(() => r().wsTitle)
    .font(10).weight("semibold").color(() => inkOn(r().wsColor))
    .lineLimit(1).truncation("tail")
    .paddingHorizontal(6).paddingVertical(2)
    .background(() => r().wsColor || "#7f7f7f4d")
    .cornerRadius(5)
    .layoutPriority(1);
}

function timeTag(textFn, colorFn) {
  return Text(textFn)
    .font(10).monospaced().color(colorFn)
    .paddingHorizontal(6).paddingVertical(2)
    .background(() => (colorFn() === AMBER ? "#FF9F0A26" : "#7f7f7f1f"))
    .cornerRadius(5)
    .fixedSize()
    .layoutPriority(3);
}

function sessionRow(e) {
  const r = () => e();
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      Circle({ size: 6 }).fill(() => dotColor(r())),
      Text(() => r().tabTitle || r().wsTitle)
        .font(12).weight("medium").lineLimit(1).truncation("tail"),
      Spacer(),
    ]),
    HStack({ spacing: 4 }, [
      workspaceTag(r),
      timeTag(() => (r().here ? "here" : fmt(r().age)), () => (r().here ? "tertiary" : timeColor(r()))),
      Text(() => (r().subagents > 0 ? "+" + r().subagents + " sub" : ""))
        .font(10).monospaced().color("tertiary").fixedSize(),
      Spacer(),
    ]).paddingLeading(12),
    Text(() => (r().lastPrompt ? "you: " + r().lastPrompt : ""))
      .font(10).color("tertiary").lineLimit(2).truncation("tail")
      .paddingLeading(12),
  ])
    .paddingLeading(10).paddingTrailing(14).paddingVertical(5)
    .cornerRadius(8)
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => jump(r()))
    .contextMenu([
      Button(() => (r().pinned ? "Unpin from Priority" : "Pin to Priority"), () => pinTab(r(), !r().pinned)),
    ]);
}

// What a pinned tab is doing, in a few words. A tab with no agent in it (a
// plain shell, a browser) has no state to show.
function pinState(r) {
  const a = r.agent;
  if (!a) return "";
  if (a.status === "working") return "running " + fmt(r.age);
  if (a.status === "needs_input") return "needs you " + fmt(r.age);
  return (r.age > PARK_AFTER_SECS ? "idle " : "waiting ") + fmt(r.age);
}

function pinColor(r) {
  const a = r.agent;
  if (!a) return "tertiary";
  if (a.status === "working") return r.age > LONG_RUN_SECS ? AMBER : "tertiary";
  if (a.status === "needs_input") return AMBER;
  return r.age > STALE_WAIT_SECS && r.age <= PARK_AFTER_SECS ? AMBER : "tertiary";
}

function pinDot(r) {
  const a = r.agent;
  if (!a) return MUTED;
  return dotColor(r);
}

function pinRow(e) {
  const r = () => e();
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      Circle({ size: 6 }).fill(() => pinDot(r())),
      Text(() => r().tabTitle || r().wsTitle)
        .font(12).weight("medium").lineLimit(1).truncation("tail"),
      Spacer(),
    ]),
    HStack({ spacing: 4 }, [
      workspaceTag(r),
      timeTag(() => (r().here ? "here" : pinState(r())), () => (r().here ? "tertiary" : pinColor(r()))),
      Spacer(),
    ]).paddingLeading(12),
    Text(() => (r().lastPrompt ? "you: " + r().lastPrompt : ""))
      .font(10).color("tertiary").lineLimit(1).truncation("tail")
      .paddingLeading(12),
  ])
    .paddingLeading(10).paddingTrailing(14).paddingVertical(5)
    .cornerRadius(8)
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => jump(r()))
    .contextMenu([Button("Unpin from Priority", () => pinTab(r(), false))]);
}

// ---- Workspaces -----------------------------------------------------------

// Agent state for one workspace: how many sessions are running, how many are
// waiting on you (parked ones don't count), and whether any wait is stale.
function wsState(w, epoch) {
  let running = 0;
  let waiting = 0;
  let stale = false;
  for (const a of w.agents ?? []) {
    if (a.status === "ended") continue;
    if (a.status === "working") {
      running += 1;
      continue;
    }
    const age = epoch - (a.sinceEpoch ?? a.lastActivityAt ?? epoch);
    if (a.status !== "needs_input" && age > PARK_AFTER_SECS) continue;
    waiting += 1;
    if (age > STALE_WAIT_SECS) stale = true;
  }
  return { running, waiting, stale };
}

function wsDot(w) {
  const s = wsState(w, data.clock()?.epoch ?? 0);
  if (s.running > 0) return BLUE;
  if (s.waiting > 0) return s.stale ? AMBER : GREEN;
  return "clear";
}

function wsDetail(w) {
  const bits = [];
  if (w.branch) bits.push(w.branch + (w.dirty ? "*" : ""));
  if (w.pr) bits.push("PR #" + w.pr.number + (w.pr.status && w.pr.status !== "open" ? " " + w.pr.status : ""));
  if (w.progress && w.progress.label) bits.push(w.progress.label);
  // No git info (e.g. ~/Code itself): show the folder so the row isn't blank.
  if (bits.length === 0) {
    const parts = String(w.directory ?? "").split("/").filter((p) => p.length > 0);
    if (parts.length) bits.push("~/" + parts.slice(-1)[0]);
  }
  return bits.join(" · ");
}

function workspaceRow(w) {
  return HStack({ spacing: 6 }, [
    // The workspace's own colour, a fixed-width bar so every row's text still starts at the same x.
    Capsule().fill(() => w().color || "clear").frame({ width: 3, height: 30 }),
    VStack({ spacing: 1 }, [
      HStack({ spacing: 6 }, [
        Circle({ size: 6 }).fill(() => wsDot(w())),
        Text(() => w().title || "untitled")
          .font(12).weight(() => (w().selected ? "semibold" : "regular"))
          .lineLimit(1).truncation("tail")
          .color(() => (w().selected ? "primary" : "secondary")),
        Spacer(),
        Text(() => {
          const s = wsState(w(), data.clock()?.epoch ?? 0);
          return s.running > 1 ? String(s.running) : "";
        }).font(10).monospaced().color(BLUE).fixedSize(),
        Text(() => {
          const s = wsState(w(), data.clock()?.epoch ?? 0);
          return s.waiting > 1 ? String(s.waiting) : "";
        }).font(10).monospaced().color(GREEN).fixedSize(),
      ]),
      Text(() => wsDetail(w()))
        .font(10).monospaced().color("tertiary").lineLimit(1).truncation("tail")
        .paddingLeading(12),
    ]).frame({ maxWidth: "infinity" }),
  ])
    .paddingLeading(6).paddingTrailing(14).paddingVertical(5)
    .cornerRadius(8)
    .background(() => (w().selected ? "#7f7f7f33" : null))
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }));
}

sidebar(() =>
  VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Text("Inbox").font(14).weight("semibold").fixedSize(),
      Spacer(),
      Text(() => {
        const p = piles();
        return p.waiting.length + " waiting · " + p.running.length + " running";
      }).font(10).monospaced().color("tertiary").lineLimit(1).fixedSize(),
    ]).paddingHorizontal(10),

    ForEach(
      { items: entries, key: (e) => e.key },
      (e) => {
        const kind = e().kind; // stable per key
        if (kind === "header") return sectionHeader(e);
        if (kind === "row") return sessionRow(e);
        if (kind === "pin") return pinRow(e);
        return plainRow(e); // "empty" and "more"
      }
    ),

    Divider(),
    HStack({ spacing: 6 }, [
      Text("Workspaces").font(11).weight("semibold").color("secondary"),
      Text(() => String((data.workspaces() ?? []).length)).font(10).monospaced().color("tertiary"),
      Spacer(),
    ]).paddingHorizontal(10),

    Reorderable(
      {
        items: () => data.workspaces() ?? [],
        key: (w) => w.id,
        onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index: index }),
      },
      (w) => workspaceRow(w)
    ),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)

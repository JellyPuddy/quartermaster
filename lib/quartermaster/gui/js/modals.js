"use strict";

/* ------- modals ------- */
let openModal = null;
function closeModal() { if (openModal) { if (openModal.onClose) openModal.onClose(); openModal.remove(); openModal = null; } }
function modal(build) {
  closeModal();
  const scrim = el("div", "scrim");
  scrim.addEventListener("mousedown", e => { if (e.target === scrim) closeModal(); });
  const m = el("div", "modal");
  build(m);
  scrim.appendChild(m);
  document.body.appendChild(scrim);
  openModal = scrim;
  const first = m.querySelector("input, textarea");
  if (first) first.focus();
}

const NOTE_KINDS = TAXONOMIES.noteKinds.map(k => k.key);

/* A note's kind, as a select that retags in place. 'history' notes are never
   injected into a session, 'open' ones always are — so this chip is how the user
   moves a handled blocker out of every future session's context. */
function kindChip(it, nt) {
  const sel = el("select", `kind-chip ${nt.kind}`,
    NOTE_KINDS.map(k => `<option value="${k}"${k === nt.kind ? " selected" : ""}>${k}</option>`).join(""));
  sel.title = `note #${nt.position} — ${nt.kind}`;
  sel.onchange = () => {
    const kind = sel.value;
    act("retag", { slug: it.slug, args: { position: nt.position, kind } })
      .then(r => { if (r.ok) { toast(`note #${nt.position} is now ${kind}`); refresh(); } });
  };
  return sel;
}

/* Distills every expiring transcript of the item (or the latest when nothing
   is expiring — the backend decides). A needs_confirmation reply means the
   target is already snapshotted: confirm, then retry with force to replace.
   The distill itself runs server-side in the background (minutes per
   transcript): the item carries a "distilling" badge meanwhile, and the
   outcome arrives with a later state poll as a toast. */
function distill(it, force = false) {
  act("distill", { slug: it.slug, args: force ? { force: true } : {} }).then(r => {
    if (r.ok) toast(`distilling ${r.sessions} transcript(s) of ${it.slug} via haiku — this takes a few minutes`);
    else if (r.needs_confirmation) confirmRedistillModal(it, r.error);
  });
}

function confirmRedistillModal(it, reason) {
  modal(m => {
    m.innerHTML = `<h2>Re-distill?</h2><p class="sub">${esc(it.slug)}</p>
      <p style="margin:12px 0">${esc(reason)}.<br>Re-distilling replaces the existing snapshot with a fresh one.</p>`;
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const go = el("button", "btn primary", "Replace snapshot");
    go.onclick = () => { closeModal(); distill(it, true); };
    bar.append(cancel, go); m.appendChild(bar);
  });
}

function noteModal(it) {
  modal(m => {
    m.innerHTML = `<h2>Add a note</h2><p class="sub">${esc(it.slug)}</p>`;
    const f = el("div", "field", `<label>Progress note</label><textarea placeholder="What changed? What's next?"></textarea>`);
    const kf = el("div", "field", `<label>Kind</label><select>${TAXONOMIES.noteKinds.map(k => `<option value="${k.key}"${k.key === TAXONOMIES.defaultNoteKind ? " selected" : ""}>${k.key} — ${k.hint}</option>`).join("")}</select>`);
    m.append(f, kf);
    const ta = f.querySelector("textarea");
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const save = el("button", "btn primary", "Add note");
    save.onclick = () => {
      const t = ta.value.trim(); if (!t) { ta.focus(); return; }
      const kind = kf.querySelector("select").value;
      act("note", { slug: it.slug, args: { text: t, kind } }).then(r => { if (r.ok) { closeModal(); toast(`note added to ${it.slug}`); } });
    };
    bar.append(cancel, save); m.appendChild(bar);
    ta.addEventListener("keydown", e => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") save.click(); });
  });
}

function newItemModal() {
  modal(m => {
    m.innerHTML = `<h2>New work item</h2><p class="sub">creates a work item · not yet linked to a session</p>`;
    const tf = el("div", "field", `<label>Title</label><input type="text" placeholder="Short, intent-named title">`);
    const pf = el("div", "field", `<label>Project</label><select>${PROJECTS.map(p => `<option>${esc(p)}</option>`).join("")}</select>`);
    const df = el("div", "field", `<label>Description <span style="text-transform:none;color:var(--faint)">(optional)</span></label><textarea placeholder="What is this about?"></textarea>`);
    m.append(tf, pf, df, issueFromNewItemRow());
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const create = el("button", "btn primary", "Create item");
    create.onclick = () => {
      const title = tf.querySelector("input").value.trim();
      if (!title) { tf.querySelector("input").focus(); return; }
      act("new", { args: { title, project: pf.querySelector("select").value, description: df.querySelector("textarea").value.trim() } })
        .then(r => { if (r.ok) { closeModal(); toast(`created ${r.slug}`); if (filter === "resolved") setFilter("open"); } });
    };
    bar.append(cancel, create); m.appendChild(bar);
  });
}

function itemFromSessionModal(sess) {
  modal(m => {
    m.innerHTML = `<h2>New work item from session</h2><p class="sub">${esc(short(sess.id))} · “${esc(String(sess.prompt).slice(0, 70))}”</p>`;
    const tf = el("div", "field", `<label>Title</label><input type="text" placeholder="Short, intent-named title">`);
    m.appendChild(tf);
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const create = el("button", "btn primary", "Create item");
    create.onclick = () => {
      const title = tf.querySelector("input").value.trim();
      if (!title) { tf.querySelector("input").focus(); return; }
      act("item-from-session", { args: { session: sess.id, title } })
        .then(r => { if (r.ok) { closeModal(); toast(`created ${r.slug} from ${short(sess.id)}` + movedFrom(r)); if (r.warning) toast(r.warning, false); if (filter === "resolved") setFilter("open"); } });
    };
    bar.append(cancel, create); m.appendChild(bar);
  });
}

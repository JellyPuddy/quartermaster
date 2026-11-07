"use strict";

/* ------- whose move it is: tab title count + browser notifications ------- */
/* The server raises a notification when a chat blocks, or a long turn ends
   (TurnNotifier). While this page is visible the server leaves it to us
   (flag "page"): a browser Notification, unless we are focused on that very
   chat. Hidden or closed, macOS shows it instead. */
const BASE_TITLE = document.title;
let seenNotification = null; // newest notification id handled; null until the first state

function noticeTurns(notifications) {
  const newest = notifications.reduce((max, n) => Math.max(max, n.id), 0);
  // What happened before this page loaded is not news; a restarted server counts from 0 again.
  if (seenNotification === null) seenNotification = newest;
  else if (newest < seenNotification) seenNotification = 0;
  notifications.filter(n => n.id > seenNotification && n.page).forEach(browserNotification);
  seenNotification = Math.max(seenNotification, newest);
  updateTitleCount();
}

function browserNotification(n) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  const chat = n.slug || n.loose;
  if (document.hasFocus() && mode === "chat" && chat && chatSlug === chat) return;
  const note = new Notification(n.title, { body: n.body, tag: n.session, silent: n.kind !== "blocked" });
  note.onclick = () => {
    window.focus();
    const it = n.slug && items.find(i => i.slug === n.slug);
    const lc = !n.slug && n.loose && looseOf(n.loose);
    if (it) openChat(it);
    else if (lc) openLooseChat(lc);
    note.close();
  };
}

/* "(2) qm — work items": the chats whose move it is, loose ones included, a snoozed turn not among them. */
function updateTitleCount() {
  const count = [...attention, ...looseChats].filter(a => a.state === "blocked" || (a.state === "your_turn" && !a.snoozed)).length;
  document.title = count ? `(${count}) ${BASE_TITLE}` : BASE_TITLE;
}

/* Browsers only ask on a user gesture: the first click anywhere, terminal included. */
function askNotificationPermission() {
  if ("Notification" in window && Notification.permission === "default") Notification.requestPermission();
}
document.addEventListener("pointerdown", askNotificationPermission, { capture: true, once: true });

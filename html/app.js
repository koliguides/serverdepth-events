/* ============================================================
   ServerDepth Events — app.js
   NUI message handlers, animation logic, and UI state.
   All server communication is done via fetch() POST to
   the FiveM NUI callback endpoints.
============================================================ */

'use strict';

// ─── Config ──────────────────────────────────────────────────
const BANNER_DURATION_MS = 8000;   // how long the banner stays visible

// ─── Friendly event type labels ───────────────────────────────
const EVENT_TYPE_LABELS = {
  cargo_drop:       'Cargo Drop',
  armored_truck:    'Armored Truck Heist',
  underground_race: 'Underground Race',
  hidden_stash:     'Hidden Stash',
};

// ─── DOM references ───────────────────────────────────────────
const banner            = document.getElementById('sd-banner');
const bannerType        = document.getElementById('banner-type');
const bannerLabel       = document.getElementById('banner-label');
const bannerSub         = document.getElementById('banner-sub');
const bannerProgressBar = document.getElementById('banner-progress-bar');
const panel             = document.getElementById('sd-panel');
const emptyState        = document.getElementById('sd-empty-state');
const eventsList        = document.getElementById('sd-events-list');
const btnClose          = document.getElementById('btn-close');
const btnRefresh        = document.getElementById('btn-refresh');

// ─── State ───────────────────────────────────────────────────
let activeEvents   = {};   // { [event_id]: eventData }
let bannerTimer    = null;
let elapsedTimers  = [];   // setInterval handles for elapsed time tickers

// ─── NUI callback helper ──────────────────────────────────────
/**
 * Send a POST to the FiveM NUI callback endpoint.
 * @param {string} name   - Callback name registered with RegisterNUICallback
 * @param {object} data   - Payload
 * @returns {Promise<object>}
 */
async function nuiPost(name, data = {}) {
  try {
    const res = await fetch(`https://${GetParentResourceName()}/${name}`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body:    JSON.stringify(data),
    });
    return await res.json();
  } catch (e) {
    console.error(`[ServerDepth Events] nuiPost error (${name}):`, e);
    return { ok: false };
  }
}

// When running outside FiveM (browser preview), stub GetParentResourceName
if (typeof GetParentResourceName === 'undefined') {
  window.GetParentResourceName = () => 'serverdepth_events';
}

// ─── Banner ───────────────────────────────────────────────────

/**
 * Show the slide-in banner with event details.
 * @param {string} eventType
 * @param {string} label       - Location / event title
 * @param {string} [subText]
 */
function showBanner(eventType, label, subText) {
  // Cancel any in-flight dismiss
  if (bannerTimer) {
    clearTimeout(bannerTimer);
    bannerTimer = null;
  }

  const typeLabel = EVENT_TYPE_LABELS[eventType] || formatEventType(eventType);
  bannerType.textContent  = typeLabel.toUpperCase();
  bannerLabel.textContent = label || 'New World Event';
  bannerSub.textContent   = subText || 'Race to the location!';

  // Show
  banner.classList.remove('hidden');
  // Force a reflow so the CSS transition fires from translateY(-110%)
  void banner.offsetHeight;
  banner.classList.add('visible');

  // Animate progress bar
  bannerProgressBar.style.transition = 'none';
  bannerProgressBar.style.transform  = 'scaleX(1)';
  void bannerProgressBar.offsetHeight;
  bannerProgressBar.style.transition = `transform ${BANNER_DURATION_MS}ms linear`;
  bannerProgressBar.style.transform  = 'scaleX(0)';

  // Auto-dismiss
  bannerTimer = setTimeout(() => {
    dismissBanner();
  }, BANNER_DURATION_MS);
}

/** Slide the banner back up. */
function dismissBanner() {
  banner.classList.remove('visible');
  setTimeout(() => {
    banner.classList.add('hidden');
  }, 450);   // matches CSS transition duration
}

// Clicking banner dismisses it
banner.addEventListener('click', () => {
  if (bannerTimer) clearTimeout(bannerTimer);
  dismissBanner();
});

// ─── Panel ────────────────────────────────────────────────────

/** Show or hide the events panel. */
function togglePanel(open) {
  if (open) {
    panel.classList.remove('hidden');
    void panel.offsetHeight;
    panel.classList.add('visible');
    renderEventsList();
  } else {
    panel.classList.remove('visible');
    setTimeout(() => panel.classList.add('hidden'), 300);
    stopElapsedTimers();
  }
}

btnClose.addEventListener('click', () => {
  nuiPost('closePanel');
  togglePanel(false);
});

btnRefresh.addEventListener('click', () => {
  btnRefresh.classList.add('spinning');
  nuiPost('refreshEvents').then(() => {
    setTimeout(() => btnRefresh.classList.remove('spinning'), 600);
  });
});

// ─── Events List Rendering ────────────────────────────────────

/** Convert snake_case event type to Title Case. */
function formatEventType(type) {
  return (type || '')
    .split('_')
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

/** Format milliseconds into a human-readable elapsed string. */
function formatElapsed(startedAtUnix) {
  const elapsedSec = Math.max(0, Math.floor(Date.now() / 1000) - startedAtUnix);
  const m = Math.floor(elapsedSec / 60);
  const s = elapsedSec % 60;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

/** Create a DOM card element for an event. */
function createEventCard(ev) {
  const card = document.createElement('div');
  card.className    = 'sd-event-card';
  card.dataset.id   = ev.event_id;

  const typeLabel = EVENT_TYPE_LABELS[ev.event_type] || formatEventType(ev.event_type);
  const hasCoords = ev.coords && (ev.coords.x !== undefined);

  const raceSection = ev.event_type === 'underground_race' && ev.registration_open
    ? `<div class="sd-race-count">
         <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
           <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/>
           <circle cx="9" cy="7" r="4"/>
           <path d="M23 21v-2a4 4 0 0 0-3-3.87"/>
           <path d="M16 3.13a4 4 0 0 1 0 7.75"/>
         </svg>
         <span class="race-count-text">${ev.registrant_count || 0} registered</span>
       </div>`
    : '';

  const joinRaceBtn = ev.event_type === 'underground_race' && ev.registration_open
    ? `<button class="sd-btn sd-btn--success" data-action="join-race" data-event-id="${ev.event_id}">
         <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
           <polygon points="5 3 19 12 5 21 5 3"/>
         </svg>
         Join Race
       </button>`
    : '';

  const waypointBtn = hasCoords
    ? `<button class="sd-btn sd-btn--primary" data-action="waypoint" data-event-id="${ev.event_id}"
                data-x="${ev.coords.x}" data-y="${ev.coords.y}" data-z="${ev.coords.z || 0}">
         <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
           <circle cx="12" cy="12" r="3"/>
           <path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>
         </svg>
         Waypoint
       </button>`
    : '';

  card.innerHTML = `
    <div class="sd-event-card__header">
      <span class="sd-event-card__type-badge">${typeLabel}</span>
      <span class="sd-event-card__elapsed" data-started="${ev.started_at}">${formatElapsed(ev.started_at)}</span>
    </div>
    <div class="sd-event-card__label">${ev.label || typeLabel}</div>
    <div class="sd-event-card__id">${ev.event_id}</div>
    ${raceSection}
    <div class="sd-event-card__actions">
      ${waypointBtn}
      ${joinRaceBtn}
    </div>
  `;

  // Button click delegation
  card.addEventListener('click', handleCardClick);

  return card;
}

/** Delegate click handler for event card buttons. */
function handleCardClick(e) {
  const btn = e.target.closest('[data-action]');
  if (!btn) return;

  const action  = btn.dataset.action;
  const eventId = btn.dataset.eventId;

  if (action === 'waypoint') {
    const coords = {
      x: parseFloat(btn.dataset.x),
      y: parseFloat(btn.dataset.y),
      z: parseFloat(btn.dataset.z || 0),
    };
    nuiPost('setWaypoint', { event_id: eventId, coords });
    btn.textContent = 'Set!';
    setTimeout(() => { btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg> Waypoint`; }, 1500);
  }

  if (action === 'join-race') {
    nuiPost('joinRace', { event_id: eventId });
    btn.disabled    = true;
    btn.textContent = 'Registered!';
  }
}

/** Render (or refresh) the events list inside the panel. */
function renderEventsList() {
  stopElapsedTimers();
  eventsList.innerHTML = '';

  const evArr = Object.values(activeEvents);

  if (evArr.length === 0) {
    emptyState.classList.remove('hidden');
    eventsList.classList.add('hidden');
    return;
  }

  emptyState.classList.add('hidden');
  eventsList.classList.remove('hidden');

  for (const ev of evArr) {
    eventsList.appendChild(createEventCard(ev));
  }

  // Start elapsed time ticker
  const ticker = setInterval(() => {
    document.querySelectorAll('[data-started]').forEach(el => {
      const started = parseInt(el.dataset.started, 10);
      if (!isNaN(started)) {
        el.textContent = formatElapsed(started);
      }
    });
  }, 1000);
  elapsedTimers.push(ticker);
}

function stopElapsedTimers() {
  elapsedTimers.forEach(clearInterval);
  elapsedTimers = [];
}

// ─── Incoming NUI Messages ────────────────────────────────────

window.addEventListener('message', function(event) {
  const data = event.data;
  if (!data || !data.action) return;

  switch (data.action) {

    // New event fired — show banner
    case 'showBanner': {
      const typeLabel = EVENT_TYPE_LABELS[data.event_type] || formatEventType(data.event_type);
      const sub = data.coords
        ? `Check your map — ${typeLabel} has started!`
        : 'Check your map for details.';
      showBanner(data.event_type, data.label, sub);

      // Track in active events state
      activeEvents[data.event_id] = {
        event_id:   data.event_id,
        event_type: data.event_type,
        label:      data.label,
        coords:     data.coords,
        started_at: Math.floor(Date.now() / 1000),
      };

      // Refresh panel if it's open
      if (panel.classList.contains('visible')) renderEventsList();
      break;
    }

    // Server sent full active events list (after panel opens / refresh)
    case 'updateEventsList': {
      activeEvents = {};
      if (Array.isArray(data.events)) {
        for (const ev of data.events) {
          activeEvents[ev.event_id] = ev;
        }
      }
      if (panel.classList.contains('visible')) renderEventsList();
      break;
    }

    // Event ended — remove from state
    case 'removeEvent': {
      delete activeEvents[data.event_id];
      const card = eventsList.querySelector(`[data-id="${data.event_id}"]`);
      if (card) {
        card.style.opacity   = '0';
        card.style.transform = 'translateX(20px)';
        card.style.transition = 'opacity 0.3s, transform 0.3s';
        setTimeout(() => {
          card.remove();
          if (Object.keys(activeEvents).length === 0) {
            emptyState.classList.remove('hidden');
            eventsList.classList.add('hidden');
          }
        }, 300);
      }
      break;
    }

    // Toggle panel open/close
    case 'togglePanel': {
      togglePanel(data.open);
      break;
    }

    // Race-specific: registration opened
    case 'raceRegistrationOpen': {
      if (activeEvents[data.event_id]) {
        activeEvents[data.event_id].registration_open = true;
        activeEvents[data.event_id].registrant_count  = 0;
        activeEvents[data.event_id].max_racers         = data.max_racers;
        activeEvents[data.event_id].label              = data.label;
      }
      if (panel.classList.contains('visible')) renderEventsList();
      break;
    }

    // Race registrant count updated
    case 'raceRegistrantUpdate': {
      if (activeEvents[data.event_id]) {
        activeEvents[data.event_id].registrant_count = data.count;
        const countEl = eventsList.querySelector(
          `[data-id="${data.event_id}"] .race-count-text`
        );
        if (countEl) countEl.textContent = `${data.count} registered`;
      }
      break;
    }

    // Race registration closed
    case 'raceRegistrationClosed': {
      if (activeEvents[data.event_id]) {
        activeEvents[data.event_id].registration_open = false;
      }
      if (panel.classList.contains('visible')) renderEventsList();
      break;
    }
  }
});

// ─── Keyboard ────────────────────────────────────────────────

document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') {
    nuiPost('closePanel');
    togglePanel(false);
  }
});

// ─── CSS for spinning refresh button ─────────────────────────
const style = document.createElement('style');
style.textContent = `
  @keyframes spin { to { transform: rotate(360deg); } }
  #btn-refresh.spinning svg { animation: spin 0.6s linear; }
`;
document.head.appendChild(style);

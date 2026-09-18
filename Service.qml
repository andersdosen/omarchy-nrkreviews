import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Strings.js" as Strings

// Singleton background service (kinds: ["service", ...] in manifest.json)
// — instantiated once regardless of how many monitors the bar renders on,
// unlike the bar-widget (Panel.qml), which is a fully separate component
// instance per monitor. Owns everything that must only ever run once:
// settings persistence, the periodic new-review poll, the suspend/resume
// watcher, and desktop notifications. Panel.qml reaches this via
// `bar.shell.serviceFor(moduleName)` (see andersdosen.nrkreviews's own
// Panel.qml, and the third-party io.github.kallupx.oma-mullvad plugin for
// the same pattern) and reads/calls it as `root.svc.*`.
Item {
  id: root

  // Injected by the host once available — not present at construction.
  property var shell: null

  readonly property string fetchReviewsHelper: Qt.resolvedUrl("fetch-reviews").toString().replace(/^file:\/\//, "")

  // Threads the user's Settings → Language choice through every Strings.t()
  // call in this file, so a background poll's notification text honors it
  // too (not just Panel.qml's live UI).
  function tr(key) { return Strings.t(key, root.languageOverride) }

  // ---------- settings persistence ----------

  // Persisted across shell restarts under ~/.local/state/omarchy/settings/,
  // NOT under the plugin's own directory — the whole plugins/ tree is
  // watched by inotify, and a write from inside it (even from the plugin's
  // own code) triggers a disruptive full plugin reload. Matches the same
  // convention as first-party `weather` (weather.json) and third-party
  // `andrewbacon.canon` (canon.json).
  property string lastSeenUrl: ""
  property bool settingsLoaded: false
  property bool hasUnseen: false

  // Options the settings-panel slider snaps to (minutes). 20 is the
  // default; the slider works on the index into this list rather than the
  // minute value directly, since the gaps aren't even (10/20/30/60).
  readonly property var refreshIntervalOptions: [10, 20, 30, 60]
  property bool backgroundRefreshEnabled: true
  property int refreshIntervalMinutes: 20
  property bool notificationsEnabled: true

  // "" means "System" (follow Qt.locale()); otherwise one of Strings.js's
  // language codes. Validated against the known table in Strings.currentLanguage
  // itself, not here — an unrecognized/stale code (e.g. a language dropped
  // in a later version) just falls back to System rather than needing a
  // guard on every read.
  property string languageOverride: ""

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/nrkreviews.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        root.lastSeenUrl = (data && data.lastSeenUrl) || ""
        root.backgroundRefreshEnabled = data && typeof data.backgroundRefreshEnabled === "boolean"
          ? data.backgroundRefreshEnabled : true
        root.refreshIntervalMinutes = data && root.refreshIntervalOptions.indexOf(data.refreshIntervalMinutes) >= 0
          ? data.refreshIntervalMinutes : 20
        root.notificationsEnabled = data && typeof data.notificationsEnabled === "boolean"
          ? data.notificationsEnabled : true
        root.languageOverride = (data && typeof data.languageOverride === "string") ? data.languageOverride : ""
      } catch (e) {
        root.lastSeenUrl = ""
        root.backgroundRefreshEnabled = true
        root.refreshIntervalMinutes = 20
        root.notificationsEnabled = true
        root.languageOverride = ""
      }
      root.settingsLoaded = true
      if (root.backgroundRefreshEnabled) root.startResumeWatcher()
    }
    onLoadFailed: {
      root.lastSeenUrl = ""
      root.backgroundRefreshEnabled = true
      root.refreshIntervalMinutes = 20
      root.notificationsEnabled = true
      root.languageOverride = ""
      root.settingsLoaded = true
      if (root.backgroundRefreshEnabled) root.startResumeWatcher()
    }
    onFileChanged: reload()
  }

  // FileView's implicit first read can race component construction and
  // never fire onLoaded/onLoadFailed — self-correct with one bounded retry
  // rather than leaving settingsLoaded stuck false forever (same race
  // omarchy.weather's own FileView comment warns about).
  Timer {
    interval: 1200
    running: !root.settingsLoaded
    onTriggered: if (!root.settingsLoaded) settingsFile.reload()
  }

  function persistSettings() {
    if (!root.settingsLoaded) return
    settingsFile.setText(JSON.stringify({
      lastSeenUrl: root.lastSeenUrl,
      backgroundRefreshEnabled: root.backgroundRefreshEnabled,
      refreshIntervalMinutes: root.refreshIntervalMinutes,
      notificationsEnabled: root.notificationsEnabled,
      languageOverride: root.languageOverride
    }))
  }

  function setLanguageOverride(code) {
    root.languageOverride = code
    root.persistSettings()
  }

  function setBackgroundRefreshEnabled(enabled) {
    root.backgroundRefreshEnabled = enabled
    root.persistSettings()
    if (enabled) root.startResumeWatcher()
    else root.stopResumeWatcher()
  }

  function setRefreshIntervalMinutes(minutes) {
    root.refreshIntervalMinutes = minutes
    root.persistSettings()
  }

  function setNotificationsEnabled(enabled) {
    root.notificationsEnabled = enabled
    root.persistSettings()
  }

  // Records the newest item from a just-fetched "All"-category page as
  // seen, clearing the badge — called by Panel.qml both when the user
  // opens the panel (they're looking right at the list) and to seed state
  // on first run.
  function markSeen(url) {
    if (!url) return
    root.lastSeenUrl = url
    root.hasUnseen = false
    root.persistSettings()
  }

  // Called by Panel.qml the instant its popup opens, ahead of markSeen()
  // confirming it once the fresh fetch lands — the user is about to be
  // looking right at the list either way.
  function clearUnseen() {
    root.hasUnseen = false
  }

  // Mirrors Panel.qml's openResult() guard of the same name — kept as an
  // independent copy rather than a shared import since Service.qml and
  // Panel.qml are separate component instances (same convention already
  // used for fetchReviewsHelper). item.url is NRK's own API data; requiring
  // https:// + an nrk.no host before it's ever handed to a launcher argv
  // matches the one check omarchy-launch-browser itself doesn't do.
  function isTrustedReviewUrl(url) {
    return /^https:\/\/([a-z0-9-]+\.)*nrk\.no\//i.test(String(url || ""))
  }

  function notifyNewReviews(newItems, countUnknown) {
    if (!newItems || newItems.length === 0) return
    // The bar badge (hasUnseen) is unconditional — this toggle only
    // controls the desktop notification itself.
    if (!root.notificationsEnabled) return
    var headline = newItems.length === 1 ? root.tr("notifyTitleOne") : root.tr("notifyTitleMany")
    var body = String(newItems[0].title || "")
    if (newItems.length > 1) {
      body += countUnknown
        ? " (" + root.tr("notifyAndMore") + ")"
        : " (+" + (newItems.length - 1) + " " + root.tr("notifyMoreSuffix") + ")"
    }
    // -g/--glyph is accepted but the shell's notification history doesn't
    // surface Nerd Font private-use glyphs (confirmed with a direct manual
    // omarchy-notification-send call, same empty "glyph" result) — skip it
    // rather than ship a flag with no visible effect.
    //
    // --exec sets the click-to-launch hint the shell's own notification
    // service reads (omarchy-exec-argv). With exactly one new review (the
    // common case) and a URL that passes the same trust check openResult()
    // uses, send the click straight to that review. With several new
    // reviews there's no single "the" one to deep-link to (and no trusted
    // URL should be used as a fallback pick either), so open our own panel
    // instead via the shell's bar-widget summon IPC — confirmed live that
    // `omarchy-shell shell summon <id> {}` correctly opens the right
    // monitor's popup, unlike calling our own per-monitor IpcHandler
    // directly (only one of the duplicate registrations is reachable).
    // execArgv (not execDetached) throughout since headline/body/url come
    // from NRK's API, not something this plugin controls; no shell
    // involved means nothing in that text can be (mis)interpreted as
    // anything but literal argv data.
    var clickArgv = (newItems.length === 1 && root.isTrustedReviewUrl(newItems[0].url))
      ? ["omarchy-launch-browser", String(newItems[0].url)]
      : ["omarchy-shell", "shell", "summon", "andersdosen.nrkreviews", "{}"]
    Util.execArgv([
      "omarchy-notification-send", "--app-name", "NRK Anmeldelser",
      headline, body,
      "--exec"
    ].concat(clickArgv))
  }

  // ---------- background polling ----------

  readonly property int pollCount: 5

  function startPoll() {
    if (pollProc.running) return
    pollProc.command = [root.fetchReviewsHelper,
      "https://www.nrk.no/komponenter/api/autonomous-content/plugs.json?type=reviews&count=" + root.pollCount]
    pollProc.running = true
  }

  Process {
    id: pollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.settingsLoaded) return
        try {
          var data = JSON.parse(String(text || ""))
          var plugs = ((data && data.plugs) || []).filter(function(p) { return p && p.url && p.title })
          if (plugs.length === 0) return
          if (root.lastSeenUrl === "") {
            // First check ever (or a missing/corrupt state file) — seed
            // silently instead of flagging every existing review as "new".
            root.markSeen(plugs[0].url)
            return
          }
          var idx = -1
          for (var i = 0; i < plugs.length; i++) {
            if (plugs[i].url === root.lastSeenUrl) { idx = i; break }
          }
          if (idx === 0) return // newest is still what we've already seen
          // idx < 0 means lastSeenUrl fell outside this small window — at
          // least `plugs.length` are new, but the exact count is unknown.
          var newItems = idx > 0 ? plugs.slice(0, idx) : plugs
          root.hasUnseen = true
          root.lastSeenUrl = plugs[0].url
          root.persistSettings()
          root.notifyNewReviews(newItems, idx < 0)
        } catch (e) {
          // Transient — the next scheduled poll will retry.
        }
      }
    }
  }

  // Independent of any bar-widget instance/popup — this is the whole
  // reason background work moved into a service: a Timer on a per-monitor
  // bar-widget runs once per monitor, doubling API calls (and once briefly
  // doubling notifications, before this refactor). Gated on settingsLoaded
  // (not just backgroundRefreshEnabled) so it can never fire once on the
  // default-true value before a persisted "off" has had a chance to load;
  // re-enabling the toggle re-triggers an immediate poll too, since
  // `running` flips false→true again and triggeredOnStart fires on every
  // start, not just the first one.
  Timer {
    id: pollTimer
    interval: root.refreshIntervalMinutes * 60 * 1000
    running: root.settingsLoaded && root.backgroundRefreshEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startPoll()
  }

  // A plain repeating Timer's countdown is paused by system suspend
  // rather than "catching up" on wake — it just resumes counting down
  // whatever was left when suspend began, so after a long sleep the next
  // scheduled poll can land well after the user is back (confirmed: this
  // is the same "countdown frozen by suspend fires late on resume"
  // behavior the shell's own lock/Service.qml works around for its idle
  // timer). Watching logind's PrepareForSleep signal directly fires a
  // poll right on resume instead of waiting that out — same technique,
  // and same `dbus-monitor` dependency, as Omarchy's own first-party
  // sleep-lock feature (see /usr/share/omarchy/bin/omarchy-system-sleep-monitor).
  Process {
    id: resumeWatcher
    running: false
    command: ["dbus-monitor", "--system",
      "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"]
    stdout: SplitParser {
      onRead: function(line) {
        // dbus-monitor prints the signal header, then each argument on its
        // own line — "boolean true" means about to sleep, "boolean false"
        // is the resume edge.
        if (String(line).indexOf("boolean false") >= 0) {
          pollTimer.restart()
          root.startPoll()
        }
      }
    }
    // dbus-monitor runs indefinitely and is never expected to exit on its
    // own; if it does (crashed, binary missing, a bus hiccup), don't spin
    // tightly — same restart-after-a-beat pattern as the shell's own
    // plugin-directory inotifywait watcher (services/PluginRegistry.qml's
    // localPluginWatcher).
    onExited: resumeWatcherRestart.restart()
  }

  Timer {
    id: resumeWatcherRestart
    interval: 5000
    onTriggered: root.startResumeWatcher()
  }

  function startResumeWatcher() {
    if (!root.backgroundRefreshEnabled || resumeWatcher.running) return
    resumeWatcher.running = true
  }

  function stopResumeWatcher() {
    resumeWatcher.running = false
  }
}

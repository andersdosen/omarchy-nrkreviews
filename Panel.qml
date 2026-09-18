import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Strings.js" as Strings

// Browse NRK's own review listings (https://www.nrk.no/anmeldelser) from the
// bar: a category dropdown mirrors the site's own filter, and each row
// opens the review on nrk.no. Backed by NRK's public (unauthenticated)
// autonomous-content plugs.json endpoint. Left click (or Enter) opens a
// review on NRK; right click (or Space) copies its URL.
Panel {
  id: root
  moduleName: "andersdosen.nrkreviews"
  ipcTarget: "andersdosen.nrkreviews"

  readonly property string icon: "\uf005" // nf-fa-star

  // Shared with ResultRow's thumbnail Item below, so the loading spinner's
  // box lines up exactly with a review's presented thumbnail height \u2014
  // one number instead of two that could drift apart.
  readonly property int thumbHeight: Style.space(40)

  // ---------- categories ----------

  // Mirrors NRK's own filter dropdown on /anmeldelser (see the site's
  // ReviewCollectionPagePlugsWrapper/PlugGrid bundles): a fixed set of
  // named groups, each covering one or more of the API's raw reviewType
  // values. "all" (no criteria param) matches the site's "Alle" option.
  readonly property var categories: [
    { id: "all", labelKey: "categoryAll", types: [] },
    { id: "list", labelKey: "categoryList", types: ["list"] },
    { id: "literature", labelKey: "categoryLiterature", types: ["literature"] },
    { id: "filmAndSeries", labelKey: "categoryFilmAndSeries", types: ["film", "series"] },
    { id: "games", labelKey: "categoryGames", types: ["games"] },
    { id: "art", labelKey: "categoryArt", types: ["art"] },
    { id: "stageArts", labelKey: "categoryStageArts", types: ["musical", "opera", "theater", "dance"] },
    { id: "music", labelKey: "categoryMusic", types: ["music", "concert"] },
    { id: "humor", labelKey: "categoryHumor", types: ["humor"] },
    { id: "show", labelKey: "categoryShow", types: ["show"] },
    { id: "architecture", labelKey: "categoryArchitecture", types: ["architecture"] }
  ]

  // Dropdown (Ui/Dropdown.qml) does highlight root.value's row when the
  // popup first opens, but that highlight doubles as the hover/keyboard
  // cursor — move the mouse over any other row and it follows, so nothing
  // marks the actually-selected category once you're not literally
  // hovering it. Marking it in the label text itself survives that.
  // Reads root.selectedCategory, so this re-evaluates (moving the mark)
  // whenever the category changes.
  function categoryOptions() {
    return root.categories.map(function(c) {
      var label = root.tr(c.labelKey)
      return { value: c.id, label: c.id === root.selectedCategory ? "✓ " + label : label }
    })
  }

  property string selectedCategory: "all"

  function currentCategory() {
    for (var i = 0; i < root.categories.length; i++)
      if (root.categories[i].id === root.selectedCategory) return root.categories[i]
    return root.categories[0]
  }

  // Per-item type badge (finer-grained than the dropdown groups, e.g.
  // "series" gets its own label even though it's filed under the
  // "Film og serier" / "Film & series" dropdown entry).
  readonly property var typeLabelKeys: ({
    film: "typeFilm", series: "typeSeries", show: "typeShow", music: "typeMusic",
    concert: "typeConcert", musical: "typeMusical", opera: "typeOpera", theater: "typeTheater",
    dance: "typeDance", literature: "typeLiterature", games: "typeGames", art: "typeArt",
    architecture: "typeArchitecture", humor: "typeHumor"
  })

  function typeLabel(reviewType) {
    var key = root.typeLabelKeys[reviewType]
    return key ? root.tr(key) : ""
  }

  function captionFor(item) {
    if (!item) return ""
    var parts = []
    // Falls back to whichever category is currently selected when the
    // item itself has no reviewType to derive a label from — confirmed
    // this happens for real: NRK's "architecture" category mixes actual
    // architecture reviews in with plain feature-classic articles that
    // carry neither a reviewType nor a reviewScore at all, which
    // otherwise left these rows with a completely blank caption line.
    // That fallback is right for feature-classic (confirmed live: those
    // only ever surface while actually browsing Architecture, never in
    // "All", so "whatever's selected" is always Architecture there), but
    // wrong for "review-collection" items (Top lists round-ups) — those
    // DO show up in the "All" feed too (confirmed live), where falling
    // back to "whatever's selected" mislabeled them "All" instead of "Top
    // lists". The API's outer `type` field (distinct from `reviewType`,
    // which these also lack) is the one place that actually says "this is
    // a top-list round-up" regardless of which category view surfaced it,
    // so check for that specifically before falling back to the ambient
    // category guess.
    var label = root.typeLabel(item.reviewType)
      || (item.type === "review-collection" ? root.tr("categoryList") : "")
      || root.tr(root.currentCategory().labelKey)
    if (label) parts.push(label)
    // Architecture reviews always report reviewScore 0 (confirmed live —
    // NRK doesn't actually rate architecture on the 1-6 terningkast scale
    // at all), so treat 0 the same as "no score" rather than showing a
    // dice roll that was never real.
    if (typeof item.reviewScore === "number" && item.reviewScore > 0)
      parts.push(root.tr("dice") + " " + item.reviewScore)
    return parts.join(" · ")
  }

  // ---------- listing state ----------

  property var results: []
  property string cursor: ""
  property bool hasNextPage: false
  property bool loading: false
  property bool fetchIsAppend: false
  property string errorText: ""

  // root.results is a plain array, so every fetch rebuilds every ResultRow
  // delegate from scratch — without this, the same image hash appearing
  // across pages would respawn a fetch-image process each time, even
  // though an earlier fetch already proved the file is cached on disk.
  // Keyed by image hash, persists across rebuilds since it lives on root.
  property var thumbCacheKnownGood: ({})

  // Hoisted up from ResultRow (every row used to compute its own copy of
  // this — same value every time — and spawn its own "mkdir -p" Process
  // on creation). Since every fetch/filter change rebuilds every visible
  // ResultRow from scratch, that meant a fresh mkdir subprocess per row
  // per rebuild for a directory that only ever needs creating once. Runs
  // here, once, for this bar-widget instance's whole lifetime instead.
  readonly property string thumbCacheHome: Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
  readonly property string thumbCacheDir: root.thumbCacheHome + "/omarchy-nrkreviews/thumbs"

  Process {
    id: thumbCacheDirProc
    command: ["mkdir", "-p", root.thumbCacheDir]
  }
  Component.onCompleted: thumbCacheDirProc.running = true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- open/close ----------

  function reviewUrl(item) {
    return item ? String(item.url || "") : ""
  }

  // item.url is NRK's own API data, not something this plugin constructs —
  // fetch-reviews/fetch-image both validate every external host they touch
  // before using it, but this URL previously went straight to
  // omarchy-launch-browser with no equivalent check. Confirmed that script
  // does no validation of its own either — it hands its argument directly
  // to the browser binary's argv (systemd-run ... "$browser_exec" "$@"),
  // so a value starting with "-" would be read as a flag by the browser
  // itself, and any URI scheme (file://, a registered custom-scheme
  // handler, etc.) would be launched as-is. This is the only check in the
  // whole chain, matching the same host-allowlist style already used for
  // the reviews API and image CDN.
  function isTrustedReviewUrl(url) {
    return /^https:\/\/([a-z0-9-]+\.)*nrk\.no\//i.test(String(url || ""))
  }

  function openResult(item) {
    var url = root.reviewUrl(item)
    if (!url || !root.isTrustedReviewUrl(url)) return
    Util.execArgv(["omarchy-launch-browser", url])
  }

  // Row-scoped "copied" feedback, tracked by url — mirrors the sibling
  // andersdosen.imdbsearch plugin's folder-name-copy feedback.
  property string copiedUrl: ""

  // Header cog toggles this to swap the category dropdown + review list
  // out for a (currently placeholder) settings view.
  property bool showSettings: false

  function copyLink(item) {
    var url = root.reviewUrl(item)
    if (!url) return
    Util.execDetached("printf %s " + Util.shellQuote(url) + " | wl-copy")
    root.copiedUrl = url
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 2000
    onTriggered: root.copiedUrl = ""
  }

  // ---------- fetching ----------

  readonly property string fetchReviewsHelper: Qt.resolvedUrl("fetch-reviews").toString().replace(/^file:\/\//, "")
  readonly property string fetchImageHelper: Qt.resolvedUrl("fetch-image").toString().replace(/^file:\/\//, "")
  readonly property int pageSize: 10

  function buildUrl(cursorValue) {
    var params = "type=reviews&count=" + root.pageSize
    var cat = root.currentCategory()
    if (cat.types.length > 0)
      params += "&criteria=" + encodeURIComponent("reviewTypes:" + cat.types.join("+"))
    if (cursorValue) params += "&cursor=" + encodeURIComponent(cursorValue)
    return "https://www.nrk.no/komponenter/api/autonomous-content/plugs.json?" + params
  }

  function loadFirstPage() {
    fetchProc.running = false
    root.fetchIsAppend = false
    root.cursor = ""
    root.hasNextPage = false
    root.errorText = ""
    root.loading = true
    fetchProc.command = [root.fetchReviewsHelper, root.buildUrl("")]
    fetchProc.running = true
  }

  function loadMore() {
    if (root.loading || !root.hasNextPage) return
    root.fetchIsAppend = true
    root.loading = true
    fetchProc.command = [root.fetchReviewsHelper, root.buildUrl(root.cursor)]
    fetchProc.running = true
  }

  function onCategoryChanged(value) {
    // Dropdown.selectCurrent() emits changed(v) unconditionally, even when
    // v is whatever's already selected (e.g. clicking the current entry
    // in the open popup) — skip the reload in that case instead of
    // clearing and re-fetching a list that wouldn't actually change.
    if (value === root.selectedCategory) return
    root.selectedCategory = value
    root.results = []
    root.loadFirstPage()
  }

  // Dropdown.selectCurrent() assigns its own `value` property imperatively
  // (`root.value = v` inside Dropdown.qml), which severs the declarative
  // `value: root.selectedCategory` binding below the first time the user
  // picks anything — after that, resetting root.selectedCategory alone no
  // longer updates what the dropdown displays. Route every reset through
  // this so the dropdown's displayed value and the actual fetch criteria
  // can never drift apart.
  function resetCategory() {
    root.selectedCategory = "all"
    if (categoryDropdown) categoryDropdown.value = "all"
  }

  // ---------- score filter ----------

  // NRK's own criteria grammar has a "score:4+5+6"-style filter (parsed by
  // the site's own frontend JS alongside reviewTypes), but confirmed live
  // that the API itself silently ignores it — a request with and without
  // it returns byte-identical plugs and cursor. So this filters
  // client-side over whatever page(s) are already in root.results, rather
  // than asking the server to do it.
  property int scoreMin: 1

  // "Topplister"/"Top lists" round-ups and "Arkitektur"/"Architecture"
  // features are mostly (or entirely) unscored content (confirmed while
  // building the category list: architecture mixes in scoreless
  // feature-classic entries, and list is review-collections with no
  // reviewScore at all) — filtering by a minimum score there would either
  // do nothing or silently empty the list, so the control hides itself
  // and the filter goes inert rather than confusingly appearing to do
  // nothing (or worse, hiding everything) in those two categories. The
  // chosen minimum itself is left alone rather than reset, so it's still
  // there — and still working — when you switch back to another category.
  readonly property bool scoreFilterApplicable: root.selectedCategory !== "list" && root.selectedCategory !== "architecture"
  readonly property bool scoreFilterActive: root.scoreMin > 1 && root.scoreFilterApplicable

  function filterByScore(list) {
    if (!root.scoreFilterActive) return list
    return list.filter(function(p) {
      return typeof p.reviewScore === "number" && p.reviewScore >= root.scoreMin
    })
  }

  readonly property var filteredResults: root.filterByScore(root.results)

  // Reusable PanelSlider (see the settings view's refresh-interval slider)
  // never assigns its own `value` property internally — only its separate
  // `liveValue` moves during a drag — so a plain `value: root.scoreMin`
  // binding at the usage site keeps tracking root.scoreMin correctly even
  // after dragging, unlike Dropdown's `value`. No explicit re-sync needed.
  function resetScoreMin() {
    root.scoreMin = 1
  }

  function setScoreMin(newMin) {
    root.scoreMin = newMin
  }

  // ---------- shared background service ----------

  // The bar-widget (this file) is a fully separate component instance per
  // monitor Omarchy's bar renders on — settings I/O, the new-review poll,
  // the suspend/resume watcher, and notifications must not run once per
  // monitor, so they live in the singleton Service.qml (kinds: ["service",
  // "bar-widget"] in manifest.json) instead. `bar.shell.serviceFor(id)`
  // only resolves to a plugin's own declared service (see the third-party
  // io.github.kallupx.oma-mullvad plugin for the identical pattern), so
  // `moduleName` here being this plugin's own manifest id is what makes
  // this work. svc can be briefly null before the host injects `bar` —
  // every read below falls back to Service.qml's own initial defaults so
  // the UI doesn't look broken in that window, and every write no-ops.
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property bool hasUnseen: svc ? svc.hasUnseen : false
  readonly property var refreshIntervalOptions: [10, 20, 30, 60]
  readonly property bool backgroundRefreshEnabled: svc ? svc.backgroundRefreshEnabled : true
  readonly property int refreshIntervalMinutes: svc ? svc.refreshIntervalMinutes : 20
  readonly property bool notificationsEnabled: svc ? svc.notificationsEnabled : true
  readonly property string languageOverride: svc ? svc.languageOverride : ""

  // Every UI string in this file goes through this instead of Strings.t()
  // directly, so a Settings → Language change re-renders live: every
  // text: root.tr("…") binding below reads root.languageOverride as part
  // of evaluating that call, and QML tracks that read the same as any
  // other property dependency — so the binding re-evaluates the moment
  // the setting changes. A plain module-level JS variable on Strings.js
  // instead wouldn't trigger that (QML bindings only re-run off
  // property-change signals, not arbitrary JS mutation).
  function tr(key) { return Strings.t(key, root.languageOverride) }

  function setLanguageOverride(code) {
    if (root.svc) root.svc.setLanguageOverride(code)
  }

  // Mirrors categoryOptions()'s checkmark treatment. "" is the sentinel for
  // "System" (follow Qt.locale()); Strings.availableLanguages() gives the
  // rest, already alphabetically sorted by native name.
  function languageOptions() {
    var systemLabel = root.tr("languageSystem")
    var opts = [{ value: "", label: root.languageOverride === "" ? "✓ " + systemLabel : systemLabel }]
    var langs = Strings.availableLanguages()
    for (var i = 0; i < langs.length; i++) {
      var l = langs[i]
      opts.push({ value: l.code, label: root.languageOverride === l.code ? "✓ " + l.name : l.name })
    }
    return opts
  }

  // Same reason categoryDropdown needs resetCategory(): Dropdown.qml's
  // selectCurrent() assigns its own `value` imperatively, severing the
  // declarative `value: root.languageOverride` binding below the first
  // time anyone picks a language in this specific dropdown instance. Since
  // the setting is shared (one singleton Service across every monitor's
  // panel), re-sync on open so a change made from another monitor's panel
  // still shows correctly here.
  function resyncLanguageDropdown() {
    if (languageDropdown) languageDropdown.value = root.languageOverride
  }

  function setBackgroundRefreshEnabled(enabled) {
    if (root.svc) root.svc.setBackgroundRefreshEnabled(enabled)
  }

  function setRefreshIntervalMinutes(minutes) {
    if (root.svc) root.svc.setRefreshIntervalMinutes(minutes)
  }

  function setNotificationsEnabled(enabled) {
    if (root.svc) root.svc.setNotificationsEnabled(enabled)
  }

  // "N min" below 60, "1 time"/"1 hour" at 60 — the only option that
  // crosses the hour mark right now, but written to generalize if a
  // future option (e.g. 90) needs it too.
  function formatRefreshInterval(minutes) {
    if (minutes >= 60 && minutes % 60 === 0) {
      var hours = minutes / 60
      return hours + " " + root.tr(hours === 1 ? "unitHour" : "unitHours")
    }
    return minutes + " " + root.tr("unitMinutes")
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        // Reassigning root.results (a plain array, not a ListModel) makes
        // ListView treat it as a brand-new model and snap contentY back to
        // 0 — fine for a fresh/filtered load, but "load more" should leave
        // the scroll position where the user was so the newly appended
        // rows are easy to find. Capture it before the reassignment below
        // and restore it once the view has re-laid-out around the larger
        // model.
        var wasAppend = root.fetchIsAppend
        var savedContentY = wasAppend ? resultsList.contentY : 0
        try {
          var data = JSON.parse(String(text || ""))
          var plugs = (data && data.plugs) || []
          var mapped = plugs.filter(function(p) { return p && p.url && p.title })
          root.results = wasAppend ? root.results.concat(mapped) : mapped
          root.cursor = (data && data.cursor) || ""
          root.hasNextPage = !!(data && data.hasNextPage)
          root.errorText = root.results.length === 0 ? root.tr("noResults") : ""
          // The unfiltered "All" page is the same feed the background poll
          // watches — whenever we've just loaded a fresh one (on open, or
          // by switching back to "All"), treat its newest item as seen.
          if (!wasAppend && root.selectedCategory === "all" && mapped.length > 0 && root.svc)
            root.svc.markSeen(mapped[0].url)
        } catch (e) {
          if (!wasAppend) root.results = []
          root.errorText = root.tr("loadFailed")
        }
        if (wasAppend) Qt.callLater(function() { resultsList.contentY = savedContentY })
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      // Reset on the way in (see andersdosen.imdbsearch for why: avoids
      // the panel's content collapsing out from under the fade-out).
      // Clear the unseen badge immediately — the fetch below will confirm
      // it via svc.markSeen() once the fresh "All" page lands, but the
      // user is about to be looking right at the list either way.
      if (root.svc) root.svc.clearUnseen()
      root.showSettings = false
      root.resetCategory()
      root.resetScoreMin()
      root.resyncLanguageDropdown()
      root.results = []
      root.cursor = ""
      root.hasNextPage = false
      root.errorText = ""
      root.copiedUrl = ""
      root.loadFirstPage()
    } else {
      fetchProc.running = false
      root.loading = false
      copiedTimer.stop()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    tooltipText: root.tr("barTooltip")
    onPressed: function(b) { root.toggle() }
  }

  // Unseen-reviews dot — same color and corner placement as the
  // Notification Center plugin's unread marker.
  Rectangle {
    visible: root.hasUnseen
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Cap is a safety ceiling, not a tight fit — raised from 620 after the
    // score-filter slider (added later) pushed the worst case (a full,
    // list-capped-at-440 page plus the header/dropdown/score section and
    // the "Load more" button) to a measured 649px, which 620 clipped:
    // the card itself stayed short but its Column content didn't, so
    // "Load more" rendered below the visible card with nothing clipping
    // it off. panel.fittedContentHeight() still shrinks to fit smaller
    // content and never exceeds the screen's actual available height, so
    // raising this is safe headroom, not a fixed size.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(headerRow.implicitHeight, headerActions.implicitHeight)

          Row {
            id: headerRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              text: root.icon
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.tr("barTooltip")
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              id: externalLinkButton
              iconText: "" // nf-fa-external_link
              tooltipText: root.tr("externalLinkTooltip")
              foreground: root.barForeground
              onClicked: Util.execArgv(["omarchy-launch-browser", "https://www.nrk.no/anmeldelser"])
            }

            PanelActionButton {
              id: settingsButton
              iconText: "" // nf-fa-cog
              tooltipText: root.tr("settingsTooltip")
              foreground: root.showSettings ? Color.accent : root.barForeground
              onClicked: root.showSettings = !root.showSettings
            }
          }
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        Column {
          id: reviewsSection
          visible: !root.showSettings
          width: parent.width
          spacing: Style.space(10)

          Dropdown {
            id: categoryDropdown
            width: parent.width
            label: root.tr("categoryLabel")
            foreground: root.barForeground
            background: Color.popups.background
            fontFamily: Style.font.family
            options: root.categoryOptions()
            value: root.selectedCategory
            onChanged: function(v) { root.onCategoryChanged(v) }
          }

          Column {
            visible: root.scoreFilterApplicable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Math.max(scoreLabel.implicitHeight, scoreHint.implicitHeight)

              // Same look as Dropdown's own built-in label (Ui/Dropdown.qml)
              // — caption size, bold, darkened foreground — so this reads
              // as the same kind of field label as "Category" above it.
              Text {
                id: scoreLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.tr("scoreFilterLabel") + ": " + root.scoreMin
                color: Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              // Clarifies this isn't a server-side search filter — it only
              // hides rows among whatever's already been fetched (see the
              // "no matches on this page" empty state below).
              Text {
                id: scoreHint
                anchors.left: scoreLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: root.tr("scoreFilterHint")
                color: Qt.darker(root.barForeground, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            PanelSlider {
              id: scoreMinSlider
              bar: root.bar
              width: parent.width
              minimum: 1
              maximum: 6
              step: 1
              integer: true
              tickCount: 6
              value: root.scoreMin
              onMoved: function(v) { root.setScoreMin(Math.round(v)) }
            }

            // Positioned to match each stop's actual fraction along the
            // track (same (value-minimum)/(maximum-minimum) math as the
            // knob itself), not divided into equal-width cells — cells
            // put "1" and "6" flush at the row's edges while centering
            // the rest within their own cell, which doesn't land on
            // where the knob actually stops and reads as uneven spacing.
            Item {
              id: scoreTicks
              width: parent.width
              height: scoreTickMetrics.implicitHeight

              // Off-screen, only for its implicitHeight — a Repeater
              // delegate can't carry its own `id` (every instance would
              // collide on the same name), so this is what the Item
              // above sizes itself against instead.
              Text {
                id: scoreTickMetrics
                visible: false
                text: "1"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: 6
                Text {
                  required property int index
                  text: String(index + 1)
                  color: Qt.darker(root.barForeground, 1.55)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  x: Math.max(0, Math.min(scoreTicks.width - implicitWidth,
                    scoreTicks.width * (index / 5) - implicitWidth / 2))
                }
              }
            }
          }

          // Fixed-height box (not just the spinner's own size) so the panel
          // doesn't visibly jump between "empty" and "spinning" the instant
          // a fetch starts — covers both the initial page load on open and
          // a category switch, never "load more" (fetchIsAppend stays
          // false for those, true for that). Matches a review row's
          // thumbnail height exactly, so the transition into the first
          // loaded row reads as seamless rather than a resize.
          Item {
            id: loadingSpinnerBox
            visible: root.loading && root.results.length === 0
            width: parent.width
            height: root.thumbHeight

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: String.fromCodePoint(0xf0996) // nf-md-loading
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.space(20)

              // Same rotating-glyph approach as omarchy.weather's own
              // location-saving spinner.
              RotationAnimator on rotation {
                running: loadingSpinnerBox.visible
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
              }
            }
          }

          Text {
            visible: !root.loading && root.errorText !== "" && root.results.length === 0
            width: parent.width
            text: root.errorText
            color: Color.urgent
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // The score filter runs over whatever's already fetched, so a
          // page can come back with results yet none in range — distinct
          // from the "NRK returned nothing at all" errorText case above.
          // Its own "Load more" button (not the list's footer below, which
          // this empty state hides along with the rest of the list) is
          // what keeps a narrow score range from becoming a dead end.
          Column {
            visible: !root.loading && root.scoreFilterActive && root.filteredResults.length === 0 && root.results.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.tr("scoreFilterNoMatches")
              color: Qt.darker(root.barForeground, 1.55)
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: root.hasNextPage
              width: parent.width
              enabled: !root.loading
              text: root.loading ? root.tr("loading") : root.tr("loadMore")
              foreground: root.barForeground
              fontFamily: Style.font.family
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              onClicked: root.loadMore()
            }
          }

          // Scrollable results list — caps its own height so a full page of
          // reviews (plus "load more" pages) never pushes the popup off-screen.
          // "Load more" is the list's own footer (not a permanent sibling
          // below it) so it only comes into view once you've actually
          // scrolled to the bottom, rather than sitting there immediately
          // below a list you haven't finished looking at yet.
          ListView {
            id: resultsList
            visible: root.filteredResults.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(440))
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.filteredResults
            delegate: ResultRow {
              required property var modelData
              width: resultsList.width
              item: modelData
            }

            footer: Item {
              width: resultsList.width
              height: (root.hasNextPage || (root.loading && root.fetchIsAppend)) ? loadMoreButton.implicitHeight + Style.space(6) : 0

              Button {
                id: loadMoreButton
                anchors.top: parent.top
                anchors.topMargin: Style.space(6)
                width: parent.width
                visible: root.hasNextPage || (root.loading && root.fetchIsAppend)
                enabled: !root.loading
                text: root.loading ? root.tr("loading") : root.tr("loadMore")
                foreground: root.barForeground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.loadMore()
              }
            }
          }
        }

        Column {
          id: settingsSection
          visible: root.showSettings
          width: parent.width
          spacing: Style.space(14)

          Dropdown {
            id: languageDropdown
            width: parent.width
            label: root.tr("languageLabel")
            foreground: root.barForeground
            background: Color.popups.background
            fontFamily: Style.font.family
            options: root.languageOptions()
            value: root.languageOverride
            onChanged: function(v) { root.setLanguageOverride(v) }
          }

          Toggle {
            width: parent.width
            label: root.tr("backgroundRefreshLabel")
            description: root.tr("backgroundRefreshDescription")
            foreground: root.barForeground
            fontFamily: Style.font.family
            checked: root.backgroundRefreshEnabled
            onClicked: root.setBackgroundRefreshEnabled(!root.backgroundRefreshEnabled)
          }

          // Both of these only mean anything when background refresh is
          // actually running, so both hide with it.
          Column {
            width: parent.width
            visible: root.backgroundRefreshEnabled
            spacing: Style.space(14)

            Column {
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: root.tr("refreshIntervalLabel") + ": " + root.formatRefreshInterval(root.refreshIntervalMinutes)
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              PanelSlider {
                id: intervalSlider
                bar: root.bar
                width: parent.width
                minimum: 0
                maximum: root.refreshIntervalOptions.length - 1
                step: 1
                integer: true
                tickCount: root.refreshIntervalOptions.length
                value: root.refreshIntervalOptions.indexOf(root.refreshIntervalMinutes)
                onMoved: function(v) { root.setRefreshIntervalMinutes(root.refreshIntervalOptions[Math.round(v)]) }
              }

              // Tick labels under the slider so the four stops (10/20/30/60)
              // read as discrete options rather than an arbitrary range.
              // Positioned at each stop's actual index/(length-1) fraction
              // (same math the PanelSlider knob itself uses) rather than
              // divided into equal-width cells — cells put the first/last
              // label flush at the row's edges while centering the rest
              // within their own cell, which doesn't land on where the
              // knob actually stops and reads as uneven spacing.
              Item {
                id: intervalTicks
                width: parent.width
                height: intervalTickMetrics.implicitHeight

                Text {
                  id: intervalTickMetrics
                  visible: false
                  text: root.formatRefreshInterval(root.refreshIntervalOptions[0])
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: root.refreshIntervalOptions
                  Text {
                    required property var modelData
                    required property int index
                    text: root.formatRefreshInterval(modelData)
                    color: Qt.darker(root.barForeground, 1.55)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    x: Math.max(0, Math.min(intervalTicks.width - implicitWidth,
                      intervalTicks.width * (index / (root.refreshIntervalOptions.length - 1)) - implicitWidth / 2))
                  }
                }
              }
            }

            Toggle {
              width: parent.width
              label: root.tr("notificationsLabel")
              description: root.tr("notificationsDescription")
              foreground: root.barForeground
              fontFamily: Style.font.family
              checked: root.notificationsEnabled
              onClicked: root.setNotificationsEnabled(!root.notificationsEnabled)
            }
          }

          PanelSeparator {
            foreground: root.barForeground
          }

          // Static, hardcoded URL — not user- or API-derived data, so this
          // doesn't need the isTrustedReviewUrl() check openResult() uses
          // for NRK's own API-sourced review links (see there for why).
          Button {
            width: parent.width
            iconText: "" // nf-fa-github
            text: root.tr("visitGithubLabel")
            foreground: root.barForeground
            fontFamily: Style.font.family
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: Util.execArgv(["omarchy-launch-browser", "https://github.com/andersdosen/omarchy-nrkreviews"])
          }
        }
      }
    }
  }

  component ResultRow: Item {
    id: row
    property var item: null

    implicitHeight: Math.max(thumb.height, textCol.implicitHeight) + Style.space(10)

    property string localThumbPath: ""

    // Picks the "160"-wide derivate out of NRK's crop/derivate JSON shape
    // (an array of single-key {"<width>": "<hash>"} objects), preferring
    // the primary teaser crop and falling back to the image's own top-level
    // derivates when no crop is present.
    function findDerivate(list, width) {
      if (!list) return ""
      for (var i = 0; i < list.length; i++) {
        var o = list[i]
        if (o && o[width] !== undefined) return o[width]
      }
      return ""
    }

    function thumbHash() {
      if (!row.item || !row.item.image) return ""
      var img = row.item.image
      var crops = img.crops
      var fromCrop = (crops && crops.length > 0) ? row.findDerivate(crops[0].derivates, "160") : ""
      return fromCrop || row.findDerivate(img.derivates, "160")
    }

    // Only ever handed to fetch-image (which itself re-validates the host)
    // and used to build a local cache filename — still worth confirming
    // the shape is exactly what NRK's CDN hands back before either.
    function isValidHash(hash) {
      return /^[A-Za-z0-9_-]+$/.test(String(hash || ""))
    }

    function startThumbFetch() {
      row.localThumbPath = ""
      thumbFetchProc.running = false
      var hash = row.thumbHash()
      if (!row.isValidHash(hash)) return
      var outPath = root.thumbCacheDir + "/" + hash + ".jpg"
      if (root.thumbCacheKnownGood[hash]) {
        row.localThumbPath = "file://" + outPath
        return
      }
      thumbFetchProc.command = [root.fetchImageHelper, "https://gfx.nrk.no/" + hash, outPath]
      thumbFetchProc.__outPath = outPath
      thumbFetchProc.__hash = hash
      thumbFetchProc.running = true
    }

    // `item: modelData` at the delegate call site already assigns a value
    // during construction, which fires this same onItemChanged — a
    // separate Component.onCompleted call here used to also call
    // startThumbFetch() a second time, immediately killing and respawning
    // an identical fetch-image process for every row on every rebuild
    // (same bug, same fix, as the sibling andersdosen.imdbsearch plugin
    // hit and fixed for its own poster fetch).
    onItemChanged: row.startThumbFetch()

    Process {
      id: thumbFetchProc
      property string __outPath: ""
      property string __hash: ""
      onExited: function(exitCode) {
        if (exitCode === 0) {
          row.localThumbPath = "file://" + thumbFetchProc.__outPath
          root.thumbCacheKnownGood[thumbFetchProc.__hash] = true
        }
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: mouseArea.containsMouse ? Util.alpha(root.barForeground, 0.08) : "transparent"
    }

    Item {
      id: thumb
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      width: Style.space(64)
      height: root.thumbHeight

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Util.alpha(root.barForeground, 0.12)
        visible: thumbImg.status !== Image.Ready
      }

      Text {
        anchors.centerIn: parent
        text: root.icon
        color: Qt.darker(root.barForeground, 1.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        visible: thumbImg.status !== Image.Ready
      }

      Image {
        id: thumbImg
        anchors.fill: parent
        source: row.localThumbPath
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: thumb.width * 2
        sourceSize.height: thumb.height * 2
        visible: status === Image.Ready
      }
    }

    Column {
      id: textCol
      anchors.left: thumb.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.item ? String(row.item.title || "") : ""
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
      }

      Text {
        readonly property bool justCopied: row.item && root.reviewUrl(row.item) === root.copiedUrl
        width: parent.width
        textFormat: Text.PlainText
        text: justCopied ? root.tr("linkCopied") : (row.item ? root.captionFor(row.item) : "")
        color: justCopied ? Color.accent : Qt.darker(root.barForeground, 1.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: justCopied
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (!row.item) return
        if (mouse.button === Qt.RightButton) root.copyLink(row.item)
        else root.openResult(row.item)
      }
    }
  }
}

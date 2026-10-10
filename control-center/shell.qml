//@ pragma IconTheme Papirus-Dark
pragma ComponentBehavior: Bound

// FR Navy — control center
//   fr-toggle fr-control            → panel lengkap
//   fr-toggle fr-control wifi       → popup Wi-Fi saja
//   fr-toggle fr-control volume     → popup volume saja
//   fr-toggle fr-control brightness → popup brightness saja
// Halaman dipilih lewat env FR_PAGE. Tutup: Esc / klik di luar.
//
// Butuh: networkmanager, power-profiles-daemon, awww, wireplumber (wpctl),
//        pipewire-pulse (pactl), brightnessctl, swaync, hypridle.
// Opsional: bluez-utils (Bluetooth), wlsunset (Night Light).

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    // ── token ────────────────────────────────────────────
    readonly property color cBg:       "#0B0F17"
    readonly property color cSurface:  "#121826"
    readonly property color cSurface2: "#1A2233"
    readonly property color cBorder:   "#24304A"
    readonly property color cText:     "#E6EAF2"
    readonly property color cMuted:    "#8A96AD"
    readonly property color cAccent:   "#6EA8FE"
    function tone(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color cOnAccent: "#0B0F17"
    readonly property color cTeal:     "#7FD1B9"
    readonly property color cWarn:     "#F2C46D"
    readonly property color cUrgent:   "#F27A7A"
    readonly property string fUi:   "Inter"
    readonly property string fIcon: "JetBrainsMono Nerd Font"

    readonly property string home: Quickshell.env("HOME")
    readonly property string user: Quickshell.env("USER") || "kamu"
    readonly property string wallDir: home + "/Pictures/Wallpaper"
    readonly property string wallLink: home + "/.config/hypr/wallpaper.png"
    readonly property string lockLink: home + "/.config/hypr/lock.png"

    function ic(cp) { return String.fromCodePoint(cp); }

    // ── halaman ──────────────────────────────────────────
    readonly property string mode: Quickshell.env("FR_PAGE") || "main"
    readonly property bool compact: ["wifi", "volume", "brightness", "battery", "calendar"].includes(mode)
    property string page: mode
    readonly property var titles: ({
        main: "Kontrol", wifi: "Wi-Fi", volume: "Suara", brightness: "Layar",
        wallpaper: "Wallpaper", monitor: "Monitor", theme: "Tema", profile: "Profil", battery: "Baterai", calendar: "Kalender"
    })
    function back() {
        if (pendingSsid !== "") { pendingSsid = ""; return; }
        if (powerConfirm !== "") { powerConfirm = ""; return; }
        if (!compact && page !== "main") page = "main"; else Qt.quit();
    }
    onPageChanged: {
        if (page === "wifi") refreshNet();
        if (page === "monitor") outProc.running = true;
        if (page === "volume") sinkProc.running = true;
        if (page === "calendar" && !weather) loadWeather(false);
        if (page === "theme") dockProc.running = true;
        // buat thumbnail yang belum ada di latar belakang (dipakai saat panel dibuka berikutnya)
        if (page === "wallpaper") exec(["sh", "-c", 'command -v fr-thumbs >/dev/null && exec fr-thumbs || exec "$HOME/.local/bin/fr-thumbs"']);
    }

    // ── dock ──
    property bool dockOn: false
    Process {
        id: dockProc
        command: ["sh", "-c", 'exec "$HOME/.local/bin/fr-dock" status']
        stdout: StdioCollector { onStreamFinished: root.dockOn = this.text.trim() === "on" }
    }
    function toggleDock() {
        dockOn = !dockOn;
        exec(["sh", "-c", 'exec "$HOME/.local/bin/fr-dock" "$1"', "sh", dockOn ? "on" : "off"]);
    }

    // ═════════ STATE ═════════════════════════════════════
    // sistem
    property int battery: -1
    property string batStatus: ""
    property int uptimeSec: 0
    property bool powerOpen: false
    property string powerConfirm: ""

    // jaringan
    property bool wifiOn: false
    property var networks: []
    property var savedSsids: ({})
    property bool scanning: false
    property string pendingSsid: ""
    property string busySsid: ""
    property string netError: ""
    property string activeConn: ""      // SSID aktif tanpa perlu scan
    property string ethDev: ""
    property string ethState: ""

    // tile lain
    property string btState: "none"     // none / on / off
    property bool dnd: false
    property bool nightOn: false
    property bool caffeine: false

    // audio & layar
    property real volume: 0
    property bool muted: false
    property real micVolume: 0
    property bool micMuted: false
    property var sinks: []              // [{name, desc}]
    property string defaultSink: ""
    property real brightness: 0
    property bool hasBacklight: true

    // daya, wallpaper, monitor
    property string profile: ""
    property bool ppdAvailable: true
    property bool autoPower: false      // service fr-power-auto aktif
    property string currentWall: ""
    property string lockWall: ""        // file asli lockscreen
    property bool lockFollows: true     // lockscreen ikut wallpaper desktop
    property string wallTab: "desktop"  // desktop / lock
    property string lockStyle: "editorial"
    property bool hasCustomLock: false
    property var outputs: []            // [{name, label, on, internal}]
    property var themes: []             // [{id, name, desc, colors}]
    property string displayName: user
    property string accountName: user
    property bool hasFace: false
    readonly property string faceFile: home + "/.face"
    property string currentTheme: "navy"

    // ── baterai ──
    property var bat: ({})              // nilai mentah sysfs
    property var powerHist: []          // watt, untuk estimasi yang stabil
    readonly property bool hasBattery: bat.capacity !== undefined
    readonly property int batPct: parseInt(bat.capacity) || 0
    // batas pengisian (-1 = laptop tidak mendukung)
    readonly property int chargeLimit: bat.charge_control_end_threshold !== undefined ? (parseInt(bat.charge_control_end_threshold) || 100) : -1
    property string chargeErr: ""
    Process {
        id: chargeSet
        stderr: StdioCollector { id: chargeErrOut }
        onExited: code => {
            root.chargeErr = code === 0 ? "" : (chargeErrOut.text.trim().split("\n").pop() || "Gagal mengatur batas");
            batProc.running = true;
        }
    }
    function setChargeLimit(n) {
        chargeSet.command = [home + "/.local/bin/fr-charge", "set", String(n)];
        chargeSet.running = true;
    }
    readonly property string batState: bat.status || ""
    readonly property bool charging: batState === "Charging"
    // energi dalam Wh (sysfs pakai µWh, atau µAh × V untuk baterai berbasis charge_*)
    function wh(e, c) {
        if (bat[e] !== undefined) return (+bat[e]) / 1e6;
        if (bat[c] !== undefined) return (+bat[c]) / 1e6 * ((+bat.voltage_now || 0) / 1e6);
        return 0;
    }
    readonly property real energyNow: wh("energy_now", "charge_now")
    readonly property real energyFull: wh("energy_full", "charge_full")
    readonly property real energyDesign: wh("energy_full_design", "charge_full_design")
    readonly property real powerNow: {
        if (bat.power_now !== undefined) return Math.abs(+bat.power_now) / 1e6;
        if (bat.current_now !== undefined) return Math.abs(+bat.current_now) / 1e6 * ((+bat.voltage_now || 0) / 1e6);
        return 0;
    }
    readonly property real powerAvg: powerHist.length ? powerHist.reduce((a, b) => a + b, 0) / powerHist.length : powerNow
    readonly property real health: energyDesign > 0 ? Math.min(1, energyFull / energyDesign) : 0
    // jam tersisa: habis (dipakai) atau penuh (mengisi)
    readonly property real hoursLeft: {
        if (powerAvg < 0.3) return -1;
        if (charging) return Math.max(0, energyFull - energyNow) / powerAvg;
        if (batState === "Discharging") return energyNow / powerAvg;
        return -1;
    }
    function fmtDur(h) {
        const m = Math.round(h * 60), hh = Math.floor(m / 60), mm = m % 60;
        return hh > 0 ? hh + " jam " + mm + " menit" : mm + " menit";
    }
    function batColor(p) { return charging ? cAccent : p <= 15 ? cUrgent : p <= 30 ? cWarn : cTeal; }

    Process {
        id: batProc
        // semua dibaca dengan builtin `read`, tanpa cat
        command: ["sh", "-c",
            'for B in /sys/class/power_supply/BAT*; do [ -d "$B" ] || continue; ' +
            'for f in capacity status energy_now energy_full energy_full_design power_now ' +
            'charge_now charge_full charge_full_design current_now voltage_now cycle_count manufacturer model_name charge_control_end_threshold; do ' +
            '[ -r "$B/$f" ] && read -r v < "$B/$f" && echo "$f=$v"; done; break; done']
        stdout: StdioCollector {
            onStreamFinished: {
                const b = {};
                this.text.split("\n").forEach(l => { const i = l.indexOf("="); if (i > 0) b[l.slice(0, i)] = l.slice(i + 1).trim(); });
                root.bat = b;
                if (root.powerNow > 0.05) root.powerHist = root.powerHist.slice(-14).concat([root.powerNow]);
            }
        }
    }
    Timer {
        interval: 2000; repeat: true; triggeredOnStart: true
        running: root.page === "battery" || root.page === "main"
        onTriggered: batProc.running = true
    }

    // ── Wi-Fi lewat QR ──
    property var shareQr: null          // {ssid, type, hidden, png}
    property string shareKind: ""       // "wifi" | "hotspot"
    property bool shareBusy: false
    property string shareErr: ""
    Process {
        id: shareProc
        command: ["sh", "-c", '"$HOME/.local/bin/fr-wifiqr" share']
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.shareQr = JSON.parse(this.text.trim()); root.shareErr = ""; }
                catch (e) { root.shareQr = null; }
            }
        }
        stderr: StdioCollector { id: shareErrOut }
        onExited: code => {
            root.shareBusy = false;
            if (code !== 0) root.shareErr = (shareErrOut.text.trim().split("\n").pop() || "Gagal membuat QR").replace(/^[^:]*: /, "");
        }
    }
    function shareWifi() {
        if (shareQr) { const was = shareKind; closeShare(); if (was === "wifi") return; }
        shareKind = "wifi"; shareBusy = true; shareErr = "";
        shareProc.command = ["sh", "-c", '"$HOME/.local/bin/fr-wifiqr" share'];
        shareProc.running = true;
    }
    function shareHotspot() {
        if (shareQr) { const was = shareKind; closeShare(); if (was === "hotspot") return; }
        shareKind = "hotspot"; shareBusy = true; shareErr = "";
        shareProc.command = ["sh", "-c", '"$HOME/.local/bin/fr-hotspot" qr'];
        shareProc.running = true;
    }

    // ── hotspot: Wi-Fi sekitar → laptop → HP ──
    property var hs: ({ on: false, can: true, reason: "", ssid: "", password: "", clients: [], tx: 0, rx: 0, upstream: "", mode: "" })
    property bool hsBusy: false
    property string hsErr: ""
    property bool hsShowPass: false
    property bool hsEdit: false
    Process {
        id: hsProc
        command: ["sh", "-c", 'exec "$HOME/.local/bin/fr-hotspot" status']
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const was = root.hs.on;
                    root.hs = JSON.parse(this.text.trim());
                    if (was && !root.hs.on && root.shareKind === "hotspot") root.closeShare();
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: root.hs.on ? 3000 : 10000; repeat: true; triggeredOnStart: true
        running: root.page === "wifi" && !root.hsBusy
        onTriggered: hsProc.running = true
    }
    Process {
        id: hsAct
        stderr: StdioCollector { id: hsActErr }
        onExited: code => {
            root.hsBusy = false;
            root.hsErr = code === 0 ? "" : (hsActErr.text.trim().split("\n").pop() || "Gagal").replace(/^fr-hotspot:\s*/, "");
            if (code === 0) root.hsEdit = false;
            hsProc.running = true;
        }
    }
    function hsRun(args) {
        hsBusy = true; hsErr = "";
        hsAct.command = [home + "/.local/bin/fr-hotspot"].concat(args);
        hsAct.running = true;
    }
    function hsSave(ssid, pass) {
        ssid = ssid.trim();
        if (pass.length < 8) { hsErr = "Password minimal 8 karakter"; return; }
        if (!ssid) { hsErr = "Nama hotspot tidak boleh kosong"; return; }
        if (ssid === hs.ssid && pass === hs.password) { hsEdit = false; return; }
        hsBusy = true; hsErr = "";
        // hanya yang berubah (tiap perubahan me-restart hotspot yang sedang menyala)
        hsAct.command = ["sh", "-c", 'f="$HOME/.local/bin/fr-hotspot"; ' +
            '{ [ "$1" = "$3" ] || "$f" set ssid "$1"; } && { [ "$2" = "$4" ] || "$f" set pass "$2"; }',
            "sh", ssid, pass, hs.ssid, hs.password];
        hsAct.running = true;
    }
    function fmtBytes(b) {
        if (b < 1e6) return Math.round(b / 1e3) + " KB";
        if (b < 1e9) return (b / 1e6).toFixed(b < 1e8 ? 1 : 0) + " MB";
        return (b / 1e9).toFixed(2) + " GB";
    }
    function closeShare() {
        if (shareQr) exec(["rm", "-f", shareQr.png]);
        shareQr = null; shareKind = "";
    }

    // ── alat ──
    property bool recording: false
    // jalankan setelah panel tertutup (supaya panel tidak ikut ter-screenshot / menghalangi)
    function tool(cmd) {
        exec(["sh", "-c", 'sleep 0.25; exec "$HOME/.local/bin/$0" "$@"'].concat(cmd));
        Qt.quit();
    }

    // ── kalender & cuaca ──
    property date today: new Date()
    property int calYear: today.getFullYear()
    property int calMonth: today.getMonth()       // 0..11
    readonly property var monthNames: ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli",
                                       "Agustus", "September", "Oktober", "November", "Desember"]
    readonly property var dayNames: ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"]
    // 42 sel (6 minggu), mulai Senin
    readonly property var calCells: {
        const first = new Date(calYear, calMonth, 1);
        const lead = (first.getDay() + 6) % 7;
        const cells = [];
        for (let i = 0; i < 42; i++) {
            const d = new Date(calYear, calMonth, 1 - lead + i);
            cells.push({ day: d.getDate(), inMonth: d.getMonth() === calMonth, sunday: d.getDay() === 0,
                         today: d.toDateString() === today.toDateString() });
        }
        return cells;
    }
    function shiftMonth(d) {
        const m = calMonth + d;
        calYear += Math.floor(m / 12);
        calMonth = ((m % 12) + 12) % 12;
    }

    property var weather: null
    property bool weatherLoading: false
    function wIcon(code, night) {
        const c = parseInt(code);
        if (c === 113) return ic(night ? 0xf0594 : 0xf0599);
        if (c === 116) return ic(night ? 0xf0f31 : 0xf0595);
        if (c === 119 || c === 122) return ic(0xf0590);
        if ([143, 248, 260].includes(c)) return ic(0xf0591);
        if ([200, 386, 389, 392, 395].includes(c)) return ic(0xf067e);
        if ([179, 182, 185, 227, 230, 281, 284, 311, 314, 317, 320, 323, 326, 329, 332, 335, 338, 350,
             362, 365, 368, 371, 374, 377].includes(c)) return ic(0xf0598);
        if ([302, 305, 308, 356, 359].includes(c)) return ic(0xf0596);
        return ic(0xf0597);
    }
    function wDesc(o) {
        if (!o) return "";
        return ((o.lang_id && o.lang_id[0] && o.lang_id[0].value) || (o.weatherDesc && o.weatherDesc[0].value) || "").trim();
    }
    Process {
        id: weatherProc
        command: ["sh", "-c", '"$HOME/.local/bin/fr-weather" "$@"', "sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { const j = JSON.parse(this.text); if (j.current_condition) root.weather = j; } catch (e) {}
                root.weatherLoading = false;
            }
        }
    }
    function loadWeather(force) {
        if (weatherProc.running) return;
        weatherLoading = true;
        weatherProc.command = ["sh", "-c", '"$HOME/.local/bin/fr-weather" "$@"', "sh"].concat(force ? ["refresh"] : []);
        weatherProc.running = true;
    }

    // ── media (MPRIS, berbasis event: tanpa polling) ──
    property int playerPick: -1         // -1 = otomatis (yang sedang diputar)
    readonly property var players: Mpris.players.values.filter(p => p.trackTitle || p.isPlaying)
    readonly property var player: {
        if (players.length === 0) return null;
        if (playerPick >= 0 && playerPick < players.length) return players[playerPick];
        return players.find(p => p.isPlaying) || players[0];
    }
    function mediaSource(p) {
        if (!p) return "";
        const url = String((p.metadata || {})["xesam:url"] || "");
        const map = [[/music\.youtube\.com/, "YouTube Music"], [/youtube\.com|youtu\.be/, "YouTube"],
                     [/netflix\.com/, "Netflix"], [/primevideo/, "Prime Video"], [/disneyplus|hotstar/, "Disney+"],
                     [/soundcloud/, "SoundCloud"]];
        for (const [re, name] of map) if (re.test(url)) return name;
        return p.identity || "Media";
    }
    function mmss(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        return Math.floor(sec / 60) + ":" + String(sec % 60).padStart(2, "0");
    }

    readonly property string activeSsid: {
        const a = networks.find(n => n.active);
        return a ? a.ssid : activeConn;
    }

    // ═════════ HELPER ════════════════════════════════════
    function exec(cmd) { Quickshell.execDetached(cmd); }
    function sh(script) { Quickshell.execDetached(["sh", "-c", script]); }

    // field nmcli -t (titik dua di dalam nilai di-escape jadi "\:")
    function splitTerse(line, n) {
        const out = []; let cur = "";
        for (let i = 0; i < line.length; i++) {
            const ch = line[i];
            if (ch === "\\" && i + 1 < line.length) { cur += line[++i]; continue; }
            if (ch === ":" && out.length < n - 1) { out.push(cur); cur = ""; continue; }
            cur += ch;
        }
        out.push(cur);
        return out;
    }
    function fmtUptime(s) {
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
        return d > 0 ? d + "h " + h + "j" : h > 0 ? h + "j " + m + "m" : m + "m";
    }
    function volGlyph(v, mute) {
        if (mute || v <= 0.001) return ic(0xf075f);
        return ic(v < 0.34 ? 0xf057f : v < 0.67 ? 0xf0580 : 0xf057e);
    }

    // ═════════ PROSES BACA ═══════════════════════════════
    Process {
        id: sysProc
        command: ["sh", "-c",
            "cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1; echo; " +
            "cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1; echo; " +
            "cut -d. -f1 /proc/uptime"]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n").filter(x => x.trim() !== "");
                const cap = parseInt(l[0]);
                root.battery = isNaN(cap) ? -1 : cap;
                root.batStatus = isNaN(cap) ? "" : (l[1] || "");
                root.uptimeSec = parseInt(l[l.length - 1]) || 0;
            }
        }
    }
    Process {
        id: tileProc
        command: ["sh", "-c",
            "if command -v bluetoothctl >/dev/null; then bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && echo bt=on || echo bt=off; else echo bt=none; fi; " +
            "echo dnd=$(swaync-client -D 2>/dev/null); " +
            "pgrep -x wlsunset >/dev/null && echo night=1 || echo night=0; " +
            "pgrep -x hypridle >/dev/null && echo idle=1 || echo idle=0; " +
            "systemctl --user is-active -q fr-power-auto 2>/dev/null && echo auto=1 || echo auto=0; " +
            "P=\"${XDG_RUNTIME_DIR:-/tmp}/fr-rec.pid\"; [ -f \"$P\" ] && kill -0 \"$(cat \"$P\")\" 2>/dev/null && echo rec=1 || echo rec=0"]
        stdout: StdioCollector {
            onStreamFinished: {
                const kv = {};
                this.text.split("\n").forEach(l => { const i = l.indexOf("="); if (i > 0) kv[l.slice(0, i)] = l.slice(i + 1).trim(); });
                root.btState = kv.bt || "none";
                root.dnd = kv.dnd === "true";
                root.nightOn = kv.night === "1";
                root.caffeine = kv.idle === "0";
                root.autoPower = kv.auto === "1";
                root.recording = kv.rec === "1";
            }
        }
    }
    Process {
        id: volProc
        command: ["sh", "-c", "wpctl get-volume @DEFAULT_AUDIO_SINK@; wpctl get-volume @DEFAULT_AUDIO_SOURCE@"]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n");
                const parse = s => ({ v: parseFloat((s || "").replace(/[^0-9.]/g, " ").trim().split(" ")[0]) || 0, m: /MUTED/.test(s || "") });
                const a = parse(l[0]), b = parse(l[1]);
                if (!volSlider.dragging && !volSliderBig.dragging) { root.volume = Math.min(1, a.v); root.muted = a.m; }
                if (!micSlider.dragging) { root.micVolume = Math.min(1, b.v); root.micMuted = b.m; }
            }
        }
    }
    Process {
        id: sinkProc
        command: ["sh", "-c", "pactl -f json list sinks 2>/dev/null | tr -d '\\n'; echo; pactl get-default-sink 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n");
                try {
                    root.sinks = JSON.parse(l[0]).map(s => ({ name: s.name, desc: s.description || s.name }));
                } catch (e) { root.sinks = []; }
                root.defaultSink = (l[1] || "").trim();
            }
        }
    }
    Process {
        id: briProc
        command: ["brightnessctl", "-m", "-c", "backlight"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = this.text.trim().split(",");
                if (f.length >= 4 && !briSlider.dragging && !briSliderBig.dragging)
                    root.brightness = (parseInt(f[3]) || 0) / 100;
            }
        }
        onExited: code => root.hasBacklight = (code === 0)
    }
    Process {
        id: ppdGet
        command: ["powerprofilesctl", "get"]
        stdout: StdioCollector { onStreamFinished: root.profile = this.text.trim() }
        onExited: code => root.ppdAvailable = (code === 0)
    }
    Process {
        id: wallGet
        command: ["readlink", "-f", root.wallLink]
        stdout: StdioCollector { onStreamFinished: root.currentWall = this.text.trim() }
    }
    Process {
        id: lockGet
        command: ["sh", "-c", 'readlink "$1"; echo; readlink -f "$1"', "sh", root.lockLink]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n").filter(x => x !== "");
                root.lockFollows = l.length === 0 || (l.length >= 2 && l[0] === root.wallLink);
                root.lockWall = l[l.length - 1] || "";
            }
        }
    }
    Process {
        id: profGet
        command: ["sh", "-c", 'cat "$HOME/.config/fr-profile/name" 2>/dev/null; echo; ' +
                  'test -s "$HOME/.face" && echo 1 || echo 0; ' +
                  'getent passwd "$USER" | cut -d: -f5 | cut -d, -f1']
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n");
                root.accountName = (l[2] || "").trim() || root.user;
                root.displayName = (l[0] || "").trim() || root.accountName;
                root.hasFace = (l[1] || "").trim() === "1";
            }
        }
    }
    Process {
        id: themeGet
        command: ["sh", "-c", 'cat "$HOME/.config/fr-theme/themes.json" 2>/dev/null | tr -d "\\n"; echo; cat "$HOME/.config/fr-theme/current" 2>/dev/null || echo navy']
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n");
                try {
                    const t = JSON.parse(l[0]);
                    root.themes = Object.keys(t).map(k => ({ id: k, name: t[k].name, desc: t[k].desc, colors: t[k].colors }));
                } catch (e) { root.themes = []; }
                root.currentTheme = (l[1] || "navy").trim();
            }
        }
    }
    Process {
        id: lockStyleGet
        command: ["sh", "-c", '"$HOME/.local/bin/fr-lockstyle"; test -f "$HOME/.config/hypr/hyprlock-custom.conf" && echo custom']
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n").map(x => x.trim());
                root.lockStyle = l[0] || "editorial";
                root.hasCustomLock = l.slice(1).includes("custom");
            }
        }
    }
    function setLockStyle(st) {
        lockStyle = st;
        exec(["sh", "-c", '"$HOME/.local/bin/fr-lockstyle" "$1"', "sh", st]);
    }
    Process {
        id: outProc
        command: ["niri", "msg", "--json", "outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(this.text);
                    root.outputs = Object.keys(o).map(k => ({
                        name: k,
                        label: ((o[k].make || "") + " " + (o[k].model || "")).trim() || k,
                        on: !!o[k].logical,
                        internal: /^eDP|^LVDS|^DSI/.test(k)
                    })).sort((a, b) => b.internal - a.internal);
                } catch (e) { root.outputs = []; }
            }
        }
    }

    // jaringan
    function refreshNet() {
        radioProc.running = true;
        devProc.running = true;
        activeProc.running = true;
        if (page === "wifi") savedProc.running = true;
    }
    function scan() { if (!wifiOn || listProc.running) return; scanning = true; listProc.running = true; }
    Process {
        id: radioProc
        command: ["nmcli", "-t", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.wifiOn = this.text.trim() === "enabled";
                if (!root.wifiOn) root.networks = [];
                else if (root.page === "wifi") root.scan();   // scan cuma kalau daftar memang dilihat
            }
        }
    }
    Process {
        id: activeProc
        command: ["nmcli", "-t", "-f", "TYPE,NAME", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                let ssid = "";
                this.text.split("\n").forEach(l => { const f = root.splitTerse(l, 2); if (f[0] === "802-11-wireless" && !ssid && f[1] !== "fr-hotspot") ssid = f[1]; });
                root.activeConn = ssid;
            }
        }
    }
    Process {
        id: savedProc
        command: ["nmcli", "-t", "-f", "TYPE,NAME", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                this.text.split("\n").forEach(l => { const f = root.splitTerse(l, 2); if (f[0] === "802-11-wireless") m[f[1]] = true; });
                root.savedSsids = m;
            }
        }
    }
    Process {
        id: listProc
        command: ["nmcli", "-t", "-f", "SIGNAL,SECURITY,IN-USE,SSID", "device", "wifi", "list", "--rescan", "auto"]
        stdout: StdioCollector {
            onStreamFinished: {
                const best = {};
                this.text.split("\n").forEach(l => {
                    if (!l) return;
                    const f = root.splitTerse(l, 4);
                    if (!f[3]) return;
                    const n = { ssid: f[3], signal: parseInt(f[0]) || 0, secure: f[1] !== "" && f[1] !== "--",
                                active: f[2] === "*", saved: !!root.savedSsids[f[3]] };
                    const o = best[n.ssid];
                    if (!o || n.active || (!o.active && n.signal > o.signal)) best[n.ssid] = n;
                });
                root.networks = Object.values(best).sort((a, b) => (b.active - a.active) || (b.signal - a.signal)).slice(0, 12);
                root.scanning = false;
            }
        }
    }
    Process {
        id: devProc
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device"]
        stdout: StdioCollector {
            onStreamFinished: {
                let dev = "", st = "";
                this.text.split("\n").forEach(l => {
                    const f = root.splitTerse(l, 3);
                    if (f[1] === "ethernet" && dev === "") { dev = f[0]; st = (f[2] || "").split(" ")[0]; }
                });
                root.ethDev = dev; root.ethState = st;
            }
        }
    }
    Process {
        id: actProc
        stderr: StdioCollector { id: actErr }
        onExited: code => {
            if (code !== 0) {
                const msg = actErr.text.trim().split("\n").pop() || "Gagal";
                if (/secret|password|802-1x/i.test(msg) && root.busySsid) {
                    root.pendingSsid = root.busySsid;
                    root.netError = "Password salah atau dibutuhkan";
                } else root.netError = msg.replace(/^Error:\s*/, "");
            } else { root.netError = ""; root.pendingSsid = ""; }
            root.busySsid = "";
            netRefresh.restart();
        }
    }
    Timer { id: netRefresh; interval: 900; onTriggered: root.refreshNet() }
    function runNet(cmd, ssid) {
        if (actProc.running) return;
        netError = ""; busySsid = ssid || "";
        actProc.command = cmd; actProc.running = true;
    }

    // ═════════ AKSI ══════════════════════════════════════
    function toggleWifi() {
        runNet(["nmcli", "radio", "wifi", wifiOn ? "off" : "on"]);
        wifiOn = !wifiOn;
        if (!wifiOn) networks = [];
    }
    function clickNetwork(n) {
        if (n.active)       runNet(["nmcli", "connection", "down", "id", n.ssid], n.ssid);
        else if (n.saved)   runNet(["nmcli", "connection", "up", "id", n.ssid], n.ssid);
        else if (!n.secure) runNet(["nmcli", "device", "wifi", "connect", n.ssid], n.ssid);
        else { pendingSsid = pendingSsid === n.ssid ? "" : n.ssid; netError = ""; }
    }
    function connectWithPassword(ssid, pw) {
        if (pw.length < 8) { netError = "Password minimal 8 karakter"; return; }
        runNet(["nmcli", "device", "wifi", "connect", ssid, "password", pw], ssid);
    }
    function toggleEthernet() {
        if (!ethDev || ethState === "unavailable") return;
        runNet(["nmcli", "device", ethState === "connected" ? "disconnect" : "connect", ethDev]);
    }
    function toggleBt()   { if (btState === "none") return; exec(["bluetoothctl", "power", btState === "on" ? "off" : "on"]); btState = btState === "on" ? "off" : "on"; }
    function toggleDnd()  { exec(["swaync-client", "-d", "-sw"]); dnd = !dnd; }
    function toggleNight() {
        if (nightOn) exec(["pkill", "-x", "wlsunset"]);
        else exec(["wlsunset", "-t", "4000", "-T", "4001"]);   // selalu hangat ±4000K
        nightOn = !nightOn;
    }
    function toggleCaffeine() {
        if (caffeine) exec(["hypridle"]); else exec(["pkill", "-x", "hypridle"]);
        caffeine = !caffeine;
    }

    // volume & brightness (ditahan 40ms supaya drag nggak banjir proses)
    property real _vol: -1
    property real _mic: -1
    property real _bri: -1
    Timer {
        id: applyTimer
        interval: 40
        onTriggered: {
            if (root._vol >= 0) { root.exec(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", Math.round(root._vol * 100) + "%"]); root._vol = -1; }
            if (root._mic >= 0) { root.exec(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SOURCE@", Math.round(root._mic * 100) + "%"]); root._mic = -1; }
            if (root._bri >= 0) { root.exec(["brightnessctl", "-q", "-c", "backlight", "s", Math.max(1, Math.round(root._bri * 100)) + "%"]); root._bri = -1; }
        }
    }
    function setVolume(v) { volume = v; _vol = v; if (muted && v > 0) toggleMute(); applyTimer.restart(); }
    function setMic(v)    { micVolume = v; _mic = v; applyTimer.restart(); }
    function setBrightness(v) { brightness = v; _bri = v; applyTimer.restart(); }
    function toggleMute()    { exec(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]); muted = !muted; }
    function toggleMicMute() { exec(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]); micMuted = !micMuted; }
    function setSink(name)   { exec(["pactl", "set-default-sink", name]); defaultSink = name; slowRefresh.restart(); }
    Timer { id: slowRefresh; interval: 300; onTriggered: volProc.running = true }

    // fr-power: ganti profil CPU + sesuaikan rice (animasi, shadow, brightness)
    function setProfile(p) {
        profile = p;
        exec(["sh", "-c", 'command -v fr-power >/dev/null && exec fr-power "$1" || exec "$HOME/.local/bin/fr-power" "$1"', "sh", p]);
    }
    function toggleAutoPower() {
        autoPower = !autoPower;
        exec(["systemctl", "--user", autoPower ? "enable" : "disable", "--now", "fr-power-auto.service"]);
    }
    function setWallpaper(path) {
        currentWall = path;
        if (lockFollows) lockWall = path;
        exec(["sh", "-c", 'ln -sf "$1" "$2" && awww img "$1" --transition-type grow --transition-pos top-right --transition-duration 1', "sh", path, wallLink]);
    }
    readonly property string thumbDir: home + "/.cache/fr-thumbs"
    function thumbOf(path) { return thumbDir + "/" + path.split("/").pop() + ".jpg"; }
    function setLockWallpaper(path) {
        lockWall = path; lockFollows = false;
        exec(["ln", "-sf", path, lockLink]);
    }
    function setLockFollow(on) {
        lockFollows = on;
        if (on) { exec(["ln", "-sf", wallLink, lockLink]); lockWall = currentWall; }
    }
    // pasang tema lalu buka ulang panel ini (supaya panelnya ikut berganti warna)
    function applyTheme(id) {
        if (id === currentTheme) return;
        exec(["sh", "-c", '"$HOME/.local/bin/fr-theme" "$1" && FR_PAGE=theme exec qs -p "$HOME/.config/fr-control/shell.qml"', "sh", id]);
        Qt.quit();
    }
    // profil: dialog file / pembuatan avatar butuh panel ditutup dulu, lalu panel dibuka lagi
    function avatar(args) {
        exec(["sh", "-c", 'b="$HOME/.local/bin"; "$b/fr-avatar" "$@"; FR_PAGE=profile exec qs -p "$HOME/.config/fr-control/shell.qml"', "sh"].concat(args));
        Qt.quit();
    }
    function saveName(n) {
        displayName = n.trim() || accountName;
        exec(["sh", "-c", '"$HOME/.local/bin/fr-avatar" name "$1"', "sh", n.trim()]);
    }
    function previewLock() { exec(["sh", "-c", "pidof hyprlock || hyprlock"]); Qt.quit(); }
    function setMonitorMode(m) {
        // m: "internal" | "extend" | "external"
        outputs.forEach(o => {
            const on = m === "extend" || (m === "internal" ? o.internal : !o.internal);
            exec(["niri", "msg", "output", o.name, on ? "on" : "off"]);
        });
        monRefresh.restart();
    }
    Timer { id: monRefresh; interval: 500; onTriggered: outProc.running = true }
    readonly property bool hasExternal: outputs.some(o => !o.internal)
    readonly property string monitorMode: {
        const i = outputs.filter(o => o.internal), x = outputs.filter(o => !o.internal);
        if (x.length === 0) return "internal";
        const iOn = i.some(o => o.on), xOn = x.some(o => o.on);
        return iOn && xOn ? "extend" : xOn ? "external" : "internal";
    }

    function power(action) {
        const destructive = ["logout", "reboot", "poweroff"];
        if (destructive.includes(action) && powerConfirm !== action) { powerConfirm = action; return; }
        const cmds = {
            lock: ["loginctl", "lock-session"],
            suspend: ["systemctl", "suspend"],
            logout: ["niri", "msg", "action", "quit", "--skip-confirmation"],
            reboot: ["systemctl", "reboot"],
            poweroff: ["systemctl", "poweroff"]
        };
        exec(cmds[action]);
        Qt.quit();
    }

    // polling ringan selama panel terbuka
    // polling ringan, cuma selama panel terbuka
    Timer {
        interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { volProc.running = true; if (root.hasBacklight) briProc.running = true; }
    }
    Timer {
        interval: 30000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: sysProc.running = true
    }
    Component.onCompleted: {
        if (page === "theme") dockProc.running = true;   // dibuka langsung ke halaman Tema (mis. setelah ganti tema)
        tileProc.running = true;
        ppdGet.running = true;
        wallGet.running = true;
        lockGet.running = true;
        lockStyleGet.running = true;
        themeGet.running = true;
        profGet.running = true;
        refreshNet();
        if (page === "volume") sinkProc.running = true;
        if (page === "monitor") outProc.running = true;
        if (page === "calendar") loadWeather(false);
    }

    // ═════════ JENDELA ═══════════════════════════════════
    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "fr-control"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
        Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: root.back() }

        Rectangle {
            id: panel
            width: root.compact ? 340 : 392
            height: Math.min(content.implicitHeight + 32, win.height - 70)
            anchors { top: parent.top; right: parent.right; topMargin: 50; rightMargin: 10 }
            radius: 20
            color: root.cBg
            border.color: root.cBorder
            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            opacity: 0
            transform: Translate { id: slide; y: -8 }
            Component.onCompleted: { opacity = 1; slide.y = 0; }
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            MouseArea { anchors.fill: parent }   // klik di dalam panel jangan tutup

            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: 16
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: content
                    width: flick.width
                    spacing: 16

                    // ── judul sub-halaman ───────────────
                    Item {
                        visible: root.page !== "main"
                        width: parent.width
                        height: 32
                        IconButton {
                            id: backBtn
                            visible: !root.compact
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: root.ic(0xf0141)   // chevron-left
                            onClicked: root.page = "main"
                        }
                        Text {
                            anchors.left: root.compact ? parent.left : backBtn.right
                            anchors.leftMargin: root.compact ? 2 : 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.titles[root.page] || ""
                            color: root.cText
                            font { family: root.fUi; pixelSize: 16; weight: Font.DemiBold }
                        }
                        IconButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: root.ic(0xf0156)
                            onClicked: Qt.quit()
                        }
                    }

                    // ════════ HALAMAN UTAMA ════════════
                    Column {
                        visible: root.page === "main"
                        width: parent.width
                        spacing: 16

                        // header
                        Item {
                            width: parent.width
                            height: 44
                            Avatar {
                                id: avatar
                                size: 44
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.page = "profile"
                                }
                            }
                            Column {
                                anchors.left: avatar.right
                                anchors.leftMargin: 12
                                anchors.right: powerBtn.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                Text {
                                    text: "Halo, " + root.displayName
                                    color: root.cText
                                    elide: Text.ElideRight
                                    width: parent.width
                                    font { family: root.fUi; pixelSize: 15; weight: Font.DemiBold }
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    color: root.cMuted
                                    font { family: root.fUi; pixelSize: 12 }
                                    text: {
                                        const parts = [];
                                        if (root.battery >= 0) parts.push(root.ic(root.batStatus === "Charging" ? 0xf0084 : 0xf0079) + " " + root.battery + "%" + (root.batStatus === "Charging" ? " · mengisi" : ""));
                                        parts.push("nyala " + root.fmtUptime(root.uptimeSec));
                                        return parts.join("   ");
                                    }
                                }
                            }
                            IconButton {
                                id: powerBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                glyph: root.ic(0xf0425)
                                tint: root.powerOpen ? root.cUrgent : root.cMuted
                                filled: root.powerOpen
                                onClicked: { root.powerOpen = !root.powerOpen; root.powerConfirm = ""; }
                            }
                        }

                        // menu power
                        Row {
                            visible: root.powerOpen
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: [
                                    { id: "lock",     label: "Kunci",   cp: 0xf033e },
                                    { id: "suspend",  label: "Tidur",   cp: 0xf04b2 },
                                    { id: "logout",   label: "Keluar",  cp: 0xf0343 },
                                    { id: "reboot",   label: "Ulang",   cp: 0xf0709 },
                                    { id: "poweroff", label: "Matikan", cp: 0xf0425 }
                                ]
                                delegate: Rectangle {
                                    id: pb
                                    required property var modelData
                                    readonly property bool confirming: root.powerConfirm === modelData.id
                                    width: Math.floor((parent.width - 24) / 5)
                                    height: 62
                                    radius: 14
                                    color: confirming ? root.cUrgent : (pbMa.containsMouse ? root.cSurface2 : root.cSurface)
                                    border.color: confirming ? root.cUrgent : root.cBorder
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 4
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.ic(pb.modelData.cp)
                                            color: pb.confirming ? root.cOnAccent : root.cText
                                            font { family: root.fIcon; pixelSize: 18 }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: pb.confirming ? "Yakin?" : pb.modelData.label
                                            color: pb.confirming ? root.cOnAccent : root.cMuted
                                            font { family: root.fUi; pixelSize: 11; weight: pb.confirming ? Font.Bold : Font.Medium }
                                        }
                                    }
                                    MouseArea {
                                        id: pbMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.power(pb.modelData.id)
                                    }
                                }
                            }
                        }

                        // sedang diputar
                        Rectangle {
                            id: media
                            visible: root.player !== null
                            readonly property var p: root.player
                            width: parent.width
                            height: mediaCol.implicitHeight + 24
                            radius: 18
                            color: root.cSurface
                            border.color: root.cBorder

                            // posisi cuma di-refresh selama memang diputar & terlihat
                            Timer {
                                interval: 1000
                                repeat: true
                                running: media.visible && media.p && media.p.isPlaying
                                onTriggered: media.p.positionChanged()
                            }

                            Column {
                                id: mediaCol
                                x: 12; y: 12
                                width: parent.width - 24
                                spacing: 10

                                Row {
                                    width: parent.width
                                    spacing: 12
                                    ClippingRectangle {
                                        width: 64; height: 64
                                        radius: 12
                                        color: root.cSurface2
                                        Text {
                                            anchors.centerIn: parent
                                            visible: art.status !== Image.Ready
                                            text: root.ic(0xf075a)   // music note
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 24 }
                                        }
                                        Image {
                                            id: art
                                            anchors.fill: parent
                                            source: media.p ? media.p.trackArtUrl : ""
                                            sourceSize: Qt.size(128, 128)
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                        }
                                    }
                                    Column {
                                        width: parent.width - 76
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 3
                                        Row {
                                            spacing: 6
                                            Rectangle {
                                                height: 18
                                                width: srcText.implicitWidth + 14
                                                radius: 9
                                                color: root.tone(root.cAccent, 0.14)
                                                Text {
                                                    id: srcText
                                                    anchors.centerIn: parent
                                                    text: root.mediaSource(media.p)
                                                    color: root.cAccent
                                                    font { family: root.fUi; pixelSize: 10; weight: Font.DemiBold }
                                                }
                                            }
                                            // ganti pemutar kalau ada lebih dari satu
                                            Rectangle {
                                                visible: root.players.length > 1
                                                height: 18
                                                width: swText.implicitWidth + 14
                                                radius: 9
                                                color: swMa2.containsMouse ? root.cSurface2 : "transparent"
                                                border.color: root.cBorder
                                                Text {
                                                    id: swText
                                                    anchors.centerIn: parent
                                                    text: (root.players.indexOf(media.p) + 1) + "/" + root.players.length + "  " + root.ic(0xf04e1)
                                                    color: root.cMuted
                                                    font { family: root.fIcon; pixelSize: 10 }
                                                }
                                                MouseArea {
                                                    id: swMa2
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.playerPick = (root.players.indexOf(media.p) + 1) % root.players.length
                                                }
                                            }
                                        }
                                        Text {
                                            width: parent.width
                                            text: media.p ? (media.p.trackTitle || "Tanpa judul") : ""
                                            elide: Text.ElideRight
                                            color: root.cText
                                            font { family: root.fUi; pixelSize: 14; weight: Font.DemiBold }
                                        }
                                        Text {
                                            width: parent.width
                                            visible: text !== ""
                                            text: media.p ? (media.p.trackArtist || media.p.trackAlbum || "") : ""
                                            elide: Text.ElideRight
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 12 }
                                        }
                                    }
                                }

                                // progress (klik untuk loncat)
                                Item {
                                    visible: media.p && media.p.lengthSupported && media.p.length > 0
                                    width: parent.width
                                    height: 20
                                    Text {
                                        id: posText
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.mmss(media.p ? media.p.position : 0)
                                        color: root.cMuted
                                        font { family: root.fUi; pixelSize: 10 }
                                    }
                                    Text {
                                        id: lenText
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.mmss(media.p ? media.p.length : 0)
                                        color: root.cMuted
                                        font { family: root.fUi; pixelSize: 10 }
                                    }
                                    Rectangle {
                                        id: seekTrack
                                        anchors.left: posText.right
                                        anchors.right: lenText.left
                                        anchors.margins: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 4
                                        radius: 2
                                        color: root.cSurface2
                                        Rectangle {
                                            height: parent.height
                                            radius: 2
                                            color: root.cAccent
                                            width: media.p && media.p.length > 0 ? parent.width * Math.min(1, media.p.position / media.p.length) : 0
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -8
                                            enabled: media.p && media.p.canSeek
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: m => { media.p.position = media.p.length * Math.max(0, Math.min(1, (m.x - 8) / seekTrack.width)); }
                                        }
                                    }
                                }

                                // kontrol
                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 18
                                    IconButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        glyph: root.ic(0xf04ae)
                                        tint: media.p && media.p.canGoPrevious ? root.cText : root.cBorder
                                        onClicked: if (media.p && media.p.canGoPrevious) media.p.previous()
                                    }
                                    Rectangle {
                                        width: 42; height: 42; radius: 21
                                        color: playMa.containsMouse ? Qt.lighter(root.cAccent, 1.08) : root.cAccent
                                        Text {
                                            anchors.centerIn: parent
                                            text: root.ic(media.p && media.p.isPlaying ? 0xf03e4 : 0xf040a)
                                            color: root.cOnAccent
                                            font { family: root.fIcon; pixelSize: 20 }
                                        }
                                        MouseArea {
                                            id: playMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: if (media.p) media.p.togglePlaying()
                                        }
                                    }
                                    IconButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        glyph: root.ic(0xf04ad)
                                        tint: media.p && media.p.canGoNext ? root.cText : root.cBorder
                                        onClicked: if (media.p && media.p.canGoNext) media.p.next()
                                    }
                                }
                            }
                        }

                        // tile 2×3
                        Grid {
                            id: tiles
                            columns: 2
                            spacing: 10
                            width: parent.width
                            readonly property real tw: (width - 10) / 2

                            Tile {
                                width: tiles.tw
                                active: root.wifiOn
                                glyph: root.ic(root.wifiOn ? 0xf05a9 : 0xf05aa)
                                title: "Wi-Fi"
                                subtitle: !root.wifiOn ? "Mati" : (root.activeSsid || "Tidak terhubung")
                                hasMore: true
                                onClicked: root.toggleWifi()
                                onMoreClicked: root.page = "wifi"
                            }
                            Tile {
                                width: tiles.tw
                                active: root.btState === "on"
                                enabled: root.btState !== "none"
                                glyph: root.ic(root.btState === "on" ? 0xf00af : 0xf00b2)
                                title: "Bluetooth"
                                subtitle: root.btState === "none" ? "Tidak tersedia" : root.btState === "on" ? "Nyala" : "Mati"
                                onClicked: root.toggleBt()
                            }
                            Tile {
                                width: tiles.tw
                                active: root.ethState === "connected"
                                enabled: root.ethDev !== "" && root.ethState !== "unavailable"
                                glyph: root.ic(0xf0200)
                                title: "Ethernet"
                                subtitle: root.ethDev === "" ? "Tidak ada port" : root.ethState === "connected" ? "Terhubung"
                                        : root.ethState === "unavailable" ? "Kabel dicabut" : "Terputus"
                                onClicked: root.toggleEthernet()
                            }
                            Tile {
                                width: tiles.tw
                                active: root.dnd
                                glyph: root.ic(root.dnd ? 0xf009b : 0xf009a)
                                title: "Jangan Ganggu"
                                subtitle: root.dnd ? "Notifikasi senyap" : "Mati"
                                onClicked: root.toggleDnd()
                            }
                            Tile {
                                width: tiles.tw
                                active: root.nightOn
                                glyph: root.ic(0xf0594)
                                title: "Night Light"
                                subtitle: root.nightOn ? "Hangat 4000K" : "Mati"
                                onClicked: root.toggleNight()
                            }
                            Tile {
                                width: tiles.tw
                                active: root.caffeine
                                glyph: root.ic(0xf0176)
                                title: "Kafein"
                                subtitle: root.caffeine ? "Layar tetap nyala" : "Mati"
                                onClicked: root.toggleCaffeine()
                            }
                        }

                        // slider ringkas
                        Column {
                            width: parent.width
                            spacing: 10
                            SliderRow {
                                id: volRow
                                width: parent.width
                                glyph: root.volGlyph(root.volume, root.muted)
                                value: root.volume
                                dim: root.muted
                                onIconClicked: root.toggleMute()
                                onMoved: v => root.setVolume(v)
                                onMoreClicked: root.page = "volume"
                                Component.onCompleted: volSlider.target = volRow
                            }
                            SliderRow {
                                id: briRow
                                visible: root.hasBacklight
                                width: parent.width
                                glyph: root.ic(root.brightness < 0.34 ? 0xf00de : root.brightness < 0.67 ? 0xf00df : 0xf00e0)
                                value: root.brightness
                                onMoved: v => root.setBrightness(v)
                                onMoreClicked: root.page = "brightness"
                                Component.onCompleted: briSlider.target = briRow
                            }
                        }

                        // alat
                        Row {
                            width: parent.width
                            spacing: 8
                            Repeater {
                                model: [
                                    { label: "Screenshot", cp: 0xf0100, cmd: ["fr-shot", "region"] },
                                    { label: root.recording ? "Stop" : "Rekam", cp: 0xf044b, cmd: ["fr-rec", "toggle"], rec: true },
                                    { label: "Warna", cp: 0xf020a, cmd: ["fr-pick"] },
                                    { label: "Terminal", cp: 0xf018d, cmd: ["fr-scratch"] }
                                ]
                                delegate: Rectangle {
                                    id: tl
                                    required property var modelData
                                    readonly property bool hot: modelData.rec === true && root.recording
                                    width: (parent.width - 24) / 4
                                    height: 60
                                    radius: 14
                                    color: hot ? root.tone(root.cUrgent, 0.16) : (tlMa.containsMouse ? root.cSurface2 : root.cSurface)
                                    border.color: hot ? root.cUrgent : root.cBorder
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 4
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.ic(tl.modelData.cp)
                                            color: tl.hot ? root.cUrgent : root.cText
                                            font { family: root.fIcon; pixelSize: 18 }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: tl.modelData.label
                                            color: tl.hot ? root.cUrgent : root.cMuted
                                            font { family: root.fUi; pixelSize: 11; weight: Font.Medium }
                                        }
                                    }
                                    MouseArea {
                                        id: tlMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.tool(tl.modelData.cmd)
                                    }
                                }
                            }
                        }

                        // mode daya
                        Column {
                            width: parent.width
                            spacing: 8
                            SectionLabel { text: "Mode daya" }
                            ProfileSwitch { width: parent.width; visible: root.ppdAvailable }
                            Text {
                                visible: root.ppdAvailable
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: root.profile === "power-saver" ? "Animasi & shadow mati, layar maks 40%."
                                    : root.profile === "performance" ? "CPU boost penuh, semua efek nyala."
                                    : "Setelan normal."
                                color: root.cMuted
                                font { family: root.fUi; pixelSize: 11 }
                            }
                            SwitchRow {
                                visible: root.ppdAvailable
                                width: parent.width
                                glyph: root.ic(0xf06a5)   // power-plug
                                label: "Otomatis ikut charger"
                                sub: root.autoPower ? "Baterai → mode baterai, charger → mode charger" : "Ganti mode secara manual"
                                checked: root.autoPower
                                onToggled: root.toggleAutoPower()
                            }
                            Text {
                                visible: !root.ppdAvailable
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "power-profiles-daemon belum aktif:  sudo systemctl enable --now power-profiles-daemon"
                                color: root.cMuted
                                font { family: root.fUi; pixelSize: 12 }
                            }
                        }

                        // navigasi
                        Column {
                            width: parent.width
                            spacing: 6
                            NavRow {
                                visible: root.hasBattery
                                width: parent.width
                                glyph: root.ic(root.charging ? 0xf0084 : 0xf0079)
                                label: "Baterai"
                                value: root.batPct + "%" + (root.hoursLeft > 0 ? "  ·  " + root.fmtDur(root.hoursLeft) + (root.charging ? " sampai penuh" : " lagi") : "")
                                onClicked: root.page = "battery"
                            }
                            NavRow {
                                width: parent.width
                                glyph: root.ic(0xf0004)   // account
                                label: "Profil"
                                value: root.displayName
                                onClicked: root.page = "profile"
                            }
                            NavRow {
                                width: parent.width
                                glyph: root.ic(0xf02e9)
                                label: "Wallpaper"
                                value: root.lockFollows ? "Desktop & lock sama" : "Desktop & lock beda"
                                onClicked: root.page = "wallpaper"
                            }
                            NavRow {
                                width: parent.width
                                glyph: root.ic(0xf03d8)
                                label: "Tema"
                                value: { const t = root.themes.find(x => x.id === root.currentTheme); return t ? t.name : ""; }
                                onClicked: root.page = "theme"
                            }
                            NavRow {
                                width: parent.width
                                glyph: root.ic(0xf0379)
                                label: "Monitor"
                                value: ({ internal: "Laptop saja", extend: "Extend", external: "Monitor saja" })[root.monitorMode]
                                onClicked: root.page = "monitor"
                                Component.onCompleted: outProc.running = true
                            }
                        }
                    }

                    // ════════ WI-FI ════════════════════
                    Column {
                        visible: root.page === "wifi"
                        width: parent.width
                        spacing: 10

                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(root.wifiOn ? 0xf05a9 : 0xf05aa)
                            label: "Wi-Fi"
                            sub: !root.wifiOn ? "Mati" : (root.activeSsid ? "Terhubung ke " + root.activeSsid : "Tidak terhubung")
                            checked: root.wifiOn
                            onToggled: root.toggleWifi()
                        }

                        // sambung / bagikan lewat QR
                        Row {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: [
                                    { label: "Gambar", cp: 0xf02e9, act: "image" },
                                    { label: "Layar",  cp: 0xf019f, act: "screen" },
                                    { label: "Kamera", cp: 0xf0100, act: "cam" },
                                    { label: root.shareKind === "wifi" ? "Tutup" : "Bagikan", cp: 0xf0432, act: "share" }
                                ]
                                delegate: Rectangle {
                                    id: qb
                                    required property var modelData
                                    readonly property bool isShare: modelData.act === "share"
                                    readonly property bool can: !isShare || root.activeSsid !== ""
                                    readonly property bool on: isShare && root.shareKind === "wifi"
                                    width: (parent.width - 18) / 4
                                    height: 54
                                    radius: 12
                                    opacity: can ? 1 : 0.4
                                    color: on ? root.cSurface2 : (qbMa.containsMouse && can ? root.cSurface2 : root.cSurface)
                                    border.color: on ? root.cAccent : root.cBorder
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 3
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.ic(qb.modelData.cp)
                                            color: qb.on ? root.cAccent : root.cText
                                            font { family: root.fIcon; pixelSize: 16 }
                                            RotationAnimation on rotation {
                                                running: qb.isShare && root.shareBusy && root.shareKind === "wifi"; loops: Animation.Infinite; from: 0; to: 360; duration: 900
                                            }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: qb.modelData.label
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 11 }
                                        }
                                    }
                                    MouseArea {
                                        id: qbMa
                                        anchors.fill: parent
                                        enabled: qb.can
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: qb.isShare ? root.shareWifi() : root.tool(["fr-wifiqr", qb.modelData.act])
                                    }
                                }
                            }
                        }
                        Text {
                            visible: root.shareErr !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: root.shareErr
                            color: root.cUrgent
                            font { family: root.fUi; pixelSize: 12 }
                        }
                        // QR untuk di-scan HP: hitam di atas putih supaya pasti terbaca
                        Rectangle {
                            visible: root.shareQr !== null
                            width: parent.width
                            height: shareCol.implicitHeight + 28
                            radius: 18
                            color: "#FFFFFF"
                            Column {
                                id: shareCol
                                anchors.centerIn: parent
                                spacing: 10
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 220; height: 220
                                    source: root.shareQr ? "file://" + root.shareQr.png : ""
                                    smooth: false            // tepi modul QR tetap tajam
                                    cache: false
                                    fillMode: Image.PreserveAspectFit
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.shareQr ? root.shareQr.ssid : ""
                                    color: "#0B0F17"
                                    font { family: root.fUi; pixelSize: 15; weight: Font.Bold }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.shareKind === "hotspot" ? "Scan untuk pakai hotspot laptop" : "Scan pakai kamera HP untuk tersambung"
                                    color: "#5A6478"
                                    font { family: root.fUi; pixelSize: 11 }
                                }
                            }
                        }

                        // ── hotspot ──
                        SectionLabel { text: "Hotspot" }
                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(root.hs.on ? 0xf0002 : 0xf0003)
                            label: root.hs.on ? root.hs.ssid : "Bagikan internet"
                            sub: root.hsBusy ? (root.hs.on ? "Mematikan…" : "Menyalakan…")
                                : root.hs.on ? root.hs.clients.length + " perangkat  ·  via " + ((root.hs.upstream || "laptop").replace(/^Wi-Fi /, ""))
                                : !root.hs.can ? "Belum bisa dinyalakan"
                                : root.hs.upstream ? "Dari " + root.hs.upstream.replace(/^Wi-Fi /, "") + " ke HP"
                                : "Tanpa internet — sambungkan Wi-Fi/LAN dulu"
                            checked: root.hs.on
                            enabled: !root.hsBusy && (root.hs.on || root.hs.can)
                            onToggled: root.hsRun([root.hs.on ? "off" : "on"])
                        }
                        Text {
                            visible: (!root.hs.on && !root.hs.can && root.hs.reason !== "") || root.hsErr !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: root.hsErr !== "" ? root.hsErr : root.hs.reason
                            color: root.hsErr !== "" ? root.cUrgent : root.cWarn
                            font { family: root.fUi; pixelSize: 11 }
                        }
                        Rectangle {
                            visible: root.hs.on || root.hsEdit || (root.hs.can && root.hs.exists === true)
                            width: parent.width
                            height: hsCol.implicitHeight + 24
                            radius: 14
                            color: root.cSurface
                            border.color: root.cBorder
                            Column {
                                id: hsCol
                                x: 12; y: 12
                                width: parent.width - 24
                                spacing: 10

                                // nama + password
                                Item {
                                    visible: !root.hsEdit
                                    width: parent.width
                                    height: 38
                                    Column {
                                        anchors.left: parent.left
                                        anchors.right: hsBtns.left
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Text {
                                            text: "Password"
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 11 }
                                        }
                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: root.hsShowPass ? root.hs.password : "•".repeat(Math.max(8, root.hs.password.length))
                                            color: root.cText
                                            font { family: root.hsShowPass ? root.fIcon : root.fUi; pixelSize: 14; weight: Font.DemiBold }
                                        }
                                    }
                                    Row {
                                        id: hsBtns
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        IconButton { small: true; glyph: root.ic(root.hsShowPass ? 0xf0209 : 0xf0208); onClicked: root.hsShowPass = !root.hsShowPass }
                                        IconButton { small: true; glyph: root.ic(0xf03eb); onClicked: { root.hsEdit = true; hsSsidIn.text = root.hs.ssid; hsPassIn.text = root.hs.password; } }
                                        IconButton {
                                            small: true
                                            enabled: root.hs.on
                                            opacity: enabled ? 1 : 0.35
                                            glyph: root.ic(0xf0432)
                                            tint: root.shareKind === "hotspot" ? root.cAccent : root.cMuted
                                            spinning: root.shareBusy && root.shareKind === "hotspot"
                                            onClicked: root.shareHotspot()
                                        }
                                    }
                                }

                                // ubah nama / password
                                Column {
                                    visible: root.hsEdit
                                    width: parent.width
                                    spacing: 8
                                    Rectangle {
                                        width: parent.width
                                        height: 46
                                        radius: 10
                                        color: root.cBg
                                        border.color: hsSsidIn.activeFocus ? root.cAccent : root.cBorder
                                        Text {
                                            x: 12; y: 6
                                            text: "Nama hotspot"
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 10 }
                                        }
                                        TextInput {
                                            id: hsSsidIn
                                            x: 12; y: 22
                                            width: parent.width - 24
                                            maximumLength: 32
                                            color: root.cText
                                            selectionColor: root.cAccent
                                            clip: true
                                            font { family: root.fUi; pixelSize: 13 }
                                            Keys.onReturnPressed: root.hsSave(hsSsidIn.text, hsPassIn.text)
                                            Keys.onEscapePressed: root.hsEdit = false
                                        }
                                    }
                                    Rectangle {
                                        width: parent.width
                                        height: 46
                                        radius: 10
                                        color: root.cBg
                                        border.color: hsPassIn.activeFocus ? root.cAccent : root.cBorder
                                        Text {
                                            x: 12; y: 6
                                            text: "Password (minimal 8 karakter)"
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 10 }
                                        }
                                        TextInput {
                                            id: hsPassIn
                                            x: 12; y: 22
                                            width: parent.width - 24
                                            maximumLength: 63
                                            color: root.cText
                                            selectionColor: root.cAccent
                                            clip: true
                                            font { family: root.fUi; pixelSize: 13 }
                                            Keys.onReturnPressed: root.hsSave(hsSsidIn.text, hsPassIn.text)
                                            Keys.onEscapePressed: root.hsEdit = false
                                        }
                                    }
                                    Row {
                                        anchors.right: parent.right
                                        spacing: 6
                                        Rectangle {
                                            width: 70; height: 30; radius: 9
                                            color: hsCancelMa.containsMouse ? root.cSurface2 : "transparent"
                                            Text { anchors.centerIn: parent; text: "Batal"; color: root.cMuted; font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold } }
                                            MouseArea { id: hsCancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.hsEdit = false; root.hsErr = ""; } }
                                        }
                                        Rectangle {
                                            width: 70; height: 30; radius: 9
                                            color: root.cAccent
                                            Text { anchors.centerIn: parent; text: root.hsBusy ? "…" : "Simpan"; color: root.cOnAccent; font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold } }
                                            MouseArea { anchors.fill: parent; enabled: !root.hsBusy; cursorShape: Qt.PointingHandCursor; onClicked: root.hsSave(hsSsidIn.text, hsPassIn.text) }
                                        }
                                    }
                                }

                                Rectangle { visible: root.hs.on; width: parent.width; height: 1; color: root.cBorder }

                                // perangkat tersambung
                                Text {
                                    visible: root.hs.on
                                    text: root.hs.clients.length ? "Perangkat tersambung" : "Belum ada perangkat — scan QR dari HP"
                                    color: root.cMuted
                                    font { family: root.fUi; pixelSize: 11 }
                                }
                                Repeater {
                                    model: root.hs.on ? root.hs.clients : []
                                    delegate: Item {
                                        id: cl
                                        required property var modelData
                                        width: hsCol.width
                                        height: 22
                                        Text {
                                            id: clIc
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.ic(0xf011c)
                                            color: root.cAccent
                                            font { family: root.fIcon; pixelSize: 14 }
                                        }
                                        Text {
                                            anchors.left: clIc.right
                                            anchors.leftMargin: 10
                                            anchors.right: clIp.left
                                            anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: cl.modelData.name
                                            elide: Text.ElideRight
                                            color: root.cText
                                            font { family: root.fUi; pixelSize: 12 }
                                        }
                                        Text {
                                            id: clIp
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: cl.modelData.ip || "menyambung…"
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 11 }
                                        }
                                    }
                                }
                                Text {
                                    visible: root.hs.on && (root.hs.tx + root.hs.rx) > 0
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: "Data   " + root.ic(0xf0045) + " " + root.fmtBytes(root.hs.tx) + "   " + root.ic(0xf005d) + " " + root.fmtBytes(root.hs.rx)
                                    color: root.cMuted
                                    font { family: root.fIcon; pixelSize: 11 }
                                }
                            }
                        }

                        Item {
                            visible: root.wifiOn
                            width: parent.width
                            height: 26
                            SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: "Jaringan terdekat" }
                            IconButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                small: true
                                glyph: root.ic(0xf0450)
                                spinning: root.scanning
                                onClicked: root.scan()
                            }
                        }

                        Text {
                            visible: root.netError !== ""
                            width: parent.width
                            text: root.netError
                            color: root.cUrgent
                            wrapMode: Text.Wrap
                            font { family: root.fUi; pixelSize: 12 }
                        }
                        Text {
                            visible: root.wifiOn && root.networks.length === 0
                            text: root.scanning ? "Mencari jaringan…" : "Tidak ada jaringan"
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }

                        Column {
                            visible: root.wifiOn
                            width: parent.width
                            spacing: 4
                            Repeater {
                                model: root.networks
                                delegate: Column {
                                    id: nr
                                    required property var modelData
                                    readonly property bool asking: root.pendingSsid === modelData.ssid
                                    readonly property bool busy: root.busySsid === modelData.ssid
                                    width: parent.width
                                    spacing: 6

                                    Rectangle {
                                        width: parent.width
                                        height: 46
                                        radius: 12
                                        color: nr.modelData.active ? root.cSurface2 : (rowMa.containsMouse ? root.cSurface : "transparent")
                                        border.color: nr.modelData.active ? root.tone(root.cAccent, 0.35) : "transparent"
                                        Text {
                                            id: sig
                                            anchors.left: parent.left
                                            anchors.leftMargin: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.ic([0xf091f, 0xf0922, 0xf0925, 0xf0928][Math.min(3, Math.floor(nr.modelData.signal / 25))])
                                            color: nr.modelData.active ? root.cAccent : root.cText
                                            font { family: root.fIcon; pixelSize: 16 }
                                        }
                                        Column {
                                            anchors.left: sig.right
                                            anchors.leftMargin: 12
                                            anchors.right: lock.left
                                            anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text {
                                                width: parent.width
                                                text: nr.modelData.ssid
                                                elide: Text.ElideRight
                                                color: root.cText
                                                font { family: root.fUi; pixelSize: 13; weight: nr.modelData.active ? Font.DemiBold : Font.Normal }
                                            }
                                            Text {
                                                visible: nr.modelData.active || nr.busy || nr.modelData.saved
                                                text: nr.busy ? "Menghubungkan…" : nr.modelData.active ? "Terhubung · klik untuk putus" : "Tersimpan"
                                                color: nr.modelData.active ? root.cAccent : root.cMuted
                                                font { family: root.fUi; pixelSize: 11 }
                                            }
                                        }
                                        Text {
                                            id: lock
                                            anchors.right: parent.right
                                            anchors.rightMargin: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: nr.modelData.secure ? root.ic(0xf033e) : ""
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 13 }
                                        }
                                        MouseArea {
                                            id: rowMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.clickNetwork(nr.modelData)
                                        }
                                    }

                                    Rectangle {
                                        visible: nr.asking
                                        width: parent.width
                                        height: 42
                                        radius: 12
                                        color: root.cSurface
                                        border.color: pw.activeFocus ? root.cAccent : root.cBorder
                                        TextInput {
                                            id: pw
                                            anchors.left: parent.left
                                            anchors.right: goBtn.left
                                            anchors.leftMargin: 12
                                            anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            echoMode: TextInput.Password
                                            color: root.cText
                                            font { family: root.fUi; pixelSize: 13 }
                                            clip: true
                                            onVisibleChanged: if (visible) { text = ""; forceActiveFocus(); }
                                            onAccepted: root.connectWithPassword(nr.modelData.ssid, text)
                                            Keys.onEscapePressed: root.pendingSsid = ""
                                            Text {
                                                anchors.fill: parent
                                                verticalAlignment: Text.AlignVCenter
                                                visible: pw.text.length === 0
                                                text: "Password"
                                                color: root.cMuted
                                                font: pw.font
                                            }
                                        }
                                        Rectangle {
                                            id: goBtn
                                            width: 72; height: 30; radius: 9
                                            anchors.right: parent.right
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: root.cAccent
                                            Text {
                                                anchors.centerIn: parent
                                                text: "Sambung"
                                                color: root.cOnAccent
                                                font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.connectWithPassword(nr.modelData.ssid, pw.text)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: root.cBorder }

                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(0xf0200)
                            label: "Ethernet"
                            sub: root.ethDev === "" ? "Tidak ada port" : root.ethState === "connected" ? "Terhubung (" + root.ethDev + ")"
                               : root.ethState === "unavailable" ? "Kabel dicabut" : "Terputus"
                            checked: root.ethState === "connected"
                            enabled: root.ethDev !== "" && root.ethState !== "unavailable"
                            onToggled: root.toggleEthernet()
                        }

                        NavRow {
                            width: parent.width
                            glyph: root.ic(0xf0493)
                            label: "Pengaturan jaringan lanjutan"
                            onClicked: { root.exec(["nm-connection-editor"]); Qt.quit(); }
                        }
                    }

                    // ════════ SUARA ════════════════════
                    Column {
                        visible: root.page === "volume"
                        width: parent.width
                        spacing: 12

                        SectionLabel { text: "Output" }
                        SliderRow {
                            id: volRowBig
                            width: parent.width
                            big: true
                            glyph: root.volGlyph(root.volume, root.muted)
                            value: root.volume
                            dim: root.muted
                            showMore: false
                            onIconClicked: root.toggleMute()
                            onMoved: v => root.setVolume(v)
                            Component.onCompleted: volSliderBig.target = volRowBig
                        }

                        SectionLabel { text: "Mikrofon" }
                        SliderRow {
                            id: micRow
                            width: parent.width
                            big: true
                            glyph: root.ic(root.micMuted ? 0xf036d : 0xf036c)
                            value: root.micVolume
                            dim: root.micMuted
                            showMore: false
                            onIconClicked: root.toggleMicMute()
                            onMoved: v => root.setMic(v)
                            Component.onCompleted: micSlider.target = micRow
                        }

                        SectionLabel { text: "Perangkat output"; visible: root.sinks.length > 0 }
                        Column {
                            width: parent.width
                            spacing: 4
                            Repeater {
                                model: root.sinks
                                delegate: Rectangle {
                                    id: sk
                                    required property var modelData
                                    readonly property bool cur: root.defaultSink === modelData.name
                                    width: parent.width
                                    height: 42
                                    radius: 12
                                    color: cur ? root.cSurface2 : (skMa.containsMouse ? root.cSurface : "transparent")
                                    Text {
                                        id: skDot
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.ic(sk.cur ? 0xf043e : 0xf043d)   // radiobox
                                        color: sk.cur ? root.cAccent : root.cMuted
                                        font { family: root.fIcon; pixelSize: 15 }
                                    }
                                    Text {
                                        anchors.left: skDot.right
                                        anchors.leftMargin: 10
                                        anchors.right: parent.right
                                        anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: sk.modelData.desc
                                        elide: Text.ElideRight
                                        color: root.cText
                                        font { family: root.fUi; pixelSize: 13; weight: sk.cur ? Font.DemiBold : Font.Normal }
                                    }
                                    MouseArea {
                                        id: skMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setSink(sk.modelData.name)
                                    }
                                }
                            }
                        }

                        NavRow {
                            width: parent.width
                            glyph: root.ic(0xf0493)
                            label: "Mixer lengkap (pavucontrol)"
                            onClicked: { root.exec(["pavucontrol"]); Qt.quit(); }
                        }
                    }

                    // ════════ LAYAR ════════════════════
                    Column {
                        visible: root.page === "brightness"
                        width: parent.width
                        spacing: 12

                        Text {
                            visible: !root.hasBacklight
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Backlight tidak terdeteksi (brightnessctl)."
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }
                        SliderRow {
                            id: briRowBig
                            visible: root.hasBacklight
                            width: parent.width
                            big: true
                            glyph: root.ic(root.brightness < 0.34 ? 0xf00de : root.brightness < 0.67 ? 0xf00df : 0xf00e0)
                            value: root.brightness
                            showMore: false
                            onMoved: v => root.setBrightness(v)
                            Component.onCompleted: briSliderBig.target = briRowBig
                        }
                        Row {
                            visible: root.hasBacklight
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: [10, 30, 60, 100]
                                delegate: Rectangle {
                                    id: preset
                                    required property int modelData
                                    readonly property bool cur: Math.abs(root.brightness * 100 - modelData) < 3
                                    width: (parent.width - 18) / 4
                                    height: 34
                                    radius: 10
                                    color: cur ? root.cSurface2 : (prMa.containsMouse ? root.cSurface : "transparent")
                                    border.color: cur ? root.tone(root.cAccent, 0.55) : root.cBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: preset.modelData + "%"
                                        color: preset.cur ? root.cText : root.cMuted
                                        font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                    }
                                    MouseArea {
                                        id: prMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setBrightness(preset.modelData / 100)
                                    }
                                }
                            }
                        }
                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(0xf0594)
                            label: "Night Light"
                            sub: root.nightOn ? "Warna hangat ±4000K" : "Kurangi cahaya biru di malam hari"
                            checked: root.nightOn
                            onToggled: root.toggleNight()
                        }
                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(0xf0176)
                            label: "Kafein"
                            sub: root.caffeine ? "Layar nggak akan redup / lock" : "Layar redup & lock otomatis"
                            checked: root.caffeine
                            onToggled: root.toggleCaffeine()
                        }
                    }

                    // ════════ WALLPAPER ════════════════
                    Loader {
                        active: root.page === "wallpaper"
                        visible: active
                        width: parent.width
                        sourceComponent: Column {
                            width: parent ? parent.width : 0
                            spacing: 12

                            // tab Desktop / Lockscreen
                            Rectangle {
                                width: parent.width
                                height: 40
                                radius: 12
                                color: root.cSurface
                                border.color: root.cBorder
                                Row {
                                    anchors.fill: parent
                                    anchors.margins: 4
                                    Repeater {
                                        model: [
                                            { id: "desktop", label: "Desktop",    cp: 0xf0379 },
                                            { id: "lock",    label: "Lockscreen", cp: 0xf033e }
                                        ]
                                        delegate: Rectangle {
                                            id: tab
                                            required property var modelData
                                            readonly property bool sel: root.wallTab === modelData.id
                                            width: parent.width / 2
                                            height: parent.height
                                            radius: 9
                                            color: sel ? root.cSurface2 : "transparent"
                                            border.color: sel ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                                            Row {
                                                anchors.centerIn: parent
                                                spacing: 7
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: root.ic(tab.modelData.cp)
                                                    color: tab.sel ? root.cAccent : root.cMuted
                                                    font { family: root.fIcon; pixelSize: 14 }
                                                }
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: tab.modelData.label
                                                    color: tab.sel ? root.cText : root.cMuted
                                                    font { family: root.fUi; pixelSize: 13; weight: tab.sel ? Font.DemiBold : Font.Medium }
                                                }
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.wallTab = tab.modelData.id
                                            }
                                        }
                                    }
                                }
                            }

                            // gaya lockscreen
                            Column {
                                visible: root.wallTab === "lock"
                                width: parent.width
                                spacing: 8
                                SectionLabel { text: "Gaya" }
                                Row {
                                    width: parent.width
                                    spacing: 8
                                    Repeater {
                                        model: [
                                            { id: "editorial", label: "Editorial", desc: "jam di kiri bawah" },
                                            { id: "center",    label: "Tengah",    desc: "semua di tengah" }
                                        ].concat(root.hasCustomLock ? [{ id: "custom", label: "Custom", desc: "file milikmu" }] : [])
                                        delegate: Rectangle {
                                            id: ls
                                            required property var modelData
                                            readonly property bool sel: root.lockStyle === modelData.id
                                            width: (parent.width - 8 * (root.hasCustomLock ? 2 : 1)) / (root.hasCustomLock ? 3 : 2)
                                            height: 58
                                            radius: 12
                                            color: sel ? root.cSurface2 : (lsMa.containsMouse ? root.cSurface : "transparent")
                                            border.width: sel ? 2 : 1
                                            border.color: sel ? root.cAccent : root.cBorder
                                            Column {
                                                anchors.centerIn: parent
                                                spacing: 2
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: ls.modelData.label
                                                    color: ls.sel ? root.cText : root.cMuted
                                                    font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
                                                }
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: ls.modelData.desc
                                                    color: root.cMuted
                                                    font { family: root.fUi; pixelSize: 11 }
                                                }
                                            }
                                            MouseArea {
                                                id: lsMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.setLockStyle(ls.modelData.id)
                                            }
                                        }
                                    }
                                }
                            }

                            SwitchRow {
                                visible: root.wallTab === "lock"
                                width: parent.width
                                glyph: root.ic(0xf0337)   // link
                                label: "Ikuti wallpaper desktop"
                                sub: root.lockFollows ? "Lockscreen = desktop" : "Pakai gambar sendiri"
                                checked: root.lockFollows
                                onToggled: root.setLockFollow(!root.lockFollows)
                            }

                            FolderListModel {
                                id: walls
                                folder: "file://" + root.wallDir
                                nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.webp"]
                                showDirs: false
                                sortField: FolderListModel.Time
                            }
                            Text {
                                visible: walls.count === 0
                                text: "Belum ada gambar di ~/Pictures/Wallpaper"
                                color: root.cMuted
                                font { family: root.fUi; pixelSize: 12 }
                            }
                            Grid {
                                id: wallGrid
                                columns: 2
                                spacing: 8
                                width: parent.width
                                opacity: root.wallTab === "lock" && root.lockFollows ? 0.45 : 1
                                Behavior on opacity { NumberAnimation { duration: 140 } }
                                Repeater {
                                    model: walls
                                    delegate: Item {
                                        id: wt
                                        required property string filePath
                                        readonly property bool cur: filePath === (root.wallTab === "desktop" ? root.currentWall : root.lockWall)
                                        width: (wallGrid.width - 8) / 2
                                        height: width * 0.6

                                        ClippingRectangle {
                                            anchors.fill: parent
                                            radius: 12
                                            color: root.cSurface
                                            Image {
                                                // thumbnail kecil kalau sudah ada; kalau belum, file asli
                                                property bool fallback: false
                                                anchors.fill: parent
                                                source: "file://" + (fallback ? wt.filePath : root.thumbOf(wt.filePath))
                                                onStatusChanged: if (status === Image.Error && !fallback) fallback = true
                                                sourceSize: Qt.size(360, 216)
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                scale: thumbMa.containsMouse ? 1.06 : 1
                                                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                            }
                                            // overlay jam kecil di tab lockscreen, biar kebayang hasilnya
                                            Rectangle {
                                                visible: root.wallTab === "lock"
                                                anchors.fill: parent
                                                color: root.tone(root.cBg, 0.35)
                                                Text {
                                                    anchors.centerIn: parent
                                                    anchors.verticalCenterOffset: -6
                                                    text: Qt.formatTime(new Date(), "HH:mm")
                                                    color: "white"
                                                    font { family: root.fUi; pixelSize: 22; weight: Font.Bold }
                                                }
                                                Rectangle {
                                                    width: parent.width * 0.42; height: 7; radius: 4
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    anchors.bottom: parent.bottom
                                                    anchors.bottomMargin: parent.height * 0.18
                                                    color: Qt.rgba(1, 1, 1, 0.25)
                                                }
                                            }
                                        }
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 12
                                            color: "transparent"
                                            border.width: wt.cur ? 2 : 1
                                            border.color: wt.cur ? root.cAccent : Qt.rgba(1, 1, 1, 0.08)
                                        }
                                        Rectangle {
                                            visible: wt.cur
                                            width: 22; height: 22; radius: 11
                                            anchors { right: parent.right; top: parent.top; margins: 7 }
                                            color: root.cAccent
                                            Text {
                                                anchors.centerIn: parent
                                                text: root.ic(0xf012c)
                                                color: root.cOnAccent
                                                font { family: root.fIcon; pixelSize: 13 }
                                            }
                                        }
                                        MouseArea {
                                            id: thumbMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.wallTab === "desktop" ? root.setWallpaper(wt.filePath) : root.setLockWallpaper(wt.filePath)
                                        }
                                    }
                                }
                            }
                            NavRow {
                                visible: root.wallTab === "lock"
                                width: parent.width
                                glyph: root.ic(0xf0208)   // eye
                                label: "Coba kunci layar sekarang"
                                onClicked: root.previewLock()
                            }
                            NavRow {
                                width: parent.width
                                glyph: root.ic(0xf024b)
                                label: "Buka folder wallpaper"
                                onClicked: { root.exec(["xdg-open", root.wallDir]); Qt.quit(); }
                            }
                        }
                    }

                    // ════════ KALENDER & CUACA ═════════
                    Column {
                        visible: root.page === "calendar"
                        width: parent.width
                        spacing: 14

                        // hari ini
                        Column {
                            spacing: 2
                            Text {
                                text: root.dayNames[root.today.getDay()]
                                color: root.cAccent
                                font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
                            }
                            Text {
                                text: root.today.getDate() + " " + root.monthNames[root.today.getMonth()] + " " + root.today.getFullYear()
                                color: root.cText
                                font { family: root.fUi; pixelSize: 22; weight: Font.Bold }
                            }
                        }

                        // cuaca
                        Rectangle {
                            width: parent.width
                            height: wCol.implicitHeight + 24
                            radius: 16
                            color: root.cSurface
                            border.color: root.cBorder
                            readonly property var cur: root.weather ? root.weather.current_condition[0] : null
                            id: wCard
                            Column {
                                id: wCol
                                x: 14; y: 12
                                width: parent.width - 28
                                spacing: 12
                                Text {
                                    visible: !wCard.cur
                                    text: root.weatherLoading ? "Mengambil cuaca…" : "Cuaca tidak tersedia (offline?)"
                                    color: root.cMuted
                                    font { family: root.fUi; pixelSize: 12 }
                                }
                                Item {
                                    visible: !!wCard.cur
                                    width: parent.width
                                    height: 60
                                    Text {
                                        id: wBig
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: wCard.cur ? root.wIcon(wCard.cur.weatherCode, root.today.getHours() < 6 || root.today.getHours() >= 18) : ""
                                        color: root.cWarn
                                        font { family: root.fIcon; pixelSize: 44 }
                                    }
                                    Column {
                                        anchors.left: wBig.right
                                        anchors.leftMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        Text {
                                            text: wCard.cur ? wCard.cur.temp_C + "°" : ""
                                            color: root.cText
                                            font { family: root.fUi; pixelSize: 30; weight: Font.Bold }
                                        }
                                        Text {
                                            text: root.wDesc(wCard.cur)
                                            color: root.cMuted
                                            font { family: root.fUi; pixelSize: 12 }
                                        }
                                    }
                                    Column {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 3
                                        Text {
                                            anchors.right: parent.right
                                            text: root.ic(0xf034e) + " " + (root.weather && root.weather.nearest_area ? root.weather.nearest_area[0].areaName[0].value : "")
                                            color: root.cText
                                            font { family: root.fIcon; pixelSize: 11 }
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            text: wCard.cur ? "terasa " + wCard.cur.FeelsLikeC + "°  " + root.ic(0xf058e) + " " + wCard.cur.humidity + "%" : ""
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 11 }
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            text: wCard.cur ? root.ic(0xf059d) + " " + wCard.cur.windspeedKmph + " km/j" : ""
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 11 }
                                        }
                                    }
                                }
                                // 3 hari
                                Row {
                                    visible: !!(root.weather && root.weather.weather)
                                    width: parent.width
                                    spacing: 8
                                    Repeater {
                                        model: root.weather && root.weather.weather ? root.weather.weather.slice(0, 3) : []
                                        delegate: Rectangle {
                                            id: fd
                                            required property var modelData
                                            required property int index
                                            width: (parent.width - 16) / 3
                                            height: 74
                                            radius: 12
                                            color: root.cSurface2
                                            Column {
                                                anchors.centerIn: parent
                                                spacing: 3
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: fd.index === 0 ? "Hari ini" : fd.index === 1 ? "Besok"
                                                        : root.dayNames[new Date(fd.modelData.date + "T12:00:00").getDay()]
                                                    color: root.cMuted
                                                    font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold }
                                                }
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: root.wIcon(fd.modelData.hourly && fd.modelData.hourly[4] ? fd.modelData.hourly[4].weatherCode : 113, false)
                                                    color: root.cWarn
                                                    font { family: root.fIcon; pixelSize: 20 }
                                                }
                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: fd.modelData.maxtempC + "° / " + fd.modelData.mintempC + "°"
                                                    color: root.cText
                                                    font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            IconButton {
                                anchors { right: parent.right; top: parent.top; margins: 6 }
                                small: true
                                visible: !wCard.cur
                                glyph: root.ic(0xf0450)
                                spinning: root.weatherLoading
                                onClicked: root.loadWeather(true)
                            }
                        }

                        // kalender bulan
                        Item {
                            width: parent.width
                            height: 30
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.monthNames[root.calMonth] + " " + root.calYear
                                color: root.cText
                                font { family: root.fUi; pixelSize: 15; weight: Font.DemiBold }
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                IconButton { small: true; glyph: root.ic(0xf0141); onClicked: root.shiftMonth(-1) }
                                Rectangle {
                                    visible: root.calMonth !== root.today.getMonth() || root.calYear !== root.today.getFullYear()
                                    width: todayTxt.implicitWidth + 16; height: 28; radius: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: tdMa.containsMouse ? root.cSurface2 : "transparent"
                                    border.color: root.cBorder
                                    Text { id: todayTxt; anchors.centerIn: parent; text: "Hari ini"; color: root.cAccent; font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold } }
                                    MouseArea {
                                        id: tdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.calYear = root.today.getFullYear(); root.calMonth = root.today.getMonth(); }
                                    }
                                }
                                IconButton { small: true; glyph: root.ic(0xf0142); onClicked: root.shiftMonth(1) }
                            }
                        }
                        Grid {
                            id: calGrid
                            columns: 7
                            width: parent.width
                            readonly property real cw: width / 7
                            Repeater {
                                model: ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"]
                                delegate: Item {
                                    required property string modelData
                                    required property int index
                                    width: calGrid.cw; height: 24
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.modelData
                                        color: parent.index === 6 ? root.cUrgent : root.cMuted
                                        font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold }
                                    }
                                }
                            }
                            Repeater {
                                model: root.calCells
                                delegate: Item {
                                    id: cell
                                    required property var modelData
                                    width: calGrid.cw; height: 36
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 32; height: 32; radius: 16
                                        visible: cell.modelData.today
                                        color: root.cAccent
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: cell.modelData.day
                                        opacity: cell.modelData.inMonth ? 1 : 0.32
                                        color: cell.modelData.today ? root.cOnAccent : cell.modelData.sunday ? root.cUrgent : root.cText
                                        font { family: root.fUi; pixelSize: 13; weight: cell.modelData.today ? Font.Bold : Font.Normal }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            width: parent.width; height: 1; color: root.cBorder
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Kota cuaca bisa diatur di ~/.config/fr-profile/city (kosong = otomatis dari IP)."
                            color: root.tone(root.cMuted, 0.8)
                            font { family: root.fUi; pixelSize: 10 }
                        }
                    }

                    // ════════ BATERAI ══════════════════
                    Column {
                        visible: root.page === "battery"
                        width: parent.width
                        spacing: 14

                        Text {
                            visible: !root.hasBattery
                            text: "Baterai tidak terdeteksi."
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }

                        // gauge + estimasi
                        Row {
                            visible: root.hasBattery
                            width: parent.width
                            spacing: 18
                            Item {
                                width: 132; height: 132
                                Canvas {
                                    id: gauge
                                    anchors.fill: parent
                                    antialiasing: true
                                    property real v: root.batPct / 100
                                    property color c: root.batColor(root.batPct)
                                    onVChanged: requestPaint()
                                    onCChanged: requestPaint()
                                    onPaint: {
                                        const ctx = getContext("2d"); ctx.reset();
                                        const cx = width / 2, r = width / 2 - 8;
                                        const a0 = Math.PI * 0.75, span = Math.PI * 1.5;
                                        ctx.lineCap = "round"; ctx.lineWidth = 11;
                                        ctx.strokeStyle = root.cSurface2;
                                        ctx.beginPath(); ctx.arc(cx, cx, r, a0, a0 + span); ctx.stroke();
                                        if (v > 0) {
                                            ctx.strokeStyle = c;
                                            ctx.beginPath(); ctx.arc(cx, cx, r, a0, a0 + span * Math.max(0.01, v)); ctx.stroke();
                                        }
                                    }
                                }
                                Column {
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: 4
                                    spacing: 0
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.batPct + "%"
                                        color: root.cText
                                        font { family: root.fUi; pixelSize: 30; weight: Font.Bold }
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.ic(root.charging ? 0xf0084 : 0xf0079) + "  " +
                                              ({ Charging: "Mengisi", Discharging: "Dipakai", Full: "Penuh", "Not charging": "Ditahan" })[root.batState] || root.batState
                                        color: root.batColor(root.batPct)
                                        font { family: root.fIcon; pixelSize: 11 }
                                    }
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 150
                                spacing: 4
                                Text {
                                    text: root.charging ? "Penuh dalam" : root.batState === "Discharging" ? "Sisa waktu" : "Status"
                                    color: root.cMuted
                                    font { family: root.fUi; pixelSize: 12 }
                                }
                                Text {
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    text: root.hoursLeft > 0 ? root.fmtDur(root.hoursLeft)
                                        : (root.batState === "Full" || root.batState === "Not charging") && root.chargeLimit > 0 && root.chargeLimit < 100 && root.batPct >= root.chargeLimit - 1 ? "Ditahan di " + root.chargeLimit + "%"
                                        : root.batState === "Full" ? "Sudah penuh"
                                        : root.batState === "Not charging" ? "Charger terpasang, tidak mengisi"
                                        : "Menghitung…"
                                    color: root.cText
                                    font { family: root.fUi; pixelSize: 20; weight: Font.Bold }
                                }
                                Text {
                                    visible: root.hoursLeft > 0
                                    text: (root.charging ? "penuh sekitar pukul " : "habis sekitar pukul ") +
                                          Qt.formatTime(new Date(Date.now() + root.hoursLeft * 3600000), "HH:mm")
                                    color: root.cMuted
                                    font { family: root.fUi; pixelSize: 12 }
                                }
                                Text {
                                    visible: root.hoursLeft > 0 && root.powerHist.length < 4
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    text: "estimasi makin akurat dalam beberapa detik"
                                    color: root.tone(root.cMuted, 0.7)
                                    font { family: root.fUi; pixelSize: 10 }
                                }
                            }
                        }

                        // detail
                        Grid {
                            id: batGrid
                            visible: root.hasBattery
                            columns: 2
                            spacing: 8
                            width: parent.width
                            Repeater {
                                model: [
                                    { k: root.charging ? "Daya masuk" : "Daya keluar",
                                      v: root.powerAvg > 0.05 ? root.powerAvg.toFixed(1) + " W" : "—", cp: 0xf140b },
                                    { k: "Kesehatan",
                                      v: root.health > 0 ? Math.round(root.health * 100) + "%" : "—", cp: 0xf05f6 },
                                    { k: "Kapasitas",
                                      v: root.energyFull > 0 ? root.energyNow.toFixed(1) + " / " + root.energyFull.toFixed(1) + " Wh" : "—", cp: 0xf0079 },
                                    { k: "Siklus cas",
                                      v: root.bat.cycle_count && root.bat.cycle_count !== "0" ? root.bat.cycle_count + "×" : "—", cp: 0xf1834 }
                                ]
                                delegate: Rectangle {
                                    id: st
                                    required property var modelData
                                    width: (batGrid.width - 8) / 2
                                    height: 58
                                    radius: 12
                                    color: root.cSurface
                                    border.color: root.cBorder
                                    Column {
                                        x: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Text {
                                            text: root.ic(st.modelData.cp) + "  " + st.modelData.k
                                            color: root.cMuted
                                            font { family: root.fIcon; pixelSize: 11 }
                                        }
                                        Text {
                                            text: st.modelData.v
                                            color: root.cText
                                            font { family: root.fUi; pixelSize: 15; weight: Font.DemiBold }
                                        }
                                    }
                                }
                            }
                        }
                        Text {
                            visible: root.hasBattery && root.energyDesign > 0
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Kapasitas pabrik " + root.energyDesign.toFixed(1) + " Wh" +
                                  (root.bat.model_name ? "  ·  " + (root.bat.manufacturer ? root.bat.manufacturer + " " : "") + root.bat.model_name : "")
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 11 }
                        }

                        SectionLabel { text: "Batas pengisian"; visible: root.hasBattery && root.chargeLimit > 0 }
                        ChargeSwitch { width: parent.width; visible: root.hasBattery && root.chargeLimit > 0 }
                        Text {
                            visible: root.hasBattery && root.chargeLimit > 0
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: root.chargeErr !== "" ? root.chargeErr
                                : root.chargeLimit >= 100 ? "Mengisi sampai penuh. Untuk laptop yang sering dicolok, 80% lebih awet."
                                : "Berhenti mengisi di " + root.chargeLimit + "%, baterai lebih awet. Pilih 100% saat butuh daya penuh."
                            color: root.chargeErr !== "" ? root.cUrgent : root.cMuted
                            font { family: root.fUi; pixelSize: 11 }
                        }

                        SectionLabel { text: "Mode daya"; visible: root.ppdAvailable }
                        ProfileSwitch { width: parent.width; visible: root.ppdAvailable }
                    }

                    // ════════ PROFIL ═══════════════════
                    Column {
                        visible: root.page === "profile"
                        width: parent.width
                        spacing: 14

                        Avatar {
                            anchors.horizontalCenter: parent.horizontalCenter
                            size: 112
                            ring: true
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.displayName
                            color: root.cText
                            font { family: root.fUi; pixelSize: 17; weight: Font.DemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "@" + root.user + (root.hasFace ? "  ·  foto juga tampil di lockscreen" : "")
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }

                        SectionLabel { text: "Nama tampilan" }
                        Rectangle {
                            width: parent.width
                            height: 44
                            radius: 12
                            color: root.cSurface
                            border.color: nameInput.activeFocus ? root.cAccent : root.cBorder
                            TextInput {
                                id: nameInput
                                anchors.left: parent.left
                                anchors.right: saveBtn.left
                                anchors.leftMargin: 14
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.displayName
                                maximumLength: 40
                                color: root.cText
                                selectionColor: root.cAccent
                                font { family: root.fUi; pixelSize: 13 }
                                clip: true
                                onAccepted: { root.saveName(text); focus = false; }
                                Keys.onEscapePressed: { text = root.displayName; focus = false; }
                                Text {
                                    anchors.fill: parent
                                    verticalAlignment: Text.AlignVCenter
                                    visible: nameInput.text.length === 0
                                    text: root.accountName
                                    color: root.cMuted
                                    font: nameInput.font
                                }
                            }
                            Rectangle {
                                id: saveBtn
                                readonly property bool dirty: nameInput.text.trim() !== root.displayName
                                width: 70; height: 30; radius: 9
                                anchors.right: parent.right
                                anchors.rightMargin: 7
                                anchors.verticalCenter: parent.verticalCenter
                                color: dirty ? root.cAccent : root.cSurface2
                                Text {
                                    anchors.centerIn: parent
                                    text: saveBtn.dirty ? "Simpan" : "Tersimpan"
                                    color: saveBtn.dirty ? root.cOnAccent : root.cMuted
                                    font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: saveBtn.dirty
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.saveName(nameInput.text); nameInput.focus = false; }
                                }
                            }
                        }

                        SectionLabel { text: "Foto profil" }
                        NavRow {
                            width: parent.width
                            glyph: root.ic(0xf02e9)
                            label: "Pilih foto dari file…"
                            onClicked: root.avatar(["pick"])
                        }
                        NavRow {
                            width: parent.width
                            glyph: root.ic(0xf0bec)   // alpha-a-circle
                            label: "Pakai huruf inisial"
                            value: "warna tema"
                            onClicked: root.avatar(["default"])
                        }
                        NavRow {
                            width: parent.width
                            glyph: root.ic(0xf0208)
                            label: "Lihat di lockscreen"
                            onClicked: root.previewLock()
                        }
                    }

                    // ════════ TEMA ═════════════════════
                    Column {
                        visible: root.page === "theme"
                        width: parent.width
                        spacing: 12

                        Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Mengganti warna waybar, notifikasi, launcher, panel, lockscreen, dan focus ring niri sekaligus."
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }
                        Text {
                            visible: root.themes.length === 0
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Daftar tema belum ada. Jalankan update.sh dulu."
                            color: root.cUrgent
                            font { family: root.fUi; pixelSize: 12 }
                        }

                        Grid {
                            id: themeGrid
                            columns: 2
                            spacing: 10
                            width: parent.width
                            Repeater {
                                model: root.themes
                                delegate: Rectangle {
                                    id: th
                                    required property var modelData
                                    readonly property bool cur: root.currentTheme === modelData.id
                                    readonly property var c: modelData.colors
                                    width: (themeGrid.width - 10) / 2
                                    height: 112
                                    radius: 16
                                    color: c.bg
                                    border.width: cur ? 2 : 1
                                    border.color: cur ? root.cAccent : (thMa.containsMouse ? root.cMuted : root.cBorder)
                                    scale: thMa.pressed ? 0.97 : 1
                                    Behavior on scale { NumberAnimation { duration: 90 } }

                                    // mini preview: bar + slider + titik warna, pakai warna tema itu sendiri
                                    Rectangle {
                                        x: 10; y: 10
                                        width: parent.width - 20; height: 44
                                        radius: 10
                                        color: th.c.surface
                                        border.color: th.c.border
                                        Rectangle {
                                            x: 8; y: 8
                                            width: parent.width - 16; height: 10; radius: 5
                                            color: th.c.surface2
                                            Rectangle { width: parent.width * 0.62; height: parent.height; radius: 5; color: th.c.accent }
                                        }
                                        Row {
                                            x: 8; y: 26
                                            spacing: 5
                                            Repeater {
                                                model: [th.c.accent, th.c.accent2, th.c.accent3, th.c.muted]
                                                delegate: Rectangle {
                                                    required property color modelData
                                                    width: 10; height: 10; radius: 5
                                                    color: modelData
                                                }
                                            }
                                        }
                                    }
                                    Column {
                                        x: 12
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 10
                                        width: parent.width - 24
                                        Text {
                                            text: th.modelData.name
                                            color: th.c.text
                                            font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
                                        }
                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: th.modelData.desc
                                            color: th.c.muted
                                            font { family: root.fUi; pixelSize: 11 }
                                        }
                                    }
                                    Rectangle {
                                        visible: th.cur
                                        width: 22; height: 22; radius: 11
                                        anchors { right: parent.right; bottom: parent.bottom; margins: 10 }
                                        color: th.c.accent
                                        Text {
                                            anchors.centerIn: parent
                                            text: root.ic(0xf012c)
                                            color: th.c.bg
                                            font { family: root.fIcon; pixelSize: 13 }
                                        }
                                    }
                                    MouseArea {
                                        id: thMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.applyTheme(th.modelData.id)
                                    }
                                }
                            }
                        }

                        SectionLabel { text: "Dock" }
                        SwitchRow {
                            width: parent.width
                            glyph: root.ic(0xf0379)
                            label: "Dock bawah"
                            sub: root.dockOn ? "Tahan kursor di tepi bawah untuk memunculkan" : "Mati — tidak ada proses yang jalan"
                            checked: root.dockOn
                            onToggled: root.toggleDock()
                        }
                        Text {
                            visible: root.dockOn
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Klik kanan ikon di dock untuk pin / lepas pin. Klik tengah membuka jendela baru."
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 11 }
                        }
                    }

                    // ════════ MONITOR ══════════════════
                    Column {
                        visible: root.page === "monitor"
                        width: parent.width
                        spacing: 12

                        Row {
                            width: parent.width
                            spacing: 8
                            Repeater {
                                model: [
                                    { id: "internal", label: "Laptop saja",  cp: 0xf0322 },
                                    { id: "extend",   label: "Extend",       cp: 0xf037a },
                                    { id: "external", label: "Monitor saja", cp: 0xf06e7 }
                                ]
                                delegate: Rectangle {
                                    id: mm
                                    required property var modelData
                                    readonly property bool cur: root.monitorMode === modelData.id
                                    readonly property bool can: modelData.id === "internal" || root.hasExternal
                                    width: (parent.width - 16) / 3
                                    height: 78
                                    radius: 14
                                    opacity: can ? 1 : 0.4
                                    color: cur ? root.cSurface2 : (mmMa.containsMouse && can ? root.cSurface : "transparent")
                                    border.color: cur ? root.cAccent : root.cBorder
                                    border.width: cur ? 2 : 1
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 6
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.ic(mm.modelData.cp)
                                            color: mm.cur ? root.cAccent : root.cText
                                            font { family: root.fIcon; pixelSize: 22 }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: mm.modelData.label
                                            color: mm.cur ? root.cText : root.cMuted
                                            font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                        }
                                    }
                                    MouseArea {
                                        id: mmMa
                                        anchors.fill: parent
                                        enabled: mm.can
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setMonitorMode(mm.modelData.id)
                                    }
                                }
                            }
                        }

                        SectionLabel { text: "Terhubung" }
                        Repeater {
                            model: root.outputs
                            delegate: Item {
                                id: od
                                required property var modelData
                                width: parent.width
                                height: 40
                                Text {
                                    id: odIc
                                    anchors.left: parent.left
                                    anchors.leftMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.ic(od.modelData.internal ? 0xf0322 : 0xf0379)
                                    color: od.modelData.on ? root.cText : root.cMuted
                                    font { family: root.fIcon; pixelSize: 17 }
                                }
                                Column {
                                    anchors.left: odIc.right
                                    anchors.leftMargin: 12
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: od.modelData.label
                                        color: root.cText
                                        font { family: root.fUi; pixelSize: 13 }
                                    }
                                    Text {
                                        text: od.modelData.name + " · " + (od.modelData.on ? "aktif" : "mati")
                                        color: od.modelData.on ? root.cTeal : root.cMuted
                                        font { family: root.fUi; pixelSize: 11 }
                                    }
                                }
                            }
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "Perubahan berlaku sampai logout. Untuk permanen, atur di config niri."
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 11 }
                        }
                    }
                }
            }
        }
    }

    // pelacak slider yang sedang di-drag (supaya polling nggak melawan jari)
    QtObject { id: volSlider;    property Item target; readonly property bool dragging: target ? target.dragging : false }
    QtObject { id: volSliderBig; property Item target; readonly property bool dragging: target ? target.dragging : false }
    QtObject { id: micSlider;    property Item target; readonly property bool dragging: target ? target.dragging : false }
    QtObject { id: briSlider;    property Item target; readonly property bool dragging: target ? target.dragging : false }
    QtObject { id: briSliderBig; property Item target; readonly property bool dragging: target ? target.dragging : false }

    // ═════════ KOMPONEN ══════════════════════════════════

    // foto profil bulat dari ~/.face; kalau belum ada, huruf inisial
    component Avatar: Item {
        id: av
        property int size: 44
        property bool ring: false
        width: size; height: size
        Rectangle {
            anchors.fill: parent
            anchors.margins: av.ring ? -4 : 0
            radius: width / 2
            color: "transparent"
            border.width: av.ring ? 2 : 0
            border.color: root.cAccent
        }
        ClippingRectangle {
            anchors.fill: parent
            radius: av.size / 2
            color: root.cSurface2
            border.color: root.cBorder
            Text {
                anchors.centerIn: parent
                visible: faceImg.status !== Image.Ready
                text: root.displayName.charAt(0).toUpperCase()
                color: root.cAccent
                font { family: root.fUi; pixelSize: Math.round(av.size * 0.42); weight: Font.Bold }
            }
            Image {
                id: faceImg
                anchors.fill: parent
                visible: root.hasFace && status === Image.Ready
                source: root.hasFace ? "file://" + root.faceFile : ""
                sourceSize: Qt.size(av.size * 2, av.size * 2)
                fillMode: Image.PreserveAspectCrop
                cache: false
                asynchronous: true
            }
        }
    }

    component SectionLabel: Text {
        color: root.cMuted
        font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold; letterSpacing: 0.6; capitalization: Font.AllUppercase }
    }

    component IconButton: Rectangle {
        id: ib
        property string glyph
        property bool small: false
        property bool spinning: false
        property bool filled: false
        property color tint: root.cMuted
        signal clicked()
        width: small ? 28 : 34
        height: width
        radius: width / 2
        color: filled ? root.tone(root.cUrgent, 0.15) : (ibMa.containsMouse ? root.cSurface2 : "transparent")
        Text {
            anchors.centerIn: parent
            text: ib.glyph
            color: ib.tint
            font { family: root.fIcon; pixelSize: ib.small ? 14 : 17 }
            RotationAnimation on rotation { running: ib.spinning; loops: Animation.Infinite; from: 0; to: 360; duration: 900 }
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ib.clicked()
        }
    }

    component Tile: Rectangle {
        id: tile
        property bool active: false
        property bool hasMore: false
        property string glyph
        property string title
        property string subtitle
        signal clicked()
        signal moreClicked()
        height: 62
        radius: 16
        opacity: enabled ? 1 : 0.45
        color: active ? root.cAccent : (tileMa.containsMouse ? root.cSurface2 : root.cSurface)
        border.color: active ? root.cAccent : root.cBorder
        Behavior on color { ColorAnimation { duration: 140 } }

        Rectangle {
            id: tileIcon
            width: 34; height: 34; radius: 17
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            color: tile.active ? root.tone(root.cBg, 0.14) : root.cSurface2
            Text {
                anchors.centerIn: parent
                text: tile.glyph
                color: tile.active ? root.cOnAccent : root.cText
                font { family: root.fIcon; pixelSize: 17 }
            }
        }
        Column {
            anchors.left: tileIcon.right
            anchors.leftMargin: 10
            anchors.right: tile.hasMore ? moreArea.left : parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                text: tile.title
                elide: Text.ElideRight
                color: tile.active ? root.cOnAccent : root.cText
                font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
            }
            Text {
                width: parent.width
                text: tile.subtitle
                elide: Text.ElideRight
                color: tile.active ? root.tone(root.cBg, 0.72) : root.cMuted
                font { family: root.fUi; pixelSize: 11 }
            }
        }
        MouseArea {
            id: tileMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: tile.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.clicked()
        }
        // area panah: buka sub-halaman
        Item {
            id: moreArea
            visible: tile.hasMore
            width: 30
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 26
                color: tile.active ? root.tone(root.cBg, 0.2) : root.cBorder
            }
            Text {
                anchors.centerIn: parent
                text: root.ic(0xf0142)
                color: tile.active ? root.cOnAccent : root.cMuted
                font { family: root.fIcon; pixelSize: 15 }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: tile.moreClicked()
            }
        }
    }

    // slider tebal ala quick settings: ikon di kiri (klik = mute), angka di kanan
    component SliderRow: Item {
        id: sr
        property string glyph
        property real value: 0
        property bool dim: false
        property bool big: false
        property bool showMore: true
        readonly property bool dragging: srMa.pressed
        property real dragVal: 0
        readonly property real shown: dragging ? dragVal : value
        signal moved(real v)
        signal iconClicked()
        signal moreClicked()
        height: big ? 48 : 40

        Rectangle {
            id: track
            anchors.left: parent.left
            anchors.right: sr.showMore ? srMore.left : parent.right
            anchors.rightMargin: sr.showMore ? 8 : 0
            height: parent.height
            radius: 14
            color: root.cSurface
            border.color: root.cBorder
            clip: true

            Rectangle {
                width: Math.max(track.height, track.width * sr.shown)
                height: parent.height
                radius: 14
                color: sr.dim ? root.cSurface2 : root.cAccent
                Behavior on width { enabled: !sr.dragging; NumberAnimation { duration: 120 } }
            }
            MouseArea {
                id: srMa
                anchors.fill: parent
                anchors.leftMargin: 44
                cursorShape: Qt.PointingHandCursor
                function upd(mx) {
                    const x = mx + anchors.leftMargin;
                    sr.dragVal = Math.max(0, Math.min(1, x / track.width));
                    sr.moved(sr.dragVal);
                }
                onPressed: m => upd(m.x)
                onPositionChanged: m => { if (pressed) upd(m.x); }
                onWheel: w => sr.moved(Math.max(0, Math.min(1, sr.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))))
            }
            // ikon (klik = mute)
            Item {
                width: 44
                height: parent.height
                Text {
                    anchors.centerIn: parent
                    text: sr.glyph
                    color: (!sr.dim && sr.shown * track.width > 30) ? root.cOnAccent : root.cText
                    font { family: root.fIcon; pixelSize: sr.big ? 19 : 17 }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sr.iconClicked()
                }
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(sr.shown * 100) + "%"
                color: (!sr.dim && sr.shown > 0.92) ? root.cOnAccent : root.cMuted
                font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
            }
        }
        Rectangle {
            id: srMore
            visible: sr.showMore
            width: parent.height
            height: parent.height
            anchors.right: parent.right
            radius: 14
            color: moreMa.containsMouse ? root.cSurface2 : root.cSurface
            border.color: root.cBorder
            Text {
                anchors.centerIn: parent
                text: root.ic(0xf0142)
                color: root.cMuted
                font { family: root.fIcon; pixelSize: 16 }
            }
            MouseArea {
                id: moreMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sr.moreClicked()
            }
        }
    }

    component SwitchRow: Rectangle {
        id: sw
        property string glyph
        property string label
        property string sub
        property bool checked: false
        signal toggled()
        height: 56
        radius: 14
        color: swMa.containsMouse && enabled ? root.cSurface2 : root.cSurface
        border.color: root.cBorder
        opacity: enabled ? 1 : 0.45

        Text {
            id: swIc
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: sw.glyph
            color: sw.checked ? root.cAccent : root.cText
            font { family: root.fIcon; pixelSize: 18 }
        }
        Column {
            anchors.left: swIc.right
            anchors.leftMargin: 12
            anchors.right: knobTrack.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            Text {
                width: parent.width
                text: sw.label
                elide: Text.ElideRight
                color: root.cText
                font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
            }
            Text {
                width: parent.width
                text: sw.sub
                elide: Text.ElideRight
                color: root.cMuted
                font { family: root.fUi; pixelSize: 11 }
            }
        }
        Rectangle {
            id: knobTrack
            width: 40; height: 22; radius: 11
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            color: sw.checked ? root.cAccent : root.cSurface2
            border.color: sw.checked ? root.cAccent : root.cBorder
            Behavior on color { ColorAnimation { duration: 140 } }
            Rectangle {
                width: 16; height: 16; radius: 8
                anchors.verticalCenter: parent.verticalCenter
                x: sw.checked ? parent.width - width - 3 : 3
                color: sw.checked ? root.cOnAccent : root.cMuted
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
        }
        MouseArea {
            id: swMa
            anchors.fill: parent
            enabled: sw.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled()
        }
    }

    component NavRow: Rectangle {
        id: nv
        property string glyph
        property string label
        property string value
        signal clicked()
        height: 44
        radius: 12
        color: nvMa.containsMouse ? root.cSurface2 : root.cSurface
        border.color: root.cBorder
        Text {
            id: nvIc
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: nv.glyph
            color: root.cText
            font { family: root.fIcon; pixelSize: 16 }
        }
        Text {
            id: nvLabel
            anchors.left: nvIc.right
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: nv.label
            color: root.cText
            font { family: root.fUi; pixelSize: 13 }
        }
        Text {
            anchors.left: nvLabel.right
            anchors.leftMargin: 10
            anchors.right: nvChev.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: nv.value || ""
            elide: Text.ElideLeft
            color: root.cMuted
            font { family: root.fUi; pixelSize: 12 }
        }
        Text {
            id: nvChev
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: root.ic(0xf0142)
            color: root.cMuted
            font { family: root.fIcon; pixelSize: 15 }
        }
        MouseArea {
            id: nvMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: nv.clicked()
        }
    }

    component ProfileSwitch: Rectangle {
        height: 46
        radius: 14
        color: root.cSurface
        border.color: root.cBorder
        Row {
            anchors.fill: parent
            anchors.margins: 4
            Repeater {
                model: [
                    { id: "power-saver", label: "Irit",     cp: 0xf032a, tint: root.cTeal },
                    { id: "balanced",    label: "Seimbang", cp: 0xf05d1, tint: root.cAccent },
                    { id: "performance", label: "Performa", cp: 0xf04c5, tint: root.cWarn }
                ]
                delegate: Rectangle {
                    id: seg
                    required property var modelData
                    readonly property bool sel: root.profile === modelData.id
                    width: parent.width / 3
                    height: parent.height
                    radius: 10
                    color: sel ? root.cSurface2 : (segMa.containsMouse ? Qt.rgba(1, 1, 1, 0.03) : "transparent")
                    border.color: sel ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Row {
                        anchors.centerIn: parent
                        spacing: 7
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.ic(seg.modelData.cp)
                            color: seg.sel ? seg.modelData.tint : root.cMuted
                            font { family: root.fIcon; pixelSize: 15 }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: seg.modelData.label
                            color: seg.sel ? root.cText : root.cMuted
                            font { family: root.fUi; pixelSize: 13; weight: seg.sel ? Font.DemiBold : Font.Medium }
                        }
                    }
                    MouseArea {
                        id: segMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setProfile(seg.modelData.id)
                    }
                }
            }
        }
    }

    component ChargeSwitch: Rectangle {
        height: 46
        radius: 14
        color: root.cSurface
        border.color: root.cBorder
        Row {
            anchors.fill: parent
            anchors.margins: 4
            Repeater {
                model: [
                    { v: 60,  label: "60%",  note: "Awet" },
                    { v: 80,  label: "80%",  note: "Disarankan" },
                    { v: 100, label: "100%", note: "Penuh" }
                ]
                delegate: Rectangle {
                    id: cseg
                    required property var modelData
                    readonly property bool sel: root.chargeLimit === modelData.v
                    width: parent.width / 3
                    height: parent.height
                    radius: 10
                    color: sel ? root.cSurface2 : (cMa.containsMouse ? Qt.rgba(1, 1, 1, 0.03) : "transparent")
                    border.color: sel ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Row {
                        anchors.centerIn: parent
                        spacing: 7
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: cseg.modelData.label
                            color: cseg.sel ? root.cAccent : root.cText
                            font { family: root.fUi; pixelSize: 13; weight: cseg.sel ? Font.DemiBold : Font.Medium }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: cseg.modelData.note
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 10 }
                        }
                    }
                    MouseArea {
                        id: cMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setChargeLimit(cseg.modelData.v)
                    }
                }
            }
        }
    }
}

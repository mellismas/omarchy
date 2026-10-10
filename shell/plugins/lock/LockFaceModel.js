// The lock screen's face cascade: a cheap `faceauth probe` on a cadence, and
// a full face scan only for a face that is near enough to judge, likely the
// owner's and turned to the screen. The daemon sends its cadence table with every probe reply
// (the [unlock] section of its config); these are the shipped values, used
// until the first reply arrives and whenever a reply has no table.
function defaultCadence() {
  return { "ac": 2.0, "performance": 3.0, "balanced": 5.0, "power-saver": 8.0 }
}

// No entry probes more often than once a second: the probe drives the IR
// camera and its illuminator, and a daemon that answers at once would spin.
var MIN_CADENCE_SECONDS = 1.0

// The table from a reply, each entry a positive number of seconds; a missing
// or unusable entry takes the shipped value. Null when the reply has none.
function cadenceFrom(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  var shipped = defaultCadence()
  var table = {}
  for (var key in shipped) {
    var seconds = Number(value[key])
    table[key] = isFinite(seconds) && seconds > 0 ? Math.max(seconds, MIN_CADENCE_SECONDS) : shipped[key]
  }
  return table
}

// Seconds between probes: `ac` on mains, whatever the profile; on battery the
// active power profile's entry, and `balanced` for an unknown or empty one.
function cadenceSeconds(table, onBattery, profile) {
  var cadence = table || defaultCadence()
  if (!onBattery) return cadence.ac
  if (profile === "performance" || profile === "balanced" || profile === "power-saver") return cadence[profile]
  return cadence.balanced
}

// One probe reply. A reply that does not parse, or an error, is no face. An
// older daemon without `scannable`, `likely` or `attentive` answers as
// before: each reads as true while missing, and anything but true reads as
// false once present.
function parseProbe(text) {
  var info = null
  try {
    info = JSON.parse(String(text || ""))
  } catch (e) {
    info = null
  }
  if (!info || typeof info !== "object" || Array.isArray(info)) {
    return { face: false, scannable: false, likely: false, attentive: false, facePx: 0, cadence: null }
  }
  return {
    face: info.face === true,
    scannable: !("scannable" in info) || info.scannable === true,
    likely: !("likely" in info) || info.likely === true,
    attentive: !("attentive" in info) || info.attentive === true,
    facePx: Number(info.face_px || 0),
    cadence: cadenceFrom(info.cadence)
  }
}

// What the lock does with a reply: "scan" runs the full face scan, waking a
// dark panel for it. Every other answer does nothing and waits for the next
// probe: "no-face", "not-scannable" (too far to judge), "not-likely" or
// "not-attentive" (turned away: the owner working at another screen reads as
// likely, and a full scan of that pose misses).
function probeAction(reply) {
  if (!reply || !reply.face) return "no-face"
  if (!reply.scannable) return "not-scannable"
  if (!reply.likely) return "not-likely"
  if (!reply.attentive) return "not-attentive"
  return "scan"
}

if (typeof module !== "undefined") {
  module.exports = {
    defaultCadence: defaultCadence,
    cadenceFrom: cadenceFrom,
    cadenceSeconds: cadenceSeconds,
    parseProbe: parseProbe,
    probeAction: probeAction
  }
}

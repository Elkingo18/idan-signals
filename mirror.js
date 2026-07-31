/* =====================================================================
   מראת החשבון החיה  —  Idan Trader
   ---------------------------------------------------------------------
   קוראת את  data/account.json  שהגשר המקומי כותב, ומציגה אותה בטאב
   "פוזיציות" מעל הכרטיסים הקיימים.

   קריאה בלבד. אין כאן שום קוד ששולח פקודה, ואין כאן סיסמאות.
   אם הקובץ לא קיים או ישן — הכרטיס אומר את זה במפורש ולא מסתיר כלום.
   ===================================================================== */
(function () {
  "use strict";

  var SRC = "data/account.json?t=";
  var STALE_MIN = 10;          // מעל זה נחשב לא טרי
  var EVERY_MS = 60000;

  var css = ""
    + "#mirrorCard .mrHead{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px}"
    + "#mirrorCard .mrDot{width:9px;height:9px;border-radius:50%;flex:0 0 auto}"
    + "#mirrorCard .mrPill{font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--line);color:var(--dim)}"
    + "#mirrorCard .mrGrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;margin:10px 0}"
    + "#mirrorCard .mrBox{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:9px 11px}"
    + "#mirrorCard .mrK{font-size:11px;color:var(--dim)}"
    + "#mirrorCard .mrV{font-size:17px;font-weight:700;margin-top:2px}"
    + "#mirrorCard .mrRow{display:flex;justify-content:space-between;gap:10px;padding:7px 0;border-top:1px solid var(--line);font-size:13px}"
    + "#mirrorCard .mrSub{font-size:11.5px;color:var(--dim);margin-top:2px}"
    + "#mirrorCard .up{color:var(--green)} #mirrorCard .dn{color:var(--red)}"
    + "#mirrorCard .mrWarn{border-left:3px solid var(--gold);background:var(--panel2);"
    + "border-radius:8px;padding:9px 11px;font-size:12.5px;margin-top:9px;line-height:1.6}";

  function styleOnce() {
    if (document.getElementById("mirrorCss")) return;
    var s = document.createElement("style");
    s.id = "mirrorCss";
    s.textContent = css;
    document.head.appendChild(s);
  }

  function money(v) {
    if (v === null || v === undefined || isNaN(v)) return "—";
    return "$" + Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function signed(v) {
    if (v === null || v === undefined || isNaN(v)) return "—";
    return (v > 0 ? "+" : "") + Number(v).toFixed(2);
  }
  function cls(v) { return v > 0 ? "up" : v < 0 ? "dn" : ""; }
  function esc(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function card() {
    var host = document.querySelector('section[data-v="pos"]');
    if (!host) return null;
    var el = document.getElementById("mirrorCard");
    if (!el) {
      el = document.createElement("div");
      el.className = "card";
      el.id = "mirrorCard";
      host.insertBefore(el, host.firstChild);
    }
    return el;
  }

  function offline(el, why) {
    el.innerHTML =
      '<h3>🏦 מראת החשבון — אינטראקטיב דמה</h3>' +
      '<div class="mrHead"><span class="mrDot" style="background:var(--dim)"></span>' +
      '<b style="color:var(--dim)">לא מחובר</b>' +
      '<span class="mrPill">קריאה בלבד</span></div>' +
      '<div class="mrWarn">' + esc(why) + '<br>' +
      'המראה מתמלאת כשהגשר רץ על המחשב שלך:<br>' +
      '<code dir="ltr">python bridge/account_mirror.py --loop 60</code><br>' +
      'לפני זה צריך ש-IB Gateway יהיה פתוח ומחובר לחשבון הדמה, פורט 4002.' +
      '</div>';
  }

  function render(el, d) {
    var w = d.shadow_wallet || {};
    var b = d.broker || {};
    var mins = (Date.now() - Date.parse(d.updated_utc)) / 60000;
    var fresh = isFinite(mins) && mins <= STALE_MIN;
    var dot = fresh ? "var(--green)" : "var(--gold)";
    var word = fresh ? "חי" : "לא טרי";

    var pos = (d.positions || []).map(function (p) {
      return '<div class="mrRow"><div><b dir="ltr">' + esc(p.symbol) + '</b>' +
        '<div class="mrSub" dir="ltr">' + esc(p.qty) + ' @ ' + esc(p.avg_cost) +
        (p.mark ? ' → ' + esc(p.mark) : '') + '</div></div>' +
        '<div class="' + cls(p.unrealized) + '" dir="ltr">' + signed(p.unrealized) + '</div></div>';
    }).join("") || '<div class="mrSub" style="padding:7px 0">אין פוזיציות פתוחות בחשבון.</div>';

    var ord = (d.open_orders || []).map(function (o) {
      return '<div class="mrRow"><div><b dir="ltr">' + esc(o.symbol) + '</b>' +
        '<div class="mrSub" dir="ltr">' + esc(o.action) + ' ' + esc(o.qty) + ' ' + esc(o.type) +
        (o.stop ? ' @ ' + esc(o.stop) : '') + (o.limit ? ' @ ' + esc(o.limit) : '') +
        '</div></div><div class="mrSub">' + esc(o.status) + '</div></div>';
    }).join("");

    var manual = (d.manual_positions || []).length;

    el.innerHTML =
      '<h3>🏦 מראת החשבון — אינטראקטיב דמה</h3>' +
      '<div class="mrHead">' +
        '<span class="mrDot" style="background:' + dot + '"></span><b>' + word + '</b>' +
        '<span class="mrPill">קריאה בלבד</span>' +
        '<span class="mrPill">' + esc(d.mode === "paper" ? "חשבון דמה" : d.mode) + '</span>' +
        '<span class="mrPill" dir="ltr">' + esc(d.updated_israel || "") + '</span>' +
      '</div>' +

      '<div class="mrGrid">' +
        '<div class="mrBox"><div class="mrK">הון — ארנק צל</div>' +
          '<div class="mrV ' + cls((w.equity || 0) - 1000) + '" dir="ltr">' + money(w.equity) + '</div></div>' +
        '<div class="mrBox"><div class="mrK">ממומש</div>' +
          '<div class="mrV ' + cls(w.realized_pnl) + '" dir="ltr">' + signed(w.realized_pnl) + '</div></div>' +
        '<div class="mrBox"><div class="mrK">פתוח</div>' +
          '<div class="mrV ' + cls(w.open_pnl) + '" dir="ltr">' + signed(w.open_pnl) + '</div></div>' +
        '<div class="mrBox"><div class="mrK">תשואה</div>' +
          '<div class="mrV ' + cls(w.return_pct) + '" dir="ltr">' + signed(w.return_pct) + '%</div></div>' +
      '</div>' +

      '<div class="mrSub">💼 פוזיציות שהמנוע פתח</div>' + pos +
      (ord ? '<div class="mrSub" style="margin-top:9px">📋 פקודות פתוחות</div>' + ord : "") +

      '<div class="mrWarn">' +
        'הארנק כאן הוא <b>ארנק צל של 1,000 דולר</b>. חשבון הדמה של אינטראקטיב מתחיל בסביבות מיליון ' +
        'דולר וירטואליים — היתרה הזאת (' + money(b.net_liquidation) + ') מוצגת רק לידיעה ואינה משמשת לשום חישוב.' +
        (manual ? '<br>⚠️ יש ' + manual + ' פוזיציות בחשבון שהמנוע לא פתח. הן לא נספרות בארנק הצל.' : '') +
        (fresh ? '' : '<br>⚠️ הנתון האחרון בן ' + Math.round(mins) + ' דקות. הגשר כנראה לא רץ כרגע.') +
      '</div>';
  }

  function load() {
    var el = card();
    if (!el) return;
    styleOnce();
    fetch(SRC + Date.now(), { cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (d) { render(el, d); })
      .catch(function () {
        offline(el, "עדיין לא נכתב קובץ מצב חשבון לריפו.");
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", load);
  } else {
    load();
  }
  setInterval(load, EVERY_MS);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) load(); });
})();

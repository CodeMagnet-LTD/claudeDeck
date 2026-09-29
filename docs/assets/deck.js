// Links to the GitHub repo, derived from the Pages URL (<owner>.github.io/<repo>/). A custom domain
// sets <meta name="repo" content="owner/repo"> instead.
(function () {
  var meta = document.querySelector('meta[name="repo"]');
  var repo = meta && meta.content;
  if (!repo && /\.github\.io$/.test(location.hostname)) {
    repo = location.hostname.split(".")[0] + "/" + (location.pathname.split("/")[1] || "ClaudeDeck");
  }
  if (!repo) return;
  document.querySelectorAll("[data-gh]").forEach(function (a) {
    a.href = "https://github.com/" + repo + a.getAttribute("data-gh");
  });
})();

// The deck: sessions change state the way they do in the app. Static when reduced motion is preferred.
(function () {
  var deck = document.querySelector(".deck");
  if (!deck || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var t = JSON.parse(deck.getAttribute("data-states"));
  var rows = {};
  deck.querySelectorAll(".row[data-id]").forEach(function (r) { rows[r.dataset.id] = r; });
  var head = deck.querySelector(".term-head .pill");
  var btns = deck.querySelector(".term-head .btns");
  var allow = btns.querySelector("span");
  var box = deck.querySelector(".deck-term .box");

  function set(id, state, detail) {
    var r = rows[id];
    r.dataset.state = state;
    r.querySelector(".state").textContent = detail || t[state];
    if (state === "turn") { r.classList.add("flash"); setTimeout(function () { r.classList.remove("flash"); }, 900); }
  }
  // [delay ms, action]
  var script = [
    [2600, function () { allow.classList.add("on"); }],
    [500, function () { allow.classList.remove("on"); box.hidden = true; btns.hidden = true; head.className = "pill run"; head.textContent = t.running; set("a", "running", t.runningTests); }],
    [2400, function () { set("c", "turn", t.done); }],
    [2400, function () { set("a", "turn", t.passed); head.className = "pill"; head.style.background = "var(--turn)"; head.textContent = t.turn; }],
    [2600, function () { set("b", "running", t.editing); }],
    [2600, function () { reset(); }]
  ];
  var initial = [];
  deck.querySelectorAll(".row[data-id]").forEach(function (r) {
    initial.push([r, r.dataset.state, r.querySelector(".state").textContent]);
  });
  var headInitial = [head.className, head.textContent];
  function reset() {
    initial.forEach(function (i) { i[0].dataset.state = i[1]; i[0].querySelector(".state").textContent = i[2]; });
    head.className = headInitial[0]; head.textContent = headInitial[1]; head.style.background = "";
    box.hidden = false; btns.hidden = false;
  }
  var step = 0;
  function next() {
    var s = script[step];
    setTimeout(function () { s[1](); step = (step + 1) % script.length; next(); }, s[0]);
  }
  next();
})();

const ICONS = {
  ground: `<svg viewBox="0 0 64 64" aria-hidden="true">
    <path fill="currentColor" d="M4 50h56v3.2H4z"/>
    <path fill="currentColor" d="M8 50c1.2-9 3.4-9 4.4 0 1.6-13 4.6-13 6 0 1.4-8 3.6-8 4.8 0 1.8-11 4.8-11 6.2 0H24c-.2-5-1.4-5-2.2 0-1.2-7-3.2-7-4.2 0-1.4-6-3-6-4 0z"/>
    <circle cx="46" cy="40" r="3.3" fill="currentColor"/>
    <path fill="currentColor" d="M48.6 39.1 56 40.6 48.8 42.4z"/>
    <path fill="currentColor" d="M44.2 41.6c-3.4.4-5.2 2-5.6 3.2 2.2-.2 4-.8 5.6-2z"/>
    <path stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M46 43.4V49M42.8 50l3.2-5.2L49.2 50"/>
  </svg>`,
  low: `<svg viewBox="0 0 64 64" aria-hidden="true">
    <path fill="currentColor" d="M6 52h52v3H6z"/>
    <path fill="currentColor" d="M8 50c2-16 10-24 24-24s22 8 24 24c-6-8-14-12-24-12S14 42 8 50z"/>
    <circle cx="34" cy="38" r="3.1" fill="#f3eee4"/>
    <path fill="#f3eee4" d="M36.4 37.2 42 38.5 36.6 40z"/>
    <path stroke="#f3eee4" stroke-width="1.8" stroke-linecap="round" d="M34 41v5"/>
  </svg>`,
  mid: `<svg viewBox="0 0 64 64" aria-hidden="true">
    <path fill="currentColor" d="M30 58V34h4v24z"/>
    <circle cx="32" cy="30" r="14" fill="currentColor"/>
    <circle cx="48" cy="30" r="3.2" fill="currentColor"/>
    <path fill="currentColor" d="M50.4 29.1 57 30.5 50.6 32.2z"/>
    <path fill="currentColor" d="M6 58h52v3H6z"/>
  </svg>`,
  canopy: `<svg viewBox="0 0 64 64" aria-hidden="true">
    <path fill="currentColor" d="M30 60V26h4v34z"/>
    <circle cx="32" cy="18" r="13" fill="currentColor"/>
    <circle cx="38" cy="16" r="2.7" fill="#f3eee4"/>
    <path fill="#f3eee4" d="M40 15.4 45 16.5 40.2 17.8z"/>
    <path fill="currentColor" d="M6 60h52v3H6z"/>
  </svg>`,
};

const app = document.querySelector("#app");
let guide = null;
let query = "";
let stratum = "all";
let group = "all";

function icon(id) {
  const wrap = document.createElement("span");
  wrap.className = "icon";
  wrap.innerHTML = ICONS[id] || "";
  return wrap;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function norm(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function stratumById(id) {
  return guide.strata.find((item) => item.id === id);
}

function groupById(id) {
  return guide.groups.find((item) => item.id === id);
}

function haystack(bird) {
  return norm(
    [
      bird.commonName,
      bird.scientificName,
      ...(bird.aliases || []),
      ...(bird.alsoCalled || []),
      ...(bird.alsoScientific || []),
      ...(bird.tags || []),
      bird.summary,
      bird.habitat,
      bird.status,
    ].join(" ")
  );
}

function filteredBirds() {
  const words = norm(query).split(" ").filter(Boolean);
  return guide.species.filter((bird) => {
    if (stratum !== "all" && !bird.strata.includes(stratum)) return false;
    if (group !== "all" && bird.group !== group) return false;
    if (!words.length) return true;
    const hay = haystack(bird);
    return words.every((word) => hay.includes(word));
  });
}

function thumb(photo) {
  const wrap = el("span", "thumb-wrap");
  const img = document.createElement("img");
  img.src = photo.src;
  img.alt = "";
  img.width = 120;
  img.height = 72;
  wrap.append(img);
  if (photo.role === "male" || photo.role === "female") {
    wrap.append(el("figcaption", null, photo.role === "male" ? "M" : "F"));
  }
  return wrap;
}

function strataInline(bird) {
  const row = el("span", "mini-strata");
  bird.strata.forEach((id) => {
    const item = stratumById(id);
    const bit = document.createElement("span");
    bit.append(icon(id), document.createTextNode(item.label));
    row.append(bit);
  });
  return row;
}

function birdRow(bird) {
  const link = document.createElement("a");
  link.className = "bird-row";
  link.href = `#/bird/${bird.id}`;
  const thumbs = el("span", bird.photos.length > 1 ? "thumbs" : "thumbs single");
  bird.photos.forEach((photo) => thumbs.append(thumb(photo)));
  const body = el("span", "body");
  const nameLine = el("span", "name-line");
  nameLine.append(el("h3", null, bird.commonName));
  body.append(nameLine, el("p", "scientific", bird.scientificName), el("p", "summary", bird.summary));
  const meta = el("span", "meta");
  const status = el("span", bird.origin === "introduced" ? "status introduced" : "status", bird.status);
  meta.append(status, strataInline(bird));
  body.append(meta);
  link.append(thumbs, body);
  return link;
}

function legend() {
  const list = el("ul", "legend");
  guide.strata.forEach((item) => {
    const li = document.createElement("li");
    const copy = el("span");
    copy.append(el("strong", null, item.label), el("span", "hint", item.hint));
    li.append(icon(item.id), copy);
    list.append(li);
  });
  return list;
}

function chip(label, pressed, onClick) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "chip";
  button.textContent = label;
  button.setAttribute("aria-pressed", pressed ? "true" : "false");
  button.addEventListener("click", onClick);
  return button;
}

function tools() {
  const bar = el("div", "tools");
  const search = document.createElement("input");
  search.className = "search";
  search.type = "search";
  search.placeholder = "Search name, scientific name, or place";
  search.value = query;
  search.setAttribute("aria-label", "Search birds");
  search.addEventListener("input", () => {
    query = search.value;
    render();
    const next = document.querySelector(".search");
    if (next) {
      next.focus();
      const end = next.value.length;
      next.setSelectionRange(end, end);
    }
  });
  const heights = el("div", "chip-row");
  heights.append(el("span", "chip-label", "Height"));
  heights.append(chip("Any height", stratum === "all", () => { stratum = "all"; render(); }));
  guide.strata.forEach((item) => {
    heights.append(chip(item.label, stratum === item.id, () => { stratum = item.id; render(); }));
  });
  const places = el("div", "chip-row");
  places.append(el("span", "chip-label", "Place"));
  places.append(chip("Anywhere", group === "all", () => { group = "all"; render(); }));
  const shortGroup = { water: "Water", coast: "Bay", open: "Grass", park: "Parks", woodland: "Hills" };
  guide.groups.forEach((item) => {
    places.append(chip(shortGroup[item.id] || item.label, group === item.id, () => { group = item.id; render(); }));
  });
  bar.append(search, heights, places);
  return bar;
}

function renderList() {
  const keepFocus = document.activeElement && document.activeElement.classList.contains("search");
  const caret = keepFocus ? document.activeElement.selectionStart : null;
  app.replaceChildren();
  const birds = filteredBirds();
  const filtering = norm(query) || stratum !== "all" || group !== "all";
  app.append(tools(), legend());
  app.append(el("p", "count", `Showing ${birds.length} of ${guide.species.length}`));
  if (!birds.length) {
    app.append(el("p", "empty", "No birds match. Try a scientific name, or clear the height and place filters."));
    return;
  }
  const grouped = !filtering;
  const buckets = grouped ? guide.groups.map((item) => item.id) : ["all"];
  buckets.forEach((bucket) => {
    const rows = birds.filter((bird) => grouped ? bird.group === bucket : true);
    rows.sort((a, b) => a.commonName.localeCompare(b.commonName));
    if (!rows.length) return;
    const section = el("section", "group-block");
    if (grouped) section.append(el("h2", null, groupById(bucket).label));
    rows.forEach((bird) => section.append(birdRow(bird)));
    app.append(section);
  });
  const note = el("p", "footer-note");
  note.textContent = "Height icons can be combined: a bird that feeds on a lawn and sings from a branch shows more than one. Photos are openly licensed; credits are on each bird.";
  app.append(note);
  if (keepFocus) {
    const next = document.querySelector(".search");
    if (next) {
      next.focus();
      next.setSelectionRange(caret, caret);
    }
  }
}

function creditLine(photo) {
  const line = el("p", "credit");
  line.append(document.createTextNode("Photo: "));
  const source = document.createElement("a");
  source.href = photo.sourceUrl;
  source.textContent = photo.author;
  source.rel = "noopener noreferrer";
  line.append(source);
  line.append(document.createTextNode(photo.licenseUrl ? ", " : `. ${photo.license}.`));
  if (photo.licenseUrl) {
    const license = document.createElement("a");
    license.href = photo.licenseUrl;
    license.textContent = photo.license;
    license.rel = "noopener noreferrer";
    line.append(license, document.createTextNode("."));
  }
  return line;
}

function renderDetail(id) {
  const bird = guide.species.find((item) => item.id === id);
  app.replaceChildren();
  const back = document.createElement("a");
  back.className = "back";
  back.href = "#/";
  back.textContent = "← All birds";
  app.append(back);
  if (!bird) {
    app.append(el("p", "error", "That bird is not in this guide."));
    document.title = "Melbourne birds";
    return;
  }
  document.title = `${bird.commonName} · Melbourne birds`;
  const article = el("article", "detail");
  article.append(el("p", "status" + (bird.origin === "introduced" ? " introduced" : ""), bird.status));
  article.append(el("h2", "bird-name", bird.commonName));
  article.append(el("p", "scientific", bird.scientificName));
  if (bird.alsoCalled && bird.alsoCalled.length) {
    article.append(el("p", "also", `Also called ${bird.alsoCalled.join(", ")}`));
  }
  if (bird.alsoScientific && bird.alsoScientific.length) {
    article.append(el("p", "also", `Also listed as ${bird.alsoScientific.join(", ")}`));
  }
  article.append(el("p", "section-label", "Where you find it"));
  article.append(el("p", "note", bird.habitat));
  article.append(el("p", "section-label", "Height"));
  const list = el("ul", "stratum-list");
  bird.strata.forEach((stratumId) => {
    const item = stratumById(stratumId);
    const li = el("li", "stratum-line");
    const copy = el("span");
    copy.append(el("strong", null, item.label), el("span", "hint", item.hint));
    li.append(icon(stratumId), copy);
    list.append(li);
  });
  article.append(list, el("p", "note", bird.stratumNote));
  article.append(el("p", "section-label", bird.dimorphic ? "Male and female" : "Sexes"));
  article.append(el("p", "note", bird.sexes));
  const photos = el("div", bird.photos.length > 1 ? "photos" : "photos single");
  bird.photos.forEach((photo) => {
    const figure = document.createElement("figure");
    const img = document.createElement("img");
    img.src = photo.src;
    img.alt = photo.alt;
    img.width = photo.width;
    img.height = photo.height;
    const caption = document.createElement("figcaption");
    caption.append(el("strong", null, photo.label), creditLine(photo));
    figure.append(img, caption);
    photos.append(figure);
  });
  article.append(photos);
  const foot = el("p", "footer-note", "Notes are for greater Melbourne. A named park is a typical public place, not a guarantee for a given day.");
  article.append(foot);
  app.append(article);
  window.scrollTo(0, 0);
}

function render() {
  if (!guide) return;
  const hash = (location.hash || "#/").replace(/^#/, "");
  const match = hash.match(/^\/bird\/([a-z0-9-]+)/);
  if (match) renderDetail(match[1]);
  else {
    document.title = "Melbourne birds";
    renderList();
  }
}

function showError(message) {
  app.replaceChildren(el("p", "error", message));
}

fetch("data/birds.json")
  .then((response) => {
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  })
  .then((data) => {
    guide = data;
    render();
    window.addEventListener("hashchange", render);
  })
  .catch(() => {
    showError("The species list did not load. From the melbourne-birds folder, run python3 -m http.server 8765 and open http://127.0.0.1:8765");
  });

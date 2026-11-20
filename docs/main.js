(() => {
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Copy buttons
  document.querySelectorAll("[data-copy]").forEach((button) => {
    const root = button.closest("[data-copy-root]");
    const text = root.querySelector("[data-copy-text]").textContent.trim();
    const label = button.querySelector(".cmd-copy-label");
    let timer;
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        const range = document.createRange();
        range.selectNodeContents(root.querySelector("[data-copy-text]"));
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        label.textContent = "Press ⌘C";
        clearTimeout(timer);
        timer = setTimeout(() => { label.textContent = "Copy"; }, 3000);
        return;
      }
      button.classList.add("copied");
      label.textContent = "Copied";
      button.setAttribute("aria-label", "Install command copied");
      clearTimeout(timer);
      timer = setTimeout(() => {
        button.classList.remove("copied");
        label.textContent = "Copy";
        button.setAttribute("aria-label", "Copy the install command");
      }, 2000);
    });
  });

  // The icon's build-up: 55 frames from Blender. The hero plays them once when
  // they are loaded. The icon in the install section builds up while it scrolls
  // into view.
  const FRAMES = 55, FPS = 30;
  // Frames 49 to 55 are the same, and the animation slows down a lot before them.
  const SETTLED = 48;
  const images = [];
  const painter = (canvas) => {
    const ctx = canvas.getContext && canvas.getContext("2d");
    let current = 0;
    return ctx && ((frame) => {
      if (frame === current) return;
      current = frame;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(images[frame - 1], 0, 0, canvas.width, canvas.height);
    });
  };
  const flight = document.querySelector(".flight");
  const drawHero = painter(document.getElementById("flight"));
  const build = document.querySelector(".install-icon");
  const drawBuild = build && painter(build.querySelector("canvas"));
  if (drawHero && drawBuild && !reduceMotion) {
    const playIntro = () => {
      const start = performance.now();
      const step = (now) => {
        const frame = Math.min(FRAMES, 1 + Math.floor(((now - start) / 1000) * FPS));
        drawHero(frame);
        if (frame < FRAMES) requestAnimationFrame(step);
      };
      drawHero(1);
      flight.classList.add("live");
      requestAnimationFrame(step);
    };
    // The build-up starts when the icon's center enters the screen at the bottom,
    // and ends when it is at the middle of the screen (or the page ends before).
    const frameForScroll = () => {
      const r = build.getBoundingClientRect();
      const center = r.top + r.height / 2 + scrollY;
      const from = center - innerHeight;
      const to = Math.min(center - innerHeight * 0.5, document.documentElement.scrollHeight - innerHeight);
      const p = Math.min(Math.max((scrollY - from) / (to - from), 0), 1);
      return p === 1 ? FRAMES : 1 + Math.round(p * (SETTLED - 1));
    };
    let ready = false, buildRaf = 0;
    const updateBuild = () => {
      if (!ready || buildRaf) return;
      buildRaf = requestAnimationFrame(() => { buildRaf = 0; drawBuild(frameForScroll()); });
    };
    addEventListener("scroll", updateBuild, { passive: true });
    addEventListener("resize", updateBuild);
    let loaded = 0;
    for (let i = 1; i <= FRAMES; i++) {
      const img = new Image();
      img.onload = () => {
        if (++loaded < FRAMES) return;
        ready = true;
        // The intro plays when the hero is on screen, also after a reload
        // that restores a scroll position further down.
        const io = new IntersectionObserver(([entry]) => {
          if (!entry.isIntersecting) return;
          io.disconnect();
          playIntro();
        });
        io.observe(flight);
        drawBuild(frameForScroll());
        build.classList.add("live");
      };
      img.src = `assets/flight/${String(i).padStart(3, "0")}.webp`;
      images.push(img);
    }
  }

  // Miniplayer demo: the layout follows the size, with the same rules as the app
  const mini = document.getElementById("mini");
  const desk = document.getElementById("mini-desk");
  const handle = document.getElementById("mini-handle");
  const hint = document.getElementById("mini-hint");
  const segButtons = document.querySelectorAll(".seg button");
  const MIN = 72, MAX_W = 640, MAX_H = 400;
  // The corner pulses and the note points at it until the first drag.
  mini.classList.add("untouched");
  // On narrow screens the note sits below left of the corner, so it does not leave the screen.
  const narrow = matchMedia("(max-width: 820px)");
  const placeHint = () => { hint.classList.toggle("ann-nw", !narrow.matches); hint.classList.toggle("ann-ne", narrow.matches); };
  placeHint();
  narrow.addEventListener("change", placeHint);

  const layoutFor = (w, h) => (w <= 170 ? "cover" : h >= 170 ? "large" : w <= 270 ? "slim" : "strip");

  const setSize = (w, h) => {
    const maxW = Math.min(MAX_W, desk.clientWidth - 32);
    const maxH = Math.min(MAX_H, desk.clientHeight - 80);
    w = Math.round(Math.max(MIN, Math.min(maxW, w)));
    h = Math.round(Math.max(MIN, Math.min(maxH, h)));
    const layout = layoutFor(w, h);
    mini.style.setProperty("--w", w + "px");
    mini.style.setProperty("--h", h + "px");
    mini.dataset.layout = layout;
    mini.setAttribute("aria-label", `Miniplayer demo, ${w} by ${h} points, layout: ${layout}`);
    segButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.textContent.toLowerCase() === layout)));
  };

  let drag = null;
  handle.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    handle.setPointerCapture(e.pointerId);
    const rect = mini.getBoundingClientRect();
    drag = { x: e.clientX, y: e.clientY, w: rect.width, h: rect.height };
    mini.classList.add("dragging");
    hint.classList.add("gone");
    mini.classList.remove("untouched");
  });
  handle.addEventListener("pointermove", (e) => {
    if (!drag) return;
    // The window stays centered, so a corner drag grows it on both sides.
    setSize(drag.w + (e.clientX - drag.x) * 2, drag.h + (e.clientY - drag.y) * 2);
  });
  const endDrag = () => { drag = null; mini.classList.remove("dragging"); };
  handle.addEventListener("pointerup", endDrag);
  handle.addEventListener("pointercancel", endDrag);

  segButtons.forEach((b) => b.addEventListener("click", () => {
    const [w, h] = b.dataset.size.split(",").map(Number);
    setSize(w, h);
  }));
  addEventListener("resize", () => {
    const r = mini.getBoundingClientRect();
    setSize(r.width, r.height);
  });

  // Notch demo: the same modes and gestures as Notch.swift
  const notch = document.getElementById("notch");
  const TRACKS = [
    { title: "Low Tide Radio", artist: "Marla Venn", cover: "cover-1", duration: 182 },
    { title: "Double Parked", artist: "The Yellow Doors", cover: "cover-2", duration: 251 },
    { title: "White Heels", artist: "Odile Fenn", cover: "cover-3", duration: 214 },
    { title: "Petunia Static", artist: "Glasshaus Choir", cover: "cover-4", duration: 168 },
  ];
  const player = { track: 2, time: 71, playing: true };
  const covers = notch.querySelectorAll(".n-cover");
  const line = notch.querySelector(".n-line");
  const timeLabel = notch.querySelector(".n-time");
  const progress = notch.querySelector(".n-progress i");
  const bars = [...notch.querySelectorAll(".n-bars i")];
  const flashIcon = notch.querySelector(".n-flash use");
  const fmt = (s) => `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

  const showTrack = () => {
    const t = TRACKS[player.track];
    notch.dataset.track = player.track + 1;
    covers.forEach((c) => { c.style.backgroundImage = `url("assets/img/${t.cover}.webp")`; });
    // Twice the text, so the marquee can loop without a jump
    line.textContent = `${t.title} · ${t.artist}  ${t.title} · ${t.artist}  `;
    notch.querySelector(".n-title").textContent = t.title;
    notch.querySelector(".n-artist").textContent = t.artist;
  };
  const showTime = () => {
    const d = TRACKS[player.track].duration;
    timeLabel.textContent = `${fmt(player.time)} / ${fmt(d)}`;
    progress.style.setProperty("--p", player.time / d);
  };

  // Modes: idle, hover after 0.5 s under the pointer, moment for 2.6 s after a track change
  let hovering = false, hoverTimer, momentTimer, flashTimer;
  const setMode = (mode) => { notch.dataset.mode = mode; };
  notch.addEventListener("pointerenter", (e) => {
    if (e.pointerType !== "mouse") return;
    hovering = true;
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => { if (hovering && notch.dataset.mode === "idle") setMode("hover"); }, 500);
  });
  notch.addEventListener("pointerleave", () => {
    hovering = false;
    clearTimeout(hoverTimer);
    if (notch.dataset.mode === "hover") setMode("idle");
  });
  const flash = (icon) => {
    clearTimeout(flashTimer);
    flashIcon.setAttribute("href", `#i-${icon}`);
    notch.classList.remove("flashing");
    void notch.offsetWidth;
    notch.classList.add("flashing");
    flashTimer = setTimeout(() => notch.classList.remove("flashing"), 700);
  };

  const togglePlay = () => {
    flash(player.playing ? "pause" : "play");
    player.playing = !player.playing;
  };
  const changeTrack = (step) => {
    player.track = (player.track + step + TRACKS.length) % TRACKS.length;
    player.time = 0;
    player.playing = true;
    showTrack();
    showTime();
    flash(step > 0 ? "next" : "prev");
    clearTimeout(momentTimer);
    setMode("moment");
    momentTimer = setTimeout(() => setMode(hovering ? "hover" : "idle"), 2600);
  };
  const seek = (seconds) => {
    player.time = Math.min(Math.max(player.time + seconds, 0), TRACKS[player.track].duration - 1);
    showTime();
  };

  // Click: play or pause
  notch.addEventListener("click", togglePlay);
  notch.addEventListener("keydown", (e) => {
    const keys = { " ": togglePlay, Enter: togglePlay, ArrowRight: () => changeTrack(1), ArrowLeft: () => changeTrack(-1),
      ArrowUp: () => seek(-10), ArrowDown: () => seek(10) };
    if (keys[e.key]) { e.preventDefault(); keys[e.key](); }
  });

  // Scroll: seek. Swipe left or right: next or previous track.
  // The notch takes the wheel only after the mouse moved over it. When the page
  // scrolls under a resting pointer, the (sticky) notch must not stop the page.
  let armed = false, swipeSum = 0, lastWheel = 0, swipeDone = false;
  notch.addEventListener("pointermove", (e) => { if (e.pointerType === "mouse" && (e.movementX || e.movementY)) armed = true; });
  notch.addEventListener("pointerleave", () => { armed = false; });
  notch.addEventListener("wheel", (e) => {
    if (!armed) return;
    e.preventDefault();
    tried();
    const now = performance.now();
    // A pause of 300 ms ends a gesture (with its momentum).
    if (now - lastWheel > 300) { swipeSum = 0; swipeDone = false; }
    lastWheel = now;
    const scale = e.deltaMode === 1 ? 16 : 1;
    const dx = e.deltaX * scale, dy = e.deltaY * scale;
    if (Math.abs(dx) > Math.abs(dy)) {
      swipeSum += dx;
      // One track per gesture
      if (swipeDone || Math.abs(swipeSum) < 60) return;
      swipeDone = true;
      changeTrack(swipeSum > 0 ? 1 : -1);
    } else if (dy) {
      // Show the time at once, so the jump is visible
      if (notch.dataset.mode === "idle") setMode("hover");
      // Trackpads give many small steps, wheels give big ones.
      seek(Math.max(-5, Math.min(5, dy * 0.2)));
    }
  }, { passive: false });

  // Touch: a horizontal swipe changes the track
  let touchStart = null;
  notch.addEventListener("touchstart", (e) => { const t = e.touches[0]; touchStart = { x: t.clientX, y: t.clientY }; }, { passive: true });
  notch.addEventListener("touchend", (e) => {
    if (!touchStart) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStart.x, dy = t.clientY - touchStart.y;
    touchStart = null;
    if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      e.preventDefault(); // no click after a swipe
      changeTrack(dx < 0 ? 1 : -1);
    }
  });

  // Playback: the time runs and the level meter moves, only while the notch is on screen.
  let visible = false, lastTick = 0, lastBars = 0;
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) { lastTick = performance.now(); requestAnimationFrame(tick); }
  }).observe(notch);
  const tick = (now) => {
    if (!visible) return;
    if (player.playing) {
      player.time += (now - lastTick) / 1000;
      if (player.time >= TRACKS[player.track].duration) changeTrack(1);
      else showTime();
    }
    lastTick = now;
    // Same formula as LevelBars in PlayerUI.swift, at 12 frames per second
    if (now - lastBars > 1000 / 12) {
      lastBars = now;
      const t = now / 1000;
      bars.forEach((bar, i) => {
        let level = 3;
        if (player.playing && !reduceMotion) {
          const wave = Math.sin(t * (5.1 + i * 0.7) + i * 1.9) * 0.5 + Math.sin(t * (2.3 + i * 0.37) + i) * 0.3 + Math.sin(t * 8.7 + i * 2.6) * 0.2;
          const center = 1 - (Math.abs(i - (bars.length - 1) / 2) / bars.length) * 0.8;
          level = Math.max(3, (wave * 0.5 + 0.5) * center * 14);
        } else if (player.playing) {
          level = [6, 9, 12, 12, 9, 6][i];
        }
        bar.style.setProperty("--l", level.toFixed(1));
      });
    }
    requestAnimationFrame(tick);
  };
  showTrack();
  showTime();

  // "Try it!" points at the notch until the first click, scroll, swipe or key.
  const notchHint = document.getElementById("notch-hint");
  const tried = () => notchHint.classList.add("gone");
  ["click", "keydown", "touchend"].forEach((type) => notch.addEventListener(type, tried, { passive: true }));

  // Menu bar demo: the item opens and closes the panel, and the panel plays the tracks.
  const mbSection = document.getElementById("features");
  const mbItem = document.getElementById("mb-item");
  const panel = document.getElementById("panel");
  const pBar = document.getElementById("p-progress");
  const pPlay = document.getElementById("p-play");
  const pHint = document.getElementById("p-hint");
  const mb = { track: 0, time: 71, playing: true };

  const mbShowTrack = (animate) => {
    const t = TRACKS[mb.track];
    // Only the player takes the accent of the cover, the field stays as it is.
    panel.dataset.track = mbItem.dataset.track = mb.track + 1;
    mbItem.querySelector(".mb-cover").src = `assets/img/${t.cover}.webp`;
    mbItem.querySelector(".mb-title").textContent = t.title;
    panel.querySelector(".p-title").textContent = t.title;
    panel.querySelector(".p-artist").textContent = t.artist;
    const cover = panel.querySelector(".p-cover");
    cover.style.backgroundImage = `url("assets/img/${t.cover}.webp")`;
    if (animate) {
      // The new cover fades in over the old one
      const layer = document.createElement("i");
      layer.style.backgroundImage = cover.style.backgroundImage;
      cover.replaceChildren(layer);
    }
    pBar.setAttribute("aria-valuemax", t.duration);
  };
  const mbShowTime = () => {
    const d = TRACKS[mb.track].duration;
    const p = mb.time / d;
    mbItem.querySelector(".macbar-progress i").style.setProperty("--p", p);
    pBar.querySelector("b").style.setProperty("--p", p);
    pBar.setAttribute("aria-valuenow", Math.floor(mb.time));
    panel.querySelector(".p-elapsed").textContent = fmt(mb.time);
    panel.querySelector(".p-remaining").textContent = "-" + fmt(d - mb.time);
  };
  const mbSetPlaying = (playing) => {
    mb.playing = playing;
    pPlay.querySelector("use").setAttribute("href", playing ? "#i-pause" : "#i-play");
    pPlay.setAttribute("aria-label", playing ? "Pause" : "Play");
  };
  const mbChangeTrack = (step) => {
    mb.track = (mb.track + step + TRACKS.length) % TRACKS.length;
    mb.time = 0;
    mbSetPlaying(true);
    mbShowTrack(true);
    mbShowTime();
  };

  mbItem.addEventListener("click", () => {
    const open = panel.classList.toggle("closed") === false;
    mbItem.setAttribute("aria-expanded", String(open));
  });
  pPlay.addEventListener("click", () => mbSetPlaying(!mb.playing));
  document.getElementById("p-prev").addEventListener("click", () => mbChangeTrack(-1));
  document.getElementById("p-next").addEventListener("click", () => { pHint.classList.add("gone"); mbChangeTrack(1); });

  // Click or drag on the progress line to seek
  const seekTo = (e) => {
    const r = pBar.getBoundingClientRect();
    const f = Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1);
    mb.time = Math.min(f * TRACKS[mb.track].duration, TRACKS[mb.track].duration - 1);
    mbShowTime();
  };
  pBar.addEventListener("pointerdown", (e) => { pBar.setPointerCapture(e.pointerId); seekTo(e); });
  pBar.addEventListener("pointermove", (e) => { if (pBar.hasPointerCapture(e.pointerId)) seekTo(e); });
  pBar.addEventListener("keydown", (e) => {
    const step = { ArrowRight: 10, ArrowUp: 10, ArrowLeft: -10, ArrowDown: -10 }[e.key];
    if (!step) return;
    e.preventDefault();
    mb.time = Math.min(Math.max(mb.time + step, 0), TRACKS[mb.track].duration - 1);
    mbShowTime();
  });

  // The panel hangs below the menu bar item, centered, but stays inside the field.
  const placePanel = () => {
    const s = mbSection.getBoundingClientRect();
    const i = mbItem.getBoundingClientRect();
    const edge = parseFloat(getComputedStyle(mbSection.querySelector(".field-inner")).paddingLeft) || 16;
    const x = Math.min(Math.max(i.left + i.width / 2 - 150 - s.left, edge), s.width - 300 - edge);
    panel.style.setProperty("--panel-x", x + "px");
    panel.style.right = "auto";
  };
  placePanel();
  addEventListener("resize", placePanel);
  document.fonts?.ready.then(placePanel);

  // The clock in the menu bar shows the real time
  const clock = document.getElementById("mb-clock");
  const showClock = () => {
    const d = new Date();
    const day = d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }).replace(",", "");
    clock.textContent = `${day}  ${d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })}`;
  };
  showClock();
  setInterval(showClock, 10000);

  // Playback runs only while the field is on screen
  let mbVisible = false, mbLast = 0;
  const mbTick = (now) => {
    if (!mbVisible) return;
    if (mb.playing) {
      mb.time += (now - mbLast) / 1000;
      if (mb.time >= TRACKS[mb.track].duration) mbChangeTrack(1);
      else mbShowTime();
    }
    mbLast = now;
    requestAnimationFrame(mbTick);
  };
  new IntersectionObserver(([entry]) => {
    mbVisible = entry.isIntersecting;
    if (mbVisible) { mbLast = performance.now(); requestAnimationFrame(mbTick); }
  }).observe(mbSection);
  mbShowTrack(false);
  mbShowTime();
})();

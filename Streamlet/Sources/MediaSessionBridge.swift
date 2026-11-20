import Foundation

class MediaSessionBridge {
    static let mediaSessionObserverScript = """
    (function() {
        // Minimal, no debug logging

        function sendUpdate(data) {
            try {
                const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mediaSession;
                if (mh && typeof mh.postMessage === 'function') {
                    mh.postMessage(data);
                }
            } catch (e) {}
        }

        function idFor(el) {
            try {
                if (!el.__streamletId) el.__streamletId = Math.random().toString(36).slice(2);
                return el.__streamletId;
            } catch (e) { return 'unknown-el'; }
        }

        function isVideo(el) {
            try { return !!el && el.tagName === 'VIDEO' && Number(el.videoWidth || 0) > 0 && Number(el.videoHeight || 0) > 0; } catch (e) { return false; }
        }

        // The video to show for the playing element. Some services (for example the
        // Spotify Canvas) play the sound in one element and show a muted, looping video
        // in another. Then the largest visible video that plays is the one to show.
        function videoFor(el) {
            if (isVideo(el)) return el;
            let best = null, bestArea = 0;
            try {
                document.querySelectorAll('video').forEach(function(v) {
                    try {
                        if (v === el || v.paused || !isVideo(v)) return;
                        const r = v.getBoundingClientRect();
                        const area = r.width * r.height;
                        if (area > bestArea) { best = v; bestArea = area; }
                    } catch (e) {}
                });
            } catch (e) {}
            return best;
        }

        function isAudible(el) {
            try { return !!el && !el.muted && Number(el.volume || 0) > 0; } catch (e) { return false; }
        }


        const state = (window.__streamletSimple = window.__streamletSimple || {
            activeElId: null,
            activeElRef: null // WeakRef or direct element
        });

        function getActiveElement() {
            try {
                if (state && state.activeElRef) {
                    if (typeof WeakRef !== 'undefined' && state.activeElRef instanceof WeakRef) {
                        const el = state.activeElRef.deref && state.activeElRef.deref();
                        if (el) return el;
                    } else if (state.activeElRef instanceof Element) {
                        return state.activeElRef;
                    }
                }
            } catch (e) {}
            return null;
        }

        // No DOM-based fallback pickers; we operate only on the remembered active element

        function applySeek(el, t) {
            try {
                const target = Math.max(0, Number(t || 0));
                // 1) Prefer fastSeek if available (WebKit supports it)
                try {
                    if (typeof el.fastSeek === 'function') {
                        el.fastSeek(target);
                        return;
                    }
                } catch (e) {}

                // 2) Direct set currentTime
                let before = Number(el.currentTime || 0);
                try { el.currentTime = target; } catch (e) {}
                let after = Number(el.currentTime || 0);

                // 3) If not applied, try pause -> set -> play sequence
                if (Math.abs(after - target) > 0.25) {
                    const wasPaused = !!el.paused;
                    try { if (!wasPaused) el.pause(); } catch (e) {}
                    try { el.currentTime = target; } catch (e) {}
                    try { if (!wasPaused) el.play(); } catch (e) {}
                    after = Number(el.currentTime || 0);
                }

                // 4) As a last nudge, retry once when ready
                if (Math.abs(after - target) > 0.25) {
                    const onReady = () => {
                        try { el.currentTime = target; } catch (e) {}
                    };
                    try { el.addEventListener('canplay', onReady, { once: true }); } catch (e) {}
                    try { el.addEventListener('loadedmetadata', onReady, { once: true }); } catch (e) {}
                    try { setTimeout(onReady, 200); } catch (e) {}
                }
            } catch (e) {}
        }

        // Minimal Media Session integration: metadata + action handlers
        try {
            if (navigator.mediaSession) {
                // Expose original mediaSession for existing integrations
                try { window.__streamletOriginalMediaSession = navigator.mediaSession; } catch (e) {}

                const MediaSessionProto = Object.getPrototypeOf(navigator.mediaSession);
                if (MediaSessionProto) {
                    // Store handlers for media keys (prev/next/play/pause etc.)
                    window.__streamletHandlers = window.__streamletHandlers || {};
                    const originalSetActionHandler = MediaSessionProto.setActionHandler;
                    if (originalSetActionHandler) {
                        MediaSessionProto.setActionHandler = function(action, handler) {
                            try {
                                if (handler) {
                                    window.__streamletHandlers[action] = handler;
                                } else {
                                    delete window.__streamletHandlers[action];
                                }
                                // Tell the app which frame owns the session handlers
                                sendUpdate({ handlers: Object.keys(window.__streamletHandlers) });
                            } catch (e) {}
                            return originalSetActionHandler.call(this, action, handler);
                        };
                    }

                    // Metadata updates
                    const originalMetadataDescriptor = Object.getOwnPropertyDescriptor(MediaSessionProto, 'metadata');
                    // Services list several sizes, often the smallest first. Take the largest.
                    // "any" (a vector image) counts as the largest.
                    function largestArtwork(list) {
                        try {
                            let best = null, bestSize = -1;
                            Array.from(list || []).forEach(function(a) {
                                if (!a || !a.src) return;
                                let size = 0;
                                String(a.sizes || '').split(/\\s+/).forEach(function(s) {
                                    if (s.toLowerCase() === 'any') { size = Infinity; return; }
                                    const m = /^(\\d+)x(\\d+)$/i.exec(s);
                                    if (m) size = Math.max(size, Number(m[1]) * Number(m[2]));
                                });
                                if (size > bestSize) { best = a.src; bestSize = size; }
                            });
                            return best;
                        } catch (e) { return null; }
                    }
                    function extractMetadata(md) {
                        try {
                            return {
                                title: md && md.title || '',
                                artist: md && md.artist || '',
                                album: md && md.album || '',
                                artwork: largestArtwork(md && md.artwork)
                            };
                        } catch (e) { return { title: '', artist: '', album: '', artwork: null }; }
                    }
                    if (originalMetadataDescriptor) {
                        Object.defineProperty(MediaSessionProto, 'metadata', {
                            get: function() { return originalMetadataDescriptor.get ? originalMetadataDescriptor.get.call(this) : undefined; },
                            set: function(value) {
                                if (value) { try { sendUpdate(extractMetadata(value)); } catch (e) {} }
                                if (originalMetadataDescriptor.set) { try { originalMetadataDescriptor.set.call(this, value); } catch (e) {} }
                            },
                            enumerable: true,
                            configurable: true
                        });
                    }

                    // Also hook MediaMetadata constructor as a fallback
                    if (window.MediaMetadata) {
                        const OriginalMediaMetadata = window.MediaMetadata;
                        window.MediaMetadata = function(init) {
                            const metadata = new OriginalMediaMetadata(init);
                            try { sendUpdate(extractMetadata(init)); } catch (e) {}
                            return metadata;
                        };
                        try {
                            Object.setPrototypeOf(window.MediaMetadata, OriginalMediaMetadata);
                            Object.defineProperty(window.MediaMetadata, 'prototype', { value: OriginalMediaMetadata.prototype, writable: false });
                        } catch (e) {}
                    }

                    // Send initial metadata if present
                    try {
                        if (navigator.mediaSession.metadata) {
                            sendUpdate(extractMetadata(navigator.mediaSession.metadata));
                        }
                    } catch (e) {}
                }
            }
        } catch (e) {}

        function attach(el) {
            if (!el || el.__streamletBound) return;
            el.__streamletBound = true;

            const onPlay = function() {
                if (isAudible(el)) {
                    try { state.activeElId = idFor(el); } catch (e) {}
                    try { state.activeElRef = (typeof WeakRef !== 'undefined') ? new WeakRef(el) : el; } catch (e) { try { state.activeElRef = el; } catch (e2) {} }
                    sendUpdate({ isPlaying: true });
                    onTime();
                }
            };

            const onPause = function() {
                if (idFor(el) === state.activeElId) {
                    sendUpdate({ isPlaying: false });
                }
            };

            const onTime = function() {
                // If we have no active element yet, adopt the first audible, playing one
                if (!state.activeElId && isAudible(el) && !el.paused && Number(el.readyState || 0) >= 2) {
                    try { state.activeElId = idFor(el); } catch (e) {}
                    try { state.activeElRef = (typeof WeakRef !== 'undefined') ? new WeakRef(el) : el; } catch (e) { try { state.activeElRef = el; } catch (e2) {} }
                }
                if (idFor(el) !== state.activeElId) return;
                let ct = 0, dur = 0;
                try { ct = Number(el.currentTime || 0); } catch (e) {}
                try { dur = (typeof el.duration === 'number' && isFinite(el.duration) && el.duration > 0) ? Number(el.duration) : 0; } catch (e) {}
                sendUpdate({ currentTime: ct, duration: dur, video: !!videoFor(el) });
            };

            try { el.addEventListener('play', onPlay); } catch (e) {}
            try { el.addEventListener('playing', onPlay); } catch (e) {}
            try { el.addEventListener('pause', onPause); } catch (e) {}
            try { el.addEventListener('ended', onPause); } catch (e) {}
            try { el.addEventListener('timeupdate', onTime); } catch (e) {}
            try { el.addEventListener('durationchange', onTime); } catch (e) {}
            try { el.addEventListener('loadedmetadata', onTime); } catch (e) {}
        }

        // Hook prototype play to catch off-DOM elements
        try {
            if (window.HTMLMediaElement && HTMLMediaElement.prototype) {
                const originalPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function() {
                    try { attach(this); } catch (e) {}
                    return originalPlay.call(this);
                };
            }
        } catch (e) {}

        // Hook src setter to attach early (covers autoplay and off-DOM)
        try {
            if (window.HTMLMediaElement && HTMLMediaElement.prototype) {
                const desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
                if (desc && desc.set) {
                    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                        configurable: true,
                        enumerable: desc.enumerable,
                        get: desc.get || function() { try { return this.getAttribute('src'); } catch (e) { return ''; } },
                        set: function(v) {
                            try { attach(this); } catch (e) {}
                            try { return desc.set.call(this, v); } catch (e) { try { this.setAttribute('src', v); } catch (e2) {} }
                        }
                    });
                }
            }
        } catch (e) {}

        // Hook srcObject to attach for MediaSource/streams
        try {
            if (window.HTMLMediaElement && HTMLMediaElement.prototype) {
                const descSO = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
                if (descSO && (descSO.set || descSO.get)) {
                    Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
                        configurable: true,
                        enumerable: !!descSO.enumerable,
                        get: descSO.get || function() { try { return this.__streamletSrcObject; } catch (e) { return null; } },
                        set: function(v) {
                            try { attach(this); } catch (e) {}
                            if (descSO.set) {
                                try { return descSO.set.call(this, v); } catch (e) {}
                            }
                            try { this.__streamletSrcObject = v; } catch (e) {}
                        }
                    });
                } else {
                    // Define a basic srcObject if missing, to still trigger attach
                    Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
                        configurable: true,
                        enumerable: true,
                        get: function() { try { return this.__streamletSrcObject; } catch (e) { return null; } },
                        set: function(v) {
                            try { attach(this); } catch (e) {}
                            try { this.__streamletSrcObject = v; } catch (e) {}
                        }
                    });
                }
            }
        } catch (e) {}

        // Document-level capture to auto-attach
        try {
            const capt = function(e) {
                const el = e && e.target;
                if (!el) return;
                try { if (el instanceof HTMLMediaElement) attach(el); } catch (err) {}
            };
            ['play', 'playing', 'pause', 'timeupdate', 'durationchange', 'loadedmetadata'].forEach(function(t){
                try { document.addEventListener(t, capt, true); } catch (e) {}
            });
        } catch (e) {}

        // Initial light scan
        try { document.querySelectorAll('audio,video').forEach(attach); } catch (e) {}

        // Observe new elements added to the DOM (covers dynamically created players)
        try {
            const mo = new MutationObserver(function(muts){
                for (const m of muts) {
                    if (m.type === 'childList') {
                        m.addedNodes && m.addedNodes.forEach(function(node){
                            try {
                                if (!node || node.nodeType !== 1) return;
                                if ((node.tagName === 'AUDIO') || (node.tagName === 'VIDEO')) {
                                    attach(node);
                                } else if (node.querySelectorAll) {
                                    node.querySelectorAll('audio,video').forEach(attach);
                                }
                            } catch (e) {}
                        });
                    }
                }
            });
            mo.observe(document.documentElement || document.body, { childList: true, subtree: true });
        } catch (e) {}

        
        // A new top-level document means a new page: clear the state of the previous one.
        // Frames must not do this, or a loading ad frame would hide the playing track.
        try { if (window.top === window) sendUpdate({ reset: true }); } catch (e) {}

        // Service-specific controls that the Media Session API does not cover.
        // Each entry maps a control to the element in the service's own web UI and reads
        // its state back from that element. A control without an entry stays hidden in the app.
        const serviceControls = [
            {
                // Verified against the soundcloud.com player bar
                host: /(^|\\.)soundcloud\\.com$/,
                shuffle: {
                    selector: '.playControls button.shuffleControl',
                    read: function(el) { return el.classList.contains('m-shuffling'); }
                },
                repeat: {
                    // The button cycles none -> one -> all
                    selector: '.playControls button.repeatControl',
                    read: function(el) {
                        if (el.classList.contains('m-one')) return 'one';
                        if (el.classList.contains('m-all')) return 'all';
                        return 'none';
                    }
                },
                like: {
                    selector: '.playControls button.playbackSoundBadge__like',
                    read: function(el) { return el.classList.contains('sc-button-selected'); }
                }
            },
            {
                // Verified against the deezer.com player bar. The data-testid ends in the state.
                host: /(^|\\.)deezer\\.com$/,
                shuffle: {
                    selector: 'button[data-testid^="shuffle_play_button_"]',
                    read: function(el) { return el.dataset.testid === 'shuffle_play_button_on'; }
                },
                repeat: {
                    // The button cycles none -> all -> one
                    selector: 'button[data-testid^="repeat_button_"]',
                    read: function(el) {
                        const id = el.dataset.testid;
                        if (id === 'repeat_button_single') return 'one';
                        if (id === 'repeat_button_all') return 'all';
                        return 'none';
                    }
                },
                like: {
                    selector: 'button[data-testid^="add_to_favorite_button_"]',
                    read: function(el) { return el.dataset.testid === 'add_to_favorite_button_on'; }
                }
            },
            {
                // Verified against the music.youtube.com player controls (ytmusic-wiz-player-controls).
                // The page can have a second, disabled set of controls: skip it.
                host: /(^|\\.)music\\.youtube\\.com$/,
                shuffle: {
                    selector: 'ytmusic-wiz-player-controls .ytmusicPlayerControlsShuffleButton button:not([disabled])',
                    read: function(el) { return el.getAttribute('aria-pressed') === 'true'; }
                },
                repeat: {
                    // The button cycles none -> all -> one. Only the label tells "all" from "one".
                    selector: 'ytmusic-wiz-player-controls .ytmusicPlayerControlsRepeatButton button:not([disabled])',
                    read: function(el) {
                        if (el.getAttribute('aria-pressed') !== 'true') return 'none';
                        return /\\bone\\b|\\b1\\b/i.test(el.getAttribute('aria-label') || '') ? 'one' : 'all';
                    }
                }
            },
            {
                // Verified against the tidal.com player footer. All three are role="switch"
                // with aria-checked. Like is not verified with an account, but uses the same
                // switch pattern as shuffle and repeat.
                host: /(^|\\.)tidal\\.com$/,
                shuffle: {
                    selector: 'button[data-test="shuffle"]',
                    read: function(el) { return el.getAttribute('aria-checked') === 'true'; }
                },
                repeat: {
                    // The button cycles none -> all -> one. The icon tells "all" from "one".
                    selector: 'button[data-test="repeat"]',
                    read: function(el) {
                        if (el.getAttribute('aria-checked') !== 'true') return 'none';
                        return el.querySelector('[data-test="icon--player__repeat-once"]') ? 'one' : 'all';
                    }
                },
                like: {
                    selector: 'button[data-test="footer-favorite-button"]',
                    read: function(el) { return el.getAttribute('aria-checked') === 'true'; }
                }
            },
            {
                // Verified against the music.amazon.* player bar (Prime). Prime has no shuffle
                // or repeat switch. The like button's test id ends in the action it performs:
                // "_Follow" (not liked) or "_Unfollow" (liked).
                host: /^music\\.amazon\\./,
                like: {
                    selector: 'button[data-testid*="MiniPlayer_Follow_"]',
                    read: function(el) { return /_Unfollow$/.test(el.getAttribute('data-testid') || ''); }
                }
            },
            {
                // Verified against the open.spotify.com player bar. Labels depend on the
                // user's language, so the mapping uses test ids, ARIA state and the accent class.
                host: /(^|\\.)spotify\\.com$/,
                shuffle: {
                    // The only button in the general controls without a test id
                    selector: '[data-testid=now-playing-bar] [data-testid=general-controls] button:not([data-testid])',
                    read: function(el) { return el.classList.contains('encore-internal-color-text-bright-accent'); }
                },
                repeat: {
                    // The button cycles none -> all -> one
                    selector: '[data-testid=now-playing-bar] button[data-testid=control-button-repeat]',
                    read: function(el) {
                        const checked = el.getAttribute('aria-checked');
                        if (checked === 'mixed') return 'one';
                        if (checked === 'true') return 'all';
                        return 'none';
                    }
                },
                like: {
                    selector: '[data-testid=now-playing-widget-v2] button[aria-checked]',
                    read: function(el) { return el.getAttribute('aria-checked') === 'true'; },
                    // A saved track opens the "Add to playlist" menu instead of removing it.
                    // Uncheck "Liked Songs" in that menu, then confirm with the submit button.
                    toggle: function(el) {
                        const saved = el.getAttribute('aria-checked') === 'true';
                        el.click();
                        if (!saved) return;
                        const started = Date.now();
                        const step = function() {
                            const menu = document.querySelector('#curation-sheet-list');
                            const items = menu ? Array.from(menu.querySelectorAll('[role=menuitemcheckbox]')) : [];
                            if (!items.length) {
                                if (Date.now() - started < 2000) setTimeout(step, 50);
                                return;
                            }
                            // "Liked Songs" is pinned at the top. Prefer a match by name.
                            const liked = items.find(function(item) {
                                return /liked songs|lieblingssongs/i.test(item.textContent || '');
                            }) || items[0];
                            if (liked.getAttribute('aria-checked') === 'true') liked.click();
                            setTimeout(function() {
                                const done = document.querySelector('#context-menu button[type=submit]');
                                if (done) done.click();
                            }, 100);
                        };
                        setTimeout(step, 50);
                    }
                }
            }
        ];

        const controls = (function() {
            try {
                const host = location.hostname;
                for (const entry of serviceControls) {
                    if (entry.host.test(host)) return entry;
                }
            } catch (e) {}
            return null;
        })();

        function findControl(name) {
            const c = controls && controls[name];
            if (!c) return null;
            try { return document.querySelector(c.selector); } catch (e) { return null; }
        }

        function readControls() {
            const out = {};
            ['shuffle', 'repeat', 'like'].forEach(function(name) {
                const el = findControl(name);
                try { out[name] = el ? controls[name].read(el) : null; } catch (e) { out[name] = null; }
            });
            return out;
        }

        if (controls) {
            let last = null;
            let hasControls = false;
            const report = function() {
                try {
                    const found = readControls();
                    // Other frames of the same service (embeds, widgets) have no player bar.
                    // A frame that never had a control stays silent, so it cannot hide the
                    // controls that the frame with the player bar reported.
                    const any = Object.keys(found).some(function(k) { return found[k] !== null; });
                    if (!any && !hasControls) return;
                    hasControls = true;
                    const now = JSON.stringify(found);
                    if (now !== last) {
                        last = now;
                        sendUpdate({ controls: JSON.parse(now) });
                    }
                } catch (e) {}
            };
            try { setInterval(report, 1000); } catch (e) {}
            window.__streamletReportControls = report;
        }

        // The current picture of the playing video as a small JPEG data URL, or null.
        // The app calls this for the miniplayer. A protected (DRM) video gives null.
        window.__streamletVideoFrame = function(maxWidth) {
            try {
                const el = videoFor(getActiveElement());
                if (!el) return null;
                const w = Math.max(16, Math.min(Number(maxWidth) || 480, el.videoWidth));
                const h = Math.max(9, Math.round(w * el.videoHeight / el.videoWidth));
                const canvas = state.frameCanvas || (state.frameCanvas = document.createElement('canvas'));
                if (canvas.width !== w) canvas.width = w;
                if (canvas.height !== h) canvas.height = h;
                canvas.getContext('2d').drawImage(el, 0, 0, w, h);
                return canvas.toDataURL('image/jpeg', 0.72);
            } catch (e) {
                return null;
            }
        };

        function callHandler(name, details) {
            const handlers = window.__streamletHandlers || {};
            const h = handlers[name];
            if (!h) return false;
            h(Object.assign({ action: name }, details || {}));
            return true;
        }

        // Command entry point. The app calls it in the frame that owns the session handlers,
        // the playing element or the service controls. It returns success only when this
        // frame could act, so the app can try the next frame without a double action.
        window.__streamletCommand = function(cmd, arg) {
            try {
                const el = getActiveElement();
                if (cmd === 'playpause') {
                    // Actual state: the tracked element first, then an explicit session state,
                    // then the state the app saw last. 'none' means unknown, not paused.
                    let playing;
                    if (el) {
                        playing = !el.paused;
                    } else {
                        const ps = navigator.mediaSession && navigator.mediaSession.playbackState;
                        playing = ps === 'playing' ? true : ps === 'paused' ? false : !!arg;
                    }
                    if (callHandler(playing ? 'pause' : 'play')) return { success: true };
                    if (callHandler('playpause')) return { success: true };
                    if (el) {
                        if (playing) { el.pause(); } else { el.play(); }
                        return { success: true };
                    }
                    return { success: false, error: 'no play/pause control' };
                }
                if (cmd === 'pause') {
                    if (callHandler('pause')) return { success: true };
                    if (el) { el.pause(); return { success: true }; }
                    return { success: false, error: 'no pause control' };
                }
                if (cmd === 'next') {
                    return callHandler('nexttrack') ? { success: true } : { success: false, error: 'no nexttrack handler' };
                }
                if (cmd === 'previous') {
                    return callHandler('previoustrack') ? { success: true } : { success: false, error: 'no previoustrack handler' };
                }
                if (cmd === 'seek') {
                    const t = Number(arg);
                    if (!isFinite(t) || t < 0) return { success: false, error: 'invalid time' };
                    if (callHandler('seekto', { seekTime: t })) return { success: true };
                    if (el) { applySeek(el, t); return { success: true }; }
                    return { success: false, error: 'no seek control' };
                }
                if (cmd === 'shuffle' || cmd === 'repeat' || cmd === 'like') {
                    const target = findControl(cmd);
                    if (!target) return { success: false, error: 'no ' + cmd + ' control' };
                    if (controls[cmd].toggle) controls[cmd].toggle(target); else target.click();
                    setTimeout(function() { try { window.__streamletReportControls && window.__streamletReportControls(); } catch (e) {} }, 100);
                    setTimeout(function() { try { window.__streamletReportControls && window.__streamletReportControls(); } catch (e) {} }, 800);
                    return { success: true };
                }
            } catch (e) {
                return { success: false, error: String(e) };
            }
            return { success: false, error: 'unknown command' };
        };
    })();
    """
}

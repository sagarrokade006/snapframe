(function () {
  'use strict';

  var repo = 'sagarrokade006/snapframe';
  var calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Reveal content as it scrolls into view.
  var revealObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        revealObserver.unobserve(entry.target);
      }
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });

  function watchReveals(root) {
    root.querySelectorAll('.reveal:not(.in)').forEach(function (el) { revealObserver.observe(el); });
  }
  watchReveals(document);

  // Only run a demo while it can be seen.
  var stageObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      entry.target.classList.toggle('play', entry.isIntersecting);
    });
  }, { threshold: 0.15 });
  document.querySelectorAll('.stage').forEach(function (el) { stageObserver.observe(el); });

  // Hero entrance, header and scroll-linked motion.
  setTimeout(function () { document.documentElement.classList.add('ready'); }, 40);

  var nav = document.getElementById('nav');
  var hero = document.getElementById('heroStage');
  var heroWindow = hero.querySelector('.hero-window');
  var floats = Array.prototype.slice.call(document.querySelectorAll('.float'));
  var ticking = false;

  function onScroll() {
    var y = window.scrollY;
    nav.classList.toggle('stuck', y > 12);
    if (!calm) {
      var rect = hero.getBoundingClientRect();
      var progress = Math.min(Math.max(1 - (rect.top + 120) / window.innerHeight, 0), 1);
      heroWindow.style.setProperty('--tilt', (14 - progress * 14).toFixed(2) + 'deg');
      heroWindow.style.setProperty('--grow', (0.93 + progress * 0.07).toFixed(3));
      floats.forEach(function (el) {
        el.style.setProperty('--shift', (rect.top * Number(el.dataset.speed)).toFixed(1) + 'px');
      });
    }
    ticking = false;
  }

  window.addEventListener('scroll', function () {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(onScroll);
    }
  }, { passive: true });
  window.addEventListener('resize', onScroll);
  onScroll();

  // Highlight the current section in the header.
  var links = {};
  document.querySelectorAll('.nav-links a').forEach(function (a) { links[a.getAttribute('href').slice(1)] = a; });
  var sectionObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      var link = links[entry.target.id];
      if (link) link.classList.toggle('active', entry.isIntersecting);
    });
  }, { rootMargin: '-45% 0px -50% 0px' });
  Object.keys(links).forEach(function (id) {
    var section = document.getElementById(id);
    if (section) sectionObserver.observe(section);
  });

  // The recording demo's clock, in step with its 8 second loop.
  var clock = document.getElementById('recClock');
  var recordStage = document.querySelector('.demo-record');
  if (clock && !calm) {
    var seconds = 0;
    setInterval(function () {
      if (!recordStage.classList.contains('play')) return;
      seconds = (seconds + 1) % 8;
      clock.textContent = '00:0' + seconds;
    }, 1000);
  }

  // Sticky download: only once the main button has gone, and not on top of the final one.
  var sticky = document.getElementById('stickyBar');
  var heroCta = document.querySelector('.hero .cta');
  var finalCta = document.getElementById('get');
  var ctaSeen = { hero: true, final: false };
  var ctaObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      ctaSeen[entry.target === heroCta ? 'hero' : 'final'] = entry.isIntersecting;
    });
    sticky.classList.toggle('show', !ctaSeen.hero && !ctaSeen.final);
  });
  ctaObserver.observe(heroCta);
  ctaObserver.observe(finalCta);

  // Studio: the story plays as you scroll, or on a loop where pinning doesn't fit.
  var studio = document.getElementById('studio');
  var player = document.getElementById('spPlayer');
  var steps = Array.prototype.slice.call(document.querySelectorAll('#spSteps li'));

  function ramp(from, to, value) {
    var t = Math.min(Math.max((value - from) / (to - from), 0), 1);
    return t * t * (3 - 2 * t);
  }

  function along(points, value) {
    for (var i = 1; i < points.length; i++) {
      if (value <= points[i][0]) {
        var t = ramp(points[i - 1][0], points[i][0], value);
        return [points[i - 1][1] + (points[i][1] - points[i - 1][1]) * t, points[i - 1][2] + (points[i][2] - points[i - 1][2]) * t];
      }
    }
    return points[points.length - 1].slice(1);
  }

  function renderStudio(p) {
    var bg = ramp(0.14, 0.3, p);
    var cursor = along([[0, 72, 74], [0.38, 72, 74], [0.45, 34, 38], [0.62, 40, 44], [0.8, 60, 58], [1, 60, 58]], p);
    var values = {
      '--p': p, '--bg': bg, '--i': bg * 8, '--r': bg * 14,
      '--z': 1 + 0.7 * (ramp(0.44, 0.52, p) - ramp(0.66, 0.74, p)),
      '--x': cursor[0], '--y': cursor[1],
      '--rip': p < 0.45 ? 1 : ramp(0.45, 0.53, p),
      '--keys': ramp(0.54, 0.57, p) - ramp(0.63, 0.66, p),
      '--ring': ramp(0.76, 0.82, p), '--cam': ramp(0.84, 0.92, p)
    };
    Object.keys(values).forEach(function (key) { player.style.setProperty(key, values[key].toFixed(3)); });
    var current = p < 0.16 ? 0 : p < 0.4 ? 1 : p < 0.75 ? 2 : 3;
    steps.forEach(function (step, index) { step.classList.toggle('on', index === current); });
  }

  var pinned = false;
  var studioVisible = false;
  function fitStudio() {
    pinned = !calm && window.innerWidth > 1020 && window.innerHeight >= 640;
    studio.classList.toggle('pinned', pinned);
    if (calm) renderStudio(0.6);
    else if (pinned) scrollStudio();
  }
  function scrollStudio() {
    var rect = studio.getBoundingClientRect();
    renderStudio(Math.min(Math.max(-rect.top / (rect.height - window.innerHeight), 0), 1));
  }
  new IntersectionObserver(function (entries) {
    studioVisible = entries[0].isIntersecting;
  }).observe(studio);
  var loopStart = performance.now();
  function loopStudio(now) {
    if (!pinned && !calm && studioVisible && !document.hidden) renderStudio(((now - loopStart) % 12000) / 12000);
    requestAnimationFrame(loopStudio);
  }
  if (!calm) requestAnimationFrame(loopStudio);
  var studioTicking = false;
  window.addEventListener('scroll', function () {
    if (!pinned || studioTicking) return;
    studioTicking = true;
    requestAnimationFrame(function () {
      scrollStudio();
      studioTicking = false;
    });
  }, { passive: true });
  window.addEventListener('resize', fitStudio);
  fitStudio();

  // Theme playground, using the app's own colors.
  var themeBand = document.getElementById('themes');
  var themes = {
    'System': null,
    'Graphite': ['#101113', '#17181b', '#1f2125', '#2c2e33', '#32343a', '#f4f3f0', '#a8abb3'],
    'Daylight': ['#eef0f4', '#f7f8fa', '#ffffff', '#e4e6eb', '#d3d6dd', '#16181d', '#555a65'],
    'Safelight': ['#180a06', '#21100a', '#2c1710', '#3d2218', '#4d2d21', '#fff3ec', '#d9b8a8'],
    'Deep Sea': ['#07171f', '#0c212b', '#122c38', '#1b3c4a', '#254b5a', '#eaf7f6', '#a5c8cb'],
    'Aurora': ['#120c24', '#1a1232', '#231943', '#322557', '#3f3168', '#f6f2ff', '#c3b8de']
  };
  var accents = { 'Safelight': '#ff6b3d', 'Teal': '#6fd3c2', 'Blue': '#7c9bff', 'Pink': '#ff8ac0', 'Sun': '#f2c14e', 'Lime': '#b5e36b' };
  var themeChoice = 'Graphite';
  var accentChoice = 'Safelight';
  var themeButtons = {};
  var accentButtons = {};

  function darkened(hex) {
    var value = parseInt(hex.slice(1), 16);
    var parts = [value >> 16, (value >> 8) & 255, value & 255].map(function (c) { return Math.round(c * 0.45); });
    return 'rgb(' + parts.join(',') + ')';
  }

  function applyTheme() {
    var name = themeChoice;
    if (name === 'System') name = window.matchMedia('(prefers-color-scheme: light)').matches ? 'Daylight' : 'Graphite';
    var colors = themes[name];
    ['--g', '--s', '--c', '--r', '--l', '--t', '--m'].forEach(function (key, index) { themeBand.style.setProperty(key, colors[index]); });
    themeBand.style.setProperty('--a', accents[accentChoice]);
    themeBand.style.setProperty('--at', name === 'Daylight' ? darkened(accents[accentChoice]) : accents[accentChoice]);
    Object.keys(themeButtons).forEach(function (key) { themeButtons[key].setAttribute('aria-pressed', String(key === themeChoice)); });
    Object.keys(accentButtons).forEach(function (key) { accentButtons[key].setAttribute('aria-pressed', String(key === accentChoice)); });
  }

  Object.keys(themes).forEach(function (name) {
    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = name;
    button.addEventListener('click', function () { themeChoice = name; applyTheme(); });
    themeButtons[name] = button;
    document.getElementById('thThemes').appendChild(button);
  });
  Object.keys(accents).forEach(function (name) {
    var button = document.createElement('button');
    button.type = 'button';
    button.style.background = accents[name];
    button.setAttribute('aria-label', name);
    button.addEventListener('click', function () { accentChoice = name; applyTheme(); });
    accentButtons[name] = button;
    document.getElementById('thAccents').appendChild(button);
  });
  applyTheme();

  // Background playground, using presets from the app.
  var bgView = document.querySelector('#bgPlay .bg-view');
  var bgHost = document.getElementById('bgSwatches');
  var bgModes = Array.prototype.slice.call(document.querySelectorAll('#bgPlay [data-mode]'));
  function blend(a, b, c) { return 'linear-gradient(135deg,#' + a + ',#' + (c ? b + ',#' + c : b) + ')'; }
  var bgSets = {
    solid: ['#ff6b3d', '#6fd3c2', '#2a2c30', '#5c8b94', '#c9694a', '#d8cdb8', '#f4f3f0', '#ef4444', '#f59e0b', '#22c55e', '#14b8a6', '#3b82f6', '#8b5cf6', '#ec4899', '#111827', '#ffffff', '#fca5a5', '#fcd34d'],
    gradient: [blend('ff8a63', 'c7a6e8'), blend('6fd3c2', '3d8bff'), blend('f2c14e', 'ff6b3d'), blend('a855f7', 'ec4899'), blend('22c55e', '14b8a6'), blend('3b82f6', '8b5cf6'), blend('ff6b3d', '6fd3c2'), blend('2a2c30', '5c8b94'), blend('15161a', 'ff6b3d'), blend('fde68a', 'fca5a5'), blend('bae6fd', 'ddd6fe'), blend('1e3a8a', '7c3aed'), blend('ff6b3d', 'ec4899', '7c3aed'), blend('22d3ee', '3b82f6', '7c3aed'), blend('f2c14e', 'f97316', 'e11d48'), blend('34d399', '06b6d4', '3b82f6'), blend('111827', '7c3aed', 'ec4899'), blend('fde68a', 'f9a8d4', 'c4b5fd')]
  };

  function setBackground(css) {
    bgView.style.background = css;
    Array.prototype.forEach.call(bgHost.children, function (button) { button.setAttribute('aria-pressed', String(button.dataset.css === css)); });
  }

  function setBackgroundMode(mode) {
    bgModes.forEach(function (button) { button.classList.toggle('on', button.dataset.mode === mode); });
    bgHost.textContent = '';
    bgView.classList.toggle('bare', mode === 'none');
    if (mode === 'none') {
      bgView.style.background = '';
      return;
    }
    bgSets[mode].forEach(function (css, index) {
      var button = document.createElement('button');
      button.type = 'button';
      button.dataset.css = css;
      button.style.background = css;
      button.setAttribute('aria-label', (mode === 'solid' ? 'Solid color ' : 'Gradient ') + (index + 1));
      button.addEventListener('click', function () { setBackground(css); });
      bgHost.appendChild(button);
    });
    setBackground(bgSets[mode][0]);
  }
  bgModes.forEach(function (button) {
    button.addEventListener('click', function () { setBackgroundMode(button.dataset.mode); });
  });
  setBackgroundMode('gradient');

  // Everything list: a short version first, with all of it one click away.
  var listGrid = document.getElementById('listGrid');
  var listMore = document.getElementById('listMore');
  listMore.hidden = false;
  listMore.addEventListener('click', function () {
    var open = listGrid.classList.toggle('open');
    listMore.setAttribute('aria-expanded', String(open));
    listMore.textContent = open ? 'Show less' : 'Show the full list';
  });

  // Latest version and direct download, with the plain release link as a fallback.
  function formatDate(value) {
    return new Date(value).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }

  function notesFrom(body) {
    return (body || '').split('\n')
      .map(function (line) { return line.trim(); })
      .filter(function (line) { return /^[-*] /.test(line); })
      .map(function (line) { return line.slice(2); });
  }

  function renderReleases(releases) {
    var host = document.getElementById('releases');
    var rendered = releases.filter(function (r) { return !r.draft && !r.prerelease; }).slice(0, 5);
    if (!rendered.length) return;
    host.textContent = '';
    rendered.forEach(function (release) {
      var article = document.createElement('article');
      article.className = 'release reveal';
      var header = document.createElement('header');
      var version = document.createElement('b');
      version.textContent = release.tag_name.replace(/^v/, '');
      var date = document.createElement('time');
      date.dateTime = release.published_at;
      date.textContent = formatDate(release.published_at);
      header.appendChild(version);
      header.appendChild(date);
      article.appendChild(header);
      var list = document.createElement('ul');
      notesFrom(release.body).forEach(function (note) {
        var item = document.createElement('li');
        var label = note.match(/^(New|Fixed|Improved|Better):\s*(.*)$/i);
        if (label) {
          var chip = document.createElement('span');
          chip.className = 'chip chip-' + label[1].toLowerCase();
          chip.textContent = label[1];
          item.appendChild(chip);
          item.appendChild(document.createTextNode(label[2]));
        } else {
          item.textContent = note;
        }
        list.appendChild(item);
      });
      article.appendChild(list);
      host.appendChild(article);
    });
    watchReveals(host);
  }

  fetch('https://api.github.com/repos/' + repo + '/releases?per_page=6', { headers: { Accept: 'application/vnd.github+json' } })
    .then(function (response) { if (!response.ok) throw new Error('status'); return response.json(); })
    .then(function (releases) {
      renderReleases(releases);
      var latest = releases.filter(function (r) { return !r.draft && !r.prerelease; })[0];
      if (!latest) return;
      var version = latest.tag_name.replace(/^v/, '');
      document.querySelectorAll('.js-version').forEach(function (el) { el.textContent = version; });
      var dmg = (latest.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      if (dmg) {
        document.querySelectorAll('.js-download').forEach(function (a) { a.href = dmg.browser_download_url; });
      }
    })
    .catch(function () { /* The links and changelog already in the page still work. */ });
})();

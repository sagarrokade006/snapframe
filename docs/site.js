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

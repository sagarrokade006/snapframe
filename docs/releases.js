(function () {
  'use strict';

  // Latest version and direct download, plus release notes, with what is already in the page as a fallback.
  var repo = 'sagarrokade006/snapframe';
  var host = document.getElementById('releases');
  var limit = host ? Number(host.dataset.limit) || 100 : 0;

  function formatDate(value) {
    return new Date(value).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }

  function notesFrom(body) {
    return (body || '').split('\n')
      .map(function (line) { return line.trim(); })
      .filter(function (line) { return /^[-*] /.test(line); })
      .map(function (line) { return line.slice(2); });
  }

  function render(releases) {
    if (!host || !releases.length) return;
    host.textContent = '';
    releases.slice(0, limit).forEach(function (release) {
      var article = document.createElement('article');
      article.className = 'release';
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
  }

  fetch('https://api.github.com/repos/' + repo + '/releases?per_page=100', { headers: { Accept: 'application/vnd.github+json' } })
    .then(function (response) { if (!response.ok) throw new Error('status'); return response.json(); })
    .then(function (all) {
      var releases = all.filter(function (r) { return !r.draft && !r.prerelease; });
      render(releases);
      var latest = releases[0];
      if (!latest) return;
      document.querySelectorAll('.js-version').forEach(function (el) { el.textContent = latest.tag_name.replace(/^v/, ''); });
      var dmg = (latest.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      if (dmg) {
        document.querySelectorAll('.js-download').forEach(function (a) { a.href = dmg.browser_download_url; });
      }
    })
    .catch(function () { /* The links and notes already in the page still work. */ });
})();

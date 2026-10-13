(() => {
  const root = document.querySelector('.mailbox');
  if (!root) return;
  const selection = [...root.querySelectorAll('.mail-check')];
  const all = root.querySelector('[data-select-all]');
  const count = root.querySelector('[data-selection-count]');
  const update = () => {
    const chosen = selection.filter(input => input.checked).length;
    if (all) { all.checked = selection.length > 0 && chosen === selection.length; all.indeterminate = chosen > 0 && chosen < selection.length; }
    if (count) count.textContent = chosen ? `${chosen} / ${selection.length}` : '';
    root.querySelectorAll('#mail-actions button').forEach(button => { button.disabled = chosen === 0; });
  };
  if (all) all.addEventListener('change', () => { selection.forEach(input => { input.checked = all.checked; }); update(); });
  selection.forEach(input => input.addEventListener('change', update));
  update();
  document.addEventListener('keydown', event => {
    if (!(event.target instanceof Element) || event.ctrlKey || event.metaKey || event.altKey || event.target.closest('input, textarea, select, [contenteditable]')) return;
    if (event.key === '/') { event.preventDefault(); root.querySelector('#mail-search')?.focus(); }
    if (event.key === 'c' && !root.querySelector('[data-compose-form]')) root.querySelector('[data-compose-link]')?.click();
  });
  const composer = root.querySelector('[data-compose-form]');
  if (composer) {
    composer.querySelector('input[name="recipient"]')?.focus();
    let changed = false;
    composer.addEventListener('input', () => { changed = true; });
    window.addEventListener('beforeunload', event => { if (changed) { event.preventDefault(); event.returnValue = ''; } });
    root.querySelectorAll('.mail-compose-form footer a').forEach(link => link.addEventListener('click', () => { changed = false; }));
    composer.addEventListener('submit', () => { changed = false; });
    composer.addEventListener('submit', () => { const button = composer.querySelector('button[type="submit"]'); if (button) button.disabled = true; });
  }
})();

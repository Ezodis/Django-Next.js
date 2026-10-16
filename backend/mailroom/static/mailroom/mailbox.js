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
  const readThread = root.dataset.readThread;
  if (readThread) {
    const data = new FormData();
    data.set('csrfmiddlewaretoken', root.querySelector('[name="csrfmiddlewaretoken"]').value);
    data.set('action', 'read');
    data.set('threads', readThread);
    fetch(root.dataset.mailboxUrl, {method: 'POST', body: data, credentials: 'same-origin', headers: {'X-Requested-With': 'XMLHttpRequest'}})
      .then(response => response.ok ? response.json() : null)
      .then(result => {
        if (!result?.ok) return;
        root.querySelector('.mail-row.selected')?.classList.remove('unread');
        root.querySelector('.mail-row.selected .mail-unread-dot')?.remove();
        const badge = root.querySelector('[data-unread-count]');
        if (badge) { badge.textContent = result.unread_count || ''; badge.hidden = !result.unread_count; }
      })
      .catch(() => {});
  }
  document.addEventListener('keydown', event => {
    if (!(event.target instanceof Element) || event.ctrlKey || event.metaKey || event.altKey || event.target.closest('input, textarea, select, [contenteditable]')) return;
    if (event.key === '/') { event.preventDefault(); root.querySelector('#mail-search')?.focus(); }
    if (event.key === 'c' && !root.querySelector('[data-compose-form]')) root.querySelector('[data-compose-link]')?.click();
    if (event.key === 'r' && !root.querySelector('[data-compose-form]')) [...root.querySelectorAll('[data-reply-link]')].at(-1)?.click();
    if (event.key === 'Escape' && !root.querySelector('[data-compose-form]')) root.querySelector('.mail-back')?.click();
    if (['j', 'k'].includes(event.key) && !root.querySelector('[data-compose-form]')) {
      const links = [...root.querySelectorAll('.mail-row-link')];
      const index = links.findIndex(link => link.getAttribute('aria-current') === 'true');
      links[index < 0 ? 0 : index + (event.key === 'j' ? 1 : -1)]?.click();
    }
  });
  const composer = root.querySelector('[data-compose-form]');
  if (composer) {
    (composer.querySelector('input[name="recipient"]')?.value ? composer.querySelector('textarea') : composer.querySelector('input[name="recipient"]'))?.focus();
    let changed = false;
    composer.addEventListener('input', () => { changed = true; });
    window.addEventListener('beforeunload', event => { if (changed) { event.preventDefault(); event.returnValue = ''; } });
    root.querySelector('[data-discard]')?.addEventListener('click', () => { changed = false; });
    let submitting = false;
    composer.addEventListener('submit', event => {
      if (submitting) { event.preventDefault(); return; }
      submitting = true;
      changed = false;
      // Preserve the chosen action when disabling the submitter before navigation.
      const action = document.createElement('input');
      action.type = 'hidden'; action.name = 'action'; action.value = event.submitter?.value || 'send';
      composer.append(action);
      composer.querySelectorAll('button[type="submit"]').forEach(button => { button.disabled = true; });
    });
  }
})();

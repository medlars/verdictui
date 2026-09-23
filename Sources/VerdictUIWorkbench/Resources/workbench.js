/* Bundled view only. The native host owns persistence, execution, and evidence. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const text = (value) => typeof value === 'string' ? value : value == null ? '' : String(value);
  const list = (value) => Array.isArray(value) ? value : [];
  const cleanStatus = (value) => ['pass', 'fail', 'unavailable', 'running'].includes(text(value).toLowerCase()) ? text(value).toLowerCase() : 'unavailable';
  const state = { connected: false, project: null, projects: [], checks: [], draft: [], history: [], report: null, dirty: false, saving: false, starting: false, running: false, cancelling: false, completed: new Set(), progress: new Map(), total: 0, active: '', view: 'overview' };
  const busy = () => state.starting || state.running || state.cancelling;
  const node = (tag, className, value) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined) element.textContent = text(value);
    return element;
  };
  const icon = (name) => {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#i-' + name);
    svg.setAttribute('aria-hidden', 'true');
    svg.append(use);
    return svg;
  };
  const copyChecks = (checks) => list(checks).filter(c => c && typeof c === 'object').map(c => ({ ...c }));
  function notice(message) {
    $('notice').textContent = text(message);
    $('notice').hidden = !message;
  }
  function post(action, fields = {}) {
    try {
      const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.verdictui;
      if (!bridge || typeof bridge.postMessage !== 'function') throw new Error('The desktop connection is unavailable. Open this workspace in the VerdictUI app.');
      bridge.postMessage({ action, ...fields });
      return true;
    } catch (error) {
      state.connected = false;
      state.starting = false;
      state.running = false;
      state.cancelling = false;
      state.saving = false;
      notice(error instanceof Error ? error.message : 'The desktop connection is unavailable.');
      renderControls();
      renderStage();
      return false;
    }
  }
  function showView(view) {
    if (!['overview', 'checks', 'history'].includes(view)) return;
    state.view = view;
    for (const button of document.querySelectorAll('[data-view]')) {
      const selected = button.dataset.view === view;
      button.classList.toggle('selected', selected);
      if (selected) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    }
    for (const name of ['overview', 'checks', 'history']) $('view-' + name).hidden = name !== view;
  }
  function renderControls() {
    const available = state.connected && Boolean(state.project);
    $('run-checks').disabled = !available || busy() || state.saving || state.dirty || state.checks.length === 0;
    $('run-checks').querySelector('span').textContent = state.starting ? 'Starting…' : state.running ? 'Running…' : 'Run checks';
    $('run-checks').title = state.dirty ? 'Save your checks before running.' : '';
    $('choose-project').disabled = !state.connected || busy() || state.saving;
    $('choose-project-icon').disabled = $('choose-project').disabled;
    $('add-check').disabled = !available || busy() || state.saving;
    $('save-checks').disabled = !available || busy() || state.saving || !state.dirty;
    $('save-checks').textContent = state.saving ? 'Saving…' : 'Save checks';
    $('save-status').textContent = state.saving ? 'Waiting for the project to save…' : state.dirty ? 'Unsaved changes' : 'No unsaved changes';
    $('setup-checks').hidden = busy();
    $('setup-checks').querySelector('span').textContent = state.checks.length ? 'Review checks' : 'Set up checks';
    $('cancel-run').hidden = !busy();
    $('cancel-run').disabled = !state.connected || state.cancelling;
    $('cancel-run').querySelector('span').textContent = state.cancelling ? 'Cancelling…' : 'Cancel run';
    $('connection-dot').classList.toggle('connected', state.connected);
    $('connection-label').textContent = state.connected ? 'Engine connected' : 'Connection unavailable';
    $('nav-check-count').textContent = String(state.draft.length);
    for (const button of document.querySelectorAll('.project-button')) button.disabled = busy() || state.saving || !state.connected;
    for (const input of document.querySelectorAll('#check-editors input, #check-editors select, #check-editors button')) input.disabled = busy() || state.saving || !available;
  }
  function renderProjects() {
    $('project-list').replaceChildren();
    for (const project of state.projects) {
      if (!project || !text(project.path)) continue;
      const button = node('button', 'project-button');
      button.type = 'button';
      button.title = text(project.path);
      button.classList.toggle('selected', project.path === state.project);
      if (project.path === state.project) button.setAttribute('aria-current', 'true');
      button.append(icon('folder'), node('span', '', project.name || project.path));
      button.addEventListener('click', () => {
        if (project.path === state.project || busy()) return;
        if (state.dirty) { notice('Save your check changes before switching projects.'); showView('checks'); return; }
        post('selectProject', { project: project.path });
      });
      $('project-list').append(button);
    }
    $('no-projects').hidden = state.projects.length > 0;
    const selected = state.projects.find(p => p && p.path === state.project);
    $('project-name').textContent = state.project ? text(selected && selected.name) || state.project.split('/').filter(Boolean).pop() || state.project : 'A clearer view of your UI.';
    $('project-path').textContent = state.project || 'Choose a project to begin.';
    $('project-path').title = state.project || '';
  }
  const fields = {
    scenario: [['scenario', 'Scenario name', 'Your registered scenario', true], ['runner', 'Runner executable', 'Optional custom runner path', false]],
    web: [['url', 'Page URL', 'https://your-product.example', true]],
    appkit: [['runner', 'Runner executable', '/path/to/your/runner', true], ['subject', 'Subject name', 'Your AppKit subject', true]],
    live: [['pid', 'Application PID', 'Process identifier', true], ['surface', 'Surface', 'window:0', false], ['expectText', 'Expected text', 'Optional text to verify in the current UI', false]]
  };
  const kindNames = { scenario: 'SwiftUI scenario', web: 'Web page', appkit: 'AppKit subject', live: 'Running macOS app' };
  function markDirty() { state.dirty = true; renderControls(); }
  function createField(check, index, key, label, placeholder, required, wide = false) {
    const wrapper = node('div', 'field' + (wide ? ' wide' : ''));
    const id = 'check-' + index + '-' + key;
    const caption = node('label', '', label + (required ? '' : ' · optional'));
    caption.htmlFor = id;
    const input = node('input');
    input.id = id;
    input.name = id;
    input.value = text(check[key]);
    input.placeholder = placeholder;
    input.required = required;
    input.autocomplete = 'off';
    input.spellcheck = false;
    if (key === 'pid') { input.type = 'number'; input.min = '2'; input.step = '1'; }
    if (key === 'url') input.type = 'url';
    input.addEventListener('input', () => {
      check[key] = key === 'pid' && input.value ? Number(input.value) : input.value;
      input.setCustomValidity('');
      if (key === 'name') for (const name of document.querySelectorAll('#check-editors input[id$="-name"]')) name.setCustomValidity('');
      markDirty();
    });
    wrapper.append(caption, input);
    return wrapper;
  }
  function renderEditors(focusIndex = null) {
    $('check-editors').replaceChildren();
    state.draft.forEach((check, index) => {
      const section = node('section', 'check-editor');
      section.setAttribute('aria-label', 'Check ' + (index + 1));
      const heading = node('div', 'editor-heading');
      heading.append(node('h3', '', 'Check ' + (index + 1)));
      const remove = node('button', 'icon-button');
      remove.type = 'button';
      remove.setAttribute('aria-label', 'Remove check ' + (index + 1));
      remove.append(icon('close'));
      remove.addEventListener('click', () => { state.draft.splice(index, 1); markDirty(); renderEditors(); $('add-check').focus(); });
      heading.append(remove);
      const grid = node('div', 'check-fields');
      grid.append(createField(check, index, 'name', 'Check name', 'A name you will recognize', true));
      const type = node('div', 'field');
      const label = node('label', '', 'Check type');
      label.htmlFor = 'check-' + index + '-kind';
      const select = node('select');
      select.id = label.htmlFor;
      for (const [value, name] of Object.entries(kindNames)) { const option = node('option', '', name); option.value = value; select.append(option); }
      select.value = fields[check.kind] ? check.kind : 'scenario';
      select.addEventListener('change', () => { check.kind = select.value; markDirty(); renderEditors(); $('check-' + index + '-kind').focus(); });
      type.append(label, select); grid.append(type);
      for (const [key, title, placeholder, required] of fields[check.kind] || fields.scenario) grid.append(createField(check, index, key, title, placeholder, required, true));
      if (check.kind === 'live') grid.append(node('p', 'field-hint', 'Reads the selected app. Declare expected text to check an observed state.'));
      section.append(heading, grid); $('check-editors').append(section);
    });
    $('checks-empty').hidden = state.draft.length > 0;
    renderControls();
    if (focusIndex !== null) $('check-' + focusIndex + '-name').focus();
  }
  function normalizedChecks() {
    const names = new Set();
    return state.draft.map((check, index) => {
      const name = text(check.name).trim();
      const input = $('check-' + index + '-name');
      if (!name || names.has(name)) {
        input.setCustomValidity(!name ? 'Enter a check name.' : 'Use a different name for each check.'); input.reportValidity();
        throw new Error('Each check needs its own name.');
      }
      names.add(name);
      const kind = fields[check.kind] ? check.kind : 'scenario';
      const result = { name, kind };
      for (const [key, , , required] of fields[kind]) {
        const value = text(check[key]).trim();
        if (required && !value) throw new Error('Complete the required fields before saving.');
        if (key === 'pid' && value) {
          const pid = Number(value);
          if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error('Application PID must be an integer greater than 1.');
          result[key] = pid;
        } else if (value) result[key] = value;
      }
      return result;
    });
  }
  function reportStatus(report) {
    if (!report || list(report.checks).length === 0) return 'unavailable';
    const status = cleanStatus(report.status);
    if (status === 'running') return 'unavailable';
    const checks = report.checks.map(c => cleanStatus(c && c.status));
    if (status === 'pass' && (report.error || report.checks.some(c => !c || c.error))) return 'unavailable';
    if (status === 'pass' && checks.some(s => s !== 'pass')) return 'unavailable';
    return status;
  }
  function renderStage() {
    let status = 'idle', label = 'Ready when you are', title = state.checks.length ? 'Put your UI\nto the test.' : 'Know what\nholds up.';
    let detail = 'Run your product’s checks. See what passed, what needs attention, and exactly where.';
    if (!state.connected) { status = 'unavailable'; label = 'Desktop app unavailable'; title = 'Reconnect your\nworkspace.'; detail = 'Open VerdictUI to connect this workspace to your local verification engine.'; }
    else if (state.starting) { label = 'Waiting for the engine'; title = 'Getting ready.'; detail = 'Your checks have been requested. Progress will appear when execution starts.'; }
    else if (state.running || state.cancelling) {
      status = 'running'; label = state.cancelling ? 'Cancellation requested' : 'Verification in progress'; title = state.cancelling ? 'Stopping\nyour checks.' : 'Looking\na little closer.';
      detail = state.cancelling ? 'Waiting for the engine to stop. Unfinished checks will remain unverified.' : 'Following each declared check and collecting the evidence as it arrives.';
    } else if (state.report) {
      status = reportStatus(state.report);
      const copy = { pass: ['Checks passed', 'Your checks\nhold up.', 'All checks in this run passed. This result covers the declared checks only.'], fail: ['Needs attention', 'Something needs\na closer look.', 'This run found an issue. Review the evidence below to see what needs to change.'], unavailable: ['Verification unavailable', 'We need\nmore evidence.', text(state.report.error) || 'One or more checks could not be verified. Review the available details below.'] }[status];
      [label, title, detail] = copy;
    }
    $('verification-stage').dataset.status = status;
    $('status-label').textContent = label;
    $('status-title').replaceChildren();
    title.split('\n').forEach((part, i) => { if (i) $('status-title').append(document.createElement('br')); $('status-title').append(document.createTextNode((i ? ' ' : '') + part)); });
    $('status-detail').textContent = detail;
    $('run-progress').hidden = !busy();
    $('progress-name').textContent = state.active || 'Preparing checks';
    const total = Math.max(state.total, state.completed.size);
    $('progress-count').textContent = state.completed.size + ' / ' + total + ' completed';
    $('progress-bar').max = Math.max(total, 1); $('progress-bar').value = state.completed.size;
    $('stage-footnote').textContent = state.dirty ? 'Save your changes before running checks.' : 'Only declared checks are measured.';
    renderControls();
  }
  function addFinding(severity, rule, nodeID, message, checkName) {
    const row = node('article', 'finding');
    const level = ['error', 'warning', 'info'].includes(text(severity).toLowerCase()) ? text(severity).toLowerCase() : 'info';
    row.append(node('span', 'severity ' + level, level));
    const body = node('div');
    body.append(node('h3', 'finding-title', rule || 'Finding'), node('p', '', message || 'No further detail was supplied.'));
    body.append(node('div', 'finding-node', (checkName ? checkName + ' · ' : '') + 'Node: ' + (text(nodeID) || 'not supplied')));
    row.append(body); $('findings').append(row);
  }
  function renderEvidence() {
    $('findings').replaceChildren(); $('check-results').replaceChildren();
    let count = 0;
    const checks = list(state.report && state.report.checks);
    const displayed = busy() ? Array.from(state.progress.values()) : checks;
    for (const check of displayed) {
      if (!check) continue;
      const status = cleanStatus(check.status);
      const chip = node('span', 'check-chip'); chip.dataset.status = status;
      chip.append(icon(status === 'pass' ? 'check' : status === 'running' ? 'lens' : 'alert'), document.createTextNode(text(check.name) + ' · ' + status));
      $('check-results').append(chip);
    }
    for (const check of checks) {
      if (!check) continue;
      for (const finding of list(check.verdict && check.verdict.findings)) {
        if (!finding) continue;
        addFinding(finding.severity, finding.rule, finding.nodeID, finding.message, check.name); count++;
      }
      if (check.error) { addFinding('warning', 'Check unavailable', '', check.error, check.name); count++; }
    }
    if (state.report && state.report.error) { addFinding('warning', 'Run unavailable', '', state.report.error, ''); count++; }
    $('finding-count').textContent = busy() ? state.completed.size + ' completed' : state.report ? count + (count === 1 ? ' finding' : ' findings') : 'No run yet';
    $('evidence-empty').hidden = count > 0;
    const heading = $('evidence-empty').querySelector('h3'), description = $('evidence-empty').querySelector('p');
    if (busy()) { heading.textContent = 'Collecting evidence.'; description.textContent = 'Completed checks appear above. Findings will be available when the run finishes.'; }
    else if (state.report && reportStatus(state.report) === 'pass') { heading.textContent = 'No findings in this run.'; description.textContent = 'The declared checks passed. Surfaces outside those checks remain unmeasured.'; }
    else if (state.report) { heading.textContent = 'No detailed findings were supplied.'; description.textContent = 'This is not a passing result. Check the reported outcome and try again when the target is available.'; }
    else { heading.textContent = 'Start with your own product.'; description.textContent = 'Add a project and declare the checks that matter. Your real results will appear here.'; }
    $('evidence-description').textContent = state.report ? 'The measured result, with its cited evidence.' : 'The result behind every verdict.';
  }
  function renderHistory() {
    $('history-list').replaceChildren();
    const entries = state.history.filter(entry => entry && (!entry.project || entry.project === state.project));
    $('history-empty').hidden = entries.length > 0;
    for (const entry of entries) {
      const row = node('article', 'history-row');
      const report = entry.report || null;
      const status = report ? reportStatus(report) : 'unavailable';
      row.append(node('span', 'severity ' + (status === 'fail' ? 'error' : status === 'pass' ? 'info' : 'warning'), status));
      const summary = node('div', 'history-summary');
      const rawDate = text(entry.timestamp), date = new Date(rawDate);
      summary.append(node('h3', '', Number.isNaN(date.valueOf()) ? rawDate || 'Saved run' : date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })));
      const count = list(report && report.checks).length;
      summary.append(node('p', '', count + (count === 1 ? ' declared check' : ' declared checks'))); row.append(summary);
      const button = node('button', 'button secondary', 'View result'); button.type = 'button'; button.disabled = !report || busy();
      button.addEventListener('click', () => { state.report = report; renderStage(); renderEvidence(); showView('overview'); });
      row.append(button); $('history-list').append(row);
    }
  }
  function receive(message) {
    if (!message || typeof message !== 'object') return;
    if (message.type === 'state') {
      const project = typeof message.selectedProject === 'string' ? message.selectedProject : null;
      const changed = project !== state.project;
      state.connected = true; state.projects = list(message.projects); state.project = project;
      state.checks = copyChecks(message.checks); state.history = list(message.history);
      if (changed || state.saving || !state.dirty) { state.draft = copyChecks(state.checks); state.dirty = false; state.saving = false; renderEditors(); }
      if (changed) { state.report = null; state.starting = false; state.running = false; state.cancelling = false; state.completed.clear(); state.progress.clear(); }
      $('version').textContent = text(message.version); notice(''); renderProjects(); renderHistory(); renderStage(); renderEvidence();
    } else if (message.type === 'progress') {
      if (!Number.isSafeInteger(message.index) || message.index < 0 || !Number.isSafeInteger(message.total)
          || message.total <= message.index || !text(message.name).trim()
          || !['running', 'pass', 'fail', 'unavailable'].includes(message.status)) {
        notice('The engine sent incomplete progress. Waiting for a complete result.'); return;
      }
      const status = cleanStatus(message.status);
      const index = message.index;
      if (status === 'running') { state.starting = false; state.running = true; state.completed.delete(index); }
      state.total = Number.isSafeInteger(message.total) && message.total >= 0 ? message.total : state.total;
      state.active = text(message.name);
      state.progress.set(index, { name: message.name, status });
      if (['pass', 'fail', 'unavailable'].includes(status)) state.completed.add(index);
      renderStage(); renderEvidence();
    } else if (message.type === 'result') {
      notice('');
      state.report = message.report && typeof message.report === 'object' ? message.report : { status: 'unavailable', checks: [], error: 'The engine returned no report.' };
      state.starting = false; state.running = false; state.cancelling = false;
      renderStage(); renderEvidence(); renderHistory();
    } else if (message.type === 'error') {
      notice(text(message.message) || 'The requested operation could not be completed.');
      if (busy()) state.report = { status: 'unavailable', checks: [], error: text(message.message) || 'The run could not be completed.' };
      state.starting = false; state.running = false; state.cancelling = false; state.saving = false;
      renderStage(); renderEvidence(); renderHistory();
    }
  }
  window.verdictui = Object.freeze({ receive });
  for (const button of document.querySelectorAll('[data-view]')) button.addEventListener('click', () => showView(button.dataset.view));
  const chooseProject = () => {
    if (state.dirty) { notice('Save your check changes before opening another project.'); showView('checks'); return; }
    post('chooseProject');
  };
  $('choose-project').addEventListener('click', chooseProject);
  $('choose-project-icon').addEventListener('click', chooseProject);
  $('setup-checks').addEventListener('click', () => { showView('checks'); $('add-check').focus(); });
  $('add-check').addEventListener('click', () => { state.draft.push({ name: '', kind: 'scenario' }); markDirty(); renderEditors(state.draft.length - 1); });
  $('checks-form').addEventListener('submit', (event) => {
    event.preventDefault();
    if (!state.connected || !state.project || busy() || state.saving) return;
    try {
      const checks = normalizedChecks(); state.saving = true; notice(''); renderControls();
      post('saveChecks', { project: state.project, checks });
    } catch (error) { notice(error.message); }
  });
  $('run-checks').addEventListener('click', () => {
    if (!state.connected || !state.project || busy() || state.dirty || !state.checks.length) return;
    state.starting = true; state.report = null; state.completed.clear(); state.progress.clear(); state.total = state.checks.length; state.active = '';
    notice(''); showView('overview'); renderStage(); renderEvidence(); renderHistory();
    post('run', { project: state.project });
  });
  $('cancel-run').addEventListener('click', () => { if (!busy() || state.cancelling) return; state.cancelling = true; renderStage(); post('cancel', { project: state.project }); });
  document.addEventListener('keydown', () => document.body.classList.add('input-keyboard'));
  document.addEventListener('pointerdown', () => document.body.classList.remove('input-keyboard'));
  renderProjects(); renderEditors(); renderStage(); renderEvidence(); renderHistory();
  post('ready');
})();

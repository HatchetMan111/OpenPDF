try{var p=JSON.parse(localStorage.getItem("opds:pdfEditorPreferences")||'{}');if(p.theme){var t=p.theme;if(t==='system'){t=window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';}document.documentElement.setAttribute('data-theme',t);}}catch(e){}

window.addEventListener('error', function (e) {
  try {
    window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke(
      'startup_diagnostic', { phase: 'frontend-error', detail: e.message || '?' }
    );
  } catch (_) {}
});
window.addEventListener('unhandledrejection', function (e) {
  try {
    var r = e.reason || {};
    window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke(
      'startup_diagnostic', { phase: 'frontend-rejection', detail: String(r.message || r) }
    );
  } catch (_) {}
});

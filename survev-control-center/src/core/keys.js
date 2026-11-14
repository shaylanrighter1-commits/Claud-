// Keyboard shortcut helpers. Combos use KeyboardEvent.code (layout-independent, safe with macOS Option).

const MOD_CODES = new Set(['ShiftLeft', 'ShiftRight', 'ControlLeft', 'ControlRight', 'AltLeft', 'AltRight', 'MetaLeft', 'MetaRight']);
export const isModifierCode = (c) => MOD_CODES.has(c);

export function comboFromEvent(e) {
  if (isModifierCode(e.code)) return null;
  const p = [];
  if (e.ctrlKey) p.push('Ctrl');
  if (e.altKey) p.push('Alt');
  if (e.shiftKey) p.push('Shift');
  if (e.metaKey) p.push('Meta');
  p.push(e.code);
  return p.join('+');
}

export function matchCombo(e, combo) {
  if (!combo || isModifierCode(e.code)) return false;
  return comboFromEvent(e) === combo;
}

const isMac = () => /Mac/i.test((globalThis.navigator && (navigator.platform || navigator.userAgent)) || '');

export function prettyCode(code) {
  if (!code) return '';
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^Digit\d$/.test(code)) return code.slice(5);
  if (/^Numpad/.test(code)) return 'Num ' + code.slice(6);
  const map = {
    ShiftLeft: 'Left Shift', ShiftRight: 'Right Shift', ControlLeft: 'Left Ctrl', ControlRight: 'Right Ctrl',
    AltLeft: isMac() ? 'Left ⌥' : 'Left Alt', AltRight: isMac() ? 'Right ⌥' : 'Right Alt',
    MetaLeft: isMac() ? 'Left ⌘' : 'Left Win', MetaRight: isMac() ? 'Right ⌘' : 'Right Win',
    ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→', Space: 'Space', Tab: 'Tab', CapsLock: 'Caps Lock',
    Backquote: '`', Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Semicolon: ';', Quote: "'",
    Comma: ',', Period: '.', Slash: '/', Backslash: '\\', Enter: 'Enter',
  };
  return map[code] || code;
}

export function prettyCombo(combo) {
  if (!combo) return 'Unbound';
  const mac = isMac();
  return combo
    .split('+')
    .map((p) => {
      if (p === 'Alt') return mac ? '⌥' : 'Alt';
      if (p === 'Shift') return mac ? '⇧' : 'Shift';
      if (p === 'Ctrl') return mac ? '⌃' : 'Ctrl';
      if (p === 'Meta') return mac ? '⌘' : 'Win';
      return prettyCode(p);
    })
    .join(mac ? ' ' : ' + ');
}

export function isTypingTarget(t) {
  if (!t || !t.tagName) return false;
  const tag = t.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || t.isContentEditable === true;
}

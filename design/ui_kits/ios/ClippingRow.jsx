// ClippingRow.jsx — canonical list row from CopiedKit/Views/ClippingRow.swift
// Exports: ClippingRow, KindIcon

const KIND_COLORS = {
  code:  '#34d399',
  link:  '#60a5fa',
  text:  '#86868b',
  image: '#c084fc',
  video: '#f472b6',
  file:  '#94a3b8',
  unknown: '#6e6e73',
};

function KindIcon({ kind, size = 18, color }) {
  const c = color || KIND_COLORS[kind] || KIND_COLORS.unknown;
  const s = size;
  const stroke = { stroke: c, strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round', fill: 'none' };
  switch (kind) {
    case 'code': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>
      </svg>);
    case 'link': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/>
        <path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/>
      </svg>);
    case 'text': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
        <polyline points="14 2 14 8 20 8"/>
        <line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>
      </svg>);
    case 'image': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <rect x="3" y="3" width="18" height="18" rx="2"/>
        <circle cx="8.5" cy="8.5" r="1.5"/>
        <polyline points="21 15 16 10 5 21"/>
      </svg>);
    case 'video': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <rect x="2" y="4" width="20" height="16" rx="2"/>
        <polygon points="10 8 16 12 10 16" fill={c} stroke="none"/>
      </svg>);
    case 'file': return (
      <svg width={s} height={s} viewBox="0 0 24 24" {...stroke}>
        <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
        <polyline points="14 2 14 8 20 8"/>
      </svg>);
    default: return null;
  }
}

function ClippingRow({ clipping, selected, onClick }) {
  const { kind = 'text', title, app, time, favorite, pinned, language, characters, words } = clipping;
  const metaBits = [];
  if (characters) metaBits.push(`${characters} characters${words ? ', ' + words + ' words' : ''}`);
  if (time) metaBits.push(time);

  return (
    <div
      onClick={onClick}
      style={{
        display: 'flex', gap: 12, padding: '14px 20px',
        borderBottom: '1px solid rgba(255,255,255,0.05)',
        background: selected ? 'rgba(45,212,191,0.08)' : 'transparent',
        cursor: 'pointer',
        alignItems: 'flex-start',
      }}
    >
      <div style={{ width: 20, marginTop: 2, flexShrink: 0 }}>
        <KindIcon kind={kind} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontSize: 15, lineHeight: 1.35, color: '#f5f5f7',
          overflow: 'hidden', display: '-webkit-box',
          WebkitLineClamp: 2, WebkitBoxOrient: 'vertical',
          wordBreak: 'break-word',
          fontFamily: kind === 'code' ? 'ui-monospace, "SF Mono", Menlo, monospace' : 'inherit',
        }}>{title}</div>
        <div style={{ display: 'flex', gap: 8, marginTop: 4, fontSize: 11, color: '#6e6e73', alignItems: 'center' }}>
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
          {metaBits.map((b, i) => <span key={i}>{b}</span>)}
        </div>
      </div>
      {favorite && <svg width="14" height="14" viewBox="0 0 24 24" fill="#fde047"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26"/></svg>}
      {pinned && <svg width="14" height="14" viewBox="0 0 24 24" fill="#fb923c"><path d="M12 2l2 6h6l-5 4 2 7-5-4-5 4 2-7-5-4h6z"/></svg>}
      {language && (
        <span style={{
          fontSize: 10, padding: '2px 8px', borderRadius: 9999,
          background: 'rgba(52,211,153,0.1)', color: '#34d399',
          alignSelf: 'flex-start', marginTop: 2, whiteSpace: 'nowrap',
        }}>{language}</span>
      )}
    </div>
  );
}

Object.assign(window, { ClippingRow, KindIcon, KIND_COLORS });

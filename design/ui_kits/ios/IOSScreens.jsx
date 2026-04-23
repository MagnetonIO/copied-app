// IOSScreens.jsx — Screen compositions for the Copied iOS app.
// Sources: CopiedIOS/Views/IOSContentView.swift + screenshots IMG_0977-0980.
// Exports: ListScreen, SidebarScreen, SettingsScreen, ActionSheet, NavBar

const DEMO_CLIPPINGS = [
  { id: 1, kind: 'text', title: 'Canonical Releases Mir 2.26 with Initial Rust Implementation of Wayland Frontend', characters: 80, words: 11, time: '16h' },
  { id: 2, kind: 'text', title: 'Want me to:\n  - A) Start the compile/test loop NOW (this is the critical path — nothing is verified yet)\n  - B) Do GitHub repos + compile/test in parallel', characters: 157, words: 26, time: '1mo' },
  { id: 3, kind: 'text', title: 'The agent was ab', characters: 16, words: 4, time: '1mo' },
  { id: 4, kind: 'text', title: '@agent-hero/agent-os', characters: 20, time: '1mo' },
  { id: 5, kind: 'text', title: 'OPENAI_API_KEY=sk-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', characters: 66, time: '1mo' },
  { id: 6, kind: 'text', title: 'nemoclaw', characters: 8, time: '1mo' },
  { id: 7, kind: 'text', title: 'What the GitHub Repos agent was doing', characters: 38, words: 7, time: '1mo' },
  { id: 8, kind: 'text', title: 'Create GitHub repos with research · 6 tool uses · 11.8k tokens', characters: 63, words: 10, time: '1mo' },
];

function NavBar({ title, leading, trailing, large = true, compact = false }) {
  return (
    <div style={{
      padding: compact ? '8px 16px 8px' : '0 16px',
      paddingTop: compact ? 8 : 0,
      background: '#000',
    }}>
      {/* Compact top action row */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        height: 32, fontSize: 17,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: '#2dd4bf' }}>{leading}</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: '#2dd4bf' }}>{trailing}</div>
      </div>
      {large && title && (
        <div style={{
          fontSize: 34, fontWeight: 700, letterSpacing: '-0.025em',
          color: '#f5f5f7', margin: '6px 0 10px', lineHeight: 1.05,
        }}>{title}</div>
      )}
    </div>
  );
}

function SearchField({ value = '', placeholder = 'Search' }) {
  return (
    <div style={{
      margin: '0 16px 12px', background: '#1c1c1e', borderRadius: 10,
      padding: '8px 12px', display: 'flex', alignItems: 'center', gap: 6,
      color: '#6e6e73', fontSize: 16,
    }}>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
        <circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/>
      </svg>
      {value || placeholder}
    </div>
  );
}

function ListScreen({ onSearch, onActions }) {
  return (
    <div style={{ background: '#000', color: '#f5f5f7', height: '100%', fontFamily: '-apple-system, "SF Pro Text", sans-serif', display: 'flex', flexDirection: 'column' }}>
      <NavBar
        title="Copied"
        leading={
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"><polyline points="15 18 9 12 15 6"/></svg>
        }
        trailing={
          <button onClick={onActions} style={{ border: 0, background: 'transparent', color: '#2dd4bf', padding: 6 }}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>
          </button>
        }
      />
      <SearchField />
      <div style={{ flex: 1, overflowY: 'auto' }}>
        {DEMO_CLIPPINGS.map(c => <ClippingRow key={c.id} clipping={c} />)}
      </div>
      {/* Tab bar */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '14px 28px 22px', borderTop: '1px solid rgba(255,255,255,0.05)',
        background: '#000',
      }}>
        <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#2dd4bf" strokeWidth="2" strokeLinecap="round"><rect x="7" y="4" width="10" height="18" rx="2"/><rect x="9" y="2" width="6" height="3" rx="1"/></svg>
        <span style={{ color: '#ff453a', fontWeight: 600, fontSize: 17 }}>500 Clippings</span>
        <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#2dd4bf" strokeWidth="2" strokeLinecap="round"><line x1="4" y1="7" x2="20" y2="7"/><circle cx="8" cy="7" r="2" fill="#000"/><line x1="4" y1="12" x2="20" y2="12"/><circle cx="16" cy="12" r="2" fill="#000"/><line x1="4" y1="17" x2="20" y2="17"/><circle cx="10" cy="17" r="2" fill="#000"/></svg>
      </div>
    </div>
  );
}

function SidebarRow({ icon, label, trail, tint }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14, padding: '10px 20px',
      fontSize: 17, color: tint || '#f5f5f7',
    }}>
      <span style={{ color: tint || '#2dd4bf', display: 'flex' }}>{icon}</span>
      <span style={{ flex: 1 }}>{label}</span>
      {trail && <span style={{ color: tint === '#ff453a' ? '#ff453a' : '#86868b' }}>{trail}</span>}
    </div>
  );
}

function SidebarScreen() {
  return (
    <div style={{ background: '#000', color: '#f5f5f7', height: '100%', fontFamily: '-apple-system, "SF Pro Text", sans-serif', paddingTop: 20 }}>
      <SidebarRow
        icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></svg>}
        label="Copied"
        trail={<span style={{ color: '#ff453a', fontWeight: 600 }}>500</span>}
      />
      <SidebarRow
        icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="7" y="4" width="10" height="18" rx="2"/><rect x="9" y="2" width="6" height="3" rx="1"/></svg>}
        label="Clipboard"
      />
      <div style={{ margin: '12px 20px', height: 1, background: 'rgba(255,255,255,0.08)' }}/>
      <SidebarRow
        icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="9"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>}
        label={<span style={{ color: '#2dd4bf' }}>New List</span>}
      />
      <div style={{ margin: '12px 20px', height: 1, background: 'rgba(255,255,255,0.08)' }}/>
      <SidebarRow
        icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#ff453a" strokeWidth="2" strokeLinecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/><path d="M10 11v6M14 11v6"/></svg>}
        label="Trash"
        trail="6"
      />
      <SidebarRow
        icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><line x1="4" y1="7" x2="20" y2="7"/><circle cx="8" cy="7" r="2" fill="#000"/><line x1="4" y1="12" x2="20" y2="12"/><circle cx="16" cy="12" r="2" fill="#000"/><line x1="4" y1="17" x2="20" y2="17"/><circle cx="10" cy="17" r="2" fill="#000"/></svg>}
        label="Settings"
      />
    </div>
  );
}

function SettingsGroup({ children }) {
  return (
    <div style={{
      margin: '0 16px 28px', background: '#1c1c1e', borderRadius: 12, overflow: 'hidden',
    }}>{children}</div>
  );
}
function SettingsRow({ label, trail, chevron = true, danger, first }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', padding: '14px 16px',
      borderTop: first ? 0 : '1px solid rgba(255,255,255,0.06)',
      fontSize: 17, color: danger ? '#ff453a' : '#f5f5f7',
    }}>
      <span style={{ flex: 1 }}>{label}</span>
      {trail && <span style={{ color: '#6e6e73', fontSize: 16, marginRight: 6 }}>{trail}</span>}
      {chevron && (
        <svg width="9" height="14" viewBox="0 0 9 14" fill="none" stroke="#48484a" strokeWidth="2" strokeLinecap="round"><polyline points="1 1 7 7 1 13"/></svg>
      )}
    </div>
  );
}

function SettingsScreen({ onDone }) {
  return (
    <div style={{ background: '#000', color: '#f5f5f7', height: '100%', fontFamily: '-apple-system, "SF Pro Text", sans-serif', overflow: 'auto' }}>
      <div style={{
        display: 'grid', gridTemplateColumns: '1fr auto 1fr', alignItems: 'center',
        padding: '14px 16px', borderBottom: '1px solid rgba(255,255,255,0.05)',
      }}>
        <div/>
        <div style={{ fontSize: 17, fontWeight: 600 }}>Settings</div>
        <button onClick={onDone} style={{ justifySelf: 'end', border: 0, background: 'transparent', color: '#2dd4bf', fontSize: 17, fontWeight: 600, padding: 0 }}>Done</button>
      </div>
      <div style={{ padding: '24px 0 32px' }}>
        <SettingsGroup>
          <SettingsRow label="General" first/>
          <SettingsRow label="Interface" />
        </SettingsGroup>
        <SettingsGroup>
          <SettingsRow label="iCloud Sync" trail="Disabled" first/>
        </SettingsGroup>
        <SettingsGroup>
          <SettingsRow label="Siri Shortcuts" first/>
          <SettingsRow label="Rules" />
          <SettingsRow label="Text Formatters" />
          <SettingsRow label="Merge Scripts" />
        </SettingsGroup>
        <SettingsGroup>
          <SettingsRow label="Documentation" chevron={false} first/>
        </SettingsGroup>
        <SettingsGroup>
          <SettingsRow label="Rate Copied" chevron={false} first/>
          <SettingsRow label="Email Support" chevron={false} />
          <SettingsRow label="Licenses" chevron={false} />
          <SettingsRow label="Privacy Policy" chevron={false} />
        </SettingsGroup>
        <div style={{ textAlign: 'center', fontSize: 13, color: '#6e6e73', marginTop: 8 }}>Copied 4.0.4 (1409)</div>
      </div>
    </div>
  );
}

function ActionRow({ icon, label, onClick }) {
  return (
    <div onClick={onClick} style={{
      display: 'flex', alignItems: 'center', gap: 14, padding: '16px 20px',
      borderTop: '1px solid rgba(255,255,255,0.06)', fontSize: 17, color: '#f5f5f7', cursor: 'pointer',
    }}>
      <span style={{ color: '#2dd4bf', display: 'flex', width: 20, justifyContent: 'center' }}>{icon}</span>
      <span>{label}</span>
    </div>
  );
}

function ActionSheet({ onClose }) {
  return (
    <div style={{
      position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column',
      justifyContent: 'flex-end', background: 'rgba(0,0,0,0.4)', backdropFilter: 'blur(2px)',
      zIndex: 30,
    }} onClick={onClose}>
      <div onClick={e => e.stopPropagation()} style={{ padding: '0 10px 16px' }}>
        <div style={{
          background: 'rgba(40,40,40,0.92)', backdropFilter: 'blur(30px)',
          borderRadius: 14, overflow: 'hidden',
        }}>
          <ActionRow icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="#2dd4bf"><rect width="24" height="24" rx="5"/><path d="M12 6v12M6 12h12" stroke="#000" strokeWidth="2.5" strokeLinecap="round"/></svg>} label="New Clipping"/>
          <ActionRow icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="#2dd4bf"><rect width="24" height="24" rx="5"/><polyline points="6 12 10 16 18 8" fill="none" stroke="#000" strokeWidth="2.5" strokeLinecap="round"/></svg>} label="Select Clippings"/>
          <ActionRow icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#2dd4bf" strokeWidth="2" strokeLinecap="round"><rect x="2" y="4" width="20" height="16" rx="3"/><line x1="6" y1="9" x2="18" y2="9"/><line x1="6" y1="13" x2="18" y2="13"/><line x1="6" y1="17" x2="14" y2="17"/></svg>} label="Hide List Clippings"/>
          <ActionRow icon={<svg width="20" height="20" viewBox="0 0 24 24" fill="#2dd4bf"><rect width="24" height="24" rx="5"/><path d="M8 17V7m0 0l-3 3m3-3l3 3M16 7v10m0 0l3-3m-3 3l-3-3" fill="none" stroke="#000" strokeWidth="2.5" strokeLinecap="round"/></svg>} label="Sort List"/>
        </div>
        <div onClick={onClose} style={{
          background: 'rgba(40,40,40,0.92)', backdropFilter: 'blur(30px)',
          borderRadius: 14, marginTop: 8, textAlign: 'center',
          padding: '16px', fontSize: 17, fontWeight: 600, color: '#f5f5f7', cursor: 'pointer',
        }}>Cancel</div>
      </div>
    </div>
  );
}

Object.assign(window, { ListScreen, SidebarScreen, SettingsScreen, ActionSheet, NavBar });

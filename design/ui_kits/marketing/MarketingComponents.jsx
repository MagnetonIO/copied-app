// MarketingComponents.jsx — recreation of getcopied.app landing components
// Source: getcopied-app/components/Nav.tsx + Footer.tsx + app/page.tsx
// Exports: Nav, Footer, Hero, AppPreview, Features, CodeDemo, Shortcuts, Download

function LogoMark({ size = 28 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: size * 0.25,
      background: 'linear-gradient(135deg,#2dd4bf 0%,#0d9488 100%)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      <svg width={size*0.5} height={size*0.5} viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.5" strokeLinecap="round">
        <path d="M16 4h2a2 2 0 012 2v14a2 2 0 01-2 2H6a2 2 0 01-2-2V6a2 2 0 012-2h2"/>
        <rect x="8" y="2" width="8" height="4" rx="1"/>
      </svg>
    </div>
  );
}

function Nav() {
  return (
    <nav style={{
      position: 'sticky', top: 0, zIndex: 50, backdropFilter: 'blur(20px)',
      background: 'rgba(0,0,0,0.7)', borderBottom: '1px solid rgba(255,255,255,0.05)',
    }}>
      <div style={{
        maxWidth: 1152, margin: '0 auto', padding: '0 24px', height: 56,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      }}>
        <a style={{ display: 'flex', alignItems: 'center', gap: 8, textDecoration: 'none' }}>
          <LogoMark/>
          <span style={{ fontWeight: 600, fontSize: 14, letterSpacing: '-0.01em', color: '#f5f5f7' }}>Copied</span>
        </a>
        <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
          <a style={linkStyle}>Features</a>
          <a style={linkStyle}>Blog</a>
          <a style={linkStyle}>Support</a>
          <a style={linkStyle}>Download</a>
          <a style={{ fontSize: 14, padding: '6px 16px', borderRadius: 9999, background: '#fff', color: '#000', fontWeight: 500, textDecoration: 'none' }}>Get Copied</a>
        </div>
      </div>
    </nav>
  );
}
const linkStyle = { fontSize: 14, color: '#86868b', textDecoration: 'none', cursor: 'pointer' };

function Pill({ dot, children }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 8, padding: '4px 12px',
      borderRadius: 9999, background: 'rgba(255,255,255,0.05)',
      border: '1px solid rgba(255,255,255,0.1)', fontSize: 12, color: '#86868b',
    }}>
      {dot && <span style={{ width: 6, height: 6, borderRadius: 9999, background: '#34d399' }}/>}
      {children}
    </span>
  );
}

function ClipRow({ icon, color, label, badge, time, shortcut }) {
  const iconMap = {
    code: <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>,
    link: <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg>,
    text: <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>,
    image: <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>,
  };
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px', borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
      <span style={{ fontSize: 10, color: '#6e6e73', fontFamily: 'ui-monospace, Menlo', width: 16, textAlign: 'right' }}>⌘{shortcut}</span>
      <span style={{ color }}>{iconMap[icon]}</span>
      <span style={{ fontSize: 14, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{label}</span>
      {badge && <span style={{ fontSize: 10, padding: '2px 8px', borderRadius: 9999, background: 'rgba(52,211,153,0.1)', color: '#34d399' }}>{badge}</span>}
      <span style={{ fontSize: 10, color: '#6e6e73' }}>{time}</span>
    </div>
  );
}

function AppPreview() {
  return (
    <div style={{
      borderRadius: 16, border: '1px solid rgba(255,255,255,0.1)', background: '#1a1a1a',
      boxShadow: '0 40px 80px -20px rgba(0,0,0,0.6)', overflow: 'hidden',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 16px', borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <div style={{ width: 12, height: 12, borderRadius: 9999, background: '#ff5f57' }}/>
          <div style={{ width: 12, height: 12, borderRadius: 9999, background: '#febc2e' }}/>
          <div style={{ width: 12, height: 12, borderRadius: 9999, background: '#28c840' }}/>
        </div>
        <div style={{ flex: 1, textAlign: 'center', fontSize: 12, color: '#6e6e73' }}>Copied</div>
      </div>
      <div style={{ padding: '12px 16px', borderBottom: '1px solid rgba(255,255,255,0.05)', display: 'flex', gap: 8, alignItems: 'center', color: '#6e6e73', fontSize: 14 }}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg>
        Search clippings...
      </div>
      <ClipRow icon="code" color="#34d399" label="func fetchUser()" badge="Swift" time="2s" shortcut="1"/>
      <ClipRow icon="link" color="#60a5fa" label="https://api.example.com/v2" time="45s" shortcut="2"/>
      <ClipRow icon="text" color="#6e6e73" label="Meeting notes from standup — discussed..." time="3m" shortcut="3"/>
      <ClipRow icon="image" color="#c084fc" label="Screenshot 1024 x 768" time="12m" shortcut="4"/>
      <div style={{ padding: '8px 16px', borderTop: '1px solid rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', justifyContent: 'space-between', fontSize: 10, color: '#6e6e73' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><span style={{ width: 6, height: 6, borderRadius: 9999, background: '#34d399' }}/>Monitoring</span>
        <span>Ctrl+Shift+C</span>
      </div>
    </div>
  );
}

function Hero() {
  return (
    <section style={{ padding: '128px 24px 80px' }}>
      <div style={{ maxWidth: 960, margin: '0 auto', textAlign: 'center' }}>
        <Pill dot>Now available for macOS</Pill>
        <h1 style={{ fontSize: 72, fontWeight: 700, letterSpacing: '-0.03em', lineHeight: 1.05, margin: '28px 0 24px' }}>
          Your clipboard,<br/>
          <span style={{ background: 'linear-gradient(90deg,#34d399,#2dd4bf,#22d3ee)', WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent' }}>supercharged.</span>
        </h1>
        <p style={{ fontSize: 20, color: '#86868b', maxWidth: 640, margin: '0 auto 40px', lineHeight: 1.55 }}>
          Copied auto-detects code, searches your history instantly, transforms text on the fly, and syncs across all your Macs.
        </p>
        <div style={{ display: 'flex', gap: 16, justifyContent: 'center', marginBottom: 64 }}>
          <a style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '14px 32px', borderRadius: 9999, background: '#fff', color: '#000', fontWeight: 600, fontSize: 16, textDecoration: 'none' }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>
            Download for Mac
          </a>
          <a style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '14px 24px', borderRadius: 9999, border: '1px solid rgba(255,255,255,0.2)', color: 'rgba(255,255,255,0.8)', fontWeight: 500, fontSize: 16, textDecoration: 'none' }}>View on GitHub</a>
        </div>
        <div style={{ maxWidth: 512, margin: '0 auto' }}>
          <AppPreview/>
        </div>
      </div>
    </section>
  );
}

const FEATURES = [
  { title: 'Code Detection', desc: 'Auto-detects 25+ languages. Code snippets get monospaced preview with language badges.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg> },
  { title: 'Fuzzy Search', desc: 'Sublime Text-style matching. Type a few characters to find any clipping instantly.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg> },
  { title: 'Smart Transforms', desc: 'JSON format, URL encode, UPPERCASE, strip markdown, and more. One click.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"><path d="M12 20h9M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg> },
  { title: 'iCloud Sync', desc: 'Your clipboard history syncs across all your Macs automatically via iCloud.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg> },
  { title: 'Keyboard First', desc: 'Arrow keys navigate, Enter copies, ⌘1–9 for quick paste. No mouse needed.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2" y="7" width="20" height="14" rx="2"/><path d="M16 3l-4 4-4-4"/></svg> },
  { title: 'Favorites & Pins', desc: 'Star important clippings, pin items to the top. Never lose what matters.',
    icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg> },
];

function Features() {
  return (
    <section style={{ padding: '96px 24px' }}>
      <div style={{ maxWidth: 1120, margin: '0 auto' }}>
        <div style={{ textAlign: 'center', marginBottom: 64 }}>
          <h2 style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.02em', margin: 0 }}>
            Everything you copy.<br/>
            <span style={{ color: '#86868b' }}>Nothing you lose.</span>
          </h2>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 16 }}>
          {FEATURES.map((f,i) => (
            <div key={i} style={{ padding: 24, borderRadius: 16, background: '#1a1a1a', border: '1px solid rgba(255,255,255,0.05)' }}>
              <div style={{ width: 40, height: 40, borderRadius: 12, background: 'rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#86868b', marginBottom: 16 }}>{f.icon}</div>
              <h3 style={{ fontSize: 16, fontWeight: 600, margin: '0 0 8px' }}>{f.title}</h3>
              <p style={{ fontSize: 14, color: '#86868b', lineHeight: 1.55, margin: 0 }}>{f.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function CodeDemo() {
  return (
    <section style={{ padding: '96px 24px', background: '#111' }}>
      <div style={{ maxWidth: 960, margin: '0 auto' }}>
        <div style={{ textAlign: 'center', marginBottom: 48 }}>
          <h2 style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.02em', margin: '0 0 16px' }}>Knows your code.</h2>
          <p style={{ color: '#86868b', fontSize: 18, margin: 0 }}>Copy a function, get syntax-aware preview with language detection.</p>
        </div>
        <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
          <div style={{ flex: 1, borderRadius: 16, border: '1px solid rgba(255,255,255,0.1)', background: '#000', overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 16px', borderBottom: '1px solid rgba(255,255,255,0.05)', fontSize: 12, color: '#6e6e73' }}>
              <span style={{ width: 8, height: 8, borderRadius: 9999, background: '#34d399' }}/>Detected: Swift
            </div>
            <pre style={{ padding: 16, fontSize: 13, fontFamily: 'ui-monospace, Menlo', color: 'rgba(110,231,183,0.9)', lineHeight: 1.6, margin: 0, overflow: 'auto' }}>
{`func fetchClippings() async throws {
    let descriptor = FetchDescriptor<Clipping>(
        sortBy: [SortDescriptor(\\.addDate, order: .reverse)]
    )
    let results = try modelContext.fetch(descriptor)
    self.clippings = results
}`}
            </pre>
          </div>
          <div style={{ padding: '32px 0', color: '#6e6e73', fontSize: 24 }}>→</div>
          <div style={{ flex: 1, borderRadius: 16, border: '1px solid rgba(255,255,255,0.1)', background: '#1a1a1a', padding: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
              <span style={{ color: '#34d399' }}><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg></span>
              <span style={{ fontSize: 14, fontWeight: 500 }}>func fetchClippings()</span>
            </div>
            <div style={{ fontSize: 12, fontFamily: 'ui-monospace, Menlo', color: '#86868b', lineHeight: 1.6, marginBottom: 12 }}>let descriptor = FetchDescriptor&lt;Clipping&gt;(...</div>
            <span style={{ fontSize: 10, padding: '2px 8px', borderRadius: 9999, background: 'rgba(52,211,153,0.1)', color: '#34d399' }}>Swift</span>
          </div>
        </div>
      </div>
    </section>
  );
}

function Kbd({ k }) {
  return <kbd style={{ padding: '6px 10px', borderRadius: 8, background: '#1a1a1a', border: '1px solid rgba(255,255,255,0.1)', fontSize: 12, fontFamily: 'ui-monospace, Menlo', color: '#86868b', boxShadow: '0 1px 0 rgba(0,0,0,0.25)', minWidth: 14, textAlign: 'center', display: 'inline-block' }}>{k}</kbd>;
}

function Shortcuts() {
  const rows = [
    [['Ctrl','Shift','C'], 'Toggle Copied'], [['Enter'], 'Copy & close'],
    [['⌘','1–9'], 'Quick paste'], [['↑','↓'], 'Navigate'],
    [['Esc'], 'Dismiss'], [['Type'], 'Fuzzy search'],
  ];
  return (
    <section style={{ padding: '96px 24px', textAlign: 'center' }}>
      <div style={{ maxWidth: 896, margin: '0 auto' }}>
        <h2 style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.02em', margin: '0 0 16px' }}>Keyboard first.</h2>
        <p style={{ color: '#86868b', fontSize: 18, marginBottom: 48 }}>Every action has a shortcut. Your hands never leave the keyboard.</p>
        <div style={{ display: 'inline-grid', gridTemplateColumns: '1fr 1fr', gap: '24px 64px', textAlign: 'left' }}>
          {rows.map(([keys, label], i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
              <div style={{ display: 'flex', gap: 4 }}>{keys.map((k,j) => <Kbd key={j} k={k}/>)}</div>
              <span style={{ fontSize: 14, color: '#86868b' }}>{label}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Download() {
  return (
    <section style={{ padding: '96px 24px', background: '#111', textAlign: 'center' }}>
      <div style={{ maxWidth: 768, margin: '0 auto' }}>
        <h2 style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.02em', margin: '0 0 16px' }}>Ready to try?</h2>
        <p style={{ color: '#86868b', fontSize: 18, marginBottom: 40 }}>Free during development. macOS 15+ required.</p>
        <div style={{ display: 'flex', gap: 16, justifyContent: 'center' }}>
          <a style={{ display: 'inline-flex', alignItems: 'center', gap: 12, padding: '16px 32px', borderRadius: 16, background: '#fff', color: '#000', fontWeight: 600, fontSize: 16, textDecoration: 'none' }}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>
            Download Installer <span style={{ fontSize: 12, color: 'rgba(0,0,0,0.5)', fontWeight: 400 }}>.pkg</span>
          </a>
          <a style={{ display: 'inline-flex', alignItems: 'center', gap: 12, padding: '16px 24px', borderRadius: 16, border: '1px solid rgba(255,255,255,0.2)', color: 'rgba(255,255,255,0.8)', fontSize: 16, textDecoration: 'none' }}>
            Unlock iCloud Sync <span style={{ fontSize: 12, color: 'rgba(255,255,255,0.3)', fontWeight: 400 }}>$4.99</span>
          </a>
        </div>
        <p style={{ marginTop: 24, fontSize: 12, color: '#6e6e73' }}>Requires macOS Sequoia (15.0) or later. Apple Silicon &amp; Intel supported.</p>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer style={{ padding: '48px 24px', borderTop: '1px solid rgba(255,255,255,0.05)' }}>
      <div style={{ maxWidth: 1152, margin: '0 auto', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <LogoMark size={20}/>
          <span style={{ fontSize: 14, color: '#86868b' }}>Copied — by Magneton Labs</span>
        </div>
        <div style={{ display: 'flex', gap: 20, fontSize: 14, color: '#6e6e73' }}>
          <a style={{ color: '#6e6e73', textDecoration: 'none' }}>Support</a>
          <a style={{ color: '#6e6e73', textDecoration: 'none' }}>Privacy</a>
          <a style={{ color: '#6e6e73', textDecoration: 'none' }}>Terms</a>
          <a style={{ color: '#6e6e73', textDecoration: 'none' }}>GitHub</a>
          <span>© 2026 Magneton Labs, LLC</span>
        </div>
      </div>
    </footer>
  );
}

Object.assign(window, { Nav, Hero, AppPreview, Features, CodeDemo, Shortcuts, Download, Footer, LogoMark });

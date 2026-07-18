// FlashOS Tour: static chapter reader and Rust source scratchpad.

const state = {
    chapters: [],
    currentChapterIndex: 0,
    currentExample: null,
    themeMode: 'auto',
    theme: 'dark',
    layout: 'split',
    sourceEditor: null,
    contractEditor: null,
    editorLoaded: false
};

const dom = {
    chaptersList: document.getElementById('chapters-list'),
    chapterContent: document.getElementById('chapter-content'),
    prevBtn: document.getElementById('prev-btn'),
    nextBtn: document.getElementById('next-btn'),
    themeToggle: document.getElementById('theme-toggle'),
    layoutToggle: document.getElementById('layout-toggle'),
    loadExampleBtn: document.getElementById('load-example-btn'),
    clearTerminal: document.getElementById('clear-terminal'),
    terminalBody: document.getElementById('terminal-body'),
    terminalStatus: document.getElementById('terminal-status'),
    workspacePane: document.querySelector('.workspace-pane'),
    contentPanel: document.getElementById('content-panel'),
    tabButtons: document.querySelectorAll('.tab-btn'),
    tabContents: document.querySelectorAll('.tab-content'),
    sourceEditorContainer: document.getElementById('editor-container'),
    contractEditorContainer: document.getElementById('output-container'),
    sidebar: document.getElementById('sidebar'),
    sidebarToggle: document.getElementById('sidebar-toggle'),
    sidebarBackdrop: document.getElementById('sidebar-backdrop'),
    terminalDrawer: document.getElementById('terminal-drawer'),
    terminalHeader: document.getElementById('terminal-header')
};

const mobileQuery = window.matchMedia('(max-width: 992px)');
const phoneQuery = window.matchMedia('(max-width: 600px)');

function layoutEditors() {
    if (state.sourceEditor) state.sourceEditor.layout();
    if (state.contractEditor) state.contractEditor.layout();
}

function setSidebarOpen(open) {
    dom.sidebar.classList.toggle('open', open);
    dom.sidebarBackdrop.classList.toggle('visible', open);
    dom.sidebarToggle.setAttribute('aria-expanded', String(open));
}

function setTerminalCollapsed(collapsed) {
    dom.terminalDrawer.classList.toggle('collapsed', collapsed);
    setTimeout(layoutEditors, 280);
}

function initDrawers() {
    dom.sidebarToggle.addEventListener('click', () => {
        setSidebarOpen(!dom.sidebar.classList.contains('open'));
    });
    dom.sidebarBackdrop.addEventListener('click', () => setSidebarOpen(false));
    mobileQuery.addEventListener('change', event => {
        if (!event.matches) setSidebarOpen(false);
    });
    dom.terminalHeader.addEventListener('click', event => {
        if (!event.target.closest('#clear-terminal')) {
            setTerminalCollapsed(!dom.terminalDrawer.classList.contains('collapsed'));
        }
    });
    if (phoneQuery.matches) setTerminalCollapsed(true);
}

function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
}

function applyResolvedTheme(theme) {
    state.theme = theme;
    document.body.classList.toggle('dark-theme', theme === 'dark');
    document.body.classList.toggle('light-theme', theme === 'light');
    if (state.editorLoaded && window.monaco) {
        monaco.editor.setTheme(theme === 'dark' ? 'atomo-one-dark' : 'atomo-one-light');
        highlightRustBlocks(dom.chapterContent);
    }
}

function setThemeMode(mode) {
    state.themeMode = mode;
    localStorage.setItem('theme', mode);
    dom.themeToggle.dataset.mode = mode;
    dom.themeToggle.setAttribute('aria-label', `Theme: ${mode} (click to cycle auto/light/dark)`);
    dom.themeToggle.title = `Theme: ${mode}`;
    applyResolvedTheme(mode === 'auto' ? getSystemTheme() : mode);
}

function setLayout(layout) {
    state.layout = layout;
    localStorage.setItem('layout', layout);
    dom.workspacePane.classList.remove('reader-only', 'editor-only');
    if (layout === 'reader') dom.workspacePane.classList.add('reader-only');
    if (layout === 'editor') dom.workspacePane.classList.add('editor-only');
    setTimeout(layoutEditors, 250);
}

function switchTab(tabName) {
    dom.tabButtons.forEach(button => {
        button.classList.toggle('active', button.dataset.tab === tabName);
    });
    dom.tabContents.forEach(content => {
        content.classList.toggle('active', content.id === `tab-${tabName}`);
    });
    setTimeout(layoutEditors, 50);
}

function initControls() {
    setThemeMode(localStorage.getItem('theme') || 'auto');
    setLayout(localStorage.getItem('layout') || 'split');

    dom.themeToggle.addEventListener('click', () => {
        const modes = ['auto', 'light', 'dark'];
        setThemeMode(modes[(modes.indexOf(state.themeMode) + 1) % modes.length]);
    });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        if (state.themeMode === 'auto') applyResolvedTheme(getSystemTheme());
    });
    dom.layoutToggle.addEventListener('click', () => {
        const layouts = ['split', 'reader', 'editor'];
        setLayout(layouts[(layouts.indexOf(state.layout) + 1) % layouts.length]);
    });
    dom.tabButtons.forEach(button => {
        button.addEventListener('click', () => switchTab(button.dataset.tab));
    });
}

function initMonaco() {
    require.config({ paths: { vs: 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.39.0/min/vs' } });
    require(['vs/editor/editor.main'], () => {
        monaco.editor.defineTheme('atomo-one-dark', {
            base: 'vs-dark',
            inherit: true,
            rules: [],
            colors: {
                'editor.background': '#282c34',
                'editor.foreground': '#abb2bf',
                'editor.lineHighlightBackground': '#2c313c',
                'editorCursor.foreground': '#528bff',
                'editor.selectionBackground': '#3e4451'
            }
        });
        monaco.editor.defineTheme('atomo-one-light', {
            base: 'vs',
            inherit: true,
            rules: [],
            colors: {
                'editor.background': '#fafafa',
                'editor.foreground': '#383a42',
                'editor.lineHighlightBackground': '#f0f0f0',
                'editorCursor.foreground': '#526fff',
                'editor.selectionBackground': '#e1e1e1'
            }
        });

        const fontSize = phoneQuery.matches ? 16 : 13;
        const lineHeight = phoneQuery.matches ? 24 : 20;
        const theme = state.theme === 'dark' ? 'atomo-one-dark' : 'atomo-one-light';
        state.sourceEditor = monaco.editor.create(dom.sourceEditorContainer, {
            value: `#![no_std]\n\n// Load a Rust example from the selected chapter,\n// or use this pane as a source scratchpad.\n\n#[no_mangle]\npub extern "C" fn example() -> usize {\n    42\n}\n`,
            language: 'rust',
            theme,
            automaticLayout: true,
            fontFamily: 'JetBrains Mono, Fira Code, monospace',
            fontSize,
            lineHeight,
            minimap: { enabled: false }
        });
        state.contractEditor = monaco.editor.create(dom.contractEditorContainer, {
            value: `# Native production and verification commands\n\ncargo xtask build --board rpi4b\ncargo xtask armstub\ncargo xtask test\ncargo xtask check-hygiene\n\n# Full unattended boot contract (after sourcing flashos.zsh)\nrun watchdog rpi4b\n`,
            language: 'shell',
            theme,
            readOnly: true,
            automaticLayout: true,
            fontFamily: 'JetBrains Mono, Fira Code, monospace',
            fontSize,
            lineHeight,
            minimap: { enabled: false }
        });
        state.editorLoaded = true;
        highlightRustBlocks(dom.chapterContent);
    });
}

function renderChaptersSidebar() {
    dom.chaptersList.innerHTML = '';
    state.chapters.forEach((chapter, index) => {
        const button = document.createElement('button');
        button.className = `nav-item ${index === state.currentChapterIndex ? 'active' : ''}`;
        button.textContent = chapter.title;
        button.addEventListener('click', () => selectChapter(index));
        dom.chaptersList.appendChild(button);
    });
}

function extractFirstRustExample(markdown) {
    const match = markdown.match(/```rust\s*\n([\s\S]*?)```/i);
    return match ? match[1].trimEnd() + '\n' : null;
}

function createMarkdownRenderer() {
    const renderer = new marked.Renderer();
    renderer.code = function (codeOrToken, language) {
        const code = typeof codeOrToken === 'object' ? (codeOrToken.text || '') : (codeOrToken || '');
        const lang = typeof codeOrToken === 'object' ? (codeOrToken.lang || '') : (language || '');
        const escaped = code
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
        return `<pre><code class="language-${lang || 'text'}">${escaped}</code></pre>`;
    };
    renderer.blockquote = function (token) {
        const text = typeof token === 'object' ? (token.text || '') : (token || '');
        const html = typeof token === 'object' ? this.parser.parse(token.tokens) : token;
        const match = text.match(/\[!(NOTE|TIP|WARNING|CAUTION|IMPORTANT)\]/i);
        if (!match) return `<blockquote>${html}</blockquote>`;
        const title = match[1].toUpperCase();
        const warning = title === 'WARNING' || title === 'CAUTION';
        const cleaned = html.replace(/\[![A-Z]+\]/i, '');
        return `<div class="callout ${warning ? 'callout-warning' : 'callout-note'}"><div class="callout-title">${title}</div>${cleaned}</div>`;
    };
    return renderer;
}

async function highlightRustBlocks(root) {
    if (!state.editorLoaded || !window.monaco) return;
    const blocks = (root || document).querySelectorAll('pre code.language-rust');
    for (const block of blocks) {
        if (block.dataset.raw === undefined) block.dataset.raw = block.textContent;
        block.innerHTML = await monaco.editor.colorize(block.dataset.raw, 'rust', { tabSize: 4 });
    }
}

async function selectChapter(index) {
    if (index < 0 || index >= state.chapters.length) return;
    state.currentChapterIndex = index;
    const chapter = state.chapters[index];
    dom.chaptersList.querySelectorAll('.nav-item').forEach((item, itemIndex) => {
        item.classList.toggle('active', itemIndex === index);
    });
    dom.prevBtn.disabled = index === 0;
    dom.nextBtn.disabled = index === state.chapters.length - 1;
    if (mobileQuery.matches) setSidebarOpen(false);
    window.location.hash = chapter.id;
    dom.chapterContent.innerHTML = `<div class="content-loading"><div class="spinner"></div><p>Loading chapter: ${chapter.title}...</p></div>`;
    try {
        const response = await fetch(chapter.file);
        if (!response.ok) throw new Error(`Status: ${response.status}`);
        const markdown = await response.text();
        state.currentExample = extractFirstRustExample(markdown);
        marked.setOptions({ gfm: true, breaks: true });
        dom.chapterContent.innerHTML = marked.parse(markdown, { renderer: createMarkdownRenderer() });
        lucide.createIcons();
        await highlightRustBlocks(dom.chapterContent);
        dom.contentPanel.querySelector('.content-body').scrollTop = 0;
        dom.loadExampleBtn.disabled = !state.currentExample;
        dom.loadExampleBtn.title = state.currentExample
            ? 'Load the first Rust example from this chapter'
            : 'This chapter has no Rust code block';
    } catch (error) {
        state.currentExample = null;
        dom.loadExampleBtn.disabled = true;
        dom.chapterContent.innerHTML = `<div class="callout callout-warning"><div class="callout-title">Error Loading Content</div><p>${error.message}</p></div>`;
    }
}

async function loadChapters() {
    try {
        const response = await fetch('chapters.json');
        if (!response.ok) throw new Error(`Status: ${response.status}`);
        state.chapters = await response.json();
        renderChaptersSidebar();
        const id = window.location.hash.substring(1);
        const index = state.chapters.findIndex(chapter => chapter.id === id);
        await selectChapter(index >= 0 ? index : 0);
    } catch (error) {
        dom.chaptersList.innerHTML = `<div class="nav-loading">Unable to load chapters: ${error.message}</div>`;
    }
}

function updateTerminal(message, status = 'Ready') {
    dom.terminalBody.textContent = message;
    dom.terminalStatus.className = 'status-indicator idle';
    dom.terminalStatus.textContent = status;
}

document.addEventListener('DOMContentLoaded', () => {
    lucide.createIcons();
    initControls();
    initDrawers();
    initMonaco();
    loadChapters();

    dom.loadExampleBtn.addEventListener('click', () => {
        if (!state.currentExample || !state.sourceEditor) return;
        state.sourceEditor.setValue(state.currentExample);
        switchTab('editor');
        updateTerminal('Loaded the first Rust code block from the current chapter. Use the repository commands in “Build Contract” for real compilation and verification.', 'Loaded');
    });
    dom.clearTerminal.addEventListener('click', event => {
        event.stopPropagation();
        updateTerminal('Tour notes cleared.', 'Idle');
    });
    dom.prevBtn.addEventListener('click', () => selectChapter(state.currentChapterIndex - 1));
    dom.nextBtn.addEventListener('click', () => selectChapter(state.currentChapterIndex + 1));
    window.addEventListener('hashchange', () => {
        const id = window.location.hash.substring(1);
        const index = state.chapters.findIndex(chapter => chapter.id === id);
        if (index >= 0 && index !== state.currentChapterIndex) selectChapter(index);
    });
});

// ==========================================================================
// App State & DOM References
// ==========================================================================
let state = {
    chapters: [],
    currentChapterIndex: 0,
    themeMode: 'auto', // 'auto' | 'light' | 'dark' — what the user picked
    theme: 'dark', // 'dark' | 'light' — resolved theme actually applied
    layout: 'split', // 'split' | 'reader' | 'editor'
    flashEditor: null,
    zigEditor: null,
    editorLoaded: false,
    backend: true // false on static hosting (GitHub Pages) — no transpile API
};

const dom = {
    chaptersList: document.getElementById('chapters-list'),
    chapterContent: document.getElementById('chapter-content'),
    prevBtn: document.getElementById('prev-btn'),
    nextBtn: document.getElementById('next-btn'),
    themeToggle: document.getElementById('theme-toggle'),
    layoutToggle: document.getElementById('layout-toggle'),
    transpileBtn: document.getElementById('transpile-btn'),
    clearTerminal: document.getElementById('clear-terminal'),
    terminalBody: document.getElementById('terminal-body'),
    terminalStatus: document.getElementById('terminal-status'),
    workspacePane: document.querySelector('.workspace-pane'),
    playgroundPanel: document.getElementById('playground-panel'),
    contentPanel: document.getElementById('content-panel'),
    tabButtons: document.querySelectorAll('.tab-btn'),
    tabContents: document.querySelectorAll('.tab-content'),
    flashEditorContainer: document.getElementById('editor-container'),
    zigEditorContainer: document.getElementById('output-container'),
    sidebar: document.getElementById('sidebar'),
    sidebarToggle: document.getElementById('sidebar-toggle'),
    sidebarBackdrop: document.getElementById('sidebar-backdrop'),
    terminalDrawer: document.getElementById('terminal-drawer'),
    terminalHeader: document.getElementById('terminal-header')
};

// Narrow screens get drawer navigation + touch-friendly editor defaults.
const mobileQuery = window.matchMedia('(max-width: 992px)');
const phoneQuery = window.matchMedia('(max-width: 600px)');

// ==========================================================================
// Off-canvas Sidebar (narrow screens)
// ==========================================================================
function setSidebarOpen(open) {
    dom.sidebar.classList.toggle('open', open);
    dom.sidebarBackdrop.classList.toggle('visible', open);
    dom.sidebarToggle.setAttribute('aria-expanded', String(open));
}

function initSidebarDrawer() {
    dom.sidebarToggle.addEventListener('click', () => {
        setSidebarOpen(!dom.sidebar.classList.contains('open'));
    });
    dom.sidebarBackdrop.addEventListener('click', () => setSidebarOpen(false));

    // Leaving the narrow layout: drop the drawer state so the static sidebar shows normally.
    mobileQuery.addEventListener('change', (e) => {
        if (!e.matches) setSidebarOpen(false);
    });
}

// ==========================================================================
// Collapsible Terminal Drawer
// ==========================================================================
function setTerminalCollapsed(collapsed) {
    dom.terminalDrawer.classList.toggle('collapsed', collapsed);
    // Monaco shares the column with the drawer — re-measure after the height transition.
    setTimeout(() => {
        if (state.flashEditor) state.flashEditor.layout();
        if (state.zigEditor) state.zigEditor.layout();
    }, 280);
}

function initTerminalDrawer() {
    dom.terminalHeader.addEventListener('click', (e) => {
        if (e.target.closest('#clear-terminal')) return; // clear button keeps its own action
        setTerminalCollapsed(!dom.terminalDrawer.classList.contains('collapsed'));
    });

    // Phones: start collapsed so the editor gets the vertical space.
    if (phoneQuery.matches) setTerminalCollapsed(true);
}

// ==========================================================================
// Theme and Layout Controls
// ==========================================================================
function initThemeAndLayout() {
    // Theme: 'auto' follows the OS; 'light'/'dark' are manual overrides. Default 'auto'.
    setThemeMode(localStorage.getItem('theme') || 'auto');

    // Cycle auto -> light -> dark -> auto on each click.
    dom.themeToggle.addEventListener('click', () => {
        const cycle = ['auto', 'light', 'dark'];
        const next = cycle[(cycle.indexOf(state.themeMode) + 1) % cycle.length];
        setThemeMode(next);
    });

    // While in 'auto', live-follow the OS theme.
    if (window.matchMedia) {
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
            if (state.themeMode === 'auto') applyResolvedTheme(getSystemTheme());
        });
    }

    // Layout
    const savedLayout = localStorage.getItem('layout') || 'split';
    setLayout(savedLayout);

    dom.layoutToggle.addEventListener('click', () => {
        const layoutModes = ['split', 'reader', 'editor'];
        const nextIndex = (layoutModes.indexOf(state.layout) + 1) % layoutModes.length;
        setLayout(layoutModes[nextIndex]);
    });

    // Tab buttons for Editor/Zig Output switcher
    dom.tabButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');
            switchTab(targetTab);
        });
    });
}

function getSystemTheme() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches
        ? 'light'
        : 'dark';
}

// Set the user's chosen mode, persist it, update the button icon, and apply the result.
function setThemeMode(mode) {
    state.themeMode = mode;
    localStorage.setItem('theme', mode);
    dom.themeToggle.dataset.mode = mode;
    dom.themeToggle.setAttribute('aria-label', `Theme: ${mode} (click to cycle auto/light/dark)`);
    dom.themeToggle.title = `Theme: ${mode}`;
    applyResolvedTheme(mode === 'auto' ? getSystemTheme() : mode);
}

// Apply a concrete 'dark'/'light' theme to the body and Monaco — no persistence.
function applyResolvedTheme(theme) {
    state.theme = theme;

    if (theme === 'dark') {
        document.body.classList.remove('light-theme');
        document.body.classList.add('dark-theme');
    } else {
        document.body.classList.remove('dark-theme');
        document.body.classList.add('light-theme');
    }

    // Update Monaco editor themes if loaded
    if (state.editorLoaded && window.monaco) {
        const monacoTheme = theme === 'dark' ? 'atomo-one-dark' : 'atomo-one-light';
        monaco.editor.setTheme(monacoTheme);
        // Re-colourise the reader's static blocks so they track the new theme.
        highlightFlashBlocks(dom.chapterContent);
    }
}

function setLayout(layout) {
    state.layout = layout;
    localStorage.setItem('layout', layout);

    // Reset layout classes
    dom.workspacePane.classList.remove('reader-only', 'editor-only');

    if (layout === 'reader') {
        dom.workspacePane.classList.add('reader-only');
    } else if (layout === 'editor') {
        dom.workspacePane.classList.add('editor-only');
    }

    // Trigger monaco layout adjustment
    setTimeout(() => {
        if (state.flashEditor) state.flashEditor.layout();
        if (state.zigEditor) state.zigEditor.layout();
    }, 250);
}

function switchTab(tabName) {
    dom.tabButtons.forEach(btn => {
        if (btn.getAttribute('data-tab') === tabName) {
            btn.classList.add('active');
        } else {
            btn.classList.remove('active');
        }
    });

    dom.tabContents.forEach(content => {
        if (content.id === `tab-${tabName}`) {
            content.classList.add('active');
        } else {
            content.classList.remove('active');
        }
    });

    // Trigger editor layout adjustments
    setTimeout(() => {
        if (tabName === 'editor' && state.flashEditor) state.flashEditor.layout();
        if (tabName === 'output' && state.zigEditor) state.zigEditor.layout();
    }, 50);
}

// ==========================================================================
// Monaco Editor Integration & Custom Highlight Definition
// ==========================================================================
function initMonaco() {
    require.config({ paths: { vs: 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.39.0/min/vs' } });
    
    require(['vs/editor/editor.main'], function () {
        // 1. Register a new custom language for Flash
        monaco.languages.register({ id: 'flash' });

        // 2. Define tokens for the Flash language
        monaco.languages.setMonarchTokensProvider('flash', {
            keywords: [
                'use', 'link', 'fn', 'const', 'var', 'export', 'noreturn', 'orelse',
                'try', 'catch', 'defer', 'errdefer', 'struct', 'enum', 'union',
                'if', 'else', 'while', 'for', 'in', 'pub', 'as', 'break', 'continue', 'undefined'
            ],
            typeKeywords: [
                'u8', 'u16', 'u32', 'u64', 'i8', 'i16', 'i32', 'i64', 'usize', 'isize',
                'cstr', 'argv', 'bool', 'void', 'f32', 'f64'
            ],
            operators: [
                '=', '+=', '-=', '*=', '/=', '%=', '==', '!=', '<', '<=', '>', '>=',
                '&&', '||', '!', '&', '|', '^', '<<', '>>', '->', ':=', ':', '::', '.'
            ],
            symbols: /[=><!~?:&|+\-*\/\^%]+/,
            escapes: /\\(?:[abfnrtv\\"']|x[0-9A-Fa-f]{1,4}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})/,
            tokenizer: {
                root: [
                    // Identifiers and keywords
                    [/[a-zA-Z_]\w*/, {
                        cases: {
                            '@keywords': 'keyword',
                            '@typeKeywords': 'type',
                            '@default': 'identifier'
                        }
                    }],
                    // Comments
                    [/\/\/.*$/, 'comment'],
                    // Numbers
                    [/\d+/, 'number'],
                    // Strings
                    [/"([^"\\]|\\.)*"/, 'string'],
                    // Operators and symbols
                    [/@symbols/, {
                        cases: {
                            '@operators': 'operator',
                            '@default': ''
                        }
                    }],
                    // Bracket matches
                    [/[{}()\[\]]/, '@brackets']
                ]
            }
        });

        // 3. Define custom editor themes
        monaco.editor.defineTheme('atomo-one-dark', {
            base: 'vs-dark',
            inherit: true,
            rules: [
                { token: 'keyword', foreground: 'c678dd', fontStyle: 'bold' },
                { token: 'type', foreground: 'e5c07b' },
                { token: 'comment', foreground: '5c6370', fontStyle: 'italic' },
                { token: 'string', foreground: '98c379' },
                { token: 'number', foreground: 'd19a66' },
                { token: 'operator', foreground: '56b6c2' },
                { token: 'identifier', foreground: 'abb2bf' },
                { token: 'delimiter', foreground: 'abb2bf' }
            ],
            colors: {
                'editor.background': '#282c34',
                'editor.foreground': '#abb2bf',
                'editor.lineHighlightBackground': '#2c313c',
                'editorCursor.foreground': '#528bff',
                'editor.selectionBackground': '#3e4451',
                'editorLineNumber.foreground': '#4b5263',
                'editorLineNumber.activeForeground': '#c8ccd4'
            }
        });

        monaco.editor.defineTheme('atomo-one-light', {
            base: 'vs',
            inherit: true,
            rules: [
                { token: 'keyword', foreground: 'a626a4', fontStyle: 'bold' },
                { token: 'type', foreground: 'c18401' },
                { token: 'comment', foreground: 'a0a1a7', fontStyle: 'italic' },
                { token: 'string', foreground: '50a14f' },
                { token: 'number', foreground: '986801' },
                { token: 'operator', foreground: '0184bc' },
                { token: 'identifier', foreground: '383a42' },
                { token: 'delimiter', foreground: '383a42' }
            ],
            colors: {
                'editor.background': '#fafafa',
                'editor.foreground': '#383a42',
                'editor.lineHighlightBackground': '#f0f0f0',
                'editorCursor.foreground': '#526fff',
                'editor.selectionBackground': '#e1e1e1',
                'editorLineNumber.foreground': '#9d9d9f',
                'editorLineNumber.activeForeground': '#383a42'
            }
        });

        // 4. Create Flash editor (editable)
        state.flashEditor = monaco.editor.create(dom.flashEditorContainer, {
            value: `// Select a chapter on the left to load examples\n// Or write your own Flash code here!\n\nuse flibc\n\nexport fn main(_ usize, _ argv) noreturn {\n    msg := "Hello World from Flash!\\n"\n    _ = flibc.sys.write_fd(1, msg.ptr, msg.len)\n    flibc.exit()\n}`,
            language: 'flash',
            theme: state.theme === 'dark' ? 'atomo-one-dark' : 'atomo-one-light',
            automaticLayout: true,
            fontFamily: 'JetBrains Mono, Fira Code, monospace',
            // ≥16px on phones, or iOS auto-zooms the page when the editor gets focus
            fontSize: phoneQuery.matches ? 16 : 13,
            lineHeight: phoneQuery.matches ? 24 : 20,
            minimap: { enabled: false },
            scrollbar: {
                vertical: 'auto',
                horizontal: 'auto'
            }
        });

        // 5. Create Zig editor (read-only)
        state.zigEditor = monaco.editor.create(dom.zigEditorContainer, {
            value: `// Click 'Transpile' to see the lowered Zig output`,
            language: 'rust', // Monaco doesn't have Zig built-in by default, Rust/C highlight matches Zig syntax tags fairly closely
            theme: state.theme === 'dark' ? 'atomo-one-dark' : 'atomo-one-light',
            readOnly: true,
            automaticLayout: true,
            fontFamily: 'JetBrains Mono, Fira Code, monospace',
            fontSize: phoneQuery.matches ? 16 : 13,
            lineHeight: phoneQuery.matches ? 24 : 20,
            minimap: { enabled: false }
        });

        state.editorLoaded = true;
        console.log("Monaco Editors initialized.");

        // The first chapter may have rendered before Monaco was ready — colour
        // its example blocks now that the Flash grammar exists.
        highlightFlashBlocks(dom.chapterContent);
    });
}

// ==========================================================================
// Chapters Loading & Navigation
// ==========================================================================
async function loadChapters() {
    try {
        // chapters.json is a plain static file (relative path), so the chapter
        // list works identically on the dev server and on static hosting.
        const response = await fetch('chapters.json');
        state.chapters = await response.json();
        renderChaptersSidebar();
        
        // Load initial chapter based on URL hash or default to first
        const hash = window.location.hash.substring(1);
        const activeChapterIndex = state.chapters.findIndex(c => c.id === hash);
        
        if (activeChapterIndex !== -1) {
            await selectChapter(activeChapterIndex);
        } else {
            await selectChapter(0);
        }
    } catch (err) {
        console.error("Failed to fetch chapters metadata:", err);
        dom.chaptersList.innerHTML = `<div class="nav-loading">Error loading chapters. Check backend status.</div>`;
    }
}

function renderChaptersSidebar() {
    dom.chaptersList.innerHTML = '';
    state.chapters.forEach((chapter, index) => {
        const button = document.createElement('button');
        button.className = `nav-item ${index === state.currentChapterIndex ? 'active' : ''}`;
        button.textContent = chapter.title;
        button.addEventListener('click', () => {
            selectChapter(index);
        });
        dom.chaptersList.appendChild(button);
    });
}

async function selectChapter(index) {
    if (index < 0 || index >= state.chapters.length) return;
    
    state.currentChapterIndex = index;
    const chapter = state.chapters[index];
    
    // Update active class on sidebar items
    const navItems = dom.chaptersList.querySelectorAll('.nav-item');
    navItems.forEach((item, i) => {
        if (i === index) {
            item.classList.add('active');
        } else {
            item.classList.remove('active');
        }
    });

    // Update Prev/Next buttons
    dom.prevBtn.disabled = index === 0;
    dom.nextBtn.disabled = index === state.chapters.length - 1;

    // Narrow screens: picking a chapter closes the drawer so content is readable.
    if (mobileQuery.matches) setSidebarOpen(false);

    // Update URL hash
    window.location.hash = chapter.id;

    // Fetch and render markdown content
    dom.chapterContent.innerHTML = `
        <div class="content-loading">
            <div class="spinner"></div>
            <p>Loading chapter: ${chapter.title}...</p>
        </div>
    `;

    try {
        const response = await fetch(chapter.file);
        if (!response.ok) throw new Error(`Status: ${response.status}`);
        const markdown = await response.text();
        
        // Configure marked options
        marked.setOptions({
            gfm: true,
            breaks: true
        });

        // Set custom marked renderer to detect code blocks and output example blocks
        const renderer = new marked.Renderer();
        let codeBlockCounter = 0;
        
        renderer.code = function(codeOrToken, language) {
            let codeText = "";
            let lang = "";

            // Handle token parameter as object (marked v11+) or string (marked <v11)
            if (codeOrToken && typeof codeOrToken === 'object') {
                codeText = codeOrToken.text || "";
                lang = codeOrToken.lang || "";
            } else {
                codeText = codeOrToken || "";
                lang = language || "";
            }

            if (lang === 'flash' || lang === 'go') {
                codeBlockCounter++;
                const escapedCode = codeText
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;')
                    .replace(/'/g, '&#039;');

                return `
                    <div class="example-card">
                        <div class="example-header">
                            <span class="example-title">Example ${codeBlockCounter}</span>
                            <button class="load-example-btn" data-code="${escapedCode}">
                                <i data-lucide="terminal" style="width:12px; height:12px;"></i> Try in Editor
                            </button>
                        </div>
                        <pre><code class="language-flash">${escapedCode}</code></pre>
                    </div>
                `;
            }
            return `<pre><code class="language-${lang || 'text'}">${codeText}</code></pre>`;
        };

        renderer.blockquote = function(token) {
            let text = "";
            let htmlContent = "";

            // Handle token parameter as object (marked v11+) or string (marked <v11)
            if (token && typeof token === 'object') {
                text = token.text || "";
                htmlContent = this.parser.parse(token.tokens);
            } else {
                text = token || "";
                htmlContent = token || "";
            }

            let quoteText = text.trim();

            let alertType = null;
            let titleText = 'NOTE';
            let calloutClass = 'callout-note';

            if (quoteText.includes('[!NOTE]')) {
                alertType = 'note';
                titleText = 'NOTE';
                calloutClass = 'callout-note';
            } else if (quoteText.includes('[!TIP]')) {
                alertType = 'tip';
                titleText = 'TIP';
                calloutClass = 'callout-tip';
            } else if (quoteText.includes('[!WARNING]')) {
                alertType = 'warning';
                titleText = 'WARNING';
                calloutClass = 'callout-warning';
            } else if (quoteText.includes('[!CAUTION]')) {
                alertType = 'caution';
                titleText = 'CAUTION';
                calloutClass = 'callout-warning';
            } else if (quoteText.includes('[!IMPORTANT]')) {
                alertType = 'important';
                titleText = 'IMPORTANT';
                calloutClass = 'callout-note';
            }

            if (alertType) {
                let innerHtml = htmlContent;
                innerHtml = innerHtml.replace(/\[![A-Z]+\]/i, '');
                innerHtml = innerHtml.replace(/<p>\s*(?:<br\s*\/?>)?\s*/i, '<p>');
                return `
                    <div class="callout ${calloutClass}">
                        <div class="callout-title">${titleText}</div>
                        ${innerHtml}
                    </div>
                `;
            }

            return `<blockquote>${htmlContent}</blockquote>`;
        };

        dom.chapterContent.innerHTML = marked.parse(markdown, { renderer });

        // Re-run lucide icons rendering
        lucide.createIcons();

        // Syntax-highlight the static Flash example blocks (no-op until Monaco
        // is ready; initMonaco re-runs this for the first-loaded chapter).
        highlightFlashBlocks(dom.chapterContent);
        
        // Bind load events to the dynamically generated "Try in Editor" buttons
        dom.chapterContent.querySelectorAll('.load-example-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const code = btn.getAttribute('data-code')
                    .replace(/&amp;/g, '&')
                    .replace(/&lt;/g, '<')
                    .replace(/&gt;/g, '>')
                    .replace(/&quot;/g, '"')
                    .replace(/&#039;/g, "'");
                
                loadCodeIntoEditor(code);
            });
        });

        // Scroll reader panel back to top
        dom.contentPanel.querySelector('.content-body').scrollTop = 0;

    } catch (err) {
        console.error("Failed to load chapter file:", err);
        dom.chapterContent.innerHTML = `
            <div class="callout callout-warning">
                <div class="callout-title">Error Loading Content</div>
                <p>Could not load the markdown documentation for this chapter. Make sure the file exists under <code>public/${chapter.file}</code>.</p>
                <p style="font-size: 12px; color: var(--text-muted); margin-top: 10px;">Details: ${err.message}</p>
            </div>
        `;
    }
}

function loadCodeIntoEditor(code) {
    if (state.flashEditor) {
        state.flashEditor.setValue(code.trim());
        logTerminal("Loaded example code into Flash Editor.", "info");

        if (phoneQuery.matches) {
            // Phones: a stacked split leaves the editor a sliver — go editor-only.
            setLayout('editor');
        } else if (state.layout === 'reader') {
            // If the layout is 'reader-only', expand to 'split' so the user can see the editor
            setLayout('split');
        }

        // Focus on the editor tab
        switchTab('editor');
    }
}

// ==========================================================================
// Static Code-Block Highlighting (reader pane)
// --------------------------------------------------------------------------
// Reuse the Flash grammar already registered with Monaco (Monarch tokenizer +
// the One Dark / One Light themes) to colourise the example <pre> blocks in
// the reader, so reader and editor highlight identically — no extra grammar
// or wasm in the browser. Re-run on theme switch so colours track the theme.
async function highlightFlashBlocks(root) {
    if (!(state.editorLoaded && window.monaco)) return;
    const scope = root || document;
    const blocks = scope.querySelectorAll('pre code.language-flash, pre code.language-go');
    for (const code of blocks) {
        // Stash the original source the first time so re-highlights start from
        // plain text, not already-colourised markup.
        if (code.dataset.raw === undefined) code.dataset.raw = code.textContent;
        try {
            code.innerHTML = await monaco.editor.colorize(code.dataset.raw, 'flash', { tabSize: 4 });
        } catch (err) {
            console.warn('Flash highlight failed:', err);
        }
    }
}

// ==========================================================================
// Transpiler API Pipeline Integration
// ==========================================================================
// One-line notice shown whenever the transpile backend is absent (static build).
function logStaticNotice() {
    logTerminal(
        "Static build — reading chapters and loading examples into the editor work, " +
        "but live transpilation needs the local dev server.\n" +
        "Clone https://github.com/ajhahnde/Flash and run `npm start` in tutorial/.",
        "warning"
    );
}

async function runTranspilation() {
    if (!state.flashEditor) return;

    if (!state.backend) {
        updateTerminalStatus('idle', 'Static');
        logStaticNotice();
        return;
    }

    const code = state.flashEditor.getValue();
    
    updateTerminalStatus('transpiling', 'Transpiling...');
    logTerminal("Invoking compiler backend...", "info");

    try {
        const response = await fetch('/api/transpile', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ code })
        });

        const result = await response.json();

        if (result.success) {
            // Update output editor
            if (state.zigEditor) {
                state.zigEditor.setValue(result.output || '// Empty output.');
            }
            
            // Switch view to output
            switchTab('output');
            
            // Log status
            updateTerminalStatus('success', 'Success');
            
            let logMsg = "Transpilation succeeded.\n";
            if (result.error) {
                logMsg += `\nCompiler Warnings:\n${result.error}`;
                logTerminal(logMsg, "warning");
            } else {
                logTerminal(logMsg + "No compiler errors or warnings.", "success");
            }
            
        } else {
            // Transpilation failed (compiler returned non-zero code)
            updateTerminalStatus('error', 'Compiler Error');
            logTerminal(`Compiler Execution Failed:\n\n${result.error}`, "error");
            
            // Focus on terminal drawer if hidden/small
            console.warn("Compilation failed. Visual logs added to terminal drawer.");
        }

    } catch (err) {
        console.error("Transpilation API call failed:", err);
        updateTerminalStatus('error', 'Network Error');
        logTerminal(`HTTP network error while communicating with backend: ${err.message}\nEnsure the local server is running on http://localhost:3000.`, "error");
    }
}

// ==========================================================================
// Terminal Drawer Logger Utilities
// ==========================================================================
function logTerminal(message, type = 'info') {
    dom.terminalBody.classList.remove('log-error', 'log-success', 'log-warning');
    
    const timestamp = new Date().toLocaleTimeString();
    const prefix = `[${timestamp}] `;
    
    dom.terminalBody.innerText = prefix + message;

    if (type === 'error') {
        dom.terminalBody.classList.add('log-error');
    } else if (type === 'success') {
        dom.terminalBody.classList.add('log-success');
    } else if (type === 'warning') {
        dom.terminalBody.classList.add('log-warning');
    }

    // Errors and warnings must be readable — pop the drawer open if collapsed.
    if ((type === 'error' || type === 'warning') && dom.terminalDrawer.classList.contains('collapsed')) {
        setTerminalCollapsed(false);
    }
}

function updateTerminalStatus(statusClass, label) {
    dom.terminalStatus.className = `status-indicator ${statusClass}`;
    dom.terminalStatus.textContent = label;
}

// ==========================================================================
// Initialization
// ==========================================================================
document.addEventListener('DOMContentLoaded', () => {
    // 0. Probe the transpile backend once; static hosting (GitHub Pages) has none.
    fetch('/api/chapters')
        .then(r => { state.backend = r.ok; })
        .catch(() => { state.backend = false; })
        .finally(() => {
            if (!state.backend) {
                updateTerminalStatus('idle', 'Static');
                logStaticNotice();
            }
        });

    // 1. Initialize icons
    lucide.createIcons();

    // 2. Initialize UI configuration (Themes & layout)
    initThemeAndLayout();
    initSidebarDrawer();
    initTerminalDrawer();

    // 3. Load Monaco Code Editors
    initMonaco();

    // 4. Fetch chapters navigation list
    loadChapters();

    // 5. Bind action buttons
    dom.transpileBtn.addEventListener('click', runTranspilation);
    
    dom.clearTerminal.addEventListener('click', () => {
        dom.terminalBody.innerHTML = 'Terminal cleared.';
        updateTerminalStatus('idle', 'Idle');
    });

    dom.prevBtn.addEventListener('click', () => {
        if (state.currentChapterIndex > 0) {
            selectChapter(state.currentChapterIndex - 1);
        }
    });

    dom.nextBtn.addEventListener('click', () => {
        if (state.currentChapterIndex < state.chapters.length - 1) {
            selectChapter(state.currentChapterIndex + 1);
        }
    });

    // Handle back/forward history navigation via hash change
    window.addEventListener('hashchange', () => {
        const hash = window.location.hash.substring(1);
        const activeChapterIndex = state.chapters.findIndex(c => c.id === hash);
        if (activeChapterIndex !== -1 && activeChapterIndex !== state.currentChapterIndex) {
            selectChapter(activeChapterIndex);
        }
    });
});


import express from 'express';
import { execFile } from 'child_process';
import { promises as fs, watch } from 'fs';
import path from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;
const LIVE_RELOAD = process.env.TUTORIAL_LIVE_RELOAD === '1';

// Path to the flashc compiler built in the Flash workspace. FlashOS itself
// consumes a pinned compiler revision (see flash-toolchain.lock), so the
// default points at the sibling Flash checkout. The tutorial requests the Zig
// compatibility backend as a readable lab/test view. FlashOS production
// artifacts are compiled through flashc's native LLVM path.
const COMPILER_PATH = process.env.FLASHC
  || path.join(homedir(), 'Flash', 'zig-out', 'bin', 'flashc');
const TEMP_DIR = path.join(__dirname, 'temp');
const PUBLIC_DIR = path.join(__dirname, 'public');

// Middleware
app.use(express.json({ limit: '128kb' }));
app.use(express.static(PUBLIC_DIR));

// Ensure temp directory exists
async function ensureTempDir() {
  try {
    await fs.mkdir(TEMP_DIR, { recursive: true });
  } catch (err) {
    console.error('Failed to create temp directory:', err);
  }
}
ensureTempDir();

// API: Lower a small Flash lab through the test-only compatibility backend.
app.post('/api/transpile', async (req, res) => {
  const { code } = req.body;

  if (typeof code !== 'string') {
    return res.status(400).json({
      success: false,
      error: 'Code must be a string.',
    });
  }

  if (Buffer.byteLength(code, 'utf8') > 64 * 1024) {
    return res.status(413).json({
      success: false,
      error: 'Example is too large (64 KiB maximum).',
    });
  }

  // Create unique filename to avoid collision if multiple requests arrive
  const tempFileName = `try_${Date.now()}_${Math.random().toString(36).substring(2, 9)}.flash`;
  const tempFilePath = path.join(TEMP_DIR, tempFileName);

  try {
    // Write temporary Flash source file
    await fs.writeFile(tempFilePath, code, 'utf-8');

    // Use execFile rather than a shell: compiler paths and generated temp names
    // are passed as arguments, never interpreted as commands.
    execFile(COMPILER_PATH, ['--backend=zig', tempFilePath], {
      timeout: 15_000,
      maxBuffer: 2 * 1024 * 1024,
    }, async (error, stdout, stderr) => {
      // Clean up the temp file
      try {
        await fs.unlink(tempFilePath);
      } catch (unlinkErr) {
        console.error('Failed to clean up temp file:', unlinkErr);
      }

      if (error) {
        // compiler returned exit code != 0, return compilation errors from stderr
        return res.json({
          success: false,
          output: stdout,
          error: stderr || error.message,
        });
      }

      // Transpilation succeeded
      res.json({
        success: true,
        output: stdout,
        error: stderr, // might contain warnings
      });
    });

  } catch (err) {
    console.error('Transpilation error:', err);
    res.status(500).json({
      success: false,
      error: `Internal Server Error: ${err.message}`,
    });
  }
});

// API: Get available chapters
app.get('/api/chapters', async (req, res) => {
  const chaptersPath = path.join(__dirname, 'public', 'chapters.json');
  try {
    const data = await fs.readFile(chaptersPath, 'utf-8');
    res.json(JSON.parse(data));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read chapters metadata' });
  }
});

// ---------------------------------------------------------------------------
// Live reload (dev): a Server-Sent Events stream that fires whenever anything
// under public/ changes. The client (index.html) opens an EventSource to this
// endpoint and reloads the page on each message. Zero dependencies — uses the
// built-in fs.watch and the browser's native EventSource.
// ---------------------------------------------------------------------------
const liveClients = new Set();

app.get('/api/config', (_req, res) => {
  res.json({ liveReload: LIVE_RELOAD });
});

app.get('/api/livereload', (req, res) => {
  if (!LIVE_RELOAD) return res.sendStatus(404);

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  res.write('retry: 1000\n\n'); // tell EventSource to auto-reconnect after 1s
  liveClients.add(res);
  req.on('close', () => liveClients.delete(res));
});

// Watch public/ recursively (macOS supports recursive fs.watch). Debounce the
// burst of events an editor emits on a single save, then notify every browser.
if (LIVE_RELOAD) {
  let reloadTimer = null;
  const publicWatcher = watch(PUBLIC_DIR, { recursive: true }, () => {
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(() => {
      for (const res of liveClients) res.write('data: reload\n\n');
    }, 100);
  });
  publicWatcher.on('error', (err) => {
    console.warn(`Live reload disabled: ${err.message}`);
    publicWatcher.close();
  });
}

app.listen(PORT, 'localhost', () => {
  console.log(`FlashOS Tutorial running at http://localhost:${PORT}`);
});

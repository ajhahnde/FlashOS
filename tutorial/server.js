import express from 'express';
import { exec } from 'child_process';
import { promises as fs, watch } from 'fs';
import path from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

// Path to the flashc compiler built in the Flash workspace. FlashOS itself
// doesn't vendor a compiler build (it consumes flashc via a pinned commit,
// see flash-toolchain.lock), so the default points at the sibling Flash repo.
// Since Flash v1.0.1, the pinned checkout's `zig build` installs the live,
// self-hosted compiler as `flashc`. The lab pins `--backend=zig` because
// that is the bootstrap mode FlashOS's own build currently consumes —
// flag-less flashc now builds a native host binary instead of printing
// anything to stdout.
const COMPILER_PATH = process.env.FLASHC
  || path.join(homedir(), 'Flash', 'zig-out', 'bin', 'flashc');
const TEMP_DIR = path.join(__dirname, 'temp');
const PUBLIC_DIR = path.join(__dirname, 'public');

// Middleware
app.use(express.json());
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

// API: Transpile Flash code to Zig
app.post('/api/transpile', async (req, res) => {
  const { code } = req.body;

  if (typeof code !== 'string') {
    return res.status(400).json({
      success: false,
      error: 'Code must be a string.',
    });
  }

  // Create unique filename to avoid collision if multiple requests arrive
  const tempFileName = `try_${Date.now()}_${Math.random().toString(36).substring(2, 9)}.flash`;
  const tempFilePath = path.join(TEMP_DIR, tempFileName);

  try {
    // Write temporary Flash source file
    await fs.writeFile(tempFilePath, code, 'utf-8');

    // Run the local flashc compiler
    // We run it and capture output
    exec(`"${COMPILER_PATH}" --backend=zig "${tempFilePath}"`, async (error, stdout, stderr) => {
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

app.get('/api/livereload', (req, res) => {
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
let reloadTimer = null;
watch(PUBLIC_DIR, { recursive: true }, () => {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(() => {
    for (const res of liveClients) res.write('data: reload\n\n');
  }, 100);
});

app.listen(PORT, 'localhost', () => {
  console.log(`FlashOS Tutorial running at http://localhost:${PORT}`);
});

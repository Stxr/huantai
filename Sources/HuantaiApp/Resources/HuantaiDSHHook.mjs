// Passive Cordis observer: runs on official DSH CLI and desktop profiles.
// Writes only lifecycle identifiers; never reads prompts, replies, tools or credentials.
import { readFileSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

export const name = 'huantai-task-sounds';

export function apply(ctx, config) {
  const runtime = join(config.stateDirectory, 'codex-hooks');
  ctx.on('session/event', (session, event) => {
    if (event.type !== 'turn/start' && event.type !== 'turn/end') return;
    // Subagent runs are part of their parent task, not separate user notifications.
    if (session.header?.parentSession || session.header?.delegationDepth > 0) return;
    const turn = event.data?.turn;
    if (!Number.isSafeInteger(turn) || turn < 1 || typeof session.id !== 'string') return;
    let state;
    if (event.type === 'turn/start') state = 'started';
    else if (event.data?.reason?.kind === 'completed') state = 'completed';
    else if (['error', 'blocked', 'max-tokens'].includes(event.data?.reason?.kind)) state = 'failed';
    else return; // Manual cancellation and repaired historical interruptions are silent.
    try {
      const settings = JSON.parse(readFileSync(join(runtime, 'settings.json'), 'utf8'));
      if (!settings.enabled || !settings.deepSeekHarnessHome ||
          resolve(settings.deepSeekHarnessHome) !== resolve(config.harnessHome)) return;
      const pending = join(runtime, 'pending');
      mkdirSync(pending, { recursive: true });
      const destination = join(pending, randomUUID() + '.json');
      const signal = JSON.stringify({ source: 'deepSeekHarness', home: resolve(config.harnessHome),
        session: session.id, turn, state, created: Date.now() / 1000 });
      writeFileSync(destination + '.tmp', signal, { mode: 0o600 });
      renameSync(destination + '.tmp', destination);
    } catch { /* Notification failures never affect the agent's task. */ }
  });
}
